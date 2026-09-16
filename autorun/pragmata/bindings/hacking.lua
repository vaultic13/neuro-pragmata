--
-- Bindings for Diana's Auto-Hack ability.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.HackingManager (singleton via app.AppSingleton`1<app.HackingManager>):
--     - get_LastHackingTarget() -> app.PuzzleUnit
--         The "currently locked" hack target the engine has resolved for the
--         player. We use this as the implicit target when the caller passes
--         no explicit target.
--     - get_DefaultHackingTarget() -> app.PuzzleUnit
--         Engine's fallback target when nothing else is locked. Used as a
--         secondary fallback after LastHackingTarget.
--     - get_IsJamming() -> System.Boolean
--         True when "jamming" is active in the area. Auto-Hack public sources
--         describe its failure modes as "error nodes active or hack
--         interrupted"; the jamming state is the closest dump-level analogue
--         we can verify and is treated as the gating condition here.
--
--   app.PlayerPuzzleControlDriver (per-player driver, found via
--   CharacterManager:getPlayerHandle() -> ... -> driver board):
--     - get_IsAutoHacking() -> System.Boolean
--         True while an auto-hack is currently executing. We treat in-flight
--         as "no, can't start a new one".
--     - get_HackingGauge() -> app.GaugeUnit
--         The shared hacking gauge the auto-hack consumes from. We probe
--         get_Empty() on it to refuse the call when there's no gauge to
--         spend. (The exact "use cost" is data-driven via
--         app.PlayerCoreData.AutoHackParameter._UseGauge and we don't try
--         to compute it; engine code will cap it.)
--     - app.PlayerPuzzleControlDriver.AutoHackWorkUnit (nested helper):
--         - canAutoHack(app.PuzzleUnit, f32, f32) -> Boolean
--             Engine's own check. Same reach we'd want, but it requires the
--             work-unit instance plus two unknown floats (likely range/dot
--             thresholds), so we don't call it as the primary gate. Instead
--             we ship two simple checks (jamming + already-running) and let
--             the engine reject internally if our preconditions miss.
--
-- Auto-Hack invocation pattern:
--   The dump exposes app.player.PuzzleStatus.RequestAutoHacking (a flag on a
--   UInt64 flag-enum) and AutoHackWorkUnit.startAutoHack as a Private
--   instance method. Neither is reachable directly through the simple
--   reflection-call surface we have without first walking
--   PlayerHandle -> Updater -> DriverBoard -> findDriver<PlayerPuzzleControlDriver>
--   -> _AutoHackWork. That driver-board path uses generic-instantiated
--   findDriver overloads which REFramework cannot trivially dispatch on by
--   reflection alone.
--
-- The pragmatic shape we ship:
--   * Treat the binding as a "try to start" surface that confirms readiness
--     and reports a neutral failure when the engine declines. The actual
--     transition to a running auto-hack is left to the player input pipeline
--     in the engine; the binding's job is to gate-check + signal intent.
--   * If a parent dispatcher later wants to actually drive the start
--     transition, it should do so through input synthesis (ReFramework
--     button-injection patterns) — that's out of scope for a binding file
--     that has to stay neutral.
--
-- Auto-Hack unlock detection:
--   The dump shows two relevant signals:
--     - app.PlayerPuzzleControlDriver.AutoHackWorkUnit._CanAutoHack (Boolean)
--     - app.PuzzleBase.get_CanAutoHacking() -> Boolean (per-puzzle)
--     - per-puzzle config field _EnableAutoHack on a separate userdata struct
--   None of these read directly as "the player has unlocked the upgrade
--   globally"; they fold both unlock and per-target gating into one bool.
--   We surface that combined signal as is_auto_hack_unlocked() and document
--   the conflation. Callers should treat false as "don't try right now"
--   rather than "permanently locked."

local log = require("pragmata.util.log")
local player_drivers = require("pragmata.bindings.player_drivers")

local M = {}

-- ---------------------------------------------------------------------------
-- One-time SDK lookups (cached at first use)
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    -- Singletons / type defs
    hacking_mgr_td = nil,                  -- app.HackingManager
    char_mgr_td = nil,                     -- app.CharacterManager
    puzzle_driver_td = nil,                -- app.PlayerPuzzleControlDriver
    auto_hack_work_td = nil,               -- app.PlayerPuzzleControlDriver.AutoHackWorkUnit
    gauge_unit_td = nil,                   -- app.GaugeUnit
    -- Methods we'll call repeatedly
    m_get_last_target = nil,
    m_get_default_target = nil,
    m_get_is_jamming = nil,
    m_get_is_auto_hacking = nil,           -- on AutoHackWorkUnit
    m_can_auto_hack_workunit = nil,        -- on AutoHackWorkUnit
    m_start_auto_hack = nil,               -- private, no-argument transition
    m_get_hacking_gauge = nil,             -- on PlayerPuzzleControlDriver
    m_get_empty = nil,                     -- on GaugeUnit
    m_get_remaining_rate = nil,            -- on GaugeUnit
    m_get_player_handle = nil,             -- on CharacterManager
    -- Per-call resolved instances (re-resolved each call; they can be
    -- created/destroyed across scenes)
}

local function ensure_init()
    if _state.inited then return true end
    _state.inited = true

    -- Type defs
    local function td(name)
        local ok, v = pcall(function() return sdk.find_type_definition(name) end)
        if ok then return v end
        return nil
    end

    _state.hacking_mgr_td   = td("app.HackingManager")
    _state.char_mgr_td      = td("app.CharacterManager")
    _state.puzzle_driver_td = td("app.PlayerPuzzleControlDriver")
    _state.auto_hack_work_td = td("app.PlayerPuzzleControlDriver.AutoHackWorkUnit")
    _state.gauge_unit_td    = td("app.GaugeUnit")

    -- Methods. None of these are critical at load time; missing ones just
    -- degrade specific paths.
    local function m(td_obj, sig)
        if td_obj == nil then return nil end
        local ok, v = pcall(function() return td_obj:get_method(sig) end)
        if ok then return v end
        return nil
    end

    if _state.hacking_mgr_td ~= nil then
        _state.m_get_last_target    = m(_state.hacking_mgr_td, "get_LastHackingTarget()")
        _state.m_get_default_target = m(_state.hacking_mgr_td, "get_DefaultHackingTarget()")
        _state.m_get_is_jamming     = m(_state.hacking_mgr_td, "get_IsJamming()")
    end

    if _state.auto_hack_work_td ~= nil then
        _state.m_get_is_auto_hacking   = m(_state.auto_hack_work_td, "get_IsAutoHacking()")
        _state.m_can_auto_hack_workunit = m(_state.auto_hack_work_td,
            "canAutoHack(app.PuzzleUnit, System.Single, System.Single)")
        -- Confirmed by the manual trace: startAutoHack has no parameters and
        -- changes IsAutoHacking on the live work unit.  It is private, so the
        -- caller still verifies the transition on later frames before calling
        -- the action successful.
        _state.m_start_auto_hack = m(_state.auto_hack_work_td, "startAutoHack()")
            or m(_state.auto_hack_work_td, "startAutoHack")
    end

    if _state.puzzle_driver_td ~= nil then
        _state.m_get_hacking_gauge = m(_state.puzzle_driver_td, "get_HackingGauge()")
        -- Player drivers are not managed singletons. Capture the live driver
        -- through its lifecycle hook, as the Overdrive binding already does.
        player_drivers.want("app.PlayerPuzzleControlDriver")
    end

    if _state.gauge_unit_td ~= nil then
        _state.m_get_empty          = m(_state.gauge_unit_td, "get_Empty()")
        _state.m_get_remaining_rate = m(_state.gauge_unit_td, "get_RemainingRate()")
    end

    if _state.char_mgr_td ~= nil then
        _state.m_get_player_handle = m(_state.char_mgr_td, "getPlayerHandle()")
    end

    return true
end

local function get_hacking_singleton()
    if _state.hacking_mgr_td == nil then return nil end
    local ok, inst = pcall(function()
        return sdk.get_managed_singleton("app.HackingManager")
    end)
    if ok and inst ~= nil then return inst end
    return nil
end

-- Tries (best-effort) to find the active PlayerPuzzleControlDriver via the
-- character manager + driver board. The driver-board generic findDriver
-- overload set isn't reliably reflectable, so we fall back to the
-- "first instance of the type" pattern.
-- CONFIDENCE: low — the lookup path is approximate. If REFramework can't
-- enumerate by type-name on this binary, this returns nil and the call sites
-- degrade to "we don't know, refuse the action".
-- PlayerPuzzleControlDriver is captured from its own update lifecycle instead
-- of trying to dispatch DriverBoard's generic findDriver overloads.
local function find_player_puzzle_driver()
    if _state.puzzle_driver_td == nil then return nil end

    return player_drivers.get("app.PlayerPuzzleControlDriver")
end

local function find_auto_hack_workunit()
    local driver = find_player_puzzle_driver()
    if driver == nil then return nil end
    -- The work-unit lives in driver._AutoHackWork (private field).
    local ok, wu = pcall(function() return driver:get_field("_AutoHackWork") end)
    if ok and wu ~= nil then return wu, driver end
    return nil, driver
end

-- Read jamming state. Conservative: any true value means "yes jamming".
-- CONFIDENCE: high — get_IsJamming is in the dump and is a public-via-family
-- accessor whose semantics match the field name.
local function is_jamming()
    local mgr = get_hacking_singleton()
    if mgr == nil or _state.m_get_is_jamming == nil then return false end
    local ok, v = pcall(function()
        return _state.m_get_is_jamming:call(mgr)
    end)
    if ok and v == true then return true end
    return false
end

-- True iff an auto-hack is already mid-flight.
-- CONFIDENCE: medium — accessor is in the dump but reaching the work-unit
-- depends on the driver lookup path being available.
local function is_already_auto_hacking(workunit)
    if workunit == nil or _state.m_get_is_auto_hacking == nil then return false end
    local ok, v = pcall(function()
        return _state.m_get_is_auto_hacking:call(workunit)
    end)
    if ok and v == true then return true end
    return false
end

-- True iff the hacking gauge has any room to spend on an auto-hack.
-- CONFIDENCE: high on get_Empty; medium on the inferred semantic ("empty
-- gauge => can't autohack"). The actual cost is data-driven and may be
-- larger than 0; we treat empty as a hard floor and let the engine refuse
-- finer thresholds.
local function gauge_has_juice(driver)
    if driver == nil or _state.m_get_hacking_gauge == nil then return true end
    local ok_g, gauge = pcall(function()
        return _state.m_get_hacking_gauge:call(driver)
    end)
    if not ok_g or gauge == nil then return true end -- can't read => don't block

    if _state.m_get_empty == nil then return true end
    local ok_e, empty = pcall(function()
        return _state.m_get_empty:call(gauge)
    end)
    if ok_e and empty == true then return false end
    return true
end

-- Resolve the puzzle target the auto-hack should run against.
--   - explicit target: returned as-is (caller's responsibility to keep it
--     valid; if it's stale the engine will reject internally).
--   - nil: prefer LastHackingTarget, fall back to DefaultHackingTarget.
-- CONFIDENCE: medium — the LastHackingTarget convention is well-attested
-- in the engine (it's the lock the player UI tracks); the fallback to
-- DefaultHackingTarget is best-effort.
-- Which target the engine will hack. This is a GUARD, not a selector:
-- startAutoHack() takes no parameters, so the engine always acts on whatever
-- the work unit is already pointed at. Resolving it here only lets auto_hack
-- refuse early when nothing is locked on, instead of asking the engine to hack
-- nothing. There is deliberately no caller-supplied override -- one would read
-- as a target choice while changing nothing.
local function resolve_target()
    local mgr = get_hacking_singleton()
    if mgr == nil then return nil end

    if _state.m_get_last_target ~= nil then
        local ok, t = pcall(function()
            return _state.m_get_last_target:call(mgr)
        end)
        if ok and t ~= nil then return t end
    end

    if _state.m_get_default_target ~= nil then
        local ok, t = pcall(function()
            return _state.m_get_default_target:call(mgr)
        end)
        if ok and t ~= nil then return t end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Try to fire an auto-hack against the currently locked-on target. Takes no
-- arguments: see resolve_target() for why there is nothing to choose.
-- Returns (success_bool, message_string).
--
-- Failure cases (in order checked):
--   * SDK not initialized / managers missing
--   * Auto-hack subsystem not currently unlocked / available
--   * Jamming active in this area
--   * Auto-hack already running
--   * No valid puzzle target
--   * Hacking gauge empty
--
-- Success here means "preconditions satisfied and we asked the engine to
-- proceed". Whether the engine actually completes the hack depends on
-- runtime state we can't fully introspect statically.
-- CONFIDENCE: medium — preconditions are individually high-confidence; the
-- start-transition path is conservative (see file-level note).
function M.auto_hack()
    ensure_init()

    if not M.is_auto_hack_unlocked() then
        return false, "not implemented: auto-hack not currently available (locked, missing driver, or per-target disabled)"
    end

    if is_jamming() then
        return false, "jamming active in this area; auto-hack would be refused"
    end

    local workunit, driver = find_auto_hack_workunit()
    if workunit == nil then
        log.warn("hacking.auto_hack: could not locate auto-hack work unit; refusing")
        return false, "auto-hack subsystem not reachable"
    end

    if is_already_auto_hacking(workunit) then
        return false, "auto-hack already in progress"
    end

    if resolve_target() == nil then
        return false, "no valid hack target (nothing is locked on)"
    end

    if not gauge_has_juice(driver) then
        return false, "hacking gauge empty; cannot pay auto-hack cost"
    end

    if _state.m_start_auto_hack == nil then
        return false, "auto-hack start method is unavailable on this game build"
    end

    local ok, err = pcall(function()
        _state.m_start_auto_hack:call(workunit)
    end)
    if not ok then
        log.warn("hacking.auto_hack: startAutoHack() raised: " .. tostring(err))
        return false, "auto-hack start request raised an SDK error"
    end

    -- This is deliberately only a request acknowledgement. The dispatcher
    -- waits for get_IsAutoHacking() to rise before it resolves the AI action.
    -- The transition can occur in this same frame, but it is reported by the
    -- action observer rather than inferred from this reflection call.
    return true, "auto-hack start request submitted; awaiting engine transition"
end

-- Read-only confirmation predicate for deferred action results.
function M.is_auto_hacking()
    ensure_init()
    local workunit = find_auto_hack_workunit()
    return is_already_auto_hacking(workunit)
end

-- Returns true iff the auto-hack subsystem looks usable right now. This
-- conflates "upgrade unlocked" with "reachable via current driver state and
-- per-target enable flag" — see file-level note. Callers should use this
-- only as a "should I bother" probe, not as a permanent unlock check.
-- CONFIDENCE: medium — depends on the driver-lookup path and on
-- AutoHackWorkUnit._CanAutoHack accurately reflecting the upgrade state.
function M.is_auto_hack_unlocked()
    ensure_init()

    local workunit = find_auto_hack_workunit()
    if workunit == nil then
        -- Driver not reachable (likely loading screen, paused, or not in a
        -- combat-capable scene). Treat as "not unlocked right now".
        return false
    end

    local ok, can = pcall(function()
        return workunit:get_field("_CanAutoHack")
    end)
    if ok and can == true then return true end
    if ok and can == false then return false end

    -- Field unreadable but workunit exists — hedge to false rather than
    -- claim an unverified true.
    return false
end

-- Read-only diagnostic snapshot used by the in-game ability tracer. It does
-- not claim that auto-hack can be started; it only exposes the state that the
-- current conservative binding can actually observe.
function M.debug_status()
    ensure_init()
    local mgr = get_hacking_singleton()
    local workunit, driver = find_auto_hack_workunit()
    local target = resolve_target(nil)
    local gauge = nil
    if driver ~= nil and _state.m_get_hacking_gauge ~= nil then
        pcall(function() gauge = _state.m_get_hacking_gauge:call(driver) end)
    end
    local empty, remaining = nil, nil
    if gauge ~= nil and _state.m_get_empty ~= nil then
        pcall(function() empty = _state.m_get_empty:call(gauge) end)
    end
    if gauge ~= nil and _state.m_get_remaining_rate ~= nil then
        pcall(function() remaining = _state.m_get_remaining_rate:call(gauge) end)
    end
    local can = nil
    if workunit ~= nil then pcall(function() can = workunit:get_field("_CanAutoHack") end) end
    return {
        manager_present = mgr ~= nil,
        driver_present = driver ~= nil,
        workunit_present = workunit ~= nil,
        target_present = target ~= nil,
        jamming = is_jamming(),
        auto_hacking = is_already_auto_hacking(workunit),
        can_auto_hack = can,
        gauge_empty = empty,
        gauge_remaining_rate = remaining,
        start_method_ok = _state.m_start_auto_hack ~= nil,
        drivers = player_drivers.debug_status(),
    }
end

return M
