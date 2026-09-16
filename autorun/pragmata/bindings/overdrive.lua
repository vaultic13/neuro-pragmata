--
-- Bindings for Diana's Overdrive Protocol -- the gauge-fuelled ability bound
-- to X on keyboard and the L3+R3 stick chord on a controller.
--
-- ENGINE LAYOUT (verified against the IL2CPP dump)
--
--   app.PlayerPuzzleControlDriver : app.PlayerDriver
--     get_HackingGauge() -> app.GaugeUnit     -- the gauge that fuels this
--     clearHackingGauge()                     -- reset-to-zero path
--     recoveryHackingGauge(System.Single)     -- gain path
--     canFinishTargetFromInput() -> bool
--     onStartDeathblow()
--   app.PlayerFinishBlowDriver : app.PlayerDriver
--     requestWideFinishBlow(System.Int32) -> bool
--     execWideFinishBlow()
--     getWideFinishBlowDamage() -> System.Int32
--   app.PlayerDeathblowDriver : app.PlayerDriver     <- never captured before
--     canDeathblow() -> bool, tryDeathblow(), startDeathBlow()
--   app.GaugeUnit
--     get_Full() / get_RemainingRate() / get_RemainingPoint() / get_TotalPoint()
--
--   NOTE: app.GaugeUnit has NO reduce(System.Single). Earlier notes assumed a
--   "HackingGaugeUnit.reduce(float)" existed to hook for the exact spend
--   amount; it does not exist in this build. The gauge's own
--   set_RemainingPoint / the driver's clearHackingGauge are the real write
--   paths, and polling get_RemainingPoint per frame (what this binding does)
--   observes both.
--
-- HOW IT IS TRIGGERED, AND HOW THAT WAS ESTABLISHED
--
-- Two F11 probe captures of a manual activation are identical:
--
--     canDeathblow()  = true
--     startDeathBlow()            <- recorded first
--     tryDeathblow()              <- same frame
--     canDeathblow()  = false     <- next frame
--     gauge 126.65 -> 26.65       <- four frames later, delta exactly -100.0
--
-- So the ability is dispatched through app.PlayerDeathblowDriver, and this
-- binding calls it there directly. A later entry/exit capture proved the two
-- methods are nested, not sequential -- see the trace above begin_trigger().
--
-- WHY EARLIER ATTEMPTS FAILED
--
--   * Injecting at app.PlayerInputDriver (bindings/command_input.lua) is
--     invisible to consumers that read input through PlayerDriver.get_Command()
--     -> app.hid.IPlayerCommand, or through app.hid.Command directly. Scan
--     happens to use the hooked path; this ability does not.
--
--   * Publishing at the command layer was the next attempt, and the captures
--     disprove it: `command_diff` was 0 for the entire recording of a
--     successful manual activation. No PlayerInputCommand changes state, so
--     there is no command to publish. That module (bindings/player_command.lua)
--     has been deleted; recover it from git history if a future ability turns
--     out to be command-driven.
--
--   * Raising app.player.FinishBlowStatus.RequestBurstFinishBlow was called
--     through a signature that does not exist. The real method is
--         app.EnumBitData.trgFlag(System.UInt64, System.Boolean,
--                                 System.UInt32, via.vec3[])
--     -- FOUR parameters. The old code looked up a three-parameter overload
--     (resolving to nil) and otherwise called it with two arguments. It is kept
--     below, with the correct signature, as an explicitly-diagnostic route.
--
-- READINESS AND CONFIRMATION ARE STATE-BASED
--
-- bindings/player_status.lua reads the live status masks
-- (app.EnumBitDatas -> app.EnumBitData -> app.BitData.get_Current), so this
-- binding asks the engine whether the ability is usable and whether it started,
-- rather than inferring both from a gauge number.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local player_drivers = require("pragmata.bindings.player_drivers")
local player_status = require("pragmata.bindings.player_status")

local M = {}

-- These drivers live on the player handle's driver board, NOT in the managed-
-- singleton registry, so they are captured live via per-frame hooks (see
-- player_drivers.lua).
local TD_PUZZLE_DRIVER     = "app.PlayerPuzzleControlDriver"
local TD_DEATHBLOW_DRIVER  = "app.PlayerDeathblowDriver"

-- CONFIRMED cost, not an assumption. Two independent F11 captures both show
-- the hacking gauge going 126.65 -> 26.65 on a successful activation: a fixed
-- deduction of exactly 100 points from a 150 total. Note what that rules out --
-- the ability does NOT require a full gauge and does NOT reset it to zero.
-- Used as the last-resort readiness signal only; the engine's own state is
-- asked first (see M.readiness).
local OBSERVED_MINIMUM_COST = 100.0

-- How long to wait for the game to show the ability starting before calling a
-- trigger unconfirmed. 3 seconds at 60fps.
local CONFIRM_TIMEOUT_FRAMES = 180

-- Status flags that mean "the ability actually started". Any one of them
-- landing while a request is pending is confirmation.
--
-- Deathblow leads because that is the driver the captures show doing the work.
-- The FinishBlow flag is kept last as a cheap corroboration: it costs one
-- lookup and would be genuine evidence if a future build routes the ability
-- through the Burst path instead.
local START_FLAGS = {
    { status = "app.player.DeathblowStatus",  flag = "Start" },
    { status = "app.player.DeathblowStatus",  flag = "Play" },
    { status = "app.player.FinishBlowStatus", flag = "StartBurstFinishBlow" },
}

-- Status flags that mean "the engine considers this usable right now".
--
-- This list used to hold FinishBlowStatus.CanBurstFinishBlow,
-- PuzzleStatus.OpenFinishBlow and PuzzleStatus.HackingGaugeFull. All three
-- read ZERO in the captures taken at the exact moment the ability was usable,
-- so the old list would have refused a ready ability. What was actually set was
-- DeathblowStatus = 36 = CanDeathblow | FindTarget.
--
-- FindTarget is deliberately NOT treated as readiness: having a target in range
-- is a precondition, not permission.
local READY_FLAGS = {
    { status = "app.player.DeathblowStatus", flag = "CanDeathblow" },
}

local _last_trigger_msg = "(overdrive not triggered yet)"
local _pending = nil
local _frame = 0
-- Confirmation evidence collected while a request is in flight, surfaced in
-- the debug panel so a failure says WHAT was missing.
local _last_confirmation = nil

-- Latched outcome of the most recent request.
--
-- The state machine is advanced from exactly ONE place (this module's frame
-- callback). Everything else -- ability_actions' poll, the debug panel -- only
-- READS it. That matters: when two callers both advanced the machine, whichever
-- ran second saw the request already cleared and reported a failure for a
-- request that had just succeeded.
--   "idle"      no request has been made yet
--   "pending"   published, waiting for the game to show it starting
--   "confirmed" the game started it
--   "failed"    the confirmation window expired
--   "cancelled" the caller gave up
local _request = { state = "idle", message = nil, id = 0 }

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function value_to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    return safe(function() return value:get_field("value__") end)
end

-- ---------------------------------------------------------------------------
-- One-time SDK lookups
-- ---------------------------------------------------------------------------

-- Only what the confirmed path actually calls. The FinishBlow request methods
-- and the EnumBitData.trgFlag overload used to be resolved here for the
-- diagnostic RequestBurstFinishBlow route; that route is gone, and resolving
-- methods no one calls is just startup work that can fail confusingly.
local _state = {
    inited = false,
    m_get_hacking_gauge = nil,
    m_can_deathblow = nil,
    m_try_deathblow = nil,
    m_gauge_full = nil,
    m_gauge_remaining_rate = nil,
    m_gauge_remaining_points = nil,
    m_gauge_total_points = nil,
}

local function ensure_init()
    if _state.inited then return end
    _state.inited = true

    local function td(name) return safe(function() return sdk.find_type_definition(name) end) end
    local function m(type_def, sig)
        if type_def == nil then return nil end
        return safe(function() return type_def:get_method(sig) end)
    end

    local puzzle_td     = td(TD_PUZZLE_DRIVER)
    local deathblow_td  = td(TD_DEATHBLOW_DRIVER)
    local gauge_td      = td("app.GaugeUnit")

    -- PuzzleControlDriver owns the hacking gauge Overdrive spends.
    if puzzle_td ~= nil then
        _state.m_get_hacking_gauge = m(puzzle_td, "get_HackingGauge()")
    end
    if deathblow_td ~= nil then
        _state.m_can_deathblow = m(deathblow_td, "canDeathblow()")
        _state.m_try_deathblow = m(deathblow_td, "tryDeathblow()")
    end
    if gauge_td ~= nil then
        _state.m_gauge_full             = m(gauge_td, "get_Full()")
        _state.m_gauge_remaining_rate   = m(gauge_td, "get_RemainingRate()")
        _state.m_gauge_remaining_points = m(gauge_td, "get_RemainingPoint()")
        _state.m_gauge_total_points     = m(gauge_td, "get_TotalPoint()")
    end

    -- Install per-frame capture hooks. Only the two drivers this binding
    -- actually reads: PuzzleControlDriver for the gauge, DeathblowDriver for
    -- canDeathblow/tryDeathblow.
    player_drivers.want(TD_PUZZLE_DRIVER)
    player_drivers.want(TD_DEATHBLOW_DRIVER)
    player_status.want_handles()
end

local function find_driver(type_name)
    ensure_init()
    return player_drivers.get(type_name)
end

local function read_gauge()
    local driver = find_driver(TD_PUZZLE_DRIVER)
    if driver == nil or _state.m_get_hacking_gauge == nil then return nil end
    return safe(function() return _state.m_get_hacking_gauge:call(driver) end)
end

local function gauge_number(method_def, clamp_max)
    ensure_init()
    local gauge = read_gauge()
    if gauge == nil or method_def == nil then return nil end
    local value = safe(function() return method_def:call(gauge) end)
    if type(value) ~= "number" then return nil end
    if value < 0 then return 0.0 end
    if clamp_max ~= nil and value > clamp_max then return clamp_max end
    return value
end

-- ---------------------------------------------------------------------------
-- Gauge reads
-- ---------------------------------------------------------------------------

-- Hacking-gauge fill fraction in [0, 1], or nil when unreachable.
-- CONFIDENCE: high -- get_RemainingRate is a property on app.GaugeUnit.
function M.gauge_fraction()
    return gauge_number(_state.m_gauge_remaining_rate, 1.0)
end

function M.gauge_total_points()
    return gauge_number(_state.m_gauge_total_points)
end

function M.gauge_remaining_points()
    return gauge_number(_state.m_gauge_remaining_points)
end

function M.gauge_full()
    ensure_init()
    local gauge = read_gauge()
    if gauge == nil or _state.m_gauge_full == nil then return nil end
    local value = safe(function() return _state.m_gauge_full:call(gauge) end)
    if type(value) == "boolean" then return value end
    local n = value_to_int(value)
    return n ~= nil and n ~= 0 or nil
end

-- True when the gauge holds at least the cost observed in the one completed
-- manual trace. Retained for compatibility (ability_state and the debug panel
-- both report it) but it is no longer the primary readiness signal.
function M.has_observed_cost()
    local points = M.gauge_remaining_points()
    return type(points) == "number" and points >= OBSERVED_MINIMUM_COST
end

-- ---------------------------------------------------------------------------
-- Readiness
-- ---------------------------------------------------------------------------

-- Live result of app.PlayerDeathblowDriver.canDeathblow(), or nil when the
-- driver or method is unreachable. This is the game's own permission check --
-- the same predicate it evaluates every frame in updateDeathblowState().
function M.can_deathblow()
    ensure_init()
    local driver = find_driver(TD_DEATHBLOW_DRIVER)
    if driver == nil or _state.m_can_deathblow == nil then return nil end
    local can = safe(function() return _state.m_can_deathblow:call(driver) end)
    if type(can) == "boolean" then return can end
    local n = value_to_int(can)
    if n == nil then return nil end
    return n ~= 0
end

-- Ask the engine, in order of authority:
--   1. PlayerDeathblowDriver.canDeathblow() -- the game's own gate. In both
--      captures it read true immediately before the successful activation and
--      false on the very next frame.
--   2. DeathblowStatus.CanDeathblow -- the same answer off the status mask,
--      used when the driver is momentarily unreachable.
--   3. The gauge threshold -- fallback only, and only meaningful because the
--      100-point cost is now confirmed.
-- Returns (ready_bool, reason_string) so a refusal can say what it checked.
function M.readiness()
    ensure_init()

    local can = M.can_deathblow()
    if can == true then return true, "PlayerDeathblowDriver.canDeathblow()" end

    local container = player_status.container()
    if container ~= nil then
        for _, entry in ipairs(READY_FLAGS) do
            if player_status.has(entry.status, entry.flag, container) == true then
                return true, entry.status:gsub("^app%.player%.", "") .. "." .. entry.flag
            end
        end
    end

    -- canDeathblow() answering a definite `false` is the game refusing, which
    -- is more informative than any gauge arithmetic we could do here.
    if can == false then
        local points = M.gauge_remaining_points()
        return false, string.format(
            "the game reports Overdrive is not currently usable (canDeathblow() is false%s)",
            type(points) == "number"
                and string.format("; gauge holds %.1f points", points) or "")
    end

    local points = M.gauge_remaining_points()
    if type(points) ~= "number" then
        return false, "hacking gauge is unreachable (not in gameplay?)"
    end
    if points >= OBSERVED_MINIMUM_COST then
        return true, string.format("gauge fallback (%.1f points)", points)
    end
    return false, string.format(
        "no engine readiness signal and the gauge holds %.1f of the %.0f points "
        .. "one activation costs", points, OBSERVED_MINIMUM_COST)
end

function M.is_ready()
    local ready = M.readiness()
    return ready == true
end

-- ---------------------------------------------------------------------------
-- Trigger
-- ---------------------------------------------------------------------------

-- How this binding fires Overdrive: app.PlayerDeathblowDriver.tryDeathblow().
--
-- That is the call the captures show the game itself making. It re-runs the
-- game's own guards, so it can refuse -- but it can never start the ability in
-- a state the game disallows. startDeathBlow() is the inner call; it skips
-- those guards, so it is both more likely to fire and more likely to fire
-- wrongly, and this binding never calls it.
--
-- tryDeathblow WRAPS startDeathBlow. PROVEN, twice, by the entry/exit depth
-- capture -- the earlier exit-only traces could not separate "A called B" from
-- "B ran, then A ran", and it turned out to be the former:
--
--     f15046  ENTER tryDeathblow()      depth 0
--     f15046    ENTER startDeathBlow()  depth 1
--     f15046    EXIT  startDeathBlow()  depth 1
--     f15046  EXIT  tryDeathblow()      depth 0
--
-- Which is exactly why they must never be chained: calling tryDeathblow and
-- then falling back to startDeathBlow is a SECOND activation, not a retry.
-- Since the outer call is strictly safer and already reaches the inner one,
-- there is nothing to select between -- so the config switch that used to
-- choose a route is gone, and with it any way to reintroduce the chain.
--
-- The same capture also gives the post-dispatch timeline, which is what the
-- confirmation logic below is timed against:
--
--     +1 frame   canDeathblow() flips true -> false; DeathblowStatus.Request
--     +4 frames  Request/CanDeathblow clear, Start|Play raise, gauge -100
--     +5 frames  Start clears (Play stays up for the animation)
local DISPATCH_METHOD_KEY = "m_try_deathblow"
local DISPATCH_LABEL = "tryDeathblow()"

local function begin_trigger()
    ensure_init()

    if _pending ~= nil then
        return false, "an overdrive request is already awaiting confirmation"
    end

    local ready, reason = M.readiness()
    if not ready then return false, reason end

    local driver = find_driver(TD_DEATHBLOW_DRIVER)
    if driver == nil then
        return false, "the Deathblow driver is not captured (not in gameplay?)"
    end
    local method = _state[DISPATCH_METHOD_KEY]
    if method == nil then
        return false, "app.PlayerDeathblowDriver." .. DISPATCH_LABEL .. " is unavailable"
    end

    local before_points = M.gauge_remaining_points()
    local before_can = M.can_deathblow()

    -- The method returns void, so a successful call says nothing about whether
    -- the ability started. That is what the confirmation window is for.
    local called = pcall(function() method:call(driver) end)
    if not called then
        return false, "app.PlayerDeathblowDriver." .. DISPATCH_LABEL .. " threw"
    end

    _pending = {
        frame = 0,
        before_points = before_points,
        before_can_deathblow = before_can,
        command = DISPATCH_LABEL,
        readiness = reason,
        start_flag = nil,
        gauge_delta = nil,
    }
    _last_confirmation = nil
    _request = { state = "pending", message = nil, id = _request.id + 1 }
    return true, string.format(
        "called PlayerDeathblowDriver.%s (ready via %s); awaiting the game's confirmation",
        DISPATCH_LABEL, reason)
end

-- Fire Overdrive. Takes no arguments: there is exactly one route.
function M.trigger()
    local ok, msg = begin_trigger()
    _last_trigger_msg = (ok and "OK: " or "FAIL: ") .. tostring(msg)
    return ok, msg
end

-- ---------------------------------------------------------------------------
-- Confirmation
-- ---------------------------------------------------------------------------

-- Advance the in-flight request. PRIVATE: called only from this module's frame
-- callback, so the state machine has exactly one writer.
--
-- Confirmation is event-based now: a START_FLAGS status flag raised on the
-- live mask, or a meaningful gauge drop. The old version only polled the gauge
-- and required half the assumed 100-point cost, which could not tell a
-- refusal apart from an ability whose cost is not 100.
local function advance_pending()
    if _pending == nil then return end
    ensure_init()

    local container = player_status.container()
    if container ~= nil then
        for _, entry in ipairs(START_FLAGS) do
            if player_status.has(entry.status, entry.flag, container) == true then
                _pending.start_flag = entry.status .. "." .. entry.flag
                _last_confirmation = {
                    frame = _frame, reason = "status flag",
                    flag = _pending.start_flag,
                    gauge_delta = _pending.gauge_delta,
                }
                _pending = nil
                _last_trigger_msg = "OK: engine raised " .. tostring(_last_confirmation.flag)
                _request.state = "confirmed"
                _request.message = "the game started Overdrive ("
                    .. tostring(_last_confirmation.flag) .. ")"
                return
            end
        end
    end

    -- canDeathblow() flipping true -> false is the fastest signal available:
    -- the captures show it one frame after dispatch, against four frames for
    -- the gauge. It is only meaningful if it was true when we dispatched --
    -- otherwise "false now" says nothing.
    if _pending.before_can_deathblow == true and M.can_deathblow() == false then
        _last_confirmation = {
            frame = _frame, reason = "canDeathblow cleared",
            gauge_delta = _pending.gauge_delta,
        }
        _pending = nil
        _last_trigger_msg = "OK: the game cleared canDeathblow(), so Overdrive started"
        _request.state = "confirmed"
        _request.message = "the game started Overdrive (canDeathblow cleared)"
        return
    end

    local current = M.gauge_remaining_points()
    if type(current) == "number" and type(_pending.before_points) == "number" then
        local delta = _pending.before_points - current
        _pending.gauge_delta = delta
        -- Any real spend counts. Well above per-frame drift and far below the
        -- confirmed 100-point cost, so a smaller cost in some other context
        -- still confirms.
        if delta >= 5.0 then
            _last_confirmation = {
                frame = _frame, reason = "gauge spend", gauge_delta = delta,
            }
            _pending = nil
            _last_trigger_msg = string.format("OK: gauge spent %.1f points", delta)
            _request.state = "confirmed"
            _request.message = string.format(
                "the game started Overdrive (gauge spent %.1f points)", delta)
            return
        end
    end

    _pending.frame = _pending.frame + 1
    if _pending.frame >= CONFIRM_TIMEOUT_FRAMES then
        local observed = _pending.gauge_delta
        _last_confirmation = {
            frame = _frame, reason = "timeout",
            gauge_delta = observed, command = _pending.command,
        }
        _pending = nil
        _last_trigger_msg = string.format(
            "FAIL: %s was called but the game showed no Overdrive start "
            .. "(no status flag, canDeathblow unchanged, gauge moved %s)",
            tostring(_last_confirmation.command),
            type(observed) == "number" and string.format("%.1f", observed) or "not at all")
        _request.state = "failed"
        _request.message = _last_trigger_msg:gsub("^FAIL: ", "")
    end
end

-- Pure read of the latched request outcome:
--   true  -- the game started Overdrive
--   false -- the request concluded without it starting
--   nil   -- still waiting
-- Safe to call from anywhere, any number of times per frame.
function M.request_progressed()
    if _request.state == "pending" then return nil end
    return _request.state == "confirmed"
end

-- The latched state and its explanation: "idle" | "pending" | "confirmed" |
-- "failed" | "cancelled".
function M.request_state()
    return _request.state, _request.message
end

function M.cancel_pending()
    if _pending ~= nil then
        _request.state = "cancelled"
        _request.message = "the overdrive request was cancelled before the game acted on it"
    end
    _pending = nil
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

function M.debug_status()
    ensure_init()
    local ready, reason = M.readiness()
    local deathblow = find_driver(TD_DEATHBLOW_DRIVER)
    local can_deathblow = nil
    if deathblow ~= nil and _state.m_can_deathblow ~= nil then
        can_deathblow = safe(function() return _state.m_can_deathblow:call(deathblow) end)
        if type(can_deathblow) ~= "boolean" then
            can_deathblow = value_to_int(can_deathblow) == 1
        end
    end
    return {
        drivers                 = player_drivers.debug_status(),
        puzzle_driver_ok        = find_driver(TD_PUZZLE_DRIVER) ~= nil,
        deathblow_driver_ok     = deathblow ~= nil,
        can_deathblow           = can_deathblow,
        dispatch_label          = DISPATCH_LABEL,
        try_deathblow_ok        = _state.m_try_deathblow ~= nil,
        gauge_fraction          = M.gauge_fraction(),
        gauge_total             = M.gauge_total_points(),
        gauge_remain            = M.gauge_remaining_points(),
        gauge_full              = M.gauge_full(),
        is_ready                = ready,
        readiness_reason        = reason,
        observed_minimum_cost   = OBSERVED_MINIMUM_COST,
        observed_cost_available = M.has_observed_cost(),
        status_layer            = player_status.debug_status(),
        input_pending           = _pending ~= nil,
        pending                 = _pending and {
            frames_waited = _pending.frame,
            command = _pending.command,
            gauge_delta = _pending.gauge_delta,
        } or nil,
        last_confirmation       = _last_confirmation,
        last_trigger_msg        = _last_trigger_msg,
    }
end

return M
