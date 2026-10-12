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

-- ---------------------------------------------------------------------------
-- Scan (pragmata_scan)
-- ---------------------------------------------------------------------------
-- One action for scanning and for re-reading the last scan: scan_memory
-- decides which, by the time since the last scan. A new
-- scan resolves with what it found, not with "scan started", so the peer needs
-- no second call; ability_state then leaves that scan's results out of the
-- context stream (peer_scan_active) rather than reporting them twice.

local scan_memory = require("pragmata.scan_memory")

-- After the engine confirms the scan: results are read no earlier than
-- SETTLE frames later (the list fills as the scan expands), reported once they
-- have held still for STABLE frames or the scan has ended, and at the latest
-- after LIMIT frames with whatever is there.
local SCAN_CONFIRM_FRAMES = 120
local SCAN_RESULT_SETTLE = 45
local SCAN_RESULT_STABLE = 30
local SCAN_RESULT_LIMIT = 180

-- True while a peer scan waits for its results; ability_state stays quiet
-- about them meanwhile, since they go back as the tool result.
M.peer_scan_active = false

local function results_text(readable)
    return readable.text .. ((readable.stale and " (the game marks this list as possibly out of date)") or "")
end

local function cached_reply(readable, info)
    local age = info and info.age or 0
    return string.format("No new scan (a new scan runs once the last is %d s old). "
        .. "Cached scan from %d s ago; the distances are from where it was made: %s.",
        scan_memory.min_seconds(), age, results_text(readable))
end

function M.scan(ctx)
    local choice, info = scan_memory.decide()
    if choice == "cached" then
        local readable = scan.describe_results()
        if readable ~= nil and readable.total_count > 0 then
            return true, cached_reply(readable, info)
        end
        -- Nothing held to answer from: scan after all.
    end

    local serial, started_at = nil, nil
    local progressed_at, last_fp, stable_since = nil, nil, nil
    return defer("scan", ctx, function()
        local ok, message = scan.scan_input()
        serial = scan.last_request_serial()
        started_at = _frame
        -- Only with a deferred result to carry them; F6 (no ctx) narrates.
        if ok and ctx ~= nil then M.peer_scan_active = true end
        return ok, message
    end, function()
        if progressed_at == nil then
            if serial ~= nil and scan.request_progressed(serial) then
                progressed_at = _frame
                scan_memory.note_scan()
            elseif _frame - started_at >= SCAN_CONFIRM_FRAMES then
                -- The same window as before the merge: no scan within ~2 s.
                return false, "scan did not produce its expected game-state transition"
            end
            return nil
        end
        local waited = _frame - progressed_at
        if waited < SCAN_RESULT_SETTLE then return nil end
        local readable = scan.describe_results()
        local fp = readable and readable.fingerprint or nil
        if fp ~= last_fp then last_fp, stable_since = fp, _frame end
        local settled = fp ~= nil
            and (_frame - stable_since >= SCAN_RESULT_STABLE or not scan.is_scanning())
        if settled or waited >= SCAN_RESULT_LIMIT then
            if readable ~= nil and readable.total_count > 0 then
                return true, "Scan done. Diana found: " .. results_text(readable) .. "."
            end
            return true, "Scan done. Nothing the scan can place was found nearby."
        end
        return nil
    end, SCAN_CONFIRM_FRAMES + SCAN_RESULT_LIMIT)
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
            if name == "scan" then M.peer_scan_active = false end
            pending.resolve(success, message)
        elseif _frame >= pending.deadline then
            _pending[name] = nil
            if name == "overdrive" then pcall(overdrive.cancel_pending) end
            if name == "scan" then M.peer_scan_active = false end
            pending.resolve(false, name .. " did not produce its expected game-state transition")
        end
    end
end)

return M
