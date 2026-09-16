-- Deferred, evidence-based action results for Scan, Auto-Hack and Overdrive.
-- A binding may only acknowledge a request synchronously; this module owns the
-- short confirmation windows so an AI receives success only after the game
-- reports the relevant state transition.

local M = {}

local scan = require("pragmata.bindings.scan")
local hacking = require("pragmata.bindings.hacking")
local overdrive = require("pragmata.bindings.overdrive")

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

-- Overdrive confirmation is event-driven inside the binding now (a start
-- status flag on the live player mask, or a real gauge spend), so this no
-- longer needs its own copy of defer(): request_progressed() is a normal
-- poll like the others.
function M.overdrive(ctx)
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
