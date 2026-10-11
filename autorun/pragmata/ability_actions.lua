-- Deferred, evidence-based action results for Scan, Auto-Hack and Overdrive.
-- A binding may only acknowledge a request synchronously; this module owns the
-- short confirmation windows so an AI receives success only after the game
-- reports the relevant state transition.

local M = {}

local scan = require("pragmata.bindings.scan")
local hacking = require("pragmata.bindings.hacking")
local overdrive = require("pragmata.bindings.overdrive")
local config = require("pragmata.mod_config")

-- Scene prompts that wait for the Overdrive button. Optional: without it,
-- pragmata_overdrive is combat Overdrive only.
local cutscene_prompt = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.cutscene_prompt")
    if ok then cutscene_prompt = mod end
end

local _frame = 0
local _pending = {}

local function defer(name, ctx, begin, poll, timeout_frames)
    if _pending[name] ~= nil then return false, name .. " request already awaiting confirmation" end
    local ok, message = begin()
    if not ok then return false, message end
    if ctx == nil or type(ctx.defer) ~= "function" then return true, message end

    _pending[name] = {
        deadline = _frame + timeout_frames,
        resolve = ctx.resolve,
        poll = poll,
    }
    return ctx.defer()
end

function M.scan(ctx)
    local serial = nil
    return defer("scan", ctx, function()
        local ok, message = scan.scan_input()
        serial = scan.last_request_serial()
        return ok, message
    end, function()
        if serial ~= nil and scan.request_progressed(serial) then
            return true, "scan started (request-specific progression observed)"
        end
        return nil
    end, 120)
end

function M.auto_hack(ctx)
    if hacking.is_auto_hacking() then return false, "auto-hack already in progress" end
    return defer("auto_hack", ctx, function() return hacking.auto_hack() end, function()
        if hacking.is_auto_hacking() then return true, "auto-hack started" end
        return nil
    end, 120)
end

-- A scene stopped on a button prompt: press it the way the player would, and
-- report whether the scene went on. `name` is the defer slot ("overdrive" /
-- "purify"), `label` how the prompt is named to the peer.
local function press_scene_prompt(ctx, active, name, label)
    local observer = package.loaded["pragmata.cutscene_prompt_observer"]
    local request_id = nil
    return defer(name, ctx, function()
        local ok, message = cutscene_prompt.press(active.id)
        request_id = cutscene_prompt.request_id()
        if ok and observer ~= nil then observer.note_peer_press(active.id) end
        return ok, message
    end, function()
        if cutscene_prompt.request_id() ~= request_id then
            return false, "the scene prompt press was superseded"
        end
        local state, message = cutscene_prompt.request_state()
        if state == "pending" then return nil end
        if state == "confirmed" then
            return true, "pressed the scene's " .. label .. " prompt; " .. tostring(message)
        end
        return false, "pressing the scene's " .. label .. " prompt did not work: " .. tostring(message)
    end, (config.cutscene_prompt_confirm_frames or 150) + 60)
end

-- The prompt up now if it wants `button`, or nil.
local function prompt_for(button)
    if cutscene_prompt == nil or config.cutscene_prompt_enabled == false then return nil end
    local active = cutscene_prompt.active()
    if active ~= nil and active.button == button then return active end
    return nil
end

-- The answer to a prompt the player already pressed: true once, so the
-- caller can say so rather than act on it.
local function late_reply(action)
    local observer = package.loaded["pragmata.cutscene_prompt_observer"]
    return observer ~= nil and observer.consume_late_reply(action)
end

-- Overdrive confirmation is event-driven inside the binding now (a start
-- status flag on the live player mask, or a real gauge spend), so this no
-- longer needs its own copy of defer(): request_progressed() is a normal
-- poll like the others. While a scene waits on the Overdrive prompt, the
-- action presses that instead.
function M.overdrive(ctx)
    local active = prompt_for("overdrive")
    if active ~= nil then
        return press_scene_prompt(ctx, active, "overdrive", "Overdrive")
    end
    if late_reply("pragmata_overdrive") then
        return false, "the scene's Overdrive prompt was already answered; the scene has moved on"
    end
    return defer("overdrive", ctx, function()
        return overdrive.trigger()
    end, function()
        -- Pure read: the binding's own frame callback owns the state machine.
        local state, message = overdrive.request_state()
        if state == "pending" then return nil end
        if state == "confirmed" then return true, message or "the game started Overdrive" end
        return false, message or "Overdrive did not start"
    end, 180)
end

-- pragmata_purify: the filament-cleaning button, which only a scene prompt
-- asks for (the Filament Remover scene). There is no field use of it here.
function M.purify(ctx)
    local active = prompt_for("purify")
    if active ~= nil then
        return press_scene_prompt(ctx, active, "purify", "filament-cleaning")
    end
    if late_reply("pragmata_purify") then
        return false, "the scene's filament-cleaning prompt was already answered; the scene has moved on"
    end
    return false, "no scene is waiting for the filament-cleaning button"
end

function M.status()
    local out = {}
    for name, value in pairs(_pending) do out[name] = value.deadline - _frame end
    return out
end

re.on_frame(function()
    _frame = _frame + 1
    for name, pending in pairs(_pending) do
        local ok, success, message = pcall(pending.poll)
        if ok and success ~= nil then
            _pending[name] = nil
            pending.resolve(success, message)
        elseif _frame >= pending.deadline then
            _pending[name] = nil
            if name == "overdrive" then pcall(overdrive.cancel_pending) end
            pending.resolve(false, name .. " did not produce its expected game-state transition")
        end
    end
end)

return M
