-- Dispatch table for AI-callable actions. Each entry is registered here with a
-- description, JSON schema, and handler. Handlers return (success, message)
-- which is sent back as a Neuro-SDK action/result.

local M = {}

local log = require("pragmata.util.log")

local _actions = {}
local GAME_NAME = "Pragmata"

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

    local h_ok, success, message = pcall(action.handler, args)
    if not h_ok then
        log.error("handler crashed for " .. name .. ": " .. tostring(success))
        send_fn({
            command = "action/result",
            game = GAME_NAME,
            data = { id = id, success = false, message = "handler error" },
        })
        return
    end

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

return M
