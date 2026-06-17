-- Bindings for the active hacking minigame (app.PuzzleSnake).
--
-- Public API:
--   M.is_active() -> bool
--       true while a hacking grid is live (between _StartTrg and a
--       success/failure/reset edge).
--   M.read_trigger(name) -> bool
--       Read a single edge-trigger boolean field on the cached instance.
--       Used by the lifecycle observer.
--   M.get_state() -> nil | {
--       width, height,
--       cursor = {x, y},                  -- the moving "snake head"
--       start  = {x, y},
--       goal   = {x, y},
--       cells  = { [y+1] = { [x+1] = { type, type_hash, in_trail, is_erase, ... } } },
--       trail  = { {x, y}, ... },         -- ordered, oldest first (best-effort)
--       finished = bool,
--       success  = bool,
--   }
--   M.move(direction) -> ok, message
--       Move the cursor one cell in `direction` ("up"|"down"|"left"|"right").
--       Wraps `app.PuzzleSnake.Unit.move(via.Int2)` with absolute-target
--       semantics (see Move dispatch section).
--   M.can_move(direction) -> ok, message
--       Pre-validate whether moving would land on a reachable cell.
--   M.queue_plan(directions) / M.clear_plan() / M.tick_plan()
--       Dispatch a sequence of moves with proper inter-cell pacing. Wire
--       M.tick_plan into pragmata_main.lua's re.on_frame loop.
--   M.try_set_request_force_success() -> ok, message
--       Write `_RequestForceSuccess = true` on the active PuzzleSnake. The
--       engine polls this field each tick and runs the full natural
--       completion flow (COMPLETE overlay, hack damage commit, dialogue
--       progression, auto-reset). Called by tick_plan on goal arrival.
--
-- Engine layout (verified against the IL2CPP dump):
--   app.PuzzleSnake (instance per active hack):
--     - _StartTrg, _SuccessTrigger, _FailedTrigger, _ResetTrg, _GridResetRequest,
--       _GridChangeStartTrg, _GridChangeEndTrg  (boolean edge fields)
--     - _RequestForceSuccess                     (boolean polled by engine)
--     - _CurrentUnit (app.PuzzleSnake.Unit)      -- the cursor / snake head
--     - _GridAccessor (app.PuzzleSnake.GridAccessor)
--   app.PuzzleSnake.GridAccessor:
--     - get_GRID_ACTUAL_SIZE_X / _Y              -- current grid dimensions
--     - getStartPos() -> via.Int2                -- spawn cell coord
--     - _GridController._ActualGrid              -- jagged Grid[][] of cells
--   app.PuzzleSnake.Grid (per-cell):
--     - _GridPosition (via.Int2)                 -- (x, y) coord
--     - _GridType (UInt32)                       -- hash; resolved via PuzzleSnakeGridType.getName.
--       Semantics verified against in-game footage: None = plain walkable
--       floor (most cells); Open = the visible BLUE bonus node.
--     - <IsPassed>k__BackingField                -- has the cursor crossed (= trail)
--     - <IsEraseCode>k__BackingField             -- is this the trap node
--     - <IsSkipRow>/<IsSkipCol>k__BackingField   -- row/col currently REMOVED by a
--       sticky bomb. Dimensions never change for this; GridAccessor keeps the
--       skip index lists (get_SkipRow/get_SkipCol) and restores via
--       expansionRow/expansionCol as bombs wear off. get_state() compacts
--       skipped rows/cols out of the snapshot.
--     - _ObstacleReasons (UInt32)                -- red "error node" marker (VERIFIED
--       in-game 2026-06-10). NOT a _GridType: affected cells read as plain None
--       with a bit set here. Bitmask of app.PuzzleSnake.ObstacleReason:
--       ObstacleGrid=1 (the red warning-triangle nodes), DeadFilament=2,
--       Ch16092=4, Ch14100=8, AllPassed=16. Nonzero => cell currently blocked.
--     - _DeadFilamentType (UInt32)               -- app.DeadFilamentType hash
--       (None | Random | Fixed). Observed 0/None on standard grids; likely only
--       authored for dead-filament boss content. Read + surfaced anyway.

local log = require("pragmata.util.log")

local M = {}

-- ---------------------------------------------------------------------------
-- Cached SDK lookups
-- ---------------------------------------------------------------------------

local _sdk = {
    inited = false,
    snake_td = nil,          -- app.PuzzleSnake
    grid_accessor_td = nil,  -- app.PuzzleSnake.GridAccessor
    grid_cell_td = nil,      -- app.PuzzleSnake.Grid (per-cell type)
    unit_td = nil,           -- app.PuzzleSnake.Unit
    grid_type_td = nil,      -- app.PuzzleSnakeGridType (for getName)
    df_type_td = nil,        -- app.DeadFilamentType (for getName)
    hacking_mgr_td = nil,    -- app.HackingManager
    m_get_size_x = nil,
    m_get_size_y = nil,
    m_get_start_pos = nil,
    m_unit_get_position = nil,
    m_unit_move = nil,
    m_unit_can_reach = nil,
    m_unit_get_is_move = nil,
    m_get_name = nil,
    m_get_df_name = nil,
    m_get_is_jamming = nil,
}

-- All PuzzleSnake instances we've observed via hooks. The engine keeps one
-- alive per hackable enemy in the level, so we can't pick a single "active"
-- one — instead we collect every instance the hooks fire on and pick the
-- right one at lookup time using HackingManager.LastHackingTarget as the
-- discriminator. (Earlier attempts to filter by `_GuiHandle` or other
-- per-instance flags fail because every enemy's puzzle has them set.)
local _known_instances = {}

-- Track init outcomes for the debug panel.
local _init_report = {
    snake_td        = false,
    accessor_td     = false,
    cell_td         = false,
    unit_td         = false,
    grid_type_td    = false,
    df_type_td      = false,
    m_get_size_x    = false,
    m_get_size_y    = false,
    m_get_start     = false,
    m_get_name      = false,
    m_get_df_name   = false,
    m_unit_move     = false,
    m_unit_can_reach = false,
    m_unit_get_is_move = false,
    ctor_hook       = "not attempted",
    update_hook     = "not attempted",
}

-- Track instance-discovery activity. The ring buffer feeds the debug panel
-- so the user can see recent events without tailing the log file.
local _discovery_log = {}
local function log_discovery(line)
    table.insert(_discovery_log, line)
    if #_discovery_log > 20 then table.remove(_discovery_log, 1) end
end


-- Each tracked entry is a RECORD, not a bare instance:
--   { id = <stable int>, inst = <PuzzleSnake>, plan = <plan table | nil>,
--     forced_struct = <structural signature we last forced against | nil>,
--     forced_cursor = <cursor {x,y} we last forced against | nil> }
-- The id is a stable, neutral handle the observer uses to track "which
-- puzzle" without ever seeing an engine object. Per-puzzle plan + force
-- state lives ON the record, so a swept (destroyed) enemy's queued moves
-- are garbage-collected with it — no separate cleanup, no leak.
local _next_instance_id = 1

-- Sweep dead handles. Managed-object handles become invalid when the engine
-- destroys them; get_type_definition() is the cheapest liveness probe.
local function _sweep_dead_instances()
    for i = #_known_instances, 1, -1 do
        local existing = _known_instances[i]
        local ok = pcall(function() return existing.inst:get_type_definition() end)
        if not ok then
            table.remove(_known_instances, i)
            log_discovery("dropped dead instance (remaining=" .. #_known_instances .. ")")
        end
    end
end

-- Add `inst` to the known-instances set. Hooks call this; lookup is later.
local function _track_instance(inst, source)
    if inst == nil then return end

    for i = #_known_instances, 1, -1 do
        local existing = _known_instances[i]
        if existing.inst == inst then
            return  -- already tracked
        end
    end
    _sweep_dead_instances()

    local rec = {
        id = _next_instance_id,
        inst = inst,
        plan = nil,
        forced_struct = nil,
        forced_cursor = nil,
    }
    _next_instance_id = _next_instance_id + 1
    table.insert(_known_instances, rec)
    log_discovery("instance tracked via " .. source
               .. " (id=" .. rec.id .. ", total=" .. #_known_instances .. ")")
end


-- Resolve the singleton HackingManager. Cached after first success.
local _hacking_mgr = nil
local function _get_hacking_manager()
    if _hacking_mgr ~= nil then
        local ok = pcall(function() return _hacking_mgr:get_type_definition() end)
        if ok then return _hacking_mgr end
        _hacking_mgr = nil
    end
    local ok, mgr = pcall(function()
        return sdk.get_managed_singleton("app.HackingManager")
    end)
    if ok and mgr ~= nil then
        _hacking_mgr = mgr
    end
    return _hacking_mgr
end


-- Returns (target_unit, is_targeted) where target_unit is the PuzzleUnit
-- that HackingManager currently considers the hacking target, or nil if no
-- enemy is currently being aimed at. The is_targeted flag distinguishes
-- "no current target" from "target set but stale" — when false, callers
-- should treat the answer as "no active puzzle" regardless of target.
local function _resolve_target_unit()
    local mgr = _get_hacking_manager()
    if mgr == nil then return nil, false end

    local is_targeted = false
    local ok_t, t = pcall(function()
        return mgr:get_field("<IsTargetedEnemy>k__BackingField")
    end)
    if ok_t and t == true then is_targeted = true end

    local target = nil
    local ok_l, l = pcall(function()
        return mgr:get_field("<LastHackingTarget>k__BackingField")
    end)
    if ok_l then target = l end

    return target, is_targeted
end


local function ensure_init()
    if _sdk.inited then return _sdk.snake_td ~= nil end
    _sdk.inited = true

    local function td(name)
        local ok, v = pcall(function() return sdk.find_type_definition(name) end)
        if ok and v ~= nil then return v end
        return nil
    end
    local function method(td_obj, sig)
        if td_obj == nil then return nil end
        local ok, v = pcall(function() return td_obj:get_method(sig) end)
        if ok and v ~= nil then return v end
        return nil
    end

    _sdk.snake_td         = td("app.PuzzleSnake")
    _sdk.grid_accessor_td = td("app.PuzzleSnake.GridAccessor")
    _sdk.grid_cell_td     = td("app.PuzzleSnake.Grid")
    _sdk.unit_td          = td("app.PuzzleSnake.Unit")
    _sdk.grid_type_td     = td("app.PuzzleSnakeGridType")
    _sdk.df_type_td       = td("app.DeadFilamentType")
    _sdk.hacking_mgr_td   = td("app.HackingManager")

    _init_report.snake_td     = _sdk.snake_td ~= nil
    _init_report.accessor_td  = _sdk.grid_accessor_td ~= nil
    _init_report.cell_td      = _sdk.grid_cell_td ~= nil
    _init_report.unit_td      = _sdk.unit_td ~= nil
    _init_report.grid_type_td = _sdk.grid_type_td ~= nil
    _init_report.df_type_td   = _sdk.df_type_td ~= nil

    if _sdk.snake_td == nil then
        log.warn("puzzle_snake: app.PuzzleSnake type def not found; binding disabled")
        return false
    end

    _sdk.m_get_size_x        = method(_sdk.grid_accessor_td, "get_GRID_ACTUAL_SIZE_X")
    _sdk.m_get_size_y        = method(_sdk.grid_accessor_td, "get_GRID_ACTUAL_SIZE_Y")
    _sdk.m_get_start_pos     = method(_sdk.grid_accessor_td, "getStartPos")
    _sdk.m_unit_get_position = method(_sdk.unit_td, "get_Position()")
    _sdk.m_unit_move         = method(_sdk.unit_td, "move(via.Int2)")
    _sdk.m_unit_can_reach    = method(_sdk.unit_td, "canReachStraight(via.Int2)")
    _sdk.m_unit_get_is_move  = method(_sdk.unit_td, "get_isMove")
    _sdk.m_get_name          = method(_sdk.grid_type_td, "getName(System.UInt32)")
    _sdk.m_get_df_name       = method(_sdk.df_type_td, "getName(System.UInt32)")
    _sdk.m_get_is_jamming    = method(_sdk.hacking_mgr_td, "get_IsJamming()")

    _init_report.m_get_size_x       = _sdk.m_get_size_x       ~= nil
    _init_report.m_get_size_y       = _sdk.m_get_size_y       ~= nil
    _init_report.m_get_start        = _sdk.m_get_start_pos    ~= nil
    _init_report.m_get_name         = _sdk.m_get_name         ~= nil
    _init_report.m_get_df_name      = _sdk.m_get_df_name      ~= nil
    _init_report.m_unit_move        = _sdk.m_unit_move        ~= nil
    _init_report.m_unit_can_reach   = _sdk.m_unit_can_reach   ~= nil
    _init_report.m_unit_get_is_move = _sdk.m_unit_get_is_move ~= nil

    -- Two instance-discovery paths feed _track_instance. The engine keeps
    -- one PuzzleSnake per hackable enemy in the level — both hooks simply
    -- ADD to a known-instances set rather than trying to pick "the" current
    -- one. Lookup-time discrimination via HackingManager.LastHackingTarget
    -- does that job.

    -- Hook the constructor. Catches NEW instances on creation.
    local ctor_method = _sdk.snake_td:get_method(".ctor")
    if ctor_method ~= nil then
        local ok, err = pcall(function()
            sdk.hook(
                ctor_method,
                function(args)
                    -- pre-hook: capture `this` while it's still alive in args[2]
                    local ok_t, inst = pcall(function() return sdk.to_managed_object(args[2]) end)
                    if ok_t and inst ~= nil then
                        _track_instance(inst, ".ctor")
                    end
                end,
                function(retval) return retval end
            )
        end)
        _init_report.ctor_hook = ok and "installed" or ("failed: " .. tostring(err))
    else
        _init_report.ctor_hook = "ctor method not resolvable"
    end

    -- Hook a periodic update method. Picks up instances the ctor hook missed
    -- (mod loaded after puzzle creation, instance pooled across hacks, etc.).
    -- Firing for every ticked instance is fine here — _track_instance dedupes.
    local update_method = method(_sdk.snake_td, "update()")
                       or method(_sdk.snake_td, "lateUpdate()")
                       or method(_sdk.snake_td, "doUpdate()")
                       or method(_sdk.snake_td, "doLateUpdate()")
                       or method(_sdk.snake_td, "onUpdate()")
    if update_method ~= nil then
        local ok, err = pcall(function()
            sdk.hook(
                update_method,
                function(args)
                    local ok_t, inst = pcall(function() return sdk.to_managed_object(args[2]) end)
                    if ok_t and inst ~= nil then
                        _track_instance(inst, "update hook")
                    end
                end,
                function(retval) return retval end
            )
        end)
        _init_report.update_hook = ok and "installed" or ("failed: " .. tostring(err))
    else
        _init_report.update_hook = "no update method resolvable"
    end

    return true
end


-- ---------------------------------------------------------------------------
-- Instance lookup
-- ---------------------------------------------------------------------------
-- Returns the PuzzleSnake whose target PuzzleUnit matches HackingManager's
-- current LastHackingTarget, or nil if no enemy is being aimed at (or no
-- known instance corresponds to the target).
--
-- This is the linchpin of the multi-instance design: every enemy in the
-- level has its own PuzzleSnake with its own GUI handle and trigger fields,
-- so any per-instance "is this the active one" check is unreliable. The
-- HackingManager singleton tracks which enemy the player is currently
-- aimed at; we match that against PuzzleBase._TargetPuzzleUnit on each
-- candidate.

-- Return the RECORD of the PuzzleSnake currently matched to the player's
-- aim (LastHackingTarget), or nil. This is the matched puzzle regardless of
-- whether its triggers say it's ending — callers that need "on screen and
-- not ending" use is_active()/is_interactive() on top.
local function _get_current_record()
    if not ensure_init() then return nil end

    -- Garbage-collect dead handles before the lookup, so a stale entry
    -- doesn't shadow a live one that happens to share a target reference.
    _sweep_dead_instances()

    -- Look up the most recently targeted enemy. We don't gate on
    -- `IsTargetedEnemy` — observed in testing, that bool means something
    -- narrower than "the player is currently aimed at an enemy" (likely
    -- "actively in the hack-input phase"). LastHackingTarget is set
    -- whenever the player has aimed at any hackable enemy in the level,
    -- which is the lookup we want. The "is this puzzle currently on
    -- screen" check happens in is_active() via the matched instance's
    -- _GuiHandle.
    local target_unit, _is_targeted = _resolve_target_unit()
    if target_unit == nil then return nil end

    -- Find the PuzzleSnake whose _TargetPuzzleUnit (inherited from
    -- PuzzleBase) is the targeted enemy. == on managed-object handles is
    -- reference equality, which is what we want.
    for _, rec in ipairs(_known_instances) do
        local ok, this_target = pcall(function()
            return rec.inst:get_field("_TargetPuzzleUnit")
        end)
        if ok and this_target == target_unit then
            return rec
        end
    end

    return nil
end


local function get_instance()
    local rec = _get_current_record()
    if rec == nil then return nil end
    return rec.inst
end


-- Find a record by its stable id (linear scan; instance count per level is
-- small). Returns nil if that puzzle has been swept (enemy destroyed).
local function _record_by_id(id)
    for _, rec in ipairs(_known_instances) do
        if rec.id == id then return rec end
    end
    return nil
end


-- Read a Boolean field, returning a default if unreadable.
local function read_bool(inst, field_name, default)
    if inst == nil then return default end
    local ok, v = pcall(function() return inst:get_field(field_name) end)
    if not ok then return default end
    if v == true then return true end
    if v == false then return false end
    return default
end


-- ---------------------------------------------------------------------------
-- Lifecycle queries
-- ---------------------------------------------------------------------------

-- Active means: the player is currently aimed at the matched enemy AND
-- the puzzle's UI is up. `get_instance()` returns whoever is the most
-- recently aimed-at puzzle even after the player drops aim, so we
-- additionally check `_GuiHandle` (the engine's "this puzzle is on
-- screen" signal). With instance discovery stable via the multi-instance
-- set, the GUI handle is now a reliable per-instance signal — the
-- earlier "GUI handle lingers indefinitely" symptom was caused by the
-- cache thrashing between enemies, not by the field being set on all of
-- them at once.
function M.is_active()
    local inst = get_instance()
    if inst == nil then return false end

    if read_bool(inst, "_SuccessTrigger", false) then return false end
    if read_bool(inst, "_FailedTrigger", false) then return false end

    local ok, gui = pcall(function() return inst:get_field("_GuiHandle") end)
    if ok and gui ~= nil then return true end

    return false
end


-- Return an identity-comparable handle for the puzzle that's *currently
-- on screen* (matched to LastHackingTarget AND has a live GUI handle),
-- or nil. The observer uses this to detect target switches without
-- relying on _StartTrg firing twice. Gating on is_active() (rather than
-- raw IsTargetedEnemy) avoids both directions of error: false during
-- aim-without-hack-input, and false-positive across aim-drop windows.
function M.get_active_target_handle()
    if not M.is_active() then return nil end
    return get_instance()
end


-- Read PuzzleBase._State (an Int32-backed enum, PuzzleState: Play|Stop).
-- Per the il2cpp dump, encoded values strongly suggest Play=1 and Stop=0.
-- Returns the raw integer, or nil if unreadable.
function M.read_state_value()
    local inst = get_instance()
    if inst == nil then return nil end
    local ok, v = pcall(function() return inst:get_field("_State") end)
    if not ok then return nil end
    if type(v) == "number" then return v end
    return nil
end


-- True iff the puzzle is currently in the Play state (i.e. accepting input,
-- not in a post-hack disabled / cooldown state). Conservatively returns
-- true when `_State` is unreadable so we don't false-negative on a future
-- build where the field name has changed — the alternative would silently
-- break every legitimate hack force. The debug panel surfaces the raw
-- value so divergence is easy to spot.
function M.is_interactive()
    if not M.is_active() then return false end
    local v = M.read_state_value()
    if v == nil then return true end
    return v ~= 0
end


-- Read a single edge-trigger boolean field.
function M.read_trigger(name)
    local inst = get_instance()
    if inst == nil then return false end
    return read_bool(inst, name, false)
end


-- True while a jammer is suppressing hacking in the area (HackingManager.
-- get_IsJamming). Forcing a plan while jammed is pointless — the engine
-- refuses the hack — so the observer pauses planning and the overlay shows
-- a "jammed" state. Conservative: unreadable => false (don't silently
-- disable planning on a reflection hiccup).
function M.is_jamming()
    ensure_init()
    if _sdk.m_get_is_jamming == nil then return false end
    local mgr = _get_hacking_manager()
    if mgr == nil then return false end
    local ok, v = pcall(function() return _sdk.m_get_is_jamming:call(mgr) end)
    return ok and v == true
end


-- ---------------------------------------------------------------------------
-- Grid snapshot
-- ---------------------------------------------------------------------------

local function read_int2(int2_value)
    if int2_value == nil then return nil end
    local ok_x, x = pcall(function() return int2_value.x end)
    local ok_y, y = pcall(function() return int2_value.y end)
    if ok_x and ok_y and x ~= nil and y ~= nil then
        return { x = x, y = y }
    end
    return nil
end


local _name_cache = {}

local function resolve_type_name(hash)
    if hash == nil then return "Unknown" end
    if _name_cache[hash] then return _name_cache[hash] end
    if _sdk.m_get_name == nil then
        local s = "Type" .. tostring(hash)
        _name_cache[hash] = s
        return s
    end
    local ok, name = pcall(function() return _sdk.m_get_name:call(nil, hash) end)
    if ok and type(name) == "string" then
        _name_cache[hash] = name
        return name
    end
    local s = "Type" .. tostring(hash)
    _name_cache[hash] = s
    return s
end


-- The DeadFilamentType hash space is a different enum from PuzzleSnakeGridType
-- (only "None" shares a value, since both hash the member name), so it gets its
-- own resolver + cache. Literal fallbacks are the hashes from the il2cpp dump,
-- used when app.DeadFilamentType.getName isn't reflectable on a future build.
local _DF_HASH_NAMES = {
    [139421919]  = "None",
    [4140296975] = "Random",
    [2395182966] = "Fixed",
}

local _df_name_cache = {}

local function resolve_df_name(hash)
    if hash == nil then return "None" end
    if _df_name_cache[hash] then return _df_name_cache[hash] end
    if _sdk.m_get_df_name ~= nil then
        local ok, name = pcall(function() return _sdk.m_get_df_name:call(nil, hash) end)
        if ok and type(name) == "string" and #name > 0 then
            _df_name_cache[hash] = name
            return name
        end
    end
    local s = _DF_HASH_NAMES[hash] or ("Type" .. tostring(hash))
    _df_name_cache[hash] = s
    return s
end


local function read_cell(cell_obj)
    -- Cell objects are app.PuzzleSnake.Grid instances. Read fields directly.
    local pos_raw = nil
    local ok_p, p = pcall(function() return cell_obj:get_field("_GridPosition") end)
    if ok_p then pos_raw = p end
    local pos = read_int2(pos_raw)
    if pos == nil then return nil end

    local ok_t, type_hash = pcall(function() return cell_obj:get_field("_GridType") end)
    if not ok_t then type_hash = nil end

    local in_trail = read_bool(cell_obj, "<IsPassed>k__BackingField", false)
    local is_erase = read_bool(cell_obj, "<IsEraseCode>k__BackingField", false)

    -- Sticky-bomb row/column removal. The engine NEVER changes the grid
    -- dimensions for this: it marks whole rows/cols as "skipped" (per-cell
    -- IsSkipRow/IsSkipCol; GridAccessor.get_SkipRow()/get_SkipCol() hold the
    -- index lists, expansionRow()/expansionCol() restore them as the bombs
    -- wear off). A skipped row is collapsed out of the playable grid, so the
    -- snapshot must compact it away or every coordinate below the seam — and
    -- the whole layout the AI plans against — is wrong.
    local is_skip_row = read_bool(cell_obj, "<IsSkipRow>k__BackingField", false)
    local is_skip_col = read_bool(cell_obj, "<IsSkipCol>k__BackingField", false)

    -- ActiveSkill decoration. The engine layers damage-boost / chain / etc.
    -- attributes on top of an underlying terrain type — e.g. a cell may
    -- have _GridType = Open AND <ActiveSkill>k__BackingField = ActiveSkill1Hash.
    -- We surface the skill hash so the renderer can prefer the decoration
    -- glyph over the (usually less informative) terrain glyph.
    --
    -- Two "no-skill" sentinels need filtering: literal 0 (uninitialized)
    -- AND the explicit "None" enum value (139421919). Without filtering
    -- the latter, every default cell ends up with active_skill_type="None"
    -- which the renderer treats as a real decoration and which then
    -- short-circuits to GLYPHS["None"]=".", masking the cell's real type
    -- glyph (Goal, FinishBlow, etc.).
    local active_skill_hash = nil
    local active_skill_type = nil
    local ok_as, as = pcall(function()
        return cell_obj:get_field("<ActiveSkill>k__BackingField")
    end)
    if ok_as and type(as) == "number" and as ~= 0 then
        local resolved = resolve_type_name(as)
        if resolved ~= "None" and resolved ~= "Nothing" then
            active_skill_hash = as
            active_skill_type = resolved
        end
    end

    -- Directional gating. A cell whose _GridType is Open can still restrict
    -- the snake's entry/exit direction via these two hashes. Visually these
    -- are the blue two-way arrow tiles (and one-way arrow tiles). Both
    -- fields are UInt32 hashes from the same PuzzleSnakeGridType enum.
    local function read_uint_field(name)
        local ok, v = pcall(function() return cell_obj:get_field(name) end)
        if ok and type(v) == "number" then return v end
        return nil
    end
    local in_way_hash  = read_uint_field("<InWayType>k__BackingField")
    local out_way_hash = read_uint_field("<OutWayType>k__BackingField")

    -- Dead-filament decoration (app.DeadFilamentType hash: None|Random|Fixed).
    -- Observed 0/None on standard grids — the field appears to be authored only
    -- for dead-filament boss content — but it's cheap to read and the renderer
    -- treats it as one more "error node" flavor if it ever shows up.
    local dead_filament_hash = read_uint_field("_DeadFilamentType")
    local dead_filament_type = nil
    if dead_filament_hash ~= nil and dead_filament_hash ~= 0 then
        local resolved = resolve_df_name(dead_filament_hash)
        if resolved ~= "None" then
            dead_filament_type = resolved
        end
    end

    -- The visible "blue" reward nodes (more damage + longer hack) ARE a
    -- distinct _GridType: Open (plain floor is None) — verified against
    -- in-game footage on multiple grids. _IsGoldenPath is the engine's
    -- AUTO-HACK route marker (it floods most walkable cells, far more than
    -- the visible blue nodes) and is surfaced for the debug dump only — the
    -- renderer must not use it. The "yellow" skill node is the ActiveSkill
    -- type. IsParryHacking / ActiveSkillCount / ActiveSkillIndex are read so
    -- the dump can disambiguate which field actually flags a given node.
    local is_golden_path   = read_bool(cell_obj, "_IsGoldenPath", false)
    local is_parry_hacking = read_bool(cell_obj, "<IsParryHacking>k__BackingField", false)
    local active_skill_count = read_uint_field("<ActiveSkillCount>k__BackingField")
    local active_skill_index = read_uint_field("<ActiveSkillIndex>k__BackingField")

    -- _ObstacleReasons IS the red "error node" marker — VERIFIED in-game
    -- 2026-06-10: a grid's four red warning-triangle cells were exactly the
    -- cells with _ObstacleReasons=1 (ObstacleReason.ObstacleGrid), everything
    -- else 0. It's a bitmask (see file-level field notes), so any nonzero
    -- value means "currently blocked"; the engine can set/clear bits
    -- mid-fight, which the structural signature turns into a replan.
    -- _IsHide marks not-yet-revealed nodes (seen on FinishBlow). _StunReasons
    -- is the analogous stun bitmask; no nonzero observation yet — dump-only.
    local is_hide          = read_bool(cell_obj, "_IsHide", false)
    local obstacle_reasons = read_uint_field("_ObstacleReasons")
    local stun_reasons     = read_uint_field("_StunReasons")
    local is_blocked       = (obstacle_reasons or 0) ~= 0

    return {
        x = pos.x, y = pos.y,
        type_hash          = type_hash,
        type               = resolve_type_name(type_hash),
        in_trail           = in_trail,
        is_erase           = is_erase,
        active_skill_hash  = active_skill_hash,
        active_skill_type  = active_skill_type,
        active_skill_count = active_skill_count,
        active_skill_index = active_skill_index,
        in_way_hash        = in_way_hash,
        in_way_type        = in_way_hash and resolve_type_name(in_way_hash) or nil,
        out_way_hash       = out_way_hash,
        out_way_type       = out_way_hash and resolve_type_name(out_way_hash) or nil,
        is_golden_path     = is_golden_path,
        is_parry_hacking   = is_parry_hacking,
        dead_filament      = dead_filament_type ~= nil,
        dead_filament_hash = dead_filament_hash,
        dead_filament_type = dead_filament_type,
        is_hide            = is_hide,
        obstacle_reasons   = obstacle_reasons,
        stun_reasons       = stun_reasons,
        is_blocked         = is_blocked,
        is_skip_row        = is_skip_row,
        is_skip_col        = is_skip_col,
    }
end


-- Get the GridAccessor instance from a PuzzleSnake.
local function get_accessor(inst)
    if inst == nil then return nil end
    local ok, acc = pcall(function() return inst:get_field("_GridAccessor") end)
    if ok and acc ~= nil then return acc end
    return nil
end


-- Iterate all cells. We avoid `executeEachGrid(System.Action<Grid>)` because
-- REFramework's Lua can't reliably wrap a Lua closure as a System.Action
-- delegate parameter. Instead we read the underlying jagged array stored on
-- the GridController as `_ActualGrid : app.PuzzleSnake.Grid[][]` and iterate
-- it directly.
--
-- The array is jagged (rows of varying length theoretically; in practice
-- rectangular for a normal grid). We trust each cell's `_GridPosition` to
-- tell us its (x, y) regardless of how the outer/inner arrays are oriented,
-- so iteration order doesn't matter.
local function for_each_cell(inst, fn)
    local acc = get_accessor(inst)
    if acc == nil then
        log_discovery("for_each_cell: no accessor")
        return false
    end

    local ok_gc, gc = pcall(function() return acc:get_field("_GridController") end)
    if not ok_gc or gc == nil then
        log_discovery("for_each_cell: _GridController not readable")
        return false
    end

    local ok_arr, outer = pcall(function() return gc:get_field("_ActualGrid") end)
    if not ok_arr or outer == nil then
        log_discovery("for_each_cell: _ActualGrid not readable")
        return false
    end

    -- REFramework arrays expose `get_size()` for length and either `[i]` or
    -- `get_element(i)` for indexing. Try both forms defensively.
    local function arr_size(a)
        local ok, n = pcall(function() return a:get_size() end)
        if ok and type(n) == "number" then return n end
        return 0
    end
    local function arr_get(a, i)
        local ok, v = pcall(function() return a[i] end)
        if ok and v ~= nil then return v end
        local ok2, v2 = pcall(function() return a:get_element(i) end)
        if ok2 then return v2 end
        return nil
    end

    local outer_n = arr_size(outer)
    if outer_n == 0 then
        log_discovery("for_each_cell: outer array length 0")
        return false
    end

    local total = 0
    for i = 0, outer_n - 1 do
        local inner = arr_get(outer, i)
        if inner ~= nil then
            local inner_n = arr_size(inner)
            for j = 0, inner_n - 1 do
                local cell_obj = arr_get(inner, j)
                if cell_obj ~= nil then
                    fn(cell_obj)
                    total = total + 1
                end
            end
        end
    end

    if total == 0 then
        log_discovery("for_each_cell: visited 0 cells (outer_n=" .. tostring(outer_n) .. ")")
        return false
    end
    return true
end


function M.get_state()
    if not ensure_init() then return nil end
    local inst = get_instance()
    if inst == nil then return nil end
    local acc = get_accessor(inst)
    if acc == nil then return nil end

    local width = 0
    local height = 0
    if _sdk.m_get_size_x ~= nil then
        local ok, v = pcall(function() return _sdk.m_get_size_x:call(acc) end)
        if ok and type(v) == "number" then width = v end
    end
    if _sdk.m_get_size_y ~= nil then
        local ok, v = pcall(function() return _sdk.m_get_size_y:call(acc) end)
        if ok and type(v) == "number" then height = v end
    end
    if width <= 0 or height <= 0 then
        log.warn("puzzle_snake: grid dimensions unreadable (got " ..
                 tostring(width) .. "x" .. tostring(height) .. ")")
        return nil
    end

    -- First pass: collect every in-bounds cell at its ENGINE coordinates and
    -- gather the skip sets (rows/cols sticky bombs have removed). The engine
    -- keeps removed rows/cols in the array — dimensions don't change — so the
    -- snapshot must compact them out itself (see read_cell's skip notes).
    local raw = {}
    local skip_rows = {}
    local skip_cols = {}
    local count = 0
    for_each_cell(inst, function(cell_obj)
        local cell = read_cell(cell_obj)
        if cell == nil then return end
        local x, y = cell.x, cell.y
        if x >= 0 and x < width and y >= 0 and y < height then
            count = count + 1
            raw[y] = raw[y] or {}
            raw[y][x] = cell
            if cell.is_skip_row then skip_rows[y] = true end
            if cell.is_skip_col then skip_cols[x] = true end
        end
    end)

    if count == 0 then
        return nil
    end

    -- Active (non-skipped) engine row/col indices, ascending, plus the
    -- engine->render maps used to remap every coordinate below.
    local active_rows, active_cols = {}, {}
    local row_to_render, col_to_render = {}, {}
    local skipped_rows, skipped_cols = {}, {}
    for y = 0, height - 1 do
        if skip_rows[y] then
            skipped_rows[#skipped_rows + 1] = y
        else
            active_rows[#active_rows + 1] = y
            row_to_render[y] = #active_rows - 1     -- 0-based render y
        end
    end
    for x = 0, width - 1 do
        if skip_cols[x] then
            skipped_cols[#skipped_cols + 1] = x
        else
            active_cols[#active_cols + 1] = x
            col_to_render[x] = #active_cols - 1     -- 0-based render x
        end
    end
    if #active_rows == 0 or #active_cols == 0 then
        log_discovery("get_state: every row or col is skip-flagged; treating as unreadable")
        return nil
    end

    local function remap(p)
        if p == nil then return nil end
        local rx = col_to_render[p.x]
        local ry = row_to_render[p.y]
        if rx == nil or ry == nil then return nil end   -- on a removed row/col
        return { x = rx, y = ry }
    end

    -- Compacted cells[y+1][x+1] table (Lua-1-indexed for ipairs friendliness).
    -- Cell x/y are rewritten to RENDER coordinates — everything downstream
    -- (renderer, struct sig, goal scan) works in the compacted space; the
    -- original engine coords stay on engine_x/engine_y for diagnostics.
    local cells = {}
    local trail = {}
    for ry = 1, #active_rows do
        cells[ry] = {}
        local ey = active_rows[ry]
        for rx = 1, #active_cols do
            local ex = active_cols[rx]
            local cell = raw[ey] and raw[ey][ex]
            if cell ~= nil then
                cell.engine_x = ex
                cell.engine_y = ey
                cell.x = rx - 1
                cell.y = ry - 1
                cells[ry][rx] = cell
                if cell.in_trail then
                    table.insert(trail, { x = rx - 1, y = ry - 1 })
                end
            end
        end
    end

    -- Cursor position from _CurrentUnit (engine coords -> render coords).
    local cursor = nil
    local ok_cu, unit = pcall(function() return inst:get_field("_CurrentUnit") end)
    if ok_cu and unit ~= nil and _sdk.m_unit_get_position ~= nil then
        local ok_p, pos_raw = pcall(function() return _sdk.m_unit_get_position:call(unit) end)
        if ok_p then cursor = remap(read_int2(pos_raw)) end
    end

    -- Start position from accessor (remapped; nil if its row/col is removed).
    local start_pos = nil
    if _sdk.m_get_start_pos ~= nil then
        local ok, sp = pcall(function() return _sdk.m_get_start_pos:call(acc) end)
        if ok then start_pos = remap(read_int2(sp)) end
    end

    -- Goal cell: scan for the cell whose type name is "Goal". The hash is
    -- known from the dump (1599924820) but resolving by name is portable
    -- across patches that might re-roll hashes.
    local goal = nil
    for y = 1, #active_rows do
        for x = 1, #active_cols do
            local c = cells[y][x]
            if c ~= nil and c.type == "Goal" then
                goal = { x = c.x, y = c.y }
                break
            end
        end
        if goal then break end
    end

    return {
        width  = #active_cols,
        height = #active_rows,
        cursor = cursor,
        start  = start_pos,
        goal   = goal,
        cells  = cells,
        trail  = trail,
        -- Skip diagnostics: engine-space dims + which engine rows/cols are
        -- currently removed. The renderer surfaces these so the AI knows the
        -- layout is the live, compacted one.
        engine_width  = width,
        engine_height = height,
        skipped_rows  = skipped_rows,
        skipped_cols  = skipped_cols,
        finished = read_bool(inst, "_SuccessTrigger", false)
                or read_bool(inst, "_FailedTrigger", false),
        success  = read_bool(inst, "_SuccessTrigger", false),
    }
end


-- ---------------------------------------------------------------------------
-- Move dispatch
-- ---------------------------------------------------------------------------
-- The engine exposes `app.PuzzleSnake.Unit.move(via.Int2) -> UnitMoveResultType`.
-- The argument is the ABSOLUTE TARGET cell (x, y), NOT a delta.
--
-- Constructing a `via.Int2` value type from Lua is the runtime unknown. We
-- try several REFramework-supported patterns in order; whichever works gets
-- cached so subsequent calls skip the probe. In our testing the working
-- pattern is `modify_position_wrapper` — get the engine's existing Position
-- struct (a real value-type wrapper, NOT one we synthesized), mutate its
-- fields in place, and pass it back. Engine-supplied wrappers honor
-- set_field writes where `sdk.create_instance("via.Int2")` ones don't.

local DIR_DELTAS = {
    up    = { x =  0, y = -1 },
    down  = { x =  0, y =  1 },
    left  = { x = -1, y =  0 },
    right = { x =  1, y =  0 },
}

-- The strategy index that worked last time. Try this one first on the next
-- call; fall back to retrying all strategies if it fails.
local _int2_strategy_winner = nil

local function _make_int2_strategies(unit, target_method, target_x, target_y)
    local function verify(wrapper, who)
        if wrapper == nil then error(who .. ": wrapper is nil") end
        local rx, ry
        local ok_x, x_val = pcall(function() return wrapper:get_field("x") end)
        local ok_y, y_val = pcall(function() return wrapper:get_field("y") end)
        if ok_x then rx = x_val end
        if ok_y then ry = y_val end
        if rx ~= target_x or ry ~= target_y then
            error(who .. ": Int2 readback mismatch (got x=" .. tostring(rx)
                  .. " y=" .. tostring(ry) .. ", wanted x=" .. tostring(target_x)
                  .. " y=" .. tostring(target_y) .. ")")
        end
        return wrapper
    end

    return {
        -- Get the engine's existing Position struct, mutate its fields, pass
        -- it. This is the strategy that works on tested REFramework builds.
        {
            name = "modify_position_wrapper",
            run = function()
                if _sdk.m_unit_get_position == nil then
                    error("get_Position method not resolvable")
                end
                local pos = _sdk.m_unit_get_position:call(unit)
                if pos == nil then error("get_Position returned nil") end
                local ok_set = pcall(function()
                    pos:set_field("x", target_x)
                    pos:set_field("y", target_y)
                end)
                if not ok_set then
                    pcall(function()
                        pos.x = target_x
                        pos.y = target_y
                    end)
                end
                verify(pos, "modify_position_wrapper")
                return target_method:call(unit, pos)
            end,
        },
        -- Fallbacks for builds where the above doesn't work. In our testing
        -- none of these succeed, but they're cheap to keep as backups in
        -- case the REFramework value-type semantics shift in a future build.
        {
            name = "ctor_call",
            run = function()
                local td = sdk.find_type_definition("via.Int2")
                if td == nil then error("via.Int2 type def not found") end
                local ctor = td:get_method(".ctor(System.Int32, System.Int32)")
                if ctor == nil then error(".ctor(Int32,Int32) not found") end
                local i = sdk.create_instance("via.Int2")
                if i == nil then error("create_instance returned nil") end
                ctor:call(i, target_x, target_y)
                verify(i, "ctor_call")
                return target_method:call(unit, i)
            end,
        },
        {
            name = "managed_set_field",
            run = function()
                local i = sdk.create_instance("via.Int2")
                if i == nil then error("create_instance returned nil") end
                i:set_field("x", target_x)
                i:set_field("y", target_y)
                verify(i, "managed_set_field")
                return target_method:call(unit, i)
            end,
        },
        {
            name = "managed_direct_assign",
            run = function()
                local i = sdk.create_instance("via.Int2")
                if i == nil then error("create_instance returned nil") end
                i.x = target_x
                i.y = target_y
                verify(i, "managed_direct_assign")
                return target_method:call(unit, i)
            end,
        },
        {
            name = "lua_table",
            run = function()
                return target_method:call(unit, { x = target_x, y = target_y })
            end,
        },
    }
end


-- Run the cached strategy first; on failure, walk through all strategies
-- and update the cached winner. Returns (ok, strategy_name, result_or_err).
local function _try_call_with_int2(unit, method, target_x, target_y)
    local strategies = _make_int2_strategies(unit, method, target_x, target_y)

    if _int2_strategy_winner ~= nil then
        local s = strategies[_int2_strategy_winner]
        if s ~= nil then
            local ok, result = pcall(s.run)
            if ok then return true, s.name, result end
            -- Cached winner failed; clear and re-probe below.
            _int2_strategy_winner = nil
        end
    end

    local tried_names = {}
    for i, s in ipairs(strategies) do
        local ok, result = pcall(s.run)
        if ok then
            _int2_strategy_winner = i
            log_discovery("Int2 strategy: " .. s.name .. " works")
            return true, s.name, result
        end
        log_discovery("Int2 strategy " .. s.name .. " failed: " .. tostring(result))
        table.insert(tried_names, s.name)
    end

    return false, "all_failed", "tried [" .. table.concat(tried_names, ",")
                            .. "] — see Discovery event log for full errors"
end


local function _resolve_unit()
    if not ensure_init() then return nil, "binding not initialized" end
    local inst = get_instance()
    if inst == nil then return nil, "no PuzzleSnake instance cached" end
    local ok, unit = pcall(function() return inst:get_field("_CurrentUnit") end)
    if not ok or unit == nil then return nil, "_CurrentUnit not readable" end
    return unit, nil
end


-- Returns true if the unit is mid-transition between cells. Calling move()
-- while this is true MAY be ignored or queued by the engine; for safety the
-- caller can refuse to fire a new move until the previous settles.
function M.is_unit_moving()
    local unit = _resolve_unit()
    if unit == nil then return false end
    if _sdk.m_unit_get_is_move == nil then
        return read_bool(unit, "<isMove>k__BackingField", false)
    end
    local ok, v = pcall(function() return _sdk.m_unit_get_is_move:call(unit) end)
    if ok and v == true then return true end
    return false
end


-- Read the cursor's current cell coordinates. Returns {x=, y=} or nil.
local function _read_cursor_pos(unit)
    if _sdk.m_unit_get_position == nil then return nil end
    local ok, raw = pcall(function() return _sdk.m_unit_get_position:call(unit) end)
    if not ok or raw == nil then return nil end
    return read_int2(raw)
end


-- Pre-validate whether moving in `direction` would land on a reachable cell.
-- Returns (true|false, message). False means the engine wouldn't accept it.
function M.can_move(direction)
    local delta = DIR_DELTAS[direction]
    if delta == nil then return false, "invalid direction: " .. tostring(direction) end

    local unit, err = _resolve_unit()
    if unit == nil then return false, err end

    if _sdk.m_unit_can_reach == nil then
        return false, "canReachStraight method not resolvable"
    end

    local pos = _read_cursor_pos(unit)
    if pos == nil then return false, "couldn't read cursor position" end
    local target_x = pos.x + delta.x
    local target_y = pos.y + delta.y

    local ok, name, result = _try_call_with_int2(unit, _sdk.m_unit_can_reach, target_x, target_y)
    if not ok then return false, "canReachStraight call failed: " .. tostring(result) end
    return result == true, string.format("canReachStraight(%d,%d) via %s -> %s",
                                         target_x, target_y, name, tostring(result))
end


-- Read grid dimensions cheaply (no full cell iteration).
local function _read_grid_dims()
    local inst = get_instance()
    if inst == nil then return nil, nil end
    local acc = get_accessor(inst)
    if acc == nil then return nil, nil end
    if _sdk.m_get_size_x == nil or _sdk.m_get_size_y == nil then
        return nil, nil
    end
    local ok_w, w = pcall(function() return _sdk.m_get_size_x:call(acc) end)
    local ok_h, h = pcall(function() return _sdk.m_get_size_y:call(acc) end)
    if not ok_w or not ok_h or type(w) ~= "number" or type(h) ~= "number" then
        return nil, nil
    end
    return w, h
end


-- Move the cursor one cell in `direction`. Returns:
--   (true, result_string) on a successful engine call (note: "successful
--     call" doesn't mean the move was *legal* — read result_string for the
--     move-result enum value the engine returned)
--   (false, error_string) if the call couldn't be made at all OR the
--     target is out of bounds (we reject OOB locally so the cursor doesn't
--     get stuck — Unit.move(via.Int2) is an absolute-target API and
--     happily accepts coords outside the grid, leaving the cursor in a
--     position no further input can rescue)
function M.move(direction)
    local delta = DIR_DELTAS[direction]
    if delta == nil then return false, "invalid direction: " .. tostring(direction) end

    local unit, err = _resolve_unit()
    if unit == nil then return false, err end

    if _sdk.m_unit_move == nil then
        return false, "move method not resolvable"
    end

    local pos = _read_cursor_pos(unit)
    if pos == nil then return false, "couldn't read cursor position" end
    local target_x = pos.x + delta.x
    local target_y = pos.y + delta.y

    -- Bounds check. If dims are unreadable we let the call through —
    -- safer to risk one OOB move than to false-negative a legitimate
    -- one when introspection is broken.
    local w, h = _read_grid_dims()
    if w ~= nil and h ~= nil then
        if target_x < 0 or target_x >= w or target_y < 0 or target_y >= h then
            return false, string.format(
                "move %s rejected: target (%d,%d) out of bounds (grid %dx%d)",
                direction, target_x, target_y, w, h)
        end
    end

    local ok, name, result = _try_call_with_int2(unit, _sdk.m_unit_move, target_x, target_y)
    if not ok then
        return false, string.format("move(%d,%d) call failed: %s",
                                    target_x, target_y, tostring(result))
    end
    return true, string.format("move(%d,%d) via %s -> %s",
                               target_x, target_y, name, tostring(result))
end


-- ---------------------------------------------------------------------------
-- Input-pipeline move via _NextMovePosition (PRIMARY MOVE PATH)
-- ---------------------------------------------------------------------------
-- Writing absolute target coords into PuzzleSnake._NextMovePosition causes
-- the engine to process the move through its natural input pipeline:
--   updateInput → updateNextPosition → updatePuzzleMovement → onEnterGrid
-- which gives us, free, every cell side-effect the player would get:
--   - walls block (canReachStraight gating)
--   - OneWay/TwoWay directional gates enforced
--   - IsPassed flags set on traversed cells (trail rendering)
--   - ActiveSkill bonuses applied (chain/damage cells)
--   - EraseCode traps trigger
--   - Goal arrival auto-completes the puzzle (full COMPLETE animation)
--
-- This is the path `tick_plan` uses for AI-dispatched moves. The older
-- `M.move()` (Unit.move(via.Int2) direct write) remains available for
-- manual debug poking but is NOT used in production — it bypasses every
-- one of the above effects.
--
-- Field mechanics: PuzzleSnake._NextMovePosition is a via.Int2 value-type
-- field at offset 0x1ac (Private). REFramework's get_field returns a
-- writable wrapper over engine storage on tested builds, so mutating
-- x/y in place propagates; we also call set_field defensively in case a
-- future build returns a copy.

-- Read the current _NextMovePosition as {x, y} or nil.
function M.read_next_move_position()
    local inst = get_instance()
    if inst == nil then return nil end
    local ok, raw = pcall(function() return inst:get_field("_NextMovePosition") end)
    if not ok or raw == nil then return nil end
    return read_int2(raw)
end


-- Write absolute target coords into _NextMovePosition. Returns
-- (true, message) on a successful write (readback included so the caller
-- can see whether the field actually accepted the value), or
-- (false, error_string) otherwise.
function M.write_next_move_position(target_x, target_y)
    local inst = get_instance()
    if inst == nil then return false, "no active puzzle" end

    -- Read the current field. For value-type fields, REFramework typically
    -- returns a wrapper over the engine's storage; mutating it in place
    -- propagates. We also call set_field afterwards in case this build returns a copy.
    local ok_g, current = pcall(function() return inst:get_field("_NextMovePosition") end)
    if not ok_g or current == nil then
        return false, "couldn't read _NextMovePosition for write"
    end

    local ok_set = pcall(function()
        current:set_field("x", target_x)
        current:set_field("y", target_y)
    end)
    if not ok_set then
        pcall(function()
            current.x = target_x
            current.y = target_y
        end)
    end

    -- Defensive: write the wrapper back. Harmless if get_field returned
    -- a reference (no-op); needed if it returned a copy.
    pcall(function() inst:set_field("_NextMovePosition", current) end)

    -- Readback for diagnostics.
    local ok_after, after = pcall(function() return inst:get_field("_NextMovePosition") end)
    local rx, ry = nil, nil
    if ok_after and after ~= nil then
        local p = read_int2(after)
        if p ~= nil then rx, ry = p.x, p.y end
    end

    return true, string.format(
        "_NextMovePosition <- (%d,%d) [readback: x=%s y=%s]",
        target_x, target_y, tostring(rx), tostring(ry))
end


-- Engine-space skip sets (rows/cols currently removed by sticky bombs). A
-- light pass over the cell array reading only positions + skip flags; runs
-- at dispatch rate (~7Hz), not per frame.
local function _read_skip_sets(inst)
    local rows, cols = {}, {}
    for_each_cell(inst, function(cell_obj)
        local ok_p, p = pcall(function() return cell_obj:get_field("_GridPosition") end)
        if not ok_p then return end
        local pos = read_int2(p)
        if pos == nil then return end
        if read_bool(cell_obj, "<IsSkipRow>k__BackingField", false) then rows[pos.y] = true end
        if read_bool(cell_obj, "<IsSkipCol>k__BackingField", false) then cols[pos.x] = true end
    end)
    return rows, cols
end


-- Direction-style wrapper around write_next_move_position. Resolves the
-- absolute ENGINE target from the current cursor + delta, steps over any
-- rows/cols sticky bombs have removed (the playable grid is compacted, so
-- one logical move can cross several engine indices), bounds-checks, then
-- delegates. Used by tick_plan for AI-dispatched moves and by debug buttons.
function M.move_via_next_position(direction)
    local delta = DIR_DELTAS[direction]
    if delta == nil then return false, "invalid direction: " .. tostring(direction) end

    local unit, err = _resolve_unit()
    if unit == nil then return false, err end

    local pos = _read_cursor_pos(unit)
    if pos == nil then return false, "couldn't read cursor position" end

    local skip_rows, skip_cols = {}, {}
    local inst = get_instance()
    if inst ~= nil then
        skip_rows, skip_cols = _read_skip_sets(inst)
    end

    local w, h = _read_grid_dims()
    local target_x = pos.x + delta.x
    local target_y = pos.y + delta.y
    local hopped = 0
    while (skip_rows[target_y] or skip_cols[target_x])
        and (w == nil or (target_x >= 0 and target_x < w))
        and (h == nil or (target_y >= 0 and target_y < h)) do
        target_x = target_x + delta.x
        target_y = target_y + delta.y
        hopped = hopped + 1
    end

    if w ~= nil and h ~= nil then
        if target_x < 0 or target_x >= w or target_y < 0 or target_y >= h then
            return false, string.format(
                "move %s rejected: target (%d,%d) out of bounds (grid %dx%d)",
                direction, target_x, target_y, w, h)
        end
    end

    if hopped > 0 then
        log.info(string.format(
            "move_via_next_position: %s hops %d removed row(s)/col(s) -> engine target (%d,%d)",
            direction, hopped, target_x, target_y))
    end

    return M.write_next_move_position(target_x, target_y)
end


-- Currently-cached Int2 strategy name (or nil). For the debug panel.
function M.int2_strategy_in_use()
    if _int2_strategy_winner == nil then return nil end
    -- Order must match _make_int2_strategies above.
    local names = {
        "modify_position_wrapper",
        "ctor_call",
        "managed_set_field",
        "managed_direct_assign",
        "lua_table",
    }
    return names[_int2_strategy_winner]
end


-- Reset the cached winner so the next move call re-probes all strategies.
function M.reset_int2_strategy_cache()
    _int2_strategy_winner = nil
end


-- ---------------------------------------------------------------------------
-- Structural signature
-- ---------------------------------------------------------------------------
-- A fingerprint of the parts of the grid that DON'T change as the cursor
-- traverses it: dimensions, goal position, and the location of every wall,
-- EraseCode trap, and dead-filament error node. Deliberately EXCLUDES the
-- cursor and the trail (IsPassed) — those advance as a plan executes, so
-- including them would make every normal move look like a "change".
-- Error nodes ARE included: _ObstacleReasons is a runtime bitmask the engine
-- can set/clear mid-fight, and a hazard-map change is exactly when a stale
-- plan needs invalidating. (If error nodes turn out to pulse rapidly, this
-- will show up as replan churn — the observer's retry dedup absorbs it, but
-- it's the first place to look.)
--
-- A plan is only valid while this signature is stable. Because get_state
-- compacts skipped rows/cols out of the grid, a sticky bomb that removes a
-- row shrinks the compacted dimensions and shifts every wall/trap/goal mark —
-- and the bomb WEARING OFF (engine expansionRow/expansionCol restoring rows
-- at the same rate they were fired) grows them back — so both directions of
-- the change invalidate stale plans and trigger a re-force. Bonus-node
-- consumption (which may or may not flip a cell's decoration on traversal —
-- pending in-game confirmation) is NOT part of the signature, so it can
-- never trigger a false replan.
local function _is_wall_type(type_name)
    return type_name == "Obstacle"
        or type_name == "Impassable"
        or type_name == "Nothing"
        or type_name == "Shield"
end

local function _struct_sig_from_state(state)
    if state == nil then return nil end
    local parts = { state.width .. "x" .. state.height }
    if state.goal then
        parts[#parts + 1] = "g" .. state.goal.x .. "," .. state.goal.y
    else
        parts[#parts + 1] = "g?"
    end
    local marks = {}
    for y = 0, state.height - 1 do
        local row = state.cells[y + 1]
        for x = 0, state.width - 1 do
            local c = row and row[x + 1]
            if c == nil then
                marks[#marks + 1] = "w" .. x .. "," .. y     -- missing cell = wall
            elseif c.is_erase or c.type == "EraseCode" then
                marks[#marks + 1] = "x" .. x .. "," .. y     -- trap
            elseif c.is_blocked or c.dead_filament or c.type == "DeadFilament" then
                marks[#marks + 1] = "d" .. x .. "," .. y     -- error node (blocked)
            elseif _is_wall_type(c.type) then
                marks[#marks + 1] = "w" .. x .. "," .. y     -- wall
            end
        end
    end
    table.sort(marks)
    parts[#parts + 1] = table.concat(marks, ";")
    return table.concat(parts, "|")
end

local function _cursor_xy(state)
    if state == nil or state.cursor == nil then return nil end
    return { x = state.cursor.x, y = state.cursor.y }
end


-- ---------------------------------------------------------------------------
-- Per-puzzle plan dispatch
-- ---------------------------------------------------------------------------
-- Each puzzle (PuzzleSnake instance, identified by its stable record id)
-- owns its own move queue. A reply for puzzle A is parked on A's record and
-- only ever dispatched while the player is aimed at A — so a plan can never
-- be applied to the wrong enemy, and a plan that arrives while the player
-- has run away waits on its puzzle and resumes ("instant response") when the
-- player returns.
--
-- Dispatch path is M.move_via_next_position() — the input-pipeline write
-- that mimics player input (walls block, gates enforce, goal auto-completes).
-- A per-move cooldown plus an isMove wait keeps us from outpacing the
-- engine's per-cell transition.

local _plan_cooldown_frames = 8     -- ~130ms at 60fps

-- One-shot events the dispatcher raises for the observer/overlay to react to
-- ("resumed" a parked plan; "grid_changed" forced a replan). Drained via
-- M.consume_plan_events().
local _plan_events = {}
local function _push_plan_event(e) _plan_events[#_plan_events + 1] = e end

function M.consume_plan_events()
    if #_plan_events == 0 then return {} end
    local out = _plan_events
    _plan_events = {}
    return out
end

-- Stable, neutral id of the puzzle currently on screen (matched to the
-- player's aim AND with a live GUI handle), or nil. The observer tracks
-- "which puzzle" purely by this int — it never sees an engine object.
function M.current_puzzle_id()
    if not M.is_active() then return nil end
    local rec = _get_current_record()
    return rec and rec.id or nil
end

-- Id of the puzzle matched to the player's aim, REGARDLESS of whether its
-- triggers say it's ending. End-of-hack handlers (success/failed) use this
-- because is_active() has already flipped false by then, yet we still need
-- to know which puzzle's plan to clear.
function M.matched_puzzle_id()
    local rec = _get_current_record()
    return rec and rec.id or nil
end

-- Set of currently-live puzzle ids. The observer uses this to release a
-- force slot whose puzzle was destroyed before the reply came back.
function M.live_puzzle_ids()
    _sweep_dead_instances()
    local ids = {}
    for _, rec in ipairs(_known_instances) do ids[rec.id] = true end
    return ids
end

-- Record the structure + cursor we're about to force a plan against, so we
-- can (a) detect a later structural change that invalidates the reply and
-- (b) know whether the puzzle has changed enough to warrant a fresh force.
-- Must be called while `id` is the current puzzle (i.e. at force time).
function M.snapshot_force_target(id)
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return end
    local state = M.get_state()
    if state == nil then return end
    rec.forced_struct = _struct_sig_from_state(state)
    rec.forced_cursor = _cursor_xy(state)
end

-- Drop the force snapshot for a puzzle so the next reconciliation re-forces
-- it even if its grid is byte-identical. Called on an explicit (re)start
-- (_StartTrg / re-aim), which is the player's "try again" signal.
function M.clear_force_snapshot(id)
    local rec = _record_by_id(id)
    if rec then rec.forced_struct = nil; rec.forced_cursor = nil end
end

-- True if puzzle `id`'s STRUCTURE has changed since we forced it (sticky
-- bomb, reset). Ignores cursor/trail. Used to invalidate a plan on a
-- _GridChangeEndTrg edge.
function M.struct_changed(id)
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return false end
    if rec.forced_struct == nil then return false end
    local state = M.get_state()
    if state == nil then return false end
    return _struct_sig_from_state(state) ~= rec.forced_struct
end

-- True if the current puzzle `id` should be (re)forced now: it's interactive,
-- has no queued plan, and either we've never forced its current state or its
-- structure/cursor has changed since (grid mutated, or the cursor advanced so
-- a follow-up plan can continue from the new position). When the state is
-- unchanged since the last force, returns false — so a plan that drained
-- without progress doesn't spin-loop re-forcing the identical grid.
function M.needs_force(id)
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return false end
    if not M.is_interactive() then return false end
    if rec.plan ~= nil and #rec.plan.queue > 0 then return false end
    local state = M.get_state()
    if state == nil then return false end
    if rec.forced_struct == nil then return true end
    if _struct_sig_from_state(state) ~= rec.forced_struct then return true end
    local cur = _cursor_xy(state)
    local fc = rec.forced_cursor
    if cur == nil or fc == nil then return true end
    return cur.x ~= fc.x or cur.y ~= fc.y
end

-- Attach a plan (list of directions) to puzzle `id`. Captures the structure
-- the plan is validated against (the force snapshot, i.e. what the peer
-- planned against). `parked` is true when the reply arrived while the player
-- was NOT aimed at this puzzle — it'll resume when they return. Returns
-- (queued_count, parked).
function M.set_plan(id, moves)
    local rec = _record_by_id(id)
    if rec == nil then return 0, false end
    if type(moves) ~= "table" then return 0, false end

    local queue = {}
    for _, d in ipairs(moves) do
        if DIR_DELTAS[d] ~= nil then queue[#queue + 1] = d end
    end

    -- Validate against the structure we forced against. If we have no
    -- snapshot (e.g. a manual debug queue), fall back to the current
    -- structure so the plan still aborts if the grid changes under it.
    local validate_struct = rec.forced_struct
    if validate_struct == nil then
        local st = M.get_state()
        if st then validate_struct = _struct_sig_from_state(st) end
    end

    local cur = _get_current_record()
    local is_current = (cur ~= nil and cur.id == id)
    rec.plan = {
        queue           = queue,
        total           = #queue,
        cooldown        = 0,
        last_msg        = nil,
        parked          = not is_current,
        validate_struct = validate_struct,
    }
    return #queue, rec.plan.parked
end

function M.discard_plan(id)
    local rec = _record_by_id(id)
    if rec then rec.plan = nil end
end

function M.has_plan(id)
    local rec = _record_by_id(id)
    return rec ~= nil and rec.plan ~= nil and #rec.plan.queue > 0
end

-- Progress snapshot for the currently-aimed puzzle (overlay + debug panel).
function M.current_plan_status()
    local rec = _get_current_record()
    local plan = rec and rec.plan
    local queue_size = plan and #plan.queue or 0
    local total = plan and plan.total or 0
    return {
        queue_size  = queue_size,
        total       = total,
        executed    = math.max(0, total - queue_size),
        parked      = plan and plan.parked or false,
        cooldown    = plan and plan.cooldown or 0,
        active      = M.is_active(),
        unit_moving = M.is_unit_moving(),
        last_msg    = plan and plan.last_msg or nil,
    }
end

-- Per-frame tick. Wire into pragmata_main.lua's re.on_frame loop. Dispatches
-- the CURRENTLY-aimed puzzle's queue only; other puzzles' queues stay parked.
function M.tick_plan()
    local rec = _get_current_record()
    if rec == nil or rec.plan == nil then return end
    local plan = rec.plan

    -- Not interactive (player dropped aim, post-hack cooldown)? Keep the
    -- queue PARKED — do not drop it. It resumes when the player re-aims.
    if not M.is_interactive() then return end

    -- Finished dispatching: clear the plan so reconciliation can decide
    -- whether to re-force (e.g. the cursor advanced but didn't reach the goal).
    if #plan.queue == 0 then
        if plan.cooldown > 0 then plan.cooldown = plan.cooldown - 1; return end
        rec.plan = nil
        return
    end

    if plan.cooldown > 0 then plan.cooldown = plan.cooldown - 1; return end

    -- Cursor is mid-cell-transition — let it settle before the next move.
    if M.is_unit_moving() then return end

    -- Continuous structural validation, evaluated only when we're about to
    -- dispatch (past the cooldown/isMove gates) so the full grid scan runs at
    -- dispatch rate (~7Hz), not every frame. If the grid's structure changed
    -- since the plan was built (sticky bomb deleted a row, puzzle reset), the
    -- remaining moves are computed against a layout that no longer exists.
    -- Abort and clear the force snapshot so reconciliation re-forces against
    -- the new grid. Checked BEFORE the "resumed" flag so a parked plan
    -- returning to a mutated grid flashes "retrying", not "resuming".
    if plan.validate_struct ~= nil then
        local state = M.get_state()
        if state ~= nil and _struct_sig_from_state(state) ~= plan.validate_struct then
            log.info("tick_plan: grid structure changed under plan (id=" .. rec.id
                  .. "); aborting " .. tostring(#plan.queue) .. " queued moves")
            rec.plan = nil
            rec.forced_struct = nil
            _push_plan_event("grid_changed")
            return
        end
    end

    -- A parked plan dispatching its first move on return → one-time "resumed"
    -- event so the overlay can show that the parked plan is resuming.
    if plan.parked then
        plan.parked = false
        _push_plan_event("resumed")
        log.info("tick_plan: resuming parked plan (id=" .. rec.id .. ", "
              .. tostring(#plan.queue) .. " moves)")
    end

    local dir = table.remove(plan.queue, 1)
    local ok, msg = M.move_via_next_position(dir)
    plan.last_msg = string.format("move %s: %s",
                                  dir, tostring(msg or (ok and "ok" or "error")))
    log.info("tick_plan: " .. plan.last_msg)
    plan.cooldown = _plan_cooldown_frames

    -- Abort the rest of the queue on a rejected move (OOB, no unit, etc.).
    -- Continuing would dispatch follow-up moves from a position the plan
    -- didn't expect — stop and let reconciliation re-force from where the
    -- cursor actually ended up.
    if not ok then
        log.warn("tick_plan: move rejected; dropping remaining "
              .. tostring(#plan.queue) .. " queued moves")
        rec.plan = nil
        return
    end

    -- Goal arrival auto-completes the puzzle via the engine's
    -- updatePuzzleMovement → onEnterGrid pipeline (COMPLETE overlay, hack
    -- damage commit, dialogue progression, auto-reset). The success trigger
    -- then fires and the observer clears this puzzle's plan.
end


-- ---------------------------------------------------------------------------
-- Compatibility shims (hacking_debug.lua manual plan buttons)
-- ---------------------------------------------------------------------------
-- The debug panel queues/clears a manual plan against whatever's on screen.
-- Route those through the per-puzzle system so manual testing behaves like
-- production dispatch (validation, parking, etc.).

function M.queue_plan(directions)
    local id = M.current_puzzle_id()
    if id == nil then return 0 end
    local queued = M.set_plan(id, directions)
    return queued
end

function M.clear_plan()
    local rec = _get_current_record()
    if rec then rec.plan = nil end
end

function M.plan_status()
    return M.current_plan_status()
end


-- ---------------------------------------------------------------------------
-- Puzzle completion
-- ---------------------------------------------------------------------------
-- Once the cursor is on the Goal cell, the puzzle's state machine doesn't
-- auto-complete because Unit.move bypasses the engine's per-cell goal check
-- (that check normally runs when the cursor arrives via the natural input
-- pipeline). Writing `_RequestForceSuccess = true` on the active PuzzleSnake
-- nudges the engine to run its full natural completion flow on the next tick.
--
-- Note on "Request*" vs "*Trg" / "*Trigger" naming: edge-trigger fields
-- (*Trg, *Trigger) are one-frame outputs the engine sets and clears around
-- a state transition; writes to them are silently dropped by the engine on
-- the REFramework builds we tested. Request fields are POLLED by the engine
-- each tick — writes propagate.

function M.try_set_request_force_success()
    if not ensure_init() then return false, "not initialized" end
    local inst = get_instance()
    if inst == nil then return false, "no PuzzleSnake instance" end

    -- Read-back so we can report whether the write took.
    local before = nil
    pcall(function() before = inst:get_field("_RequestForceSuccess") end)

    local ok, e = pcall(function() inst:set_field("_RequestForceSuccess", true) end)
    if not ok then return false, "set_field threw: " .. tostring(e) end

    local after = nil
    pcall(function() after = inst:get_field("_RequestForceSuccess") end)

    log.info(string.format("try_set_request_force_success: before=%s after=%s",
                           tostring(before), tostring(after)))
    return true, string.format("set _RequestForceSuccess (before=%s, after=%s)",
                               tostring(before), tostring(after))
end


-- ---------------------------------------------------------------------------
-- Debug introspection (used by hacking_debug.lua ImGui panel)
-- ---------------------------------------------------------------------------

-- Clear the entire known-instances set. The hooks will repopulate as the
-- engine ticks PuzzleSnake instances. Useful for debugging cache-vs-engine
-- divergence — production code shouldn't need it now that lookup is
-- discriminated by HackingManager.
function M.invalidate_instance()
    if #_known_instances > 0 then
        log_discovery("known-instances set cleared by caller")
        _known_instances = {}
    end
    _hacking_mgr = nil
end


-- Force a re-discovery attempt, returning a snapshot of state.
function M.debug_discover()
    ensure_init()
    log_discovery("manual discover requested")
    return {
        instance_cached = get_instance() ~= nil,
        known_count     = #_known_instances,
        init_report     = _init_report,
        log             = _discovery_log,
    }
end


-- Dump the raw cells we read from _ActualGrid plus the array shape, for
-- diagnostic purposes.
function M.debug_dump_cells()
    if not ensure_init() then return { shape = "no init", cells = {} } end
    local inst = get_instance()
    if inst == nil then return { shape = "no instance", cells = {} } end

    local acc = get_accessor(inst)
    if acc == nil then return { shape = "no accessor", cells = {} } end

    local ok_gc, gc = pcall(function() return acc:get_field("_GridController") end)
    if not ok_gc or gc == nil then return { shape = "no gc", cells = {} } end

    local ok_arr, outer = pcall(function() return gc:get_field("_ActualGrid") end)
    if not ok_arr or outer == nil then return { shape = "no _ActualGrid", cells = {} } end

    local ok_n, outer_n = pcall(function() return outer:get_size() end)
    if not ok_n then outer_n = "<get_size failed>" end

    local inner_sizes = {}
    if type(outer_n) == "number" then
        for i = 0, outer_n - 1 do
            local inner = nil
            local ok_i, v = pcall(function() return outer[i] end)
            if ok_i and v ~= nil then inner = v end
            if inner == nil then
                local ok_i2, v2 = pcall(function() return outer:get_element(i) end)
                if ok_i2 then inner = v2 end
            end
            if inner == nil then
                table.insert(inner_sizes, "nil")
            else
                local ok_in, n = pcall(function() return inner:get_size() end)
                table.insert(inner_sizes, ok_in and tostring(n) or "?")
            end
        end
    end

    local cells = {}
    for_each_cell(inst, function(cell_obj)
        local cell = read_cell(cell_obj)
        if cell ~= nil then table.insert(cells, cell) end
    end)

    return {
        shape = string.format("outer=%s, inner=[%s]",
                              tostring(outer_n),
                              table.concat(inner_sizes, ",")),
        cells = cells,
    }
end


-- Return a status snapshot for the debug panel. Cheap to call every frame.
function M.debug_status()
    ensure_init()
    local inst = get_instance()
    local target_unit, is_targeted = _resolve_target_unit()
    local s = {
        init_report          = _init_report,
        instance_cached      = inst ~= nil,
        known_instance_count = #_known_instances,
        hacking_mgr_present  = _get_hacking_manager() ~= nil,
        is_targeted_enemy    = is_targeted,
        has_target_unit      = target_unit ~= nil,
        triggers             = {},
        active               = false,
        grid_dims            = nil,
        cursor               = nil,
    }
    if inst == nil then return s end

    -- Read each trigger field. A nil read is reported separately from false.
    local trigger_fields = {
        "_StartTrg", "_SuccessTrigger", "_FailedTrigger",
        "_ResetTrg", "_GridResetRequest",
        "_GridChangeStartTrg", "_GridChangeEndTrg",
        "_AttackTrg",
    }
    for _, name in ipairs(trigger_fields) do
        local ok, v = pcall(function() return inst:get_field(name) end)
        if ok then
            s.triggers[name] = v
        else
            s.triggers[name] = "<unreadable>"
        end
    end

    -- GUI handle = puzzle UI is up.
    local ok_g, gui = pcall(function() return inst:get_field("_GuiHandle") end)
    s.gui_handle_present = (ok_g and gui ~= nil)

    -- Try to read grid dims directly (without going through full get_state).
    local acc = get_accessor(inst)
    if acc ~= nil and _sdk.m_get_size_x and _sdk.m_get_size_y then
        local ok_x, w = pcall(function() return _sdk.m_get_size_x:call(acc) end)
        local ok_y, h = pcall(function() return _sdk.m_get_size_y:call(acc) end)
        if ok_x and ok_y then
            s.grid_dims = { width = w, height = h }
        end
    end

    -- Cursor position from _CurrentUnit.
    local ok_cu, unit = pcall(function() return inst:get_field("_CurrentUnit") end)
    if ok_cu and unit ~= nil and _sdk.m_unit_get_position then
        local ok_p, pos_raw = pcall(function() return _sdk.m_unit_get_position:call(unit) end)
        if ok_p then s.cursor = read_int2(pos_raw) end
    end

    s.active = M.is_active()
    return s
end


return M
