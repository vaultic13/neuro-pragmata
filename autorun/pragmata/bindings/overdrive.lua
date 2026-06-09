--
-- Bindings for Diana's Overdrive Protocol ultimate (the gauge-fueled AoE
-- pulse triggered by the dual-stick chord once the hacking gauge fills).
--
-- Engine layout (verified against the IL2CPP dump):
--
--   The "ultimate" is implemented in the engine as the wide-area variant of
--   the FinishBlow system, gated on the hacking gauge being full. We have
--   three signals to work with:
--
--   * app.player.PuzzleStatus (UInt64 flag enum) members:
--       HackingGaugeFull        -> gauge is at full capacity right now
--       HackingGaugeFullTrigger -> gauge just hit full this frame
--     These are status flags read on the player's per-frame status mask.
--     We don't have a clean reflection path to the live mask, so they're
--     informational only at this layer.
--
--   * app.player.FinishBlowStatus (UInt64 flag enum) members:
--       CheckBurstFinishBlow   = 1
--       CanBurstFinishBlow     = 2     -- ultimate is currently usable
--       RequestBurstFinishBlow = 4     -- "fire the ultimate this frame"
--       StartBurstFinishBlow   = 8     -- engine has begun the ultimate
--       CanFinishBlow          = 16    -- the regular (non-ultimate) variant
--     These flags are the actual engine-level state for the ultimate. The
--     "Burst" prefix in the engine's naming is what the game's UI calls
--     this ability under different naming. We translate to the public
--     "Overdrive" terminology in this binding's API surface.
--
--   * app.PlayerPuzzleControlDriver:
--       get_HackingGauge() -> app.GaugeUnit
--         Where the actual gauge instance lives. app.GaugeUnit gives us:
--           get_Full() -> bool
--           get_RemainingRate() -> f32 in [0, 1]
--           get_RemainingPoint(), get_TotalPoint() -> raw points
--
--   * app.PlayerFinishBlowDriver:
--       requestWideFinishBlow(System.Int32) -> System.Boolean
--         Private, but it's the closest direct trigger we found. Takes a
--         single Int32 (the wide-blow damage value). The boolean return
--         presumably indicates whether the request was accepted. We use
--         this as the trigger entry point; the damage value is passed
--         through unchanged from getWideFinishBlowDamage() if that's
--         readable, else we fall back to 0 and rely on the engine clamping.
--
-- Trigger philosophy:
--   The driver's requestWideFinishBlow is marked Private in the dump, which
--   may or may not survive REFramework reflection-call. If it doesn't, the
--   binding logs a warning and reports a neutral failure. The fallback path
--   would be input synthesis (the dual-stick chord) but we don't ship that
--   from a binding file.

local log = require("pragmata.util.log")
local player_drivers = require("pragmata.bindings.player_drivers")

local M = {}

-- These drivers live on the player handle's driver board, NOT in the managed-
-- singleton registry, so they're captured live via per-frame hooks (see
-- player_drivers.lua). Earlier this binding called get_managed_singleton on
-- them, which always returned nil — that was why Overdrive never fired.
local TD_PUZZLE_DRIVER     = "app.PlayerPuzzleControlDriver"
local TD_FINISHBLOW_DRIVER = "app.PlayerFinishBlowDriver"

-- Last trigger attempt result, surfaced to the abilities debug panel.
local _last_trigger_msg = "(overdrive not triggered yet)"

-- ---------------------------------------------------------------------------
-- One-time SDK lookups
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    char_mgr_td = nil,
    puzzle_driver_td = nil,
    finishblow_driver_td = nil,
    gauge_unit_td = nil,
    m_get_player_handle = nil,
    m_get_hacking_gauge = nil,
    m_request_wide_finishblow = nil,
    m_get_wide_finishblow_damage = nil,
    m_gauge_full = nil,
    m_gauge_remaining_rate = nil,
}

local function ensure_init()
    if _state.inited then return end
    _state.inited = true

    local function td(name)
        local ok, v = pcall(function() return sdk.find_type_definition(name) end)
        if ok then return v end
        return nil
    end
    local function m(td_obj, sig)
        if td_obj == nil then return nil end
        local ok, v = pcall(function() return td_obj:get_method(sig) end)
        if ok then return v end
        return nil
    end

    _state.char_mgr_td          = td("app.CharacterManager")
    _state.puzzle_driver_td     = td("app.PlayerPuzzleControlDriver")
    _state.finishblow_driver_td = td("app.PlayerFinishBlowDriver")
    _state.gauge_unit_td        = td("app.GaugeUnit")

    if _state.char_mgr_td ~= nil then
        _state.m_get_player_handle = m(_state.char_mgr_td, "getPlayerHandle()")
    end

    if _state.puzzle_driver_td ~= nil then
        _state.m_get_hacking_gauge = m(_state.puzzle_driver_td, "get_HackingGauge()")
    end

    if _state.finishblow_driver_td ~= nil then
        _state.m_request_wide_finishblow = m(_state.finishblow_driver_td,
            "requestWideFinishBlow(System.Int32)")
        _state.m_get_wide_finishblow_damage = m(_state.finishblow_driver_td,
            "getWideFinishBlowDamage()")
    end

    if _state.gauge_unit_td ~= nil then
        _state.m_gauge_full          = m(_state.gauge_unit_td, "get_Full()")
        _state.m_gauge_remaining_rate = m(_state.gauge_unit_td, "get_RemainingRate()")
    end

    -- Install the per-frame capture hooks for the two player drivers. They
    -- start populating the moment the drivers tick (i.e. once the player is
    -- in a level), well before any overdrive attempt.
    player_drivers.want(TD_PUZZLE_DRIVER)
    player_drivers.want(TD_FINISHBLOW_DRIVER)
end

-- The two player drivers are captured live by player_drivers.lua (per-frame
-- hook on each driver's onUpdate). Returns nil in pause/loading/non-combat
-- scenes where the driver isn't ticking yet.
local function find_puzzle_driver()
    ensure_init()
    return player_drivers.get(TD_PUZZLE_DRIVER)
end

local function find_finishblow_driver()
    ensure_init()
    return player_drivers.get(TD_FINISHBLOW_DRIVER)
end

local function read_gauge()
    local driver = find_puzzle_driver()
    if driver == nil or _state.m_get_hacking_gauge == nil then return nil end
    local ok, gauge = pcall(function()
        return _state.m_get_hacking_gauge:call(driver)
    end)
    if ok and gauge ~= nil then return gauge end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns true iff the gauge appears full and the ultimate is fireable
-- right now. False if the gauge isn't full, the driver isn't reachable, or
-- the engine state can't be probed.
-- CONFIDENCE: high on the gauge.get_Full() read; the binding falls through
-- to a remaining-rate >= 0.999 check if the boolean accessor isn't usable.
function M.is_ready()
    ensure_init()
    local gauge = read_gauge()
    if gauge == nil then return false end

    if _state.m_gauge_full ~= nil then
        local ok, full = pcall(function()
            return _state.m_gauge_full:call(gauge)
        end)
        if ok and full == true then return true end
        if ok and full == false then return false end
    end

    -- Backup path via remaining rate.
    if _state.m_gauge_remaining_rate ~= nil then
        local ok, rate = pcall(function()
            return _state.m_gauge_remaining_rate:call(gauge)
        end)
        if ok and type(rate) == "number" and rate >= 0.999 then return true end
    end

    return false
end

-- Returns the hacking gauge fill fraction in [0.0, 1.0], or nil if the
-- driver/gauge isn't currently reachable.
-- CONFIDENCE: high — get_RemainingRate is a public property on GaugeUnit.
function M.gauge_fraction()
    ensure_init()
    local gauge = read_gauge()
    if gauge == nil then return nil end

    if _state.m_gauge_remaining_rate == nil then return nil end
    local ok, rate = pcall(function()
        return _state.m_gauge_remaining_rate:call(gauge)
    end)
    if not ok then return nil end
    if type(rate) ~= "number" then return nil end
    if rate < 0 then return 0.0 end
    if rate > 1 then return 1.0 end
    return rate
end

-- Fire Overdrive. Returns (success_bool, message_string).
-- Refuses gracefully if the gauge isn't full or the engine subsystem can't
-- be reached. On success, the engine takes over the cinematic + AoE pulse.
-- CONFIDENCE: low — the trigger method is private in the dump and may not
-- survive reflection invocation in all REFramework builds. The binding
-- logs a warning so callers know to verify against in-game behaviour.
local function _do_trigger()
    ensure_init()

    if not M.is_ready() then
        return false, "hacking gauge not full; overdrive unavailable"
    end

    local fb_driver = find_finishblow_driver()
    if fb_driver == nil or _state.m_request_wide_finishblow == nil then
        log.warn("overdrive.trigger: finish-blow driver not reachable; cannot dispatch ultimate from binding layer")
        return false, "not implemented: ultimate trigger path not callable from this binding (driver lookup failed)"
    end

    -- Compute the wide-blow damage payload. The engine has its own getter;
    -- if we can read it we pass it through. Otherwise we pass 0 and rely on
    -- internal clamping / data lookup.
    local damage = 0
    if _state.m_get_wide_finishblow_damage ~= nil then
        local ok, v = pcall(function()
            return _state.m_get_wide_finishblow_damage:call(fb_driver)
        end)
        if ok and type(v) == "number" then damage = v end
    end

    log.warn("overdrive.trigger: invoking a method marked Private in the dump; verify behaviour in-game.")

    local ok, accepted = pcall(function()
        return _state.m_request_wide_finishblow:call(fb_driver, damage)
    end)
    if not ok then
        return false, "ultimate request raised an SDK error (private-method reflection may have refused)"
    end
    if accepted == false then
        return false, "engine rejected ultimate request (gauge state changed mid-call?)"
    end

    return true, "overdrive fired"
end


-- Public trigger wrapper: records the last outcome for the abilities debug
-- panel, then returns it unchanged.
function M.trigger()
    local ok, msg = _do_trigger()
    _last_trigger_msg = (ok and "OK: " or "FAIL: ") .. tostring(msg)
    return ok, msg
end


-- Snapshot for the abilities debug panel. Cheap to call every frame.
function M.debug_status()
    ensure_init()
    local fb = find_finishblow_driver()
    local pz = find_puzzle_driver()
    return {
        drivers              = player_drivers.debug_status(),
        finishblow_driver_ok = fb ~= nil,
        puzzle_driver_ok     = pz ~= nil,
        gauge_fraction       = M.gauge_fraction(),
        is_ready             = M.is_ready(),
        request_method_ok    = _state.m_request_wide_finishblow ~= nil,
        last_trigger_msg     = _last_trigger_msg,
    }
end


return M
