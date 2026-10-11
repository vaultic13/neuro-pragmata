--
-- Scene prompts that wait for the Overdrive button.
--
-- Some scripted scenes slow or freeze and show one centred button icon: the
-- scene will not continue until the player presses Overdrive. This binding
-- notices that, and presses it on the peer's behalf.
--
-- ENGINE LAYOUT (il2cpp dump; confirmed in game 2026-10-09..11)
--
--   app.EventActionDeathBlowUnlock_PLWrapperd : app.EventActionWrapperdBase
--     the timeline action that runs such a scene. Subclasses:
--       app.EventActionCh14500DeathBlowWrapperd        (a boss finisher)
--       app.EventActionFilamentRemoverUnlock_PLWrapperd
--     neither overrides update(), so one hook on the base update() sees all
--     three (CLAUDE.md §3: a base hook misses overrides -- here there are none).
--     _State : ...Wrapperd.State
--       Wait, AddGauge, WaitGaugeFullEffect, WaitStartDeathBlowButton,
--       StartedDeathBlow
--     get_OpenType() -> app.FinishBlowGuiMediator.OpenType
--     onSpecialMove() -- what a real press runs
--   app.FinishBlowGuiMediator.requestOpen / requestClose(OpenType) -- the
--     centred icon; hooked to latch whether it is on screen.
--   GuiManager.<FinishBlowGuiMediator>k__BackingField._OpeningType -- the
--     same icon as a bitmask; read for the debug panel only.
--
-- CAPTURED 2026-10-09 (boss scene, Ch14500, one manual press):
--
--     Wait -> AddGauge -> icon.requestOpen -> WaitGaugeFullEffect
--     ... the scene waits here with the icon up ...
--     f45051 ENTER scene.onSpecialMove      depth 0
--     f45051   ENTER icon.requestClose
--     f45051 EXIT  scene.onSpecialMove
--     f45052 state -> StartedDeathBlow
--
-- So the prompt is up while the action is in WaitGaugeFullEffect (or, for the
-- scenes that use it, WaitStartDeathBlowButton) AND the icon is open. The
-- press reaches the scene as onSpecialMove(), not through a command reader:
-- FinishBlow, FillamentRemove and SpecialMove injected on PlayerInputDriver,
-- PlayerUpdater and PlayerCommandUpdater did nothing, and tryDeathblow() is
-- not involved. press() therefore calls the action's own onSpecialMove(); the
-- Overdrive unlock, the first boss and the Filament Remover scenes all went on
-- that way (2026-10-11).
--
-- Confirmation is the scene's own state: confirmed when the action leaves its
-- waiting state (or ends), failed when it has not within
-- cutscene_prompt_confirm_frames. One writer: this module's frame callback.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local r = require("pragmata.bindings.reflect")
local registry = require("pragmata.bindings.puzzle_registry")
local scene = require("pragmata.bindings.scene")
-- The sector a prompt comes up in (cutscene_prompt_followup_overdrive).
local area_progress = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.area_progress")
    if ok then area_progress = mod end
end

local M = {}

local TD_WRAPPER = "app.EventActionDeathBlowUnlock_PLWrapperd"
local TD_STATE = "app.EventActionDeathBlowUnlock_PLWrapperd.State"
local TD_OPEN_TYPE = "app.FinishBlowGuiMediator.OpenType"
-- States in which the scene waits for the button (with the icon up).
local WAIT_STATE_NAMES = { WaitGaugeFullEffect = true, WaitStartDeathBlowButton = true }
-- The dump's packed defaults for those members; used only if reflecting the
-- enum's names fails.
local WAIT_STATE_FALLBACK = { [2] = true, [3] = true }

local KIND_OF_TYPE = {
    ["app.EventActionDeathBlowUnlock_PLWrapperd"] = "unlock",
    ["app.EventActionCh14500DeathBlowWrapperd"] = "boss",
    ["app.EventActionFilamentRemoverUnlock_PLWrapperd"] = "filament",
}

-- update() runs every frame the action is live. The clock below stops while
-- the game is paused, so a pause neither ends a prompt nor mints it a new id.
-- A wrapper unseen for
-- STALE_FRAMES is not offered as a prompt (the game may only be paused, so it
-- keeps its id); one unseen for FORGET_FRAMES, or no longer live, is dropped.
local STALE_FRAMES = 30
local FORGET_FRAMES = 1800

local _frame = 0
local _s = { inited = false, icon_open = {} }
local _wrappers = {}        -- address -> { obj, type_name, kind, last_frame, waiting_id }
local _next_id = 0
local _active = nil         -- neutral table of the prompt up now, or nil
local _request = { state = "idle", message = nil, id = 0 }
local _pending = nil        -- { prompt_id, address, frame }
local _last_press = nil     -- { frame, ok, message }

local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- ---------------------------------------------------------------------------
-- Init: the one hook that finds live scene actions
-- ---------------------------------------------------------------------------

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local td = r.td(TD_WRAPPER)
    _s.m_update = r.method(td, "update()")
    _s.m_open_type = r.method(td, "get_OpenType()")
    _s.m_special_move = r.method(td, "onSpecialMove()")
    _s.state_names = r.enum_value_names(TD_STATE)
    _s.open_type_names = r.enum_value_names(TD_OPEN_TYPE)
    _s.wait_values = {}
    for value, name in pairs(_s.state_names) do
        if WAIT_STATE_NAMES[name] then _s.wait_values[value] = true end
    end
    if next(_s.wait_values) == nil then
        _s.wait_values = WAIT_STATE_FALLBACK
        log.warn("cutscene_prompt: state enum unreadable; assuming wait states 2 and 3")
    end
    -- The prompt icon, latched from the mediator's own open/close requests.
    -- Rarely called, so the hooks cost nothing between prompts.
    local med_td = r.td("app.FinishBlowGuiMediator")
    local m_open = r.method(med_td, "requestOpen(app.FinishBlowGuiMediator.OpenType)")
    local m_close = r.method(med_td, "requestClose(app.FinishBlowGuiMediator.OpenType)")
    if m_open ~= nil and m_close ~= nil then
        _s.icon_hooked = pcall(function()
            sdk.hook(m_open, function(args)
                local t = safe(function() return sdk.to_int64(args[3]) end)
                if t ~= nil then _s.icon_open[t] = _frame end
            end, function(retval) return retval end)
            sdk.hook(m_close, function(args)
                local t = safe(function() return sdk.to_int64(args[3]) end)
                if t ~= nil then _s.icon_open[t] = nil end
            end, function(retval) return retval end)
        end)
    end
    if not _s.icon_hooked then
        log.warn("cutscene_prompt: icon open/close hooks unavailable; going by the scene state alone")
    end
    if _s.m_update == nil then
        _s.error = TD_WRAPPER .. ".update() unresolved"
        log.warn("cutscene_prompt: " .. _s.error)
        return
    end
    local ok, err = pcall(function()
        sdk.hook(_s.m_update, function(args)
            local obj = sdk.to_managed_object(args[2])
            if obj == nil then return end
            local addr = safe(function() return obj:get_address() end)
            if addr == nil then return end
            local w = _wrappers[addr]
            if w == nil then
                local tn = safe(function() return obj:get_type_definition():get_full_name() end)
                w = { obj = obj, type_name = tn, kind = KIND_OF_TYPE[tn] or "unknown",
                      address = addr }
                _wrappers[addr] = w
            end
            w.last_frame = _frame
        end, function(retval) return retval end)
    end)
    if not ok then
        _s.error = "hook failed: " .. tostring(err)
        log.warn("cutscene_prompt: " .. _s.error)
    else
        log.info("cutscene_prompt: scene action hook installed")
    end
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

local function state_of(w)
    return r.to_int(r.field(w.obj, "_State"))
end

local function open_type_of(w)
    local v = r.to_int(r.call(_s.m_open_type, w.obj))
    if v == nil then return nil end
    return _s.open_type_names[v] or tostring(v)
end

-- Names of the bits set in FinishBlowGuiMediator._OpeningType, i.e. which
-- prompt icons the HUD is showing. Empty when nothing is, nil if unreadable.
local function opening_bits()
    local gm = r.singleton("app.GuiManager")
    local med = r.field(gm, "<FinishBlowGuiMediator>k__BackingField")
    local bits = r.to_int(r.field(med, "_OpeningType"))
    if bits == nil then return nil end
    local out = {}
    for value, name in pairs(_s.open_type_names or {}) do
        if value > 0 and math.floor(bits / value) % 2 == 1 then out[#out + 1] = name end
    end
    table.sort(out)
    return out, bits
end

local function icon_up()
    if not _s.icon_hooked then return true end
    return next(_s.icon_open) ~= nil
end

local function is_waiting(st)
    return st ~= nil and _s.wait_values ~= nil and _s.wait_values[st] == true
end

local function button_for(kind)
    local map = config.cutscene_prompt_buttons or {}
    return map[kind]
end

-- ---------------------------------------------------------------------------
-- Press
-- ---------------------------------------------------------------------------

local function press_wrapper(w)
    if _s.m_special_move == nil then return false, "onSpecialMove() unresolved" end
    if not pcall(function() _s.m_special_move:call(w.obj) end) then
        return false, "onSpecialMove() threw"
    end
    return true, "called the scene action's onSpecialMove()"
end

-- ---------------------------------------------------------------------------
-- Frame: track wrappers, mint prompt ids, advance the request
-- ---------------------------------------------------------------------------

local function finish(state, message)
    _pending = nil
    _request.state = state
    _request.message = message
end

local function advance_pending()
    if _pending == nil then return end
    local w = _wrappers[_pending.address]
    local st = w and state_of(w) or nil
    if w == nil or st == nil then
        finish("confirmed", "the scene moved on (its prompt action ended)")
        return
    end
    -- Not updated lately: the game is paused, not finished. Hold the clock.
    if _frame - (w.last_frame or 0) > STALE_FRAMES then return end
    if not is_waiting(st) then
        finish("confirmed", "the scene continued ("
            .. tostring(_s.state_names[st] or st) .. ")")
        return
    end
    _pending.frame = _pending.frame + 1
    if _pending.frame >= (config.cutscene_prompt_confirm_frames or 150) then
        finish("failed", "the scene is still waiting for the button")
    end
end

local function tick()
    ensure_init()
    local best = nil
    for addr, w in pairs(_wrappers) do
        local age = _frame - (w.last_frame or 0)
        if age > FORGET_FRAMES or not r.is_live(w.obj) then
            _wrappers[addr] = nil
        elseif age <= STALE_FRAMES then
            local st = state_of(w)
            -- Once up, a prompt stays up for as long as the state holds, even
            -- if the icon latch misses its close.
            if is_waiting(st) and (w.waiting_id ~= nil or icon_up()) then
                if w.waiting_id == nil then
                    _next_id = _next_id + 1
                    w.waiting_id = _next_id
                    w.waiting_since = _frame
                    if area_progress ~= nil then
                        local ok_s, hash, name = pcall(area_progress.current_sector)
                        if ok_s then w.sector_hash, w.sector_name = hash, name end
                    end
                    log.info(string.format("cutscene_prompt: prompt %d up (%s, %s, state %s, sector %s / %s)",
                        w.waiting_id, tostring(w.kind), tostring(open_type_of(w)),
                        tostring(_s.state_names[st] or st),
                        tostring(w.sector_name), tostring(w.sector_hash)))
                end
                if best == nil or w.waiting_since > best.waiting_since then best = w end
            else
                w.waiting_id = nil
            end
        end
    end
    if best ~= nil then
        _active = {
            id = best.waiting_id,
            kind = best.kind,
            open_type = open_type_of(best),
            button = button_for(best.kind),
            since_frame = best.waiting_since,
            sector = best.sector_name,
            sector_hash = best.sector_hash,
        }
        _s.active_address = best.address
    else
        _active = nil
        _s.active_address = nil
    end
    advance_pending()
end

re.on_frame(function()
    local ok_p, paused = pcall(registry.is_game_paused)
    if ok_p and paused then return end
    _frame = _frame + 1
    if config.cutscene_prompt_enabled == false then
        _active = nil
        return
    end
    -- Scene actions are torn down during loads; read nothing then.
    local ok_l, loaded = pcall(scene.is_loaded)
    if ok_l and loaded == false then return end
    local ok, err = pcall(tick)
    if not ok and not _s.tick_warned then
        _s.tick_warned = true
        log.warn("cutscene_prompt: tick raised: " .. tostring(err))
    end
end)

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- The prompt waiting right now, or nil:
--   { id, kind = "unlock"|"boss"|"filament"|"unknown", open_type, button, since_frame,
--     sector, sector_hash }   (the sector the prompt came up in, when readable)
-- `button` is mod_config.cutscene_prompt_buttons[kind]; only "overdrive" is
-- one the peer is asked to press.
function M.active() return _active end

-- True while any scene action of this kind is still being updated, i.e. the
-- scene is still playing (in or out of its waiting state).
function M.scene_running()
    for _, w in pairs(_wrappers) do
        if _frame - (w.last_frame or 0) <= STALE_FRAMES then return true end
    end
    return false
end

-- Press the waiting prompt. `expected_id` (optional) refuses if a different
-- prompt -- or none -- is up, so a late reply never presses the wrong one.
function M.press(expected_id)
    if _active == nil then return false, "no scene is waiting for a button press" end
    if expected_id ~= nil and _active.id ~= expected_id then
        return false, "the prompt that was offered is no longer up"
    end
    if _pending ~= nil then return false, "a press is already waiting for the scene to respond" end
    local w = _wrappers[_s.active_address]
    if w == nil then return false, "the scene action is no longer tracked" end

    _request = { state = "pending", message = nil, id = _request.id + 1 }
    _pending = { prompt_id = _active.id, address = _s.active_address, frame = 0 }
    local ok, message = press_wrapper(w)
    _last_press = { frame = _frame, ok = ok, message = message }
    log.info("cutscene_prompt: press prompt " .. tostring(_active.id) .. " -> " .. tostring(message))
    if not ok then
        finish("failed", message)
        return false, message
    end
    return true, "pressing the scene's prompt: " .. message
end

-- "idle" | "pending" | "confirmed" | "failed", and its explanation.
function M.request_state() return _request.state, _request.message end
function M.request_id() return _request.id end

function M.debug_status()
    ensure_init()
    local bits_names, bits = opening_bits()
    local wrappers = {}
    for addr, w in pairs(_wrappers) do
        local st = state_of(w)
        wrappers[#wrappers + 1] = {
            address = string.format("%X", addr),
            type_name = w.type_name, kind = w.kind,
            state = st, state_name = _s.state_names and _s.state_names[st],
            open_type = open_type_of(w),
            waiting_id = w.waiting_id,
            age = _frame - (w.last_frame or 0),
        }
    end
    return {
        error = _s.error,
        hook = _s.m_update ~= nil and _s.error == nil,
        wait_value = table.concat((function()
            local out = {}
            for v in pairs(_s.wait_values or {}) do out[#out + 1] = tostring(v) end
            return out
        end)(), ","),
        icon_hooked = _s.icon_hooked,
        icon_open = next(_s.icon_open) ~= nil,
        wrappers = wrappers,
        active = _active,
        opening_bits = bits,
        opening_names = bits_names,
        request_state = _request.state,
        request_message = _request.message,
        pending_frames = _pending and _pending.frame or nil,
        last_press = _last_press,
    }
end

return M
