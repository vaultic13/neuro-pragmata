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
--     - _GridType (UInt32)                       -- hash; resolved via PuzzleSnakeGridType.getName
--     - <IsPassed>k__BackingField                -- has the cursor crossed (= trail)
--     - <IsEraseCode>k__BackingField             -- is this the red trap node

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
    hacking_mgr_td = nil,    -- app.HackingManager
    m_get_size_x = nil,
    m_get_size_y = nil,
    m_get_start_pos = nil,
    m_unit_get_position = nil,
    m_unit_move = nil,
    m_unit_can_reach = nil,
    m_unit_get_is_move = nil,
    m_get_name = nil,
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
    m_get_size_x    = false,
    m_get_size_y    = false,
    m_get_start     = false,
    m_get_name      = false,
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


-- Add `inst` to the known-instances set. Hooks call this; lookup is later.
local function _track_instance(inst, source)
    if inst == nil then return end

    -- Sweep dead entries while we're here; managed-object handles become
    -- invalid when the engine destroys them, and get_type_definition() is
    -- the cheapest test for liveness.
    for i = #_known_instances, 1, -1 do
        local existing = _known_instances[i]
        if existing == inst then
            return  -- already tracked
        end
        local ok = pcall(function() return existing:get_type_definition() end)
        if not ok then
            table.remove(_known_instances, i)
            log_discovery("dropped dead instance (remaining=" .. #_known_instances .. ")")
        end
    end

    table.insert(_known_instances, inst)
    log_discovery("instance tracked via " .. source
               .. " (total=" .. #_known_instances .. ")")
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
    _sdk.hacking_mgr_td   = td("app.HackingManager")

    _init_report.snake_td     = _sdk.snake_td ~= nil
    _init_report.accessor_td  = _sdk.grid_accessor_td ~= nil
    _init_report.cell_td      = _sdk.grid_cell_td ~= nil
    _init_report.unit_td      = _sdk.unit_td ~= nil
    _init_report.grid_type_td = _sdk.grid_type_td ~= nil

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

    _init_report.m_get_size_x       = _sdk.m_get_size_x       ~= nil
    _init_report.m_get_size_y       = _sdk.m_get_size_y       ~= nil
    _init_report.m_get_start        = _sdk.m_get_start_pos    ~= nil
    _init_report.m_get_name         = _sdk.m_get_name         ~= nil
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

local function get_instance()
    if not ensure_init() then return nil end

    -- Garbage-collect dead handles before the lookup, so a stale entry
    -- doesn't shadow a live one that happens to share a target reference.
    for i = #_known_instances, 1, -1 do
        local existing = _known_instances[i]
        local ok = pcall(function() return existing:get_type_definition() end)
        if not ok then
            table.remove(_known_instances, i)
            log_discovery("dropped dead instance (remaining=" .. #_known_instances .. ")")
        end
    end

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
    for _, inst in ipairs(_known_instances) do
        local ok, this_target = pcall(function()
            return inst:get_field("_TargetPuzzleUnit")
        end)
        if ok and this_target == target_unit then
            return inst
        end
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

    return {
        x = pos.x, y = pos.y,
        type_hash         = type_hash,
        type              = resolve_type_name(type_hash),
        in_trail          = in_trail,
        is_erase          = is_erase,
        active_skill_hash = active_skill_hash,
        active_skill_type = active_skill_type,
        in_way_hash       = in_way_hash,
        in_way_type       = in_way_hash and resolve_type_name(in_way_hash) or nil,
        out_way_hash      = out_way_hash,
        out_way_type      = out_way_hash and resolve_type_name(out_way_hash) or nil,
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

    -- Build cells[y+1][x+1] table. Lua-1-indexed for ipairs friendliness.
    local cells = {}
    for y = 1, height do
        cells[y] = {}
        for x = 1, width do
            cells[y][x] = nil
        end
    end

    local count = 0
    local trail = {}
    for_each_cell(inst, function(cell_obj)
        local cell = read_cell(cell_obj)
        if cell == nil then return end
        count = count + 1
        local x, y = cell.x, cell.y
        if x >= 0 and x < width and y >= 0 and y < height then
            cells[y + 1][x + 1] = cell
            if cell.in_trail then
                table.insert(trail, { x = x, y = y })
            end
        end
    end)

    if count == 0 then
        return nil
    end

    -- Cursor position from _CurrentUnit.
    local cursor = nil
    local ok_cu, unit = pcall(function() return inst:get_field("_CurrentUnit") end)
    if ok_cu and unit ~= nil and _sdk.m_unit_get_position ~= nil then
        local ok_p, pos_raw = pcall(function() return _sdk.m_unit_get_position:call(unit) end)
        if ok_p then cursor = read_int2(pos_raw) end
    end

    -- Start position from accessor.
    local start_pos = nil
    if _sdk.m_get_start_pos ~= nil then
        local ok, sp = pcall(function() return _sdk.m_get_start_pos:call(acc) end)
        if ok then start_pos = read_int2(sp) end
    end

    -- Goal cell: scan for the cell whose type name is "Goal". The hash is
    -- known from the dump (1599924820) but resolving by name is portable
    -- across patches that might re-roll hashes.
    local goal = nil
    for y = 1, height do
        for x = 1, width do
            local c = cells[y][x]
            if c ~= nil and c.type == "Goal" then
                goal = { x = c.x, y = c.y }
                break
            end
        end
        if goal then break end
    end

    return {
        width  = width,
        height = height,
        cursor = cursor,
        start  = start_pos,
        goal   = goal,
        cells  = cells,
        trail  = trail,
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


-- Direction-style wrapper around write_next_move_position. Resolves the
-- absolute target from the current cursor + delta, bounds-checks, then
-- delegates. Use this from debug buttons / experimental tick paths.
function M.move_via_next_position(direction)
    local delta = DIR_DELTAS[direction]
    if delta == nil then return false, "invalid direction: " .. tostring(direction) end

    local unit, err = _resolve_unit()
    if unit == nil then return false, err end

    local pos = _read_cursor_pos(unit)
    if pos == nil then return false, "couldn't read cursor position" end
    local target_x = pos.x + delta.x
    local target_y = pos.y + delta.y

    local w, h = _read_grid_dims()
    if w ~= nil and h ~= nil then
        if target_x < 0 or target_x >= w or target_y < 0 or target_y >= h then
            return false, string.format(
                "move %s rejected: target (%d,%d) out of bounds (grid %dx%d)",
                direction, target_x, target_y, w, h)
        end
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
-- Plan dispatch
-- ---------------------------------------------------------------------------
-- Queues a sequence of directions and dispatches them one at a time via
-- M.move_via_next_position() — the input-pipeline path that mimics player
-- input. A small inter-move cooldown plus a wait for the cursor's isMove
-- flag prevents us from outpacing the engine's per-cell transition.

local _plan_queue = {}
local _plan_dispatch_cooldown = 0   -- frames remaining before next dispatch
local _plan_cooldown_frames = 8     -- ~130ms at 60fps
local _plan_last_msg = nil          -- diagnostic: last move() result

function M.queue_plan(directions)
    if type(directions) ~= "table" then return 0 end
    local queued = 0
    for _, d in ipairs(directions) do
        if DIR_DELTAS[d] ~= nil then
            table.insert(_plan_queue, d)
            queued = queued + 1
        end
    end
    return queued
end

function M.clear_plan()
    _plan_queue = {}
    _plan_dispatch_cooldown = 0
end

function M.plan_status()
    return {
        queue_size  = #_plan_queue,
        cooldown    = _plan_dispatch_cooldown,
        active      = M.is_active(),
        unit_moving = M.is_unit_moving(),
        last_msg    = _plan_last_msg,
    }
end

-- Per-frame tick. Wire into pragmata_main.lua's re.on_frame loop.
function M.tick_plan()
    -- If puzzle ends mid-plan (success/failure trigger fired), drop the
    -- remaining moves; they're stale relative to whatever happens next.
    if #_plan_queue > 0 and not M.is_active() then
        log.info("tick_plan: puzzle no longer active; dropping "
              .. tostring(#_plan_queue) .. " queued moves")
        _plan_queue = {}
        _plan_dispatch_cooldown = 0
        return
    end

    if _plan_dispatch_cooldown > 0 then
        _plan_dispatch_cooldown = _plan_dispatch_cooldown - 1
        return
    end

    if #_plan_queue == 0 then return end

    -- Cursor is mid-cell-transition — let it settle before the next move.
    if M.is_unit_moving() then return end

    local dir = table.remove(_plan_queue, 1)
    local ok, msg = M.move_via_next_position(dir)
    _plan_last_msg = string.format("move %s: %s",
                                   dir, tostring(msg or (ok and "ok" or "error")))
    log.info("tick_plan: " .. _plan_last_msg)
    _plan_dispatch_cooldown = _plan_cooldown_frames

    -- Abort the rest of the queue on a rejected move (OOB, no unit, etc.).
    -- Continuing would dispatch follow-up moves from a position the plan
    -- didn't expect — better to stop and let the AI replan if it wants.
    if not ok then
        log.warn("tick_plan: move rejected; dropping remaining "
              .. tostring(#_plan_queue) .. " queued moves")
        _plan_queue = {}
        return
    end

    -- Goal arrival auto-completes the puzzle now — the engine's
    -- updatePuzzleMovement → onEnterGrid pipeline runs the full natural
    -- completion (COMPLETE overlay, hack damage commit, dialogue
    -- progression, auto-reset) when the cursor enters the Goal cell.
    -- The old code wrote _RequestForceSuccess on goal arrival as a
    -- workaround for Unit.move(via.Int2) bypassing the goal check;
    -- that's unnecessary on the input-pipeline path.
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
