-- Dispatch table for AI-callable actions. Each entry is registered here with a
-- description, JSON schema, and handler. Handlers are called as
-- handler(args, ctx) and normally return (success, message), sent back as a
-- Neuro-SDK action/result.
--
-- DEFERRED results: a handler whose real outcome isn't known synchronously (e.g.
-- a hacking plan that executes move-by-move over the next second) can return
-- `ctx.defer()` instead. The dispatcher then sends NO result immediately; the
-- handler is responsible for calling `ctx.resolve(success, message)` later, when
-- the outcome IS known. The Neuro-SDK action protocol lets a result arrive
-- asynchronously, so the tool result the AI sees reflects what actually happened
-- rather than a blind acknowledgement. ctx.resolve is idempotent and ignored
-- once a result has been sent.

local M = {}

local log = require("pragmata.util.log")

local _actions = {}
local GAME_NAME = "Pragmata"

-- Unique sentinel a handler returns (via ctx.defer()) to suppress the immediate
-- action/result. Compared by identity, so it can never collide with a real
-- success value.
M.DEFER = {}

function M.register(name, def)
    assert(type(name) == "string" and name ~= "", "action name required")
    assert(type(def.handler) == "function", "handler required for " .. name)
    _actions[name] = {
        description = def.description or "",
        schema = def.schema or { type = "object" },
        handler = def.handler,
    }
    log.info("registered action " .. name)
end

function M.action_list()
    local list = {}
    for name, def in pairs(_actions) do
        table.insert(list, {
            name = name,
            description = def.description,
            schema = def.schema,
        })
    end
    return list
end

function M.handle_incoming(msg, send_fn)
    local cmd = msg.command
    if cmd ~= "action" then
        log.warn("ignoring incoming command " .. tostring(cmd))
        return
    end
    local d = msg.data or {}
    local id = d.id
    local name = d.name
    local raw_args = d.data or "{}"

    local action = _actions[name]
    if not action then
        log.warn("unknown action " .. tostring(name))
        send_fn({
            command = "action/result",
            game = GAME_NAME,
            data = { id = id, success = false, message = "unknown action: " .. tostring(name) },
        })
        return
    end

    local ok, args = pcall(json.load_string, raw_args)
    if not ok or type(args) ~= "table" then args = {} end

    -- Send the action/result at most once, whether synchronously or later via
    -- ctx.resolve (deferred handlers).
    local sent = false
    local function send_result(success, message)
        if sent then return end
        sent = true
        send_fn({
            command = "action/result",
            game = GAME_NAME,
            data = {
                id = id,
                success = success and true or false,
                message = message or "",
            },
        })
    end

    local ctx = {
        id = id,
        defer = function() return M.DEFER end,
        resolve = function(success, message) send_result(success, message) end,
    }

    local h_ok, success, message = pcall(action.handler, args, ctx)
    if not h_ok then
        log.error("handler crashed for " .. name .. ": " .. tostring(success))
        send_result(false, "handler error")
        return
    end

    -- A deferred handler will call ctx.resolve later; send nothing now.
    if success == M.DEFER then return end

    send_result(success, message)
end

return M
