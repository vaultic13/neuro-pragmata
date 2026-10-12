-- Scene prompts -> the peer.
--
-- When a scripted scene stops on a button prompt (bindings/cutscene_prompt.lua),
-- this offers it to the peer as an actions/force for the action that button
-- belongs to (BUTTONS below):
--   overdrive  pragmata_overdrive -- ability_actions routes it to the prompt
--              instead of combat Overdrive while one is up
--   purify     pragmata_purify    -- the filament-cleaning button, which the
--              Filament Remover scene asks for; offered only while it is up
-- When the prompt goes away without the peer -- the player pressed it
-- themselves -- the peer is told the scene went on, and a reply that arrives
-- afterwards is refused rather than spent on something nobody asked for.
--
-- Forces share hacking_observer's rule: at most one actions/force outstanding.
-- This module does not send while a hacking force is out, and hacking_observer
-- does not send while this one is (it asks M.inflight()).

local M = {}

local log = require("pragmata.util.log")
local emit = require("pragmata.util.emit")
local mailbox = require("pragmata.bridge_mailbox")
local config = require("pragmata.mod_config")
local dispatcher = require("pragmata.dispatcher")

-- mod_config.cutscene_prompt_buttons value -> what the peer is asked to do.
local BUTTONS = {
    overdrive = {
        action = "pragmata_overdrive",
        what = "the Overdrive button prompt: Diana's Overdrive has to be used",
        query = "Use Overdrive now to continue the scene.",
    },
    purify = {
        action = "pragmata_purify",
        what = "the filament-cleaning button prompt: Diana has to clean the filament",
        query = "Clean the filament now to continue the scene.",
    },
}

local prompt = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.cutscene_prompt")
    if ok then prompt = mod else log.warn("cutscene_prompt_observer: binding not loaded: " .. tostring(mod)) end
end

local GAME = "Pragmata"
local PRIORITY_VALUES = { low = true, medium = true, high = true, critical = true }
-- Same last-resort watchdog as hacking_observer: release the slot only if a
-- reply is physically lost.
local INFLIGHT_WATCHDOG_FRAMES = 1200
-- How long a reply to a prompt that already went away is still recognised
-- as one (and refused), rather than taken as a fresh Overdrive request.
local LATE_REPLY_FRAMES = 1200

local _frame = 0
local _offered = nil        -- { id, since, forced, peer_pressed, fallback_done }
local _inflight = nil       -- { id, since }
local _late_reply = nil      -- { until_frame, action }
local _events = {}          -- newest first, for the debug panel
-- A normal Overdrive owed after a scene prompt (cutscene_prompt_followup_overdrive):
--   { phase = "scene"|"delay"|"firing", since, secs, at, deadline }
local _followup = nil
local FOLLOWUP_SCENE_MAX_FRAMES = 30 * 60   -- give up waiting for the scene to end
local FOLLOWUP_FIRE_FRAMES = 10 * 60        -- keep trying Overdrive this long
local FOLLOWUP_RETRY_FRAMES = 30

local function note(text)
    table.insert(_events, 1, { frame = _frame, text = text })
    while #_events > 12 do table.remove(_events) end
    log.info("cutscene_prompt_observer: " .. text)
end

local function hacking_busy()
    local hobs = package.loaded["pragmata.hacking_observer"]
    if hobs == nil or hobs.inflight == nil then return false end
    local ok, f = pcall(hobs.inflight)
    return ok and type(f) == "table" and f.id ~= nil
end

local function priority()
    local v = config.cutscene_prompt_force_priority
    if type(v) ~= "string" then return nil end
    v = v:lower()
    return PRIORITY_VALUES[v] and v or nil
end

local function describe(active)
    local b = BUTTONS[active.button]
    local who = active.kind == "boss" and "to finish the boss"
        or "to continue"
    return "A scene has stopped on " .. b.what .. " " .. who .. ". Calling "
        .. b.action .. " presses it for the player and the scene carries on."
end

local function send_force(active)
    local b = BUTTONS[active.button]
    local data = {
        state = describe(active),
        query = b.query,
        ephemeral_context = true,
        action_names = { b.action },
        priority = priority(),
    }
    mailbox.send({ command = "actions/force", game = GAME, data = data })
    _inflight = { id = active.id, since = _frame }
    _offered.forced = true
    note("forced " .. b.action .. " for scene prompt " .. tostring(active.id))
end

-- Seconds of cutscene_prompt_followup_overdrive for `sector`, or nil.
local function followup_seconds(sector, sector_hash)
    local map = config.cutscene_prompt_followup_overdrive
    if type(map) ~= "table" then return nil end
    if type(sector) == "string" then
        for k, v in pairs(map) do
            if type(k) == "string" and k:lower() == sector:lower() then return tonumber(v) end
        end
    end
    if sector_hash ~= nil and map[sector_hash] ~= nil then return tonumber(map[sector_hash]) end
    return nil
end

-- The first boss (Solar Power Plant, 2026-10-11): pressing its scene prompt
-- ends the cutscene, but the boss still has to be finished with a normal
-- Overdrive (the gauge is left full for it). Wait for the scene to finish,
-- then `secs`, then fire Overdrive through the same call as F8, retrying while
-- the game is not ready yet.
local function tick_followup()
    local f = _followup
    if f == nil then return end
    if f.phase == "scene" then
        local running = prompt.scene_running()
        if not running or _frame - f.since > FOLLOWUP_SCENE_MAX_FRAMES then
            f.phase = "delay"
            f.at = _frame + math.floor(f.secs * 60)
            note("scene over; normal Overdrive in " .. tostring(f.secs) .. "s")
        end
        return
    end
    if f.phase == "delay" then
        if _frame < f.at then return end
        f.phase = "firing"
        f.deadline = _frame + FOLLOWUP_FIRE_FRAMES
        f.next_try = _frame
        return
    end
    local overdrive = package.loaded["pragmata.bindings.overdrive"]
    if overdrive == nil then _followup = nil return end
    local state = overdrive.request_state()
    if f.fired and state == "confirmed" then
        note("follow-up Overdrive started")
        emit.narrative("Diana used Overdrive to finish the boss.", { silent = true })
        _followup = nil
        return
    end
    if f.fired and state == "pending" then return end
    if _frame > f.deadline then
        note("follow-up Overdrive gave up: " .. tostring(f.last_msg))
        _followup = nil
        return
    end
    if _frame < f.next_try then return end
    f.next_try = _frame + FOLLOWUP_RETRY_FRAMES
    local ok, msg = overdrive.trigger()
    f.fired = ok or f.fired
    f.last_msg = msg
    if ok then note("follow-up Overdrive fired: " .. tostring(msg)) end
end

local function on_cleared(old)
    local secs = followup_seconds(old.sector, old.sector_hash)
    if secs ~= nil and old.action == "pragmata_overdrive" then
        _followup = { phase = "scene", since = _frame, secs = secs }
        note("prompt " .. tostring(old.id) .. " cleared; normal Overdrive owed after the scene")
    end
    local had_force = _inflight ~= nil and _inflight.id == old.id
    if had_force then _inflight = nil end
    if old.peer_pressed then return end
    -- Went away without the peer: the player pressed it (or the scene was
    -- skipped). If a force was out, the peer's answer may still be coming.
    if had_force then
        _late_reply = { until_frame = _frame + LATE_REPLY_FRAMES, action = old.action }
    end
    if old.forced or not config.cutscene_prompt_auto_force then
        emit.narrative("The scene's button prompt was answered without Diana; "
            .. "the scene has moved on.", { silent = true })
    end
    note("prompt " .. tostring(old.id) .. " cleared without the peer")
end

re.on_frame(function()
    _frame = _frame + 1
    if prompt == nil or config.cutscene_prompt_enabled == false then return end

    local active = prompt.active()
    if active ~= nil and BUTTONS[active.button] == nil then active = nil end
    local cur_id = active and active.id or nil

    if _offered ~= nil and _offered.id ~= cur_id then
        on_cleared(_offered)
        _offered = nil
    end
    if active ~= nil and _offered == nil then
        _offered = { id = cur_id, since = _frame, action = BUTTONS[active.button].action,
                     sector = active.sector, sector_hash = active.sector_hash }
        note("prompt " .. tostring(cur_id) .. " up (" .. tostring(active.kind)
            .. ", " .. tostring(active.open_type) .. ")")
        if not config.cutscene_prompt_auto_force then
            emit.narrative(describe(active), { silent = false })
        end
    end

    if _offered ~= nil and not _offered.peer_pressed then
        -- Force once per prompt, as soon as the slot is free -- and only once
        -- the peer holds the action: pragmata_purify is announced only while
        -- its prompt is up, and a force naming an unknown action is rejected.
        if config.cutscene_prompt_auto_force and not _offered.forced
           and _inflight == nil and not hacking_busy() then
            if not dispatcher.is_announced(_offered.action) then
                dispatcher.sync()
            end
            if dispatcher.is_announced(_offered.action) then
                send_force(active)
            end
        end
        -- Optional fallback: press it ourselves if the peer is silent.
        local secs = config.cutscene_prompt_fallback_seconds
        if type(secs) == "number" and not _offered.fallback_done
           and _frame - _offered.since >= secs * 60 then
            _offered.fallback_done = true
            local ok, msg = prompt.press(cur_id)
            note("fallback press after " .. tostring(secs) .. "s: "
                .. tostring(ok) .. " (" .. tostring(msg) .. ")")
        end
    end

    if _inflight ~= nil and _frame - _inflight.since > INFLIGHT_WATCHDOG_FRAMES then
        log.warn("cutscene_prompt_observer: force watchdog fired (no reply in "
            .. INFLIGHT_WATCHDOG_FRAMES .. " frames); releasing slot")
        _inflight = nil
    end
    pcall(tick_followup)
    if _late_reply ~= nil and _frame > _late_reply.until_frame then
        _late_reply = nil
    end
end)

-- A failed press needs nothing here: the result is `success: false`, the
-- server retries the force on its own, and the slot stays held because
-- note_peer_press runs only on a press that went through. A new connection,
-- though, never saw the old force, so the prompt is offered again.
dispatcher.on_reregister(function()
    _inflight = nil
    if _offered ~= nil and not _offered.peer_pressed then _offered.forced = false end
end)

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- Non-nil while a scene-prompt force awaits its reply (hacking_observer
-- holds its own forces back while it is).
function M.inflight() return _inflight end

-- ability_actions: the peer's action is pressing prompt `id`. Releases the
-- force slot -- the reply has arrived.
function M.note_peer_press(id)
    if _offered ~= nil and _offered.id == id then _offered.peer_pressed = true end
    if _inflight ~= nil and _inflight.id == id then _inflight = nil end
    _late_reply = nil
    note("peer pressed prompt " .. tostring(id))
end

-- ability_actions: true (once) when `action` arriving now is most likely the
-- late answer to a prompt that has already gone.
function M.consume_late_reply(action)
    if _late_reply == nil or _late_reply.action ~= action then return false end
    _late_reply = nil
    return true
end

-- The action a mod_config.cutscene_prompt_buttons value is offered as, or nil.
function M.action_for(button)
    local b = BUTTONS[button]
    return b and b.action or nil
end

function M.debug_status()
    return {
        offered = _offered,
        inflight = _inflight,
        followup = _followup and _followup.phase or nil,
        late_reply_window = _late_reply and (_late_reply.until_frame - _frame) or nil,
        events = _events,
        frame = _frame,
    }
end

return M
