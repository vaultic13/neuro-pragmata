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
--       Ch16092=4, Ch14100=8, AllPassed=16. The ObstacleGrid bit is the
--       single-cell red error node. Ch16092/Ch14100 are named after the two
--       enemies whose grids carry the large red BLOCK rectangles (see
--       bindings/puzzle_snake_modifiers.lua); they were once taken for purple
--       "slow" nodes, which the dump does not support. DeadFilament is the
--       corruption marker (with _DeadFilamentType); AllPassed is a completion
--       flag. See read_cell.
--     - _DeadFilamentType (UInt32)               -- app.DeadFilamentType hash
--       (None | Random | Fixed): a corrupted ("dead filament") cell.

local log = require("pragmata.util.log")
local modifiers = require("pragmata.bindings.puzzle_snake_modifiers")
local _render_mod = require("pragmata.util.snake_render")
local config = require("pragmata.mod_config")
-- Which sector the player is in, for the corruption gate's per-sector
-- exemption. Optional: without it the gate applies everywhere.
local area_progress = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.area_progress")
    if ok then area_progress = mod end
end

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
    pause_mgr_td = nil,      -- app.PauseManager
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
    m_is_paused = nil,       -- app.PauseManager.isPaused()
    enhance_mgr_td = nil,    -- app.EnhanceManager (managed singleton; equipped hacking style)
    mode_td = nil,           -- app.PuzzleSnakeMode (smart-enum; getName for engine label)
    m_get_cur_mode = nil,    -- EnhanceManager.getCurrentPuzzleSnakeMode() -> UInt32 hash
    m_mode_getname = nil,    -- PuzzleSnakeMode.getName(UInt32) -> String
    skill_td = nil,          -- app.ActiveSkill (smart-enum; getName for engine label)
    m_skill_getname = nil,   -- ActiveSkill.getName(UInt32) -> String
    m_get_equipped_skills = nil, -- EnhanceManager.getEquippedActiveSkillInfos() -> ActiveSkillItemInfo[]
    m_skill_to_id = nil,     -- EnhanceManager.convertActiveSkillToActiveSkillID(UInt32 enumHash) -> UInt32 objectID
}

-- Hacking "modes" (equipped at the Tram Terminal). The mode decides what the
-- blue OPEN nodes turn into on an EXPOSED (repeat) hack. Only offense actually
-- retypes the cell's _GridType (-> Attack); every other mode leaves the node as
-- Open and changes its EFFECT, so the mode value (not the grid) is the only way
-- to know which is in play. Keyed by the app.PuzzleSnakeMode member hash (6
-- members, CountOf=6). `style` is the in-game card name; nil style = no banner.
local PUZZLE_SNAKE_MODES = {
    [1106175613] = { key = "Default", style = nil,       desc = nil },
    [1092595404] = { key = "Attack",  style = "Offense",
        desc = "the blue OPEN nodes ('O') turn into blue ATTACK nodes ('A') on an exposed hack - route through the A nodes just like O nodes; they raise the damage of your next hack." },
    [2947211997] = { key = "Mix",     style = "Hybrid",
        desc = "on an exposed hack you get a mix of blue OPEN ('O') and blue ATTACK ('A') nodes - route through BOTH; you get more damage AND a longer vulnerable window." },
    [1992221496] = { key = "OneShot", style = "Strike",
        desc = "the blue OPEN ('O') nodes become STRIKE nodes on an exposed hack - they hit harder, so route through them as usual." },
    [402367616]  = { key = "Active",  style = "Boost",
        desc = "the blue OPEN ('O') nodes become BOOST nodes on an exposed hack - route through a boost node AND a yellow skill node ('*') on the way to the goal to amplify that skill's effect." },
    [4064461264] = { key = "Heat",    style = "Combust",
        desc = "the blue OPEN ('O') nodes become HEAT nodes on an exposed hack - route through them to build the heat gauge and overheat the enemy faster." },
}

-- Equipped hacking SKILL (the yellow '*' node on the grid). app.ActiveSkill is a
-- 9-member smart-enum (8 skills + None); only ONE can be equipped, so only one
-- ever appears on a grid. Keyed by the ActiveSkill member hash. `display` is the
-- in-game card name (some differ from the internal enum name): Stun=Freeze,
-- Shock=Expose, DefenseDown=Decode (in-game confirmed); rest match. `desc` is a
-- self-contained, AI-facing sentence for that skill node. nil display = None.
local ACTIVE_SKILLS = {
    [3965989474] = { key = "Chain",       display = "Chain",       grid_type = "Chain",
        desc = "passing through it lets the hack keep going after the goal; each chain stacks more damage, released all at once when you finish a puzzle WITHOUT a chain node." },
    [2636730176] = { key = "Drain",       display = "Drain",
        desc = "route through it to siphon enemy filament and slowly repair the suit." },
    [1601673713] = { key = "Stun",        display = "Freeze",
        desc = "route through it to briefly stun the target." },
    [4064461264] = { key = "Heat",        display = "Heat",
        desc = "route through it to make the enemy overheat more easily; passing through several extends the effect." },
    [2139049636] = { key = "DefenseDown", display = "Decode",
        desc = "route through it to disrupt the enemy's internal systems and temporarily raise damage dealt; passing through several boosts damage further." },
    [939523450]  = { key = "Confuse",     display = "Confuse",
        desc = "route through it to disrupt the enemy's sensors and cause friendly fire (effect varies by bot); passing through several increases friendly-fire damage." },
    [4176994072] = { key = "Multi",       display = "Multihack",
        desc = "route through it to link enemies and open multiple targets; OPEN time is extended but per-target damage is reduced; passing through several extends OPEN duration." },
    [3784658649] = { key = "Shock",       display = "Expose",
        desc = "route through it so the next hack deals critical damage and staggers the target; passing through several increases the damage." },
    [139421919]  = { key = "None",        display = nil,        desc = nil },
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
            -- If this puzzle owed a deferred action result (its plan was still
            -- pending/parked), resolve it now so the tool call doesn't dangle
            -- forever. Inlined (the shared _resolve_pending is declared later).
            if existing.pending_resolve then
                local cb = existing.pending_resolve
                existing.pending_resolve = nil
                pcall(cb, false, "The hack target is gone; the plan was abandoned.")
            end
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
    _sdk.pause_mgr_td     = td("app.PauseManager")
    _sdk.enhance_mgr_td   = td("app.EnhanceManager")
    _sdk.mode_td          = td("app.PuzzleSnakeMode")

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
    -- app.PauseManager.isPaused() — the no-arg overload returns true while ANY
    -- pause type is active (pause menu, system pause). Used to halt forcing +
    -- dispatch so a paused, frozen cursor isn't misread as a wall-blocked move.
    _sdk.m_is_paused         = method(_sdk.pause_mgr_td, "isPaused()")
    -- Equipped hacking style. EnhanceManager.getCurrentPuzzleSnakeMode() returns
    -- a hash into app.PuzzleSnakeMode; getName turns a hash into the engine's own
    -- label (cross-check vs PUZZLE_SNAKE_MODES). Both no-arg/single-arg overloads
    -- are tried (signature spelling varies across REFramework builds).
    _sdk.m_get_cur_mode      = method(_sdk.enhance_mgr_td, "getCurrentPuzzleSnakeMode()")
        or method(_sdk.enhance_mgr_td, "getCurrentPuzzleSnakeMode")
    _sdk.m_mode_getname      = method(_sdk.mode_td, "getName(System.UInt32)")
    -- Equipped active SKILL (the '*' node). getEquippedActiveSkillInfos() returns
    -- ActiveSkillItemInfo[] (.ID = an ObjectID, NOT the enum hash), so we match
    -- the equipped ID against convertActiveSkillToActiveSkillID(enumHash) to
    -- recover the app.ActiveSkill enum member.
    _sdk.skill_td            = td("app.ActiveSkill")
    _sdk.m_skill_getname     = method(_sdk.skill_td, "getName(System.UInt32)")
    _sdk.m_get_equipped_skills = method(_sdk.enhance_mgr_td, "getEquippedActiveSkillInfos()")
        or method(_sdk.enhance_mgr_td, "getEquippedActiveSkillInfos")
    _sdk.m_skill_to_id       = method(_sdk.enhance_mgr_td, "convertActiveSkillToActiveSkillID(System.UInt32)")

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
-- Coarse lifecycle of a PuzzleSnake instance, used to break ties when more
-- than one tracked instance is bound to the same enemy:
--   "ended"    -> a finish trigger is set (success/failed) — a completed,
--                 leftover instance. Picking it makes is_active() permanently
--                 false (is_active bails on _SuccessTrigger), so the enemy
--                 looks "invisible": no _StartTrg, no force ever emitted.
--   "idle"     -> not ended but _State == Stop(0); not yet (or no longer)
--                 accepting input.
--   "playable" -> _State == Play, or state unreadable (assume playable so a
--                 reflection hiccup never hides a live puzzle).
-- read_bool isn't in scope yet here (defined below), so read inline.
local function _instance_lifecycle(inst)
    local function flag(name)
        local ok, v = pcall(function() return inst:get_field(name) end)
        return ok and v == true
    end
    if flag("_SuccessTrigger") or flag("_FailedTrigger") then return "ended" end
    local ok_s, st = pcall(function() return inst:get_field("_State") end)
    if ok_s and type(st) == "number" and st == 0 then return "idle" end
    return "playable"
end

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
    --
    -- The engine pools/leaks instances (observed 80+ alive at once), and a
    -- previously-hacked enemy can leave a COMPLETED PuzzleSnake bound to the
    -- same _TargetPuzzleUnit as the live one — verified in-game: matched
    -- instance had _SuccessTrigger=true, _State=Stop, cursor parked on goal,
    -- so is_active() stayed false and the enemy was un-forceable. So don't
    -- just take the first match: prefer a PLAYABLE instance, fall back to a
    -- non-ended one, and only return an ended instance if it's the sole match
    -- (end-of-hack handlers still need to resolve the just-completed puzzle).
    local first_match, not_ended = nil, nil
    for _, rec in ipairs(_known_instances) do
        local ok, this_target = pcall(function()
            return rec.inst:get_field("_TargetPuzzleUnit")
        end)
        if ok and this_target == target_unit then
            first_match = first_match or rec
            local life = _instance_lifecycle(rec.inst)
            if life == "playable" then
                return rec               -- best possible match; take it
            elseif life == "idle" then
                not_ended = not_ended or rec
            end
        end
    end

    return not_ended or first_match
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
    if v ~= nil and v == 0 then return false end
    -- The final boss's last stage is not playable yet while its opening
    -- sequence runs, whatever _State says. See M.finale_hold_reason.
    if M.finale_hold_reason() ~= nil then return false end
    return true
end


-- The final boss's last stage (2026-10-08). It opens with a scripted sequence
-- (Diana: "Let me try something!" ... "Optimizing hacking matrix: Initiate!")
-- in which the grid shrinks a few times, ~14 s from when it appears. Through
-- all of it the puzzle reads exactly like a playable one -- _State Play, GUI
-- up, no move block, no queued grid change; a full field dump at the start of
-- the sequence matched a playable grid field for field. So the mod forced it
-- and drove the cursor to the goal mid-sequence; the stage "succeeded", the
-- animation was cut, the hack UI vanished and the game could not go on.
-- Without the mod, or with hacking_auto_force off, it plays fine.
--
-- Nothing marks the sequence, but the stage itself is unmistakable: the same
-- authored 7x7 grid every run (the fifth of the finale's five fixed stages,
-- see FINALE_STAGES at the end of the file). On that grid ONLY, the puzzle
-- counts as not taking input for mod_config.hack_finale_hold_seconds after it
-- first appears -- no force, no dispatch. Every other grid is untouched.
local _last_hold_reason = nil
local _finale_hold          -- assigned at the end of the file (needs later locals)

function M.finale_hold_reason()
    local reason = _finale_hold and _finale_hold() or nil
    if reason ~= _last_hold_reason then
        log.info("puzzle_snake: finale hold " .. (reason and ("ON: " .. reason) or "off"))
        _last_hold_reason = reason
    end
    return reason
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


-- Resolve the app.PauseManager singleton. Cached after first success. Tries the
-- native singleton registry first, then the static get_sPauseManager accessor.
local _pause_mgr = nil
local function _get_pause_manager()
    if _pause_mgr ~= nil then
        local ok = pcall(function() return _pause_mgr:get_type_definition() end)
        if ok then return _pause_mgr end
        _pause_mgr = nil
    end
    local ok, mgr = pcall(function()
        return sdk.get_managed_singleton("app.PauseManager")
    end)
    if ok and mgr ~= nil then _pause_mgr = mgr; return mgr end
    -- Fallback: the static sPauseManager accessor (PauseManager may not be in
    -- the via singleton registry on every build).
    if _sdk.pause_mgr_td ~= nil then
        local getter = nil
        pcall(function() getter = _sdk.pause_mgr_td:get_method("get_sPauseManager") end)
        if getter ~= nil then
            local ok2, m2 = pcall(function() return getter:call(nil) end)
            if ok2 and m2 ~= nil then _pause_mgr = m2; return m2 end
        end
    end
    return nil
end


-- True while the game is paused (pause menu / system pause). The hacking
-- observer halts forcing AND the dispatcher halts move execution while paused:
-- a paused cursor never moves, so a dispatched move would never land where the
-- plan expected, churning re-forces forever (and the post-move position check
-- would misclassify the frozen cursor as wall-blocked). Conservative: unreadable
-- => false, so a reflection hiccup never silently freezes planning for good.
function M.is_game_paused()
    ensure_init()
    if _sdk.m_is_paused == nil then return false end
    local mgr = _get_pause_manager()
    if mgr == nil then return false end
    local ok, v = pcall(function() return _sdk.m_is_paused:call(mgr) end)
    return ok and v == true
end


-- ---------------------------------------------------------------------------
-- Equipped hacking style (app.PuzzleSnakeMode)
-- ---------------------------------------------------------------------------
local _enhance_mgr = nil
local function _get_enhance_manager()
    if _enhance_mgr ~= nil then
        local ok = pcall(function() return _enhance_mgr:get_type_definition() end)
        if ok then return _enhance_mgr end
        _enhance_mgr = nil
    end
    local ok, mgr = pcall(function()
        return sdk.get_managed_singleton("app.EnhanceManager")
    end)
    if ok and mgr ~= nil then _enhance_mgr = mgr end
    return _enhance_mgr
end

-- Read the player's currently-equipped hacking style. The mode dictates what
-- OPEN nodes become on an exposed hack (see PUZZLE_SNAKE_MODES). Returns
--   { ok=true, hash, engine_name, key, style, desc }   on success, or
--   { ok=false, err }                                  on failure.
-- Read-only and cheap; safe to poll from the debug panel / get_state. A nil
-- `style` (Default, or unmapped hash) means "no style banner".
function M.read_hacking_mode()
    ensure_init()
    if _sdk.m_get_cur_mode == nil then
        return { ok = false, err = "getCurrentPuzzleSnakeMode method unresolved" }
    end
    local mgr = _get_enhance_manager()
    if mgr == nil then
        return { ok = false, err = "EnhanceManager singleton nil" }
    end
    local ok, hash = pcall(function() return _sdk.m_get_cur_mode:call(mgr) end)
    if not ok or hash == nil then
        return { ok = false, err = "getCurrentPuzzleSnakeMode call failed" }
    end
    -- The engine's own label for this hash — lets us spot an unmapped/new hash
    -- (engine_name set but key="Unknown") rather than silently mis-mapping.
    local engine_name = nil
    if _sdk.m_mode_getname ~= nil then
        local ok2, n = pcall(function() return _sdk.m_mode_getname:call(nil, hash) end)
        if ok2 and type(n) == "string" then engine_name = n end
    end
    local info = PUZZLE_SNAKE_MODES[hash]
    return {
        ok          = true,
        hash        = hash,
        engine_name = engine_name,
        key         = info and info.key or "Unknown",
        style       = info and info.style or nil,
        desc        = info and info.desc or nil,
    }
end


-- Read the player's currently-equipped active SKILL (the '*' node). Returns
--   { ok=true, none=true, count=0 }                       if no skill equipped, or
--   { ok=true, count, equipped_id, key, display, desc, engine_name }  on success, or
--   { ok=false, err }                                     on failure.
-- The equipped info's .ID is an ObjectID; we recover the app.ActiveSkill enum by
-- matching it against convertActiveSkillToActiveSkillID(hash) for each member.
-- Read-only; safe to poll. A nil `display` means None / unmatched.
function M.read_active_skill()
    ensure_init()
    if _sdk.m_get_equipped_skills == nil then
        return { ok = false, err = "getEquippedActiveSkillInfos method unresolved" }
    end
    local mgr = _get_enhance_manager()
    if mgr == nil then
        return { ok = false, err = "EnhanceManager singleton nil" }
    end
    local ok, infos = pcall(function() return _sdk.m_get_equipped_skills:call(mgr) end)
    if not ok then
        return { ok = false, err = "getEquippedActiveSkillInfos call failed" }
    end
    if infos == nil then return { ok = true, none = true, count = 0, distinct = 0 } end

    -- Array length (REFramework SystemArray): try get_size, then get_Length.
    -- NOTE: this is the equipped-slot CAPACITY, not the number of skills set, so
    -- empty slots are normal — we must scan and count DISTINCT matched skills.
    local count = 0
    if not pcall(function() count = infos:get_size() end) then
        pcall(function() count = infos:get_Length() end)
    end
    if type(count) ~= "number" then count = 0 end

    -- ObjectID -> skill lookup, built once from the 8 enum->ID conversions.
    local id_to_skill = {}
    if _sdk.m_skill_to_id ~= nil then
        for hash, info in pairs(ACTIVE_SKILLS) do
            if info.key ~= "None" then
                local oid = nil
                local okc = pcall(function() oid = _sdk.m_skill_to_id:call(mgr, hash) end)
                if okc and oid ~= nil then id_to_skill[oid] = { hash = hash, info = info } end
            end
        end
    end

    -- Scan every equipped slot; collect distinct real skills (skip empty/None).
    local first_id = nil
    local matched, order = {}, {}
    for i = 0, count - 1 do
        local elem = nil
        if not pcall(function() elem = infos:get_element(i) end) then
            pcall(function() elem = infos[i] end)
        end
        if elem ~= nil then
            local id = nil
            if not pcall(function() id = elem:get_field("<ID>k__BackingField") end) then
                pcall(function() id = elem:call("get_ID") end)
            end
            if id ~= nil and id ~= 0 then
                if first_id == nil then first_id = id end
                local m = id_to_skill[id]
                if m ~= nil and matched[m.info.key] == nil then
                    matched[m.info.key] = m
                    order[#order + 1] = m.info.key
                end
            end
        end
    end

    local distinct = #order
    if distinct == 0 then
        return { ok = true, none = true, count = count, distinct = 0, equipped_id = first_id }
    end

    local m = matched[order[1]]
    local engine_name = nil
    if _sdk.m_skill_getname ~= nil then
        pcall(function() engine_name = _sdk.m_skill_getname:call(nil, m.hash) end)
    end

    return {
        ok          = true,
        count       = count,        -- raw slot capacity
        distinct    = distinct,     -- number of DISTINCT real skills equipped
        multiple    = distinct > 1, -- true with the Code Generator weapon
        equipped_id = first_id,
        key         = m.info.key,
        display     = m.info.display,
        desc        = m.info.desc,
        grid_type   = m.info.grid_type,   -- dedicated grid type (Chain), else nil
        engine_name = engine_name,
    }
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


-- app.PuzzleSnake.ObstacleReason bitmask values (decoded from the IL2CPP
-- dump): ObstacleGrid=1, DeadFilament=2, Ch16092=4, Ch14100=8, AllPassed=16.
-- Each bit is a different mechanic with a different consequence, so each gets
-- its own reading (and glyph):
--   * ObstacleGrid(1): the single-cell red "error node" -- entering one RESETS
--     the hack (verified in-game 2026-06-10). is_blocked, 'd'.
--   * DeadFilament(2): corruption -- walkable, stuns the cursor briefly.
--     corrupted, 'c' (with _DeadFilamentType).
--   * Ch16092(4)/Ch14100(8): the large red BLOCK rectangles of the antenna
--     enemies -- touching one FAILS the hack (verified in-game 2026-10-08).
--     block_bit -> in_block, 'R'.
--   * AllPassed(16): a completion flag, not an obstacle at all.
-- Treating the whole nonzero mask as "blocked" once mislabeled walkable cells
-- as error nodes, so the peer routed around cells it needed to cross.
local OBSTACLE_REASON_ERROR_NODE = 1   -- ObstacleReason.ObstacleGrid
-- The rectangles read by puzzle_snake_modifiers are the primary source for the
-- blocks, these bits the per-cell cross-check.
local OBSTACLE_REASON_BLOCK_BITS = { 4, 8 }
-- ObstacleReason.DeadFilament: the corruption marker (Part B).
local OBSTACLE_REASON_CORRUPTION = 2

-- Test whether a single power-of-two bit is set in `mask`. Pure arithmetic so
-- it doesn't depend on the LuaJIT `bit` library being present.
local function has_bit(mask, bit_value)
    if mask == nil or mask == 0 then return false end
    return (mask % (bit_value * 2)) >= bit_value
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

    -- _ObstacleReasons is a bitmask (see OBSTACLE_REASON_ERROR_NODE notes
    -- above). VERIFIED in-game 2026-06-10: a grid's four red warning-triangle
    -- cells were exactly the cells with the ObstacleGrid bit (=1) set, and
    -- is_blocked is that bit alone. The Ch16092/Ch14100 bits mark the large
    -- red block rectangles (block_bit, cross-checked against the rectangles in
    -- get_state); DeadFilament marks corruption; AllPassed is a completion
    -- flag. The engine can set/clear the bits mid-fight, which the structural
    -- signature turns into a replan. _IsHide marks not-yet-revealed nodes
    -- (seen on FinishBlow). _StunReasons is the analogous stun bitmask; no
    -- nonzero observation yet — dump-only.
    local is_hide          = read_bool(cell_obj, "_IsHide", false)
    local obstacle_reasons = read_uint_field("_ObstacleReasons")
    local stun_reasons     = read_uint_field("_StunReasons")
    local is_blocked       = has_bit(obstacle_reasons, OBSTACLE_REASON_ERROR_NODE)
    local block_bit        = false
    for _, b in ipairs(OBSTACLE_REASON_BLOCK_BITS) do
        if has_bit(obstacle_reasons, b) then block_bit = true end
    end
    -- Corruption ("dead filament"): any of the three markers the dump offers
    -- -- the per-cell _DeadFilamentType, the DeadFilament obstacle bit, or a
    -- cell whose type is DeadFilament. Walkable; it stuns the cursor briefly.
    local type_name        = resolve_type_name(type_hash)
    local corrupted        = dead_filament_type ~= nil
        or has_bit(obstacle_reasons, OBSTACLE_REASON_CORRUPTION)
        or type_name == "DeadFilament"

    return {
        x = pos.x, y = pos.y,
        type_hash          = type_hash,
        type               = type_name,
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
        block_bit          = block_bit,   -- per-cell red-block marker (see get_state)
        corrupted          = corrupted,   -- corruption: walkable, stuns briefly
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
    local engine_cursor = nil
    local ok_cu, unit = pcall(function() return inst:get_field("_CurrentUnit") end)
    if ok_cu and unit ~= nil and _sdk.m_unit_get_position ~= nil then
        local ok_p, pos_raw = pcall(function() return _sdk.m_unit_get_position:call(unit) end)
        if ok_p then
            engine_cursor = read_int2(pos_raw)
            cursor = remap(engine_cursor)
        end
    end

    -- Backtrack target: the one visited cell the cursor may REVERSE onto. The
    -- engine's undo lets the cursor step straight back the way it came (which
    -- frees that cell again); no other ~ cell is re-enterable. It's the cursor
    -- minus the Unit's _LastMoveDirection. Computed in engine space (skip-safe)
    -- then mapped, and only honored if it's actually a visited cell.
    local came_from = nil
    if ok_cu and unit ~= nil and engine_cursor ~= nil then
        local ok_d, dir_raw = pcall(function() return unit:get_field("_LastMoveDirection") end)
        local dir = ok_d and read_int2(dir_raw) or nil
        if dir ~= nil and (dir.x ~= 0 or dir.y ~= 0) then
            local cf = remap({ x = engine_cursor.x - dir.x, y = engine_cursor.y - dir.y })
            if cf ~= nil then
                for _, p in ipairs(trail) do
                    if p.x == cf.x and p.y == cf.y then came_from = cf; break end
                end
            end
        end
    end

    -- Start position from accessor (remapped; nil if its row/col is removed).
    local start_pos = nil
    if _sdk.m_get_start_pos ~= nil then
        local ok, sp = pcall(function() return _sdk.m_get_start_pos:call(acc) end)
        if ok then start_pos = remap(read_int2(sp)) end
    end

    -- Full backtrack route. The engine's `_History` stack (app.PuzzleSnake.Unit
    -- ._History : Stack<via.Int2>) is the ORDERED list of visited positions, so
    -- we can surface the whole return path, not just the one cell behind the
    -- cursor. For each visited cell we record its "backtrack-in" direction = the
    -- way to MOVE to step back onto it while retracing toward start (= reverse
    -- of how the cursor left it). The renderer draws these as arrows so the AI
    -- can plan a multi-cell reverse in one go. Falls back to the single
    -- came_from above if the history is unreadable / doesn't reconcile.
    local trail_back = nil
    if ok_cu and unit ~= nil and cursor ~= nil then
        local path = nil
        local ok_h, hist = pcall(function() return unit:get_field("_History") end)
        if ok_h and hist ~= nil then
            local size = 0
            pcall(function() size = hist:get_field("_size") or 0 end)
            local arr = nil
            pcall(function() arr = hist:get_field("_array") end)
            if type(size) == "number" and size > 0 and arr ~= nil then
                path = {}
                for i = 0, size - 1 do
                    local elem
                    local ok_e = pcall(function() elem = arr[i] end)
                    if not ok_e or elem == nil then
                        pcall(function() elem = arr:get_element(i) end)
                    end
                    local rp = elem and remap(read_int2(elem)) or nil
                    if rp ~= nil then path[#path + 1] = rp end
                end
            end
        end
        if path ~= nil and #path >= 2 then
            local function eq(a, b) return a and b and a.x == b.x and a.y == b.y end
            local function adj(a, b)
                return a and b and (math.abs(a.x - b.x) + math.abs(a.y - b.y)) == 1
            end
            -- The history may or may not include the live cursor; if an end is
            -- adjacent to it, splice the cursor on so orientation works.
            if not eq(path[1], cursor) and not eq(path[#path], cursor) then
                if adj(path[#path], cursor) then path[#path + 1] = cursor
                elseif adj(path[1], cursor) then table.insert(path, 1, cursor) end
            end
            -- Orient so the cursor is LAST (path runs start -> cursor).
            if eq(path[1], cursor) then
                local r = {}
                for i = #path, 1, -1 do r[#r + 1] = path[i] end
                path = r
            end
            if eq(path[#path], cursor) then
                trail_back = {}
                for i = 1, #path - 1 do
                    local a, b = path[i], path[i + 1]   -- a nearer start, b nearer cursor
                    local dx, dy = a.x - b.x, a.y - b.y -- move from b to step onto a
                    local dir = nil
                    if dx == 0 and dy == -1 then dir = "up"
                    elseif dx == 0 and dy == 1 then dir = "down"
                    elseif dx == -1 and dy == 0 then dir = "left"
                    elseif dx == 1 and dy == 0 then dir = "right" end
                    if dir then trail_back[a.x .. "," .. a.y] = dir end
                end
            end
        end
    end

    -- Goal cell: scan for the cell whose type name is "Goal". The hash is
    -- known from the dump (1599924820) but resolving by name is portable
    -- across patches that might re-roll hashes.
    local goal = nil
    local goal_engine = nil
    for y = 1, #active_rows do
        for x = 1, #active_cols do
            local c = cells[y][x]
            if c ~= nil and c.type == "Goal" then
                goal = { x = c.x, y = c.y }
                -- Engine coords too: the dispatcher compares a move's engine
                -- target against this to tell "stepped onto the goal" (= the
                -- hack completed) from an error-node reset.
                goal_engine = { x = c.engine_x, y = c.engine_y }
                break
            end
        end
        if goal then break end
    end

    -- Red block rectangles (puzzle_snake_modifiers). A cell is in a block when
    -- an ACTIVE rectangle covers its engine position, or -- the cross-check,
    -- and the only source when the rectangles can't be read -- when it carries
    -- a block bit. block_index names which rectangle (nil = bit only).
    local blocks = modifiers.read_blocks(inst)
    local block_info = nil
    if blocks ~= nil then
        local next_corner, up = nil, {}
        for _, r in ipairs(blocks.rects) do
            r.corner = modifiers.corner(r, width, height)
            if r.active then
                up[#up + 1] = r.corner
                if next_corner == nil then next_corner = r.corner end
            end
        end
        block_info = {
            source = blocks.source, total = blocks.total, active = blocks.active,
            impossible = blocks.impossible, next_corner = next_corner, corners_up = up,
        }
    end
    for ry = 1, #active_rows do
        for rx = 1, #active_cols do
            local c = cells[ry][rx]
            if c ~= nil then
                if blocks ~= nil then
                    for _, r in ipairs(blocks.rects) do
                        if r.active and r.x0 ~= nil
                            and c.engine_x >= r.x0 and c.engine_x <= r.x1
                            and c.engine_y >= r.y0 and c.engine_y <= r.y1 then
                            c.in_block = true
                            c.block_index = r.index
                            break
                        end
                    end
                end
                if c.block_bit then c.in_block = true end
            end
        end
    end

    -- Corruption: decided by the corrupted cells -- what the player sees, and
    -- field reads only. The module's isDeadFilament() is a method call, kept to
    -- the F5 snapshot (see the top of puzzle_snake_modifiers.lua).
    local corrupted_cells = 0
    for ry = 1, #active_rows do
        for rx = 1, #active_cols do
            local c = cells[ry][rx]
            if c ~= nil and c.corrupted and not c.in_block then
                corrupted_cells = corrupted_cells + 1
            end
        end
    end
    local corruption_info = nil
    if corrupted_cells > 0 then
        corruption_info = { cells = corrupted_cells }
    end

    -- Explosions (the boss's attack system). Each pulsing or exploding cell
    -- gets c.danger = { explodes_in, ends_in, exploding } in seconds from now;
    -- where two units overlap, the earliest start and the latest end win. The
    -- engine reports ENGINE coordinates, so they go through remap() like
    -- everything else -- a row a sticky bomb removed is simply not there.
    -- Not structural: _struct_sig_from_state ignores c.danger, so a row going
    -- off never reads as "the grid changed".
    local explosion_info = nil
    local danger = modifiers.read_danger(inst)
    if danger ~= nil then
        explosion_info = { live = #danger.units, exploding = false }
        for _, u in ipairs(danger.units) do
            if u.state == "Attack" then explosion_info.exploding = true end
            for _, p in ipairs(u.cells) do
                local rp = remap(p)
                local c = rp and cells[rp.y + 1] and cells[rp.y + 1][rp.x + 1] or nil
                if c ~= nil then
                    local d = c.danger
                    if d == nil then
                        c.danger = { explodes_in = u.explodes_in, ends_in = u.ends_in,
                                     exploding = u.state == "Attack" }
                    else
                        d.explodes_in = math.min(d.explodes_in, u.explodes_in)
                        d.ends_in = math.max(d.ends_in, u.ends_in)
                        d.exploding = d.exploding or u.state == "Attack"
                    end
                end
            end
        end
    end

    -- Equipped hacking style for the renderer's mode note. nil for Default /
    -- unreadable, so the renderer simply omits the line. Read here so the live
    -- force context AND the debug preview both reflect it.
    local mode_info = nil
    local m = M.read_hacking_mode()
    if m and m.ok and m.style then
        mode_info = { key = m.key, style = m.style, desc = m.desc }
    end

    -- Equipped active skill (the '*' node) for the renderer's skill note. ONLY
    -- when exactly ONE skill is equipped — with the "Code Generator" weapon
    -- multiple node types can coexist and we can't tell which '*' is which, so
    -- we fall back to the generic "skill node" rather than mislabel.
    local skill_info = nil
    local sk = M.read_active_skill()
    if sk and sk.ok and not sk.none and sk.distinct == 1 and sk.display then
        skill_info = { key = sk.key, display = sk.display, desc = sk.desc,
                       grid_type = sk.grid_type }
    end

    return {
        width  = #active_cols,
        height = #active_rows,
        cursor = cursor,
        came_from = came_from,   -- the one ~ cell the cursor may reverse onto
        trail_back = trail_back, -- "x,y" -> backtrack-in dir for each visited cell
        start  = start_pos,
        goal   = goal,
        goal_engine = goal_engine,   -- goal in engine coords (completion check)
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
        mode = mode_info,   -- equipped hacking style { key, style, desc } or nil
        active_skill = skill_info,  -- equipped skill { key, display, desc } or nil (count==1 only)
        -- Red blocks: { source, total, active, impossible, next_corner,
        -- corners_up } or nil when this enemy has none.
        blocks = block_info,
        -- Corruption: { cells } or nil when the enemy is clean.
        corruption = corruption_info,
        -- Explosions: { live, exploding } on an enemy with the attack system
        -- (even with nothing pulsing right now), nil otherwise.
        explosions = explosion_info,
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

    -- Return the resolved engine target as extra results so the dispatcher can
    -- record where the cursor is expected to land (used to detect error-node
    -- cursor resets between moves).
    local ok, msg = M.write_next_move_position(target_x, target_y)
    return ok, msg, target_x, target_y
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
-- EraseCode trap, and red (ObstacleGrid) error node. Deliberately EXCLUDES
-- the cursor and the trail (IsPassed) — those advance as a plan executes, so
-- including them would make every normal move look like a "change". Also
-- excludes corrupted cells (c.corrupted): they're walkable, so they're
-- not blockers and shouldn't perturb the plan-validity fingerprint.
-- Red error nodes ARE included: _ObstacleReasons is a runtime bitmask the
-- engine can set/clear mid-fight, and a hazard-map change is exactly when a
-- stale plan needs invalidating. (If error nodes turn out to pulse rapidly, this
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
            elseif c.in_block then
                marks[#marks + 1] = "r" .. x .. "," .. y     -- red block (shooting one away replans)
            elseif c.is_erase or c.type == "EraseCode" then
                marks[#marks + 1] = "x" .. x .. "," .. y     -- trap
            elseif c.is_blocked then
                marks[#marks + 1] = "d" .. x .. "," .. y     -- error node (blocked)
            -- NOTE: corrupted cells (c.corrupted) are intentionally NOT a
            -- structural blocker — those cells are walkable, so they're plain
            -- floor for routing and must not show up as 'd' marks.
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

local _plan_cooldown_frames = 4     -- ~65ms at 60fps (the isMove wait still gates
                                    -- per-cell pacing; halved from 8 to roughly
                                    -- match the game's faster auto-hack cursor)

-- Frames to wait after a move doesn't land before classifying + re-forcing. An
-- error node resets the WHOLE puzzle a few frames AFTER the bad move, so reading
-- the cursor immediately races the reset: it still reads the pre-reset position
-- and the grid still shows the old trail (the "cursor shown one move before the
-- error node" bug). We hold, watch for the cursor to snap back to start (= reset
-- confirmed), and only then re-force — so the next force renders the real, reset
-- grid. Generous so a slow reset animation still resolves as an error-node hit
-- rather than timing out into a wall classification.
local FAIL_SETTLE_FRAMES = 90       -- ~1.5s at 60fps
-- Grace after a plan's queue drains before declaring it fell short of the goal:
-- the goal-arrival success trigger fires a few frames after the final move
-- lands, and we want on_success to claim the deferred result as a WIN first.
local DRAIN_GRACE_FRAMES = 30       -- ~0.5s at 60fps
-- Corruption stuns the cursor after it steps on a corrupted cell; while the
-- engine's move block is up a dispatched move is dropped. The dispatcher holds
-- instead, for at most this long (a block stuck for longer is not a stun).
local STUN_HOLD_MAX_FRAMES = 300    -- ~5s at 60fps
-- A move that didn't land counts as eaten by a stun only if the block was up
-- within this many seconds. The engine's last-move result is NOT used: it
-- stays "Stun" long after the stun, and on 2026-10-08 that made a plain
-- blocked move (onto the plan's own trail) retry five times before failing.
local STUN_GRACE_SECONDS = 0.6
local STUN_MAX_RETRIES = 3

-- One-shot events the dispatcher raises for the observer/overlay to react to
-- ("resumed" a parked plan; "grid_changed" forced a replan; "settling"/"move_failed"
-- around a failed move). Drained via M.consume_plan_events().
local _plan_events = {}
local function _push_plan_event(e) _plan_events[#_plan_events + 1] = e end

-- Resolve a puzzle's DEFERRED action result exactly once. pragmata_hack_plan
-- defers its action/result (sends nothing immediately) so the tool result the AI
-- sees reflects what the plan ACTUALLY did — reached the goal, hit an error node
-- and reset, stopped at a wall, or fell short — instead of a blind "plan applied".
-- The resolve callback (captured from the dispatcher) is stored on the RECORD,
-- not the plan table, so it survives `rec.plan = nil` and fires at any terminal.
-- Returns true iff a pending result was actually resolved (the caller uses this
-- to tell a plan-driven hack ending from a manual/auto one).
local function _resolve_pending(rec, success, message)
    if rec == nil then return false end
    local cb = rec.pending_resolve
    if cb == nil then return false end
    rec.pending_resolve = nil
    pcall(cb, success and true or false, message or "")
    return true
end

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
    -- This force describes the cursor where it is now, even if it stepped
    -- aside from an exploding row: the way back no longer applies.
    rec.dodge_back = nil
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
    if rec.fail_settle ~= nil then return false end  -- waiting for a failed move to settle
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

-- ---------------------------------------------------------------------------
-- Gates: puzzles that cannot be played yet
-- ---------------------------------------------------------------------------
-- Some enemy modifiers make a hack pointless until the player deals with them
-- outside the grid. The observer asks two questions about the puzzle on screen:
-- blocked_notice(id) -- even while it isn't taking input, since a sealed grid
-- fails the moment it starts -- and force_blocked(id) before each force. The
-- notice is said once per puzzle per reason (key), so the peer hears it as
-- information rather than as a stream.

-- (key, message) when puzzle `inst` must not be planned, else nil.
local function _clock()
    local ok, t = pcall(os.clock)
    if ok and type(t) == "number" then return t end
    return nil
end

-- Is the player in a sector listed in mod_config.hack_corruption_gate_skip_sectors
-- (by sector hash or by the map's sector name)? In "Experimental Pragmatics"
-- the corrupted enemies come before the scene that unlocks purification, so
-- refusing their grids until the player purifies would refuse them for good.
-- The sector read walks the map's stage list, so it is kept for 2 s; it is only
-- asked when the gate would otherwise block.
local SECTOR_RECHECK_SECONDS = 2.0
local _sector_cache = nil
local function _corruption_gate_exempt()
    local skip = config.hack_corruption_gate_skip_sectors
    if type(skip) ~= "table" or next(skip) == nil or area_progress == nil then return false end
    local now = _clock()
    if _sector_cache == nil or now == nil or now - _sector_cache.t > SECTOR_RECHECK_SECONDS then
        local ok, hash, name = pcall(area_progress.current_sector)
        _sector_cache = { t = now or 0, hash = ok and hash or nil, name = ok and name or nil }
    end
    local hash, name = _sector_cache.hash, _sector_cache.name
    for _, s in ipairs(skip) do
        if (type(s) == "number" and s == hash)
            or (type(s) == "string" and type(name) == "string" and s:lower() == name:lower()) then
            return true
        end
    end
    return false
end

-- Returns (key, message, settled). settled is false when the answer could
-- not be complete -- the corruption half is skipped while the puzzle is not
-- taking input -- so the caller must not cache it: cached, a "no gate" from
-- just before the hack went live let the force through (sector 5, 2026-10-11).
local function _gate(rec)
    local inst = rec and rec.inst
    if inst == nil then return nil end
    if config.hack_block_gate ~= false then
        local b = modifiers.read_blocks(inst)
        if b ~= nil and (b.impossible == true or (b.total >= 4 and b.active == b.total)) then
            return "blocks:" .. b.active, string.format(
                "The enemy's hacking grid is sealed by red blocks (%d of %d up): "
             .. "touching one fails the hack, so there is no way through. Shoot the "
             .. "enemy's antennas (weak points) to remove the blocks; they go one at "
             .. "a time, top-left first. Hacking can start once a block is gone.",
                b.active, b.total)
        end
    end
    -- The corruption check needs the whole grid, and get_state calls into the
    -- game (grid size, start cell, equipped mode and skill). It is skipped while
    -- the puzzle isn't taking input -- before this work get_state never ran in
    -- that window, and the final boss's last stage plays its shrinking-grid
    -- animation right there. The notice simply comes once input starts.
    --
    -- Some enemies' corrupted cells come and go (sector 5's), so one look with
    -- no c cell on screen is not "purified": a large grid seen corrupted stays
    -- gated for hack_corruption_hold_seconds after the last corrupted look.
    if config.hack_corruption_gate ~= false then
        if not M.is_interactive() then return nil, nil, false end
        local st = M.get_state()
        if st == nil then return nil, nil, false end
        local limit = tonumber(config.hack_corruption_max_cells) or 30
        local cells = st.width * st.height
        local now = _clock()
        if cells > limit and st.corruption ~= nil then
            rec.corruption_seen = { t = now, w = st.width, h = st.height }
        end
        local seen = rec.corruption_seen
        local hold = tonumber(config.hack_corruption_hold_seconds) or 3
        if seen ~= nil and cells > limit and now ~= nil and now - seen.t < hold
            and not _corruption_gate_exempt() then
            return "corruption:" .. seen.w .. "x" .. seen.h, string.format(
                "The enemy is corrupted, and its hacking grid (%dx%d, %d cells) is too "
             .. "large to hack through the corruption: corrupted cells keep stunning "
             .. "the cursor. Purify the corruption first, then hack.",
                seen.w, seen.h, seen.w * seen.h), true
        end
    end
    return nil, nil, true
end

-- Both questions are asked every frame and the corruption check reads the
-- whole grid, so the answer is kept on the record for a quarter second.
local GATE_RECHECK_SECONDS = 0.25

local function _gate_cached(rec)
    local now = _clock()
    local g = rec.gate_cache
    if g ~= nil and now ~= nil and now - g.t < GATE_RECHECK_SECONDS then
        return g.key, g.message
    end
    local key, message, settled = _gate(rec)
    if settled ~= false then
        rec.gate_cache = { t = now or 0, key = key, message = message }
    else
        rec.gate_cache = nil
    end
    return key, message
end

function M.force_blocked(id)
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return false end
    return _gate_cached(rec) ~= nil
end

function M.blocked_notice(id)
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return nil end
    local key, message = _gate_cached(rec)
    if key == nil then
        rec.gate_said = nil      -- cleared: say it again if it comes back
        return nil
    end
    if rec.gate_said == key then return nil end
    rec.gate_said = key
    return message
end

-- The first step of `dirs`, walked from the cursor, that lands in a red block:
-- (step_number, x, y) in render coordinates, or nil. Walls are ignored -- a
-- wall would stop the cursor short, so this can only over-report.
--
-- Red blocks are the ONLY thing a plan is refused for up front (and only with
-- hack_block_refuse_plan on). A plan into a wall, an error node or off the
-- grid runs like a player's input would; the peer hears what happened in the
-- tool result and gets the grid again if the hack is still going.
local function _first_block_step(state, dirs)
    if state == nil or state.cursor == nil then return nil end
    local x, y = state.cursor.x, state.cursor.y
    for i, d in ipairs(dirs) do
        local dd = DIR_DELTAS[d]
        if dd ~= nil then
            x, y = x + dd.x, y + dd.y
            local row = state.cells[y + 1]
            local c = row and row[x + 1]
            if c ~= nil and c.in_block then return i, x, y end
        end
    end
    return nil
end

-- Attach a plan (list of directions) to puzzle `id`. Captures the structure
-- the plan is validated against (the force snapshot, i.e. what the peer
-- planned against). `parked` is true when the reply arrived while the player
-- was NOT aimed at this puzzle — it'll resume when they return. Returns
-- (queued_count, parked).
function M.set_plan(id, moves, resolve)
    local rec = _record_by_id(id)
    if rec == nil then
        -- No record to attach to: resolve immediately so the deferred action
        -- result doesn't dangle (the dispatcher deferred on our say-so).
        if resolve then pcall(resolve, false, "the hack target is no longer tracked") end
        return 0, false
    end
    if type(moves) ~= "table" then
        if resolve then pcall(resolve, false, "no moves to apply") end
        return 0, false
    end

    -- A fresh plan supersedes any still-pending deferred result on this record.
    -- Every terminal already resolves, so this normally finds nothing — but it
    -- guarantees we never silently drop a prior action's result.
    _resolve_pending(rec, false, "superseded by a newer plan")
    rec.pending_resolve = resolve   -- nil for manual/debug queues (no deferral)

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

    -- A red block fails the hack on contact, so a plan that enters one is
    -- refused whole rather than run up to the block. Clearing the snapshot
    -- re-forces the same grid, with this result telling the peer why. With
    -- hack_block_refuse_plan off the plan runs and fails like a player's would.
    if is_current and config.hack_block_refuse_plan ~= false then
        local step, bx, by = _first_block_step(M.get_state(), queue)
        if step ~= nil then
            rec.forced_struct = nil
            _resolve_pending(rec, false, string.format(
                "Plan refused: move %d would enter a red block at (%d, %d), and "
             .. "touching a red block fails the hack. None of the moves were made; "
             .. "plan a route that avoids every R cell.", step, bx, by))
            return 0, false
        end
    end

    rec.plan = {
        queue           = queue,
        total           = #queue,
        cooldown        = 0,
        last_msg        = nil,
        parked          = not is_current,
        validate_struct = validate_struct,
        expected_pos    = nil,  -- where the last dispatched move aimed the cursor
        prev_pos        = nil,  -- cursor position just before the last dispatch
        confirmed       = 0,    -- moves verified to have actually landed
    }
    return #queue, rec.plan.parked
end

function M.discard_plan(id)
    local rec = _record_by_id(id)
    if rec then rec.plan = nil end
end

-- Resolve puzzle `id`'s DEFERRED action result (used by the observer when an
-- engine trigger ends the hack: success / failed / reset). No-op if the puzzle
-- has no pending deferred result (e.g. a manual or auto hack with no AI plan, or
-- one already resolved by the dispatcher's own terminal handling).
function M.resolve_plan(id, success, message)
    return _resolve_pending(_record_by_id(id), success, message)
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

-- Read the puzzle's start cell (where the engine snaps the cursor on an
-- error-node hit), as {x, y} or nil. Only called on the rare mismatch path.
local function _read_start_pos()
    local inst = get_instance()
    if inst == nil then return nil end
    local acc = get_accessor(inst)
    if acc == nil or _sdk.m_get_start_pos == nil then return nil end
    local ok, raw = pcall(function() return _sdk.m_get_start_pos:call(acc) end)
    if not ok then return nil end
    return read_int2(raw)
end

-- Drive a pending post-failure settle for `rec`. After a dispatched move didn't
-- land where the plan aimed we DON'T classify + re-force immediately — an error
-- node resets the whole puzzle a few frames later, and reading the cursor too
-- early sees a pre-reset position (the "cursor shown one move before the error
-- node, trail intact" bug). Instead we wait: the moment the cursor snaps back to
-- start it's a confirmed error-node reset; if the window elapses with the cursor
-- parked where it stopped, it was a wall. Either way we resolve the deferred tool
-- result accurately and clear the snapshot so reconciliation re-forces from the
-- settled position/grid. rec.plan is already nil while this runs.
local function _resolve_fail_settle(rec)
    -- Freeze the settle while paused: a paused cursor is frozen wherever it was
    -- when the pause hit, so neither the start-snap nor the elapse path should
    -- advance until the game (and any in-flight error-node reset) resumes.
    if M.is_game_paused() then return end
    local fs = rec.fail_settle
    fs.waited = fs.waited + 1
    -- Keep the explosion clock current through the settle (field reads; nil
    -- at once on an enemy without the attack system), so a reset caused by a
    -- row going off is reported as that, not as an error node.
    modifiers.read_danger(rec.inst)

    local unit = _resolve_unit()
    local cur = unit and _read_cursor_pos(unit) or nil
    local start = _read_start_pos()

    local function finish(reason, message)
        rec.fail_settle = nil
        rec.forced_struct = nil     -- re-force against the settled grid
        _resolve_pending(rec, false, message)
        _push_plan_event({ kind = "move_failed", reason = reason,
                           confirmed = fs.confirmed, total = fs.total })
    end

    -- Error-node reset confirmed: the cursor snapped back to start. An
    -- explosion failure looks the same (the hack restarts from the start);
    -- tell them apart by whether a row was going off just now.
    if cur ~= nil and start ~= nil and cur.x == start.x and cur.y == start.y then
        local now = _clock()
        local boom = modifiers.last_attack_clock
        if now ~= nil and boom ~= nil and now - boom < 1.0 then
            finish("explosion",
                "An exploding row caught the cursor - the hack failed and restarted "
             .. "from the start, so none of those moves counted.")
            return
        end
        finish("error_node",
            "Hit an error node — the puzzle reset to the start, so none of those "
         .. "moves counted.")
        return
    end

    if fs.waited < FAIL_SETTLE_FRAMES then return end   -- still settling

    -- Window elapsed without a reset: the move was wall-blocked (cursor stopped
    -- at the pre-move cell) or otherwise displaced. The earlier moves DID land.
    if cur ~= nil and fs.prev_pos ~= nil
        and cur.x == fs.prev_pos.x and cur.y == fs.prev_pos.y then
        finish("wall", string.format(
            "Move blocked by a wall after %d move(s) landed; the cursor stopped "
         .. "there.", fs.confirmed))
    else
        finish("displaced", "The cursor ended up off the planned path.")
    end
end

-- Try to claim a completion. When the last dispatched move stepped ONTO the
-- goal (plan.dispatched_into_goal), the engine auto-completes the hack and then
-- resets the puzzle so the enemy can be re-hacked — clearing the trail and
-- snapping the cursor back to start, which looks EXACTLY like an error-node
-- reset (and changes the grid). So this MUST be checked before the structural
-- and mismatch handlers, in both the dispatch path and the queue-drain path
-- (the last move empties the queue, routing the next tick to the drain branch).
-- Guard: only claim the win if the cursor actually LEFT the pre-move cell; if
-- it's still parked there the goal-entry was blocked, not completed. Pass `cur`
-- if already read this tick; otherwise it's read here. Returns true if claimed.
local function _try_claim_completion(rec, plan, cur)
    if not plan.dispatched_into_goal then return false end
    if cur == nil then
        local unit = _resolve_unit()
        cur = unit and _read_cursor_pos(unit) or nil
    end
    if cur ~= nil and plan.prev_pos ~= nil
        and cur.x == plan.prev_pos.x and cur.y == plan.prev_pos.y then
        plan.dispatched_into_goal = false   -- goal-entry blocked; not a completion
        return false
    end
    rec.plan = nil
    rec.forced_struct = nil   -- let reconciliation re-force the re-hack
    _resolve_pending(rec, true, "Reached the goal — the hack is complete.")
    _push_plan_event({ kind = "succeeded" })
    return true
end

-- ---------------------------------------------------------------------------
-- Exploding rows (the boss's attack system) -- move timing
-- ---------------------------------------------------------------------------
-- get_state marks every pulsing/exploding cell with c.danger = { explodes_in,
-- ends_in } (seconds from now). A cursor on such a cell anywhere in that
-- window fails the hack. Two guards, both off with hack_explosion_guard:
--
--   _explosion_gate  before each dispatch: simulate the rest of the queue at
--     hack_explosion_move_seconds per move. Crossing danger cells is fine if
--     every one of them is left before its window (plus a margin); otherwise
--     hold on the current cell until they have gone off. If the current cell
--     is itself about to go off, step to a safe neighbour and back (the two
--     moves are put in front of the queue, so the plan stays valid and the
--     gate then holds on the neighbour).
--   _guard_idle  while no plan is running, or one has run out short of the
--     goal and is finishing (the peer is replanning -- the case that failed
--     in testing): if
--     the cursor stands on a pulsing cell, step to a safe neighbour, and step
--     back once it has gone off -- or in front of the plan, if the plan
--     arrives first. A force sent while the cursor is aside describes it
--     there, so snapshot_force_target forgets the way back.

local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
local DIR_ORDER = { "up", "down", "left", "right" }
local EXPLOSION_HOLD_MAX_SECONDS = 4.0
local IDLE_GUARD_INTERVAL = 3          -- frames between idle checks

local function _explosion_cfg()
    return config.hack_explosion_move_seconds or 0.1,
           config.hack_explosion_margin_seconds or 0.15
end

local function _cell_at(state, x, y)
    local row = state.cells[y + 1]
    return row and row[x + 1] or nil
end

-- Would a cursor on (x, y) from t0 to t1 seconds from now be hit?
local function _deadly(state, x, y, t0, t1)
    local c = _cell_at(state, x, y)
    local d = c and c.danger
    if d == nil then return false end
    local _, margin = _explosion_cfg()
    return t1 + margin > d.explodes_in and t0 < d.ends_in + margin
end

-- A neighbour the cursor can step onto and come straight back from: walkable,
-- not a hazard, not pulsing, and either unvisited or the cell it came from
-- (a retrace). Retracing is preferred; it frees that cell. nil if none.
local function _dodge_dir(state)
    local cx, cy = state.cursor.x, state.cursor.y
    local visited = {}
    for _, p in ipairs(state.trail or {}) do visited[p.x .. "," .. p.y] = true end
    local best = nil
    for _, d in ipairs(DIR_ORDER) do
        local dd = DIR_DELTAS[d]
        local nx, ny = cx + dd.x, cy + dd.y
        local c = (nx >= 0 and ny >= 0 and nx < state.width and ny < state.height)
            and _cell_at(state, nx, ny) or nil
        if c ~= nil and c.danger == nil and not c.in_block and not c.is_erase
            and not c.is_blocked and not _is_wall_type(c.type) then
            local retrace = state.came_from ~= nil
                and state.came_from.x == nx and state.came_from.y == ny
            if retrace then return d end
            if not visited[nx .. "," .. ny] and best == nil then best = d end
        end
    end
    return best
end

-- "go" | "hold" | "dodge", dir. `queue` is the plan's remaining moves.
local function _explosion_gate(state, queue)
    if config.hack_explosion_guard == false then return "go" end
    if state == nil or state.explosions == nil or state.cursor == nil
        or (state.explosions.live or 0) == 0 then
        return "go"
    end
    local T = _explosion_cfg()
    local cx, cy = state.cursor.x, state.cursor.y
    -- Only the cells ahead decide "go": if they are safe, moving on is also
    -- the fastest way off a current cell that is about to go off.
    local run_ok = true
    local clear_at = 0                    -- when the blocking cells are done
    local px, py = cx, cy
    for i, d in ipairs(queue) do
        local dd = DIR_DELTAS[d]
        if dd == nil then break end
        px, py = px + dd.x, py + dd.y
        local c = _cell_at(state, px, py)
        local arrive = i * T
        local on_goal = state.goal ~= nil and px == state.goal.x and py == state.goal.y
        -- The goal completes the hack on arrival; any other cell is held
        -- until the next move lands.
        local leave = on_goal and arrive or (i + 1) * T
        if _deadly(state, px, py, arrive, leave) then
            run_ok = false
            clear_at = math.max(clear_at, c.danger.ends_in)
        end
        if c == nil or c.danger == nil or on_goal then break end   -- reached safety
    end
    if run_ok then return "go" end
    -- Holding is safe unless the current cell goes off before the way clears.
    local _, margin = _explosion_cfg()
    if not _deadly(state, cx, cy, 0, clear_at + margin + T) then return "hold" end
    local dir = _dodge_dir(state)
    if dir ~= nil then return "dodge", dir end
    return "hold"
end

-- Called by tick_plan whenever the record has no plan to run.
local function _guard_idle(rec)
    if config.hack_explosion_guard == false then return end
    rec.idle_tick = (rec.idle_tick or 0) + 1
    if rec.idle_tick % IDLE_GUARD_INTERVAL ~= 0 then return end
    if (rec.idle_cooldown or 0) > 0 then rec.idle_cooldown = rec.idle_cooldown - 1; return end
    -- Cheap pre-check: only an enemy with something pulsing needs get_state.
    local danger = modifiers.read_danger(rec.inst)
    local live = danger ~= nil and #danger.units > 0
    if not live and rec.dodge_back == nil then return end
    if M.is_game_paused() or not M.is_interactive() or M.is_unit_moving() then return end
    local state = M.get_state()
    if state == nil or state.cursor == nil then return end
    local T = _explosion_cfg()
    local cx, cy = state.cursor.x, state.cursor.y

    -- Standing on a pulsing cell: step aside.
    if _deadly(state, cx, cy, 0, 10) then
        local dir = _dodge_dir(state)
        if dir == nil then return end
        local ok, msg = M.move_via_next_position(dir)
        log.info("tick_plan: cursor on an exploding row; stepping " .. dir
              .. " out of it (" .. tostring(msg) .. ")")
        if ok then
            -- A second dodge chains its way back onto the first.
            rec.dodge_back = rec.dodge_back or {}
            table.insert(rec.dodge_back, 1, OPPOSITE[dir])
            rec.idle_cooldown = 2
        end
        return
    end

    -- Aside, and the cell we left is clear for the trip back: return.
    if rec.dodge_back ~= nil and #rec.dodge_back > 0 then
        local back = rec.dodge_back[1]
        local dd = DIR_DELTAS[back]
        if not _deadly(state, cx + dd.x, cy + dd.y, 0, 2 * T) then
            local ok, msg = M.move_via_next_position(back)
            log.info("tick_plan: row cleared; stepping " .. back .. " back ("
                  .. tostring(msg) .. ")")
            table.remove(rec.dodge_back, 1)
            if #rec.dodge_back == 0 then rec.dodge_back = nil end
            if not ok then rec.dodge_back = nil end
            rec.idle_cooldown = 2
        end
    end
end

-- Per-frame tick. Wire into pragmata_main.lua's re.on_frame loop. Dispatches
-- the CURRENTLY-aimed puzzle's queue only; other puzzles' queues stay parked.
function M.tick_plan()
    local rec = _get_current_record()
    if rec == nil then return end

    -- Drive a post-failure settle to completion before anything else — it owns
    -- the record until it resolves (rec.plan is already nil here).
    if rec.fail_settle ~= nil then
        _resolve_fail_settle(rec)
        return
    end

    if rec.plan == nil then
        _guard_idle(rec)
        return
    end
    local plan = rec.plan

    -- The cursor stepped aside from an exploding row while this plan was
    -- being written: walk back first, so the plan starts where it was planned.
    if rec.dodge_back ~= nil then
        for i = #rec.dodge_back, 1, -1 do table.insert(plan.queue, 1, rec.dodge_back[i]) end
        log.info("tick_plan: returning to the planned start before the plan ("
              .. table.concat(rec.dodge_back, ",") .. ")")
        rec.dodge_back = nil
    end

    -- Game paused: freeze dispatch entirely. A paused cursor never moves, so
    -- dispatching a move would accomplish nothing AND make the next post-move
    -- check read the frozen cursor as wall-blocked. Keep the queue PARKED; it
    -- resumes on unpause. (Reconciliation independently halts new forces while
    -- paused, so we finish the in-flight force's parked plan but don't re-force.)
    if M.is_game_paused() then return end

    -- Not interactive (player dropped aim, post-hack cooldown)? Keep the
    -- queue PARKED — do not drop it. It resumes when the player re-aims.
    -- Except a plan whose last move went into the goal and whose puzzle has
    -- already flipped to success: the completion claim below would never run
    -- (the puzzle is no longer interactive), so the peer's tool result was
    -- never sent -- the final boss's last stage, 2026-10-08.
    if not M.is_interactive() then
        if #plan.queue == 0 and plan.dispatched_into_goal
            and read_bool(rec.inst, "_SuccessTrigger", false) then
            rec.plan = nil
            rec.forced_struct = nil
            _resolve_pending(rec, true, "Reached the goal — the hack is complete.")
            _push_plan_event({ kind = "succeeded" })
        end
        return
    end

    -- Finished dispatching: decide the outcome. Wait out the cooldown and the
    -- final cell transition, then give the goal-arrival success trigger a grace
    -- window to claim the deferred result as a WIN (observer.on_success resolves
    -- it). If no success comes, the plan ran out short of the goal — resolve as
    -- such and let reconciliation re-force to continue from the new position.
    if #plan.queue == 0 then
        if plan.cooldown > 0 then plan.cooldown = plan.cooldown - 1; return end
        if M.is_unit_moving() then return end
        -- The last move stepped onto the goal → completion (the engine resets
        -- the puzzle afterward, which would otherwise read as "fell short" once
        -- the cursor snaps back to start). Claim the win deterministically.
        if _try_claim_completion(rec, plan) then return end
        -- Did the LAST move land? The mid-queue check below only ever looks at
        -- the move before the one it dispatches, so a final move into a wall
        -- used to be reported as "ran all moves without reaching the goal" --
        -- and, the cursor not having moved, nothing was ever forced again (the
        -- final boss's timed maze ran out that way). Same handling as mid-queue:
        -- a stun puts the move back, anything else goes to the settle machine,
        -- which classifies it and re-forces.
        if plan.expected_pos ~= nil and not plan.last_checked then
            local unit = _resolve_unit()
            local c = unit and _read_cursor_pos(unit) or nil
            if c ~= nil then
                plan.last_checked = true
                if c.x == plan.expected_pos.x and c.y == plan.expected_pos.y then
                    plan.confirmed = (plan.confirmed or 0) + 1
                else
                    local now = _clock()
                    local stun = plan.stun_seen_at ~= nil and now ~= nil
                        and now - plan.stun_seen_at < STUN_GRACE_SECONDS
                    local stayed = plan.prev_pos ~= nil
                        and c.x == plan.prev_pos.x and c.y == plan.prev_pos.y
                    if stayed and stun and plan.last_dir ~= nil
                        and (plan.stun_retries or 0) < STUN_MAX_RETRIES then
                        plan.stun_retries = (plan.stun_retries or 0) + 1
                        plan.last_checked = nil
                        plan.expected_pos = nil
                        table.insert(plan.queue, 1, plan.last_dir)
                        return
                    end
                    log.warn(string.format(
                        "tick_plan: last move left the cursor at (%d,%d), not (%d,%d); entering settle",
                        c.x, c.y, plan.expected_pos.x, plan.expected_pos.y))
                    rec.fail_settle = {
                        waited    = 0,
                        confirmed = plan.confirmed or 0,
                        total     = plan.total,
                        prev_pos  = plan.prev_pos,
                    }
                    rec.plan = nil
                    _push_plan_event({ kind = "settling" })
                    return
                end
            end
        end
        plan.drain_grace = plan.drain_grace or DRAIN_GRACE_FRAMES
        if plan.drain_grace > 0 then
            plan.drain_grace = plan.drain_grace - 1
            -- The plan ran out short of the goal and the cursor is parked
            -- until the next plan: the same exposure as having no plan, and
            -- the case that failed in testing (a row went off while the peer
            -- was replanning). The last move's landing was checked above.
            _guard_idle(rec)
            return
        end
        -- Grace elapsed without a success trigger. If the cursor is actually ON
        -- the goal, the hack is just completing slowly — claim the win (the
        -- success trigger then no-ops). Otherwise the plan ran out short of the
        -- goal: resolve as such and let reconciliation re-force to continue.
        local st = M.get_state()
        local dcur = st and st.cursor or nil
        local dgoal = st and st.goal or nil
        if dcur ~= nil and dgoal ~= nil and dcur.x == dgoal.x and dcur.y == dgoal.y then
            _resolve_pending(rec, true, "Reached the goal — the hack is complete.")
        else
            _resolve_pending(rec, false, string.format(
                "Ran all %d planned move(s) without reaching the goal%s.", plan.total,
                dcur and string.format(" (cursor now at %d,%d)", dcur.x, dcur.y) or ""))
            -- Ask again even if the cursor ended where it was forced from:
            -- needs_force alone would see an unchanged puzzle and wait forever.
            -- Capped, so a peer that keeps answering with nothing can't loop.
            if (plan.confirmed or 0) > 0 then
                rec.short_plans = 0         -- it got somewhere; not a stall
            else
                rec.short_plans = (rec.short_plans or 0) + 1
            end
            if rec.short_plans <= 3 then rec.forced_struct = nil end
        end
        rec.plan = nil
        return
    end

    if plan.cooldown > 0 then plan.cooldown = plan.cooldown - 1; return end

    -- Cursor is mid-cell-transition — let it settle before the next move.
    if M.is_unit_moving() then return end

    -- Corruption stun (or any other engine move block): hold, don't dispatch.
    -- A move written now would be dropped and then read as a wall.
    local block_flag = modifiers.read_move_block(get_instance())
    if block_flag ~= nil and block_flag ~= 0 then
        plan.stun_hold = (plan.stun_hold or 0) + 1
        plan.stun_seen_at = _clock()
        if plan.stun_hold < STUN_HOLD_MAX_FRAMES then return end
        if plan.stun_hold == STUN_HOLD_MAX_FRAMES then
            log.warn("tick_plan: move block held " .. STUN_HOLD_MAX_FRAMES
                  .. " frames (flag=" .. tostring(block_flag) .. "); dispatching anyway")
        end
    else
        plan.stun_hold = 0
    end

    -- Read the grid + cursor once for the checks below (completion, structural
    -- validation, landing verification). get_state runs at dispatch rate (~7Hz)
    -- here, not every frame.
    local state = M.get_state()
    local unit = _resolve_unit()
    local cur = unit and _read_cursor_pos(unit) or nil

    -- COMPLETION preempt — MUST come before the structural-change and mismatch
    -- checks (a completion resets the puzzle, which would otherwise read as an
    -- error-node reset or a grid change). See _try_claim_completion.
    if _try_claim_completion(rec, plan, cur) then return end

    -- Continuous structural validation: if the grid's structure changed since
    -- the plan was built (sticky bomb deleted a row), the remaining moves are
    -- computed against a layout that no longer exists. Abort + clear the force
    -- snapshot so reconciliation re-forces against the new grid. Checked BEFORE
    -- the "resumed" flag so a parked plan returning to a mutated grid flashes
    -- "retrying", not "resuming".
    if plan.validate_struct ~= nil and state ~= nil
        and _struct_sig_from_state(state) ~= plan.validate_struct then
        log.info("tick_plan: grid structure changed under plan (id=" .. rec.id
              .. "); aborting " .. tostring(#plan.queue) .. " queued moves")
        rec.plan = nil
        rec.forced_struct = nil
        _resolve_pending(rec, false,
            "The grid changed mid-plan (a sticky bomb shifted it, or a red block "
         .. "came or went).")
        _push_plan_event("grid_changed")
        return
    end

    -- Verify the cursor actually landed where the previous move aimed. If it
    -- didn't, the engine moved it somewhere the plan never predicted, so the
    -- rest of the queue is computed against a wrong position. DON'T classify the
    -- cause here — an error node resets the whole puzzle a few frames LATER, so
    -- the cursor may still read its pre-reset position this instant. Hand the
    -- record to the settle machine: it waits for the cursor to snap back to
    -- start (error-node reset) or for the window to elapse (wall), then resolves
    -- the deferred result accurately and lets reconciliation re-force. Stop
    -- dispatching now. Checked after the cooldown/isMove gates so the cursor has
    -- settled from the *previous* transition (just not from an error-node reset).
    if plan.expected_pos ~= nil and cur ~= nil then
        local stayed = plan.prev_pos ~= nil
            and cur.x == plan.prev_pos.x and cur.y == plan.prev_pos.y
        local now = _clock()
        local stun = plan.stun_seen_at ~= nil and now ~= nil
            and now - plan.stun_seen_at < STUN_GRACE_SECONDS
        if cur.x == plan.expected_pos.x and cur.y == plan.expected_pos.y then
            plan.confirmed = (plan.confirmed or 0) + 1
            plan.stun_retries = 0
            -- Checked once: a tick that holds instead of dispatching (an
            -- exploding row) must not count the same landing again.
            plan.expected_pos = nil
        elseif stayed and stun and plan.last_dir ~= nil
            and (plan.stun_retries or 0) < STUN_MAX_RETRIES then
            -- The move was eaten by a corruption stun, not stopped by a wall:
            -- the cursor never left its cell. Put the move back and try again.
            plan.stun_retries = (plan.stun_retries or 0) + 1
            table.insert(plan.queue, 1, plan.last_dir)
            plan.expected_pos = nil
            log.info("tick_plan: move " .. plan.last_dir .. " dropped by a stun; retrying")
            return
        else
            log.warn(string.format(
                "tick_plan: cursor at (%d,%d) but expected (%d,%d); entering "
             .. "settle (%d confirmed, %d queued dropped)",
                cur.x, cur.y, plan.expected_pos.x, plan.expected_pos.y,
                plan.confirmed or 0, #plan.queue))
            rec.fail_settle = {
                waited    = 0,
                confirmed = plan.confirmed or 0,
                total     = plan.total,
                prev_pos  = plan.prev_pos,
            }
            rec.plan = nil
            -- Flash the "rerouting" banner immediately (via the settling event)
            -- so the overlay isn't blank during the settle; the classified
            -- move_failed event follows when the settle resolves.
            _push_plan_event({ kind = "settling" })
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

    -- Safety net for red blocks: set_plan refuses plans that enter one, and a
    -- block appearing changes the structure (caught above), so this fires only
    -- if both missed. Stopping short beats failing the hack.
    if config.hack_block_refuse_plan ~= false
        and _first_block_step(state, { plan.queue[1] }) ~= nil then
        log.warn("tick_plan: next move enters a red block (id=" .. rec.id .. "); stopping")
        rec.plan = nil
        rec.forced_struct = nil
        _resolve_pending(rec, false, string.format(
            "Stopped after %d move(s): the next one would enter a red block, which "
         .. "fails the hack.", plan.confirmed or 0))
        _push_plan_event("grid_changed")
        return
    end

    -- Exploding rows: wait on a safe cell, or step aside, rather than be on a
    -- row when it goes off (see _explosion_gate).
    local verdict, dodge = _explosion_gate(state, plan.queue)
    if verdict == "go" then
        plan.explosion_hold_since = nil
    else
        local now = _clock() or 0
        plan.explosion_hold_since = plan.explosion_hold_since or now
        if now - plan.explosion_hold_since > EXPLOSION_HOLD_MAX_SECONDS then
            log.warn("tick_plan: held for an exploding row over "
                  .. EXPLOSION_HOLD_MAX_SECONDS .. "s; moving on anyway")
            plan.explosion_hold_since = nil
        elseif verdict == "dodge" then
            table.insert(plan.queue, 1, OPPOSITE[dodge])
            table.insert(plan.queue, 1, dodge)
            plan.total = plan.total + 2
            log.info("tick_plan: cursor's row is about to explode; stepping "
                  .. dodge .. " and back")
        else
            if not plan.explosion_holding then
                log.info("tick_plan: holding for an exploding row (id=" .. rec.id .. ")")
            end
            plan.explosion_holding = true
            plan.cooldown = 2
            return
        end
    end
    plan.explosion_holding = nil

    plan.prev_pos = cur   -- cursor right before this dispatch
    local dir = table.remove(plan.queue, 1)
    plan.last_dir = dir
    local ok, msg, tx, ty = M.move_via_next_position(dir)
    plan.last_msg = string.format("move %s: %s",
                                  dir, tostring(msg or (ok and "ok" or "error")))
    log.info("tick_plan: " .. plan.last_msg)
    plan.cooldown = _plan_cooldown_frames
    -- Record where this move aimed the cursor so the next tick can confirm it
    -- got there (and catch an error-node reset if it didn't). Also flag when the
    -- move steps ONTO the goal: the hack auto-completes and resets, and next
    -- tick's completion preempt uses this to claim the win instead of reading
    -- the reset as an error node.
    if ok and tx ~= nil and ty ~= nil then
        plan.expected_pos = { x = tx, y = ty }
        plan.dispatched_into_goal =
            state ~= nil and state.goal_engine ~= nil
            and tx == state.goal_engine.x and ty == state.goal_engine.y
    end

    -- Abort the rest of the queue on a rejected move (OOB, no unit, etc.).
    -- Continuing would dispatch follow-up moves from a position the plan
    -- didn't expect — stop and let reconciliation re-force from where the
    -- cursor actually ended up.
    if not ok then
        log.warn("tick_plan: move rejected; dropping remaining "
              .. tostring(#plan.queue) .. " queued moves")
        rec.plan = nil
        rec.forced_struct = nil
        _resolve_pending(rec, false,
            "A planned move couldn't run (it ran off the grid), so the plan "
         .. "stopped before reaching the goal.")
        _push_plan_event({ kind = "move_failed", reason = "rejected",
                           confirmed = plan.confirmed or 0, total = plan.total })
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
-- How the puzzle on screen is (or isn't) being found. Written for the final
-- boss's last, cutscene-driven hack (2026-10-08), which the mod never saw:
-- no start edge, no force. Lookup goes HackingManager.LastHackingTarget ->
-- a tracked instance whose _TargetPuzzleUnit is that unit, so this lists both
-- ends: the manager's targets, and every tracked instance that is on screen
-- (_GuiHandle) or bound to one of those targets.
function M.debug_targeting()
    if not ensure_init() then return { error = "binding not initialized" } end
    local mgr = _get_hacking_manager()
    local function f(obj, name)
        if obj == nil then return nil end
        local ok, v = pcall(function() return obj:get_field(name) end)
        if ok then return v end
        return nil
    end
    local function tname(obj)
        if obj == nil then return nil end
        local ok, n = pcall(function() return obj:get_type_definition():get_full_name() end)
        return ok and n or "<dead>"
    end
    local last = f(mgr, "<LastHackingTarget>k__BackingField")
    local default = f(mgr, "_DefaultHackingTarget")
    local out = {
        manager            = mgr ~= nil,
        is_targeted        = f(mgr, "<IsTargetedEnemy>k__BackingField"),
        last_target        = tname(last),
        last_target_puzzle = tname(f(last, "_MyPuzzle")),
        default_target     = tname(default),
        default_puzzle     = tname(f(default, "_MyPuzzle")),
        matched_id         = M.matched_puzzle_id(),
        current_id         = M.current_puzzle_id(),
        tracked_total      = #_known_instances,
        tracked            = {},
    }
    for _, rec in ipairs(_known_instances) do
        local target = f(rec.inst, "_TargetPuzzleUnit")
        local gui = f(rec.inst, "_GuiHandle") ~= nil
        local is_last = last ~= nil and target == last
        local is_default = default ~= nil and target == default
        if gui or is_last or is_default then
            out.tracked[#out.tracked + 1] = string.format(
                "id=%d %s gui=%s state=%s last=%s default=%s success=%s failed=%s target=%s",
                rec.id, tostring(tname(rec.inst)), tostring(gui),
                tostring(f(rec.inst, "_State")), tostring(is_last), tostring(is_default),
                tostring(f(rec.inst, "_SuccessTrigger")), tostring(f(rec.inst, "_FailedTrigger")),
                tostring(tname(target)))
        end
    end
    return out
end


-- Everything the enemy-modifier work needs to confirm in game, in one table
-- (Hacking Debug -> Modifiers, F5). Engine coordinates throughout, uncompacted.
--   type          runtime PuzzleSnake subclass
--   blocks / corruption / explosions   the raw puzzle_snake_modifiers reads
--   bits          per ObstacleReason bit: count and cell list; plus stun and
--                 dead-filament cells
--   rect_check    do the block rectangles cover exactly the block-bit cells?
--                 Counted with EndPoint inclusive and exclusive, since which
--                 one the engine means is not known yet.
-- Every plain (bool / number) instance field of `obj`, walking up the type
-- chain, as "Name=value" strings. For spotting which flag marks a phase the
-- named reads miss (the final boss's grid-shrinking sequence).
local function _plain_fields(obj)
    local out = {}
    if obj == nil then return out end
    local ok_t, t = pcall(function() return obj:get_type_definition() end)
    local guard = 0
    while ok_t and t ~= nil and guard < 8 do
        guard = guard + 1
        local fields = {}
        pcall(function() fields = t:get_fields() end)
        for _, fd in ipairs(fields or {}) do
            local ok_s, is_static = pcall(function() return fd:is_static() end)
            if ok_s and not is_static then
                local ok_n, name = pcall(function() return fd:get_name() end)
                if ok_n and type(name) == "string" then
                    local ok_v, v = pcall(function() return obj:get_field(name) end)
                    if ok_v and (type(v) == "boolean" or type(v) == "number") then
                        out[#out + 1] = name .. "=" .. tostring(v)
                    end
                end
            end
        end
        local ok_p, parent = pcall(function() return t:get_parent_type() end)
        if not ok_p then break end
        t = parent
    end
    table.sort(out)
    return out
end

function M.debug_modifiers()
    if not ensure_init() then return { error = "binding not initialized" } end
    local inst = get_instance()
    if inst == nil then return { error = "no PuzzleSnake matched to the aim" } end
    local function f(obj, name)
        if obj == nil then return nil end
        local ok, v = pcall(function() return obj:get_field(name) end)
        if ok then return v end
        return nil
    end
    local processing = f(inst, "_ProcessingChangeGridRequest")
    local block_timer = f(inst, "_GridChangingBlockInputTimer")
    local out = {
        type        = modifiers.type_name(inst),
        active      = M.is_active(),
        interactive = M.is_interactive(),
        finale_hold = M.finale_hold_reason() or "none",
        puzzle_fields = _plain_fields(inst),
        change_queue_size = f(f(inst, "_ChangeGridRequests"), "_size"),
        processing_change = processing and _plain_fields(processing) or "nil",
        block_input_timer = block_timer and _plain_fields(block_timer) or "nil",
        unit_fields = _plain_fields(f(inst, "_CurrentUnit")),
        blocks      = modifiers.read_blocks(inst, true),
        corruption  = modifiers.read_corruption(inst, true),
        explosions  = modifiers.read_explosions(inst),
        bits        = {},
        stun_cells  = {},
        dead_filament_cells = {},
    }
    local bit_names = { [1] = "ObstacleGrid", [2] = "DeadFilament", [4] = "Ch16092",
                        [8] = "Ch14100", [16] = "AllPassed" }
    for value, name in pairs(bit_names) do
        out.bits[name] = { bit = value, cells = {} }
    end
    local block_bit_cells = {}
    for_each_cell(inst, function(cell_obj)
        local c = read_cell(cell_obj)
        if c == nil then return end
        local xy = c.x .. "," .. c.y
        for value, name in pairs(bit_names) do
            if has_bit(c.obstacle_reasons, value) then
                table.insert(out.bits[name].cells, xy)
            end
        end
        if c.stun_reasons ~= nil and c.stun_reasons ~= 0 then
            table.insert(out.stun_cells, xy .. "=" .. c.stun_reasons)
        end
        if c.dead_filament then
            table.insert(out.dead_filament_cells, xy .. "=" .. tostring(c.dead_filament_type))
        end
        if c.block_bit then block_bit_cells[xy] = true end
    end)
    for _, entry in pairs(out.bits) do
        table.sort(entry.cells)
        entry.count = #entry.cells
    end

    local b = out.blocks
    if b ~= nil and not b.no_geometry then
        local function covered(exclusive)
            local set, n = {}, 0
            for _, r in ipairs(b.rects) do
                -- A misread rectangle must not turn into a runaway loop.
                local area = (r.x1 - r.x0 + 1) * (r.y1 - r.y0 + 1)
                if r.active and area > 0 and area <= 4096 then
                    local x1 = exclusive and r.x1 - 1 or r.x1
                    local y1 = exclusive and r.y1 - 1 or r.y1
                    for x = r.x0, x1 do
                        for y = r.y0, y1 do
                            local k = x .. "," .. y
                            if not set[k] then set[k] = true; n = n + 1 end
                        end
                    end
                end
            end
            local bits_outside, rect_without_bit = 0, 0
            for k in pairs(block_bit_cells) do
                if not set[k] then bits_outside = bits_outside + 1 end
            end
            for k in pairs(set) do
                if not block_bit_cells[k] then rect_without_bit = rect_without_bit + 1 end
            end
            return { covered = n, bit_cells_outside = bits_outside,
                     rect_cells_without_bit = rect_without_bit }
        end
        out.rect_check = { inclusive = covered(false), exclusive = covered(true) }
    end
    return out
end


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
        -- How many tracked instances are bound to the currently-aimed enemy,
        -- broken down by lifecycle. >1 match with an "ended" one present is
        -- the "invisible enemy" signature: a leftover completed PuzzleSnake
        -- sharing the target. picked_lifecycle is what the matcher chose.
        match_total          = 0,
        match_playable       = 0,
        match_idle           = 0,
        match_ended          = 0,
        picked_lifecycle     = nil,
    }

    -- Lifecycle breakdown of all instances matching the aimed enemy.
    if target_unit ~= nil then
        for _, rec in ipairs(_known_instances) do
            local ok, t = pcall(function() return rec.inst:get_field("_TargetPuzzleUnit") end)
            if ok and t == target_unit then
                s.match_total = s.match_total + 1
                local life = _instance_lifecycle(rec.inst)
                if life == "playable" then s.match_playable = s.match_playable + 1
                elseif life == "idle" then s.match_idle = s.match_idle + 1
                else s.match_ended = s.match_ended + 1 end
            end
        end
        if inst ~= nil then s.picked_lifecycle = _instance_lifecycle(inst) end
    end

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


-- ---------------------------------------------------------------------------
-- Family interface
-- ---------------------------------------------------------------------------
-- The observer used to call into this module by name. It now drives whichever
-- puzzle family is active through one shared interface, so the pieces below
-- adapt this binding to it. Everything else in the file is unchanged: the
-- interface is a thin naming layer over functions that already existed.

M.kind = "snake"
M.action_name = "pragmata_hack_plan"
M.force_query = "Hacking grid is live. Call pragmata_hack_plan with your "
             .. "moves from @ to G (see the grid)."

-- Neutral lifecycle booleans. The observer edge-tracks these, so it no longer
-- needs to know that this family spells its triggers _StartTrg / _ResetTrg /
-- _SuccessTrigger / _FailedTrigger / _GridChangeEndTrg.
function M.lifecycle()
    return {
        started = M.read_trigger("_StartTrg"),
        changed = M.read_trigger("_GridChangeEndTrg"),
        reset   = M.read_trigger("_ResetTrg"),
        success = M.read_trigger("_SuccessTrigger"),
        failed  = M.read_trigger("_FailedTrigger"),
    }
end

-- Required lazily: util/snake_render pulls in nothing from here, but keeping the
-- require inside the call avoids any load-order question at boot, when this
-- binding is required from pragmata_main before the util modules are touched.
local _render, _render_config
function M.render_state()
    local state = M.get_state()
    if state == nil then return nil end
    _render = _render or require("pragmata.util.snake_render")
    _render_config = _render_config or require("pragmata.mod_config")
    local ok, rendered = pcall(_render.render, state, {
        with_legend    = _render_config.hacking_render_legend,
        with_adjacency = _render_config.hacking_render_adjacency,
    })
    if not ok then
        log.error("puzzle_snake: render threw: " .. tostring(rendered))
        return "Hacking grid is active. (rendering failed: "
            .. tostring(rendered):sub(1, 200) .. ")"
    end
    return rendered
end


-- ---------------------------------------------------------------------------
-- Final boss: the scripted stages (see M.finale_hold_reason)
-- ---------------------------------------------------------------------------
-- The finale is five fixed grids, the same every run, recognised by
-- snake_render.layout_fingerprint (walls, error nodes, size and goal -- what
-- the peer is shown). Recorded from the forces of 2026-10-08 (three runs).
-- An earlier attempt fingerprinted the engine's raw cell array; that array is
-- larger than the playable grid, so the size never matched and the hold never
-- fired.
local FINALE_STAGES = {
    ["9x9|4,4|####....#/#..###.##/##.....#./##.#####./##.#...../##.###.##/#....#..#/#.##.##.#/####....#"] = 1,
    ["7x9|3,8|###.###/......./#####.#/......./#.#####/......./###.###/......./###.###"] = 2,
    ["9x9|4,6|#########/##..#..##/####..###/###...###/###.#.###/###...###/###..####/##..#..##/#########"] = 3,
    ["7x7|6,6|.#####d/.#...##/.#.#.../.#.#.#./...#.#./##...#./d#####."] = 4,
    ["7x7|3,6|d#d.##./d#..#.#/#d.##.d/#....#d/d###.d./#d#...#/d##.#d#"] = 5,
}
local FINALE_LAST_STAGE = 5
local FINALE_RECHECK_SECONDS = 1.0

-- Which finale stage puzzle `rec` is showing (1..5), or nil. Re-read at most
-- once a second per puzzle; get_state is the same read a force makes.
local function _finale_stage(rec)
    local now = _clock()
    if rec.finale_checked_at ~= nil and now ~= nil
        and now - rec.finale_checked_at < FINALE_RECHECK_SECONDS then
        return rec.finale_stage
    end
    rec.finale_checked_at = now
    local fp = _render_mod.layout_fingerprint(M.get_state())
    local stage = fp and FINALE_STAGES[fp] or nil
    if stage ~= rec.finale_stage then
        log.info("puzzle_snake: finale stage " .. tostring(stage)
              .. (stage and " recognised" or " left"))
        rec.finale_stage = stage
        rec.finale_since = (stage == FINALE_LAST_STAGE) and (now or 0) or nil
    end
    return stage
end

_finale_hold = function()
    local hold = tonumber(config.hack_finale_hold_seconds) or 0
    if hold <= 0 then return nil end
    local rec = _get_current_record()
    if rec == nil then return nil end
    if _finale_stage(rec) ~= FINALE_LAST_STAGE or rec.finale_since == nil then return nil end
    local now = _clock()
    if now == nil or now - rec.finale_since >= hold then return nil end
    return "final-stage opening sequence"
end

-- The observer asks this before each force: false keeps the grid in the
-- peer's context (no ephemeral_context). The finale's stages repeat exactly on
-- every attempt, so what the peer learned on one is worth keeping.
function M.force_ephemeral(id)
    if config.hack_finale_keep_context == false then return true end
    local rec = _get_current_record()
    if rec == nil or rec.id ~= id then return true end
    return _finale_stage(rec) == nil
end

return M
