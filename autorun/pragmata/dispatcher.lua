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
--
-- AVAILABILITY: an action may carry `available = function() -> ok, reason`.
-- Only available actions are announced to the peer, and a call to a hidden one
-- (a race with a menu closing, say) is refused with its reason. The set the
-- peer holds is tracked here; sync() re-announces when it no longer matches.
-- action_gates.lua polls sync(). An action without `available` is always shown.

local M = {}

local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")

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
        available = def.available,
    }
    log.info("registered action " .. name)
end

-- Replaces an action's description and schema, keeping its handler. For an
-- action whose wording can change while the game runs (the sequence hack's
-- group); re-announcing it to the peer is the caller's job.
function M.update(name, fields)
    local action = _actions[name]
    if action == nil then return false end
    if fields.description ~= nil then action.description = fields.description end
    if fields.schema ~= nil then action.schema = fields.schema end
    return true
end

-- Set once the startup actions/register has gone out. Before that, a changed
-- action needs no re-announcing: the startup list carries it.
M.announced = false

-- Names the peer currently holds, as of the last actions/register we sent.
local _announced = {}

-- ok, reason. A predicate that raises counts as available: hiding an action
-- because of a reflection hiccup would be worse than showing it.
local function is_available(action)
    if action.available == nil then return true, nil end
    local ok, avail, reason = pcall(action.available)
    if not ok then return true, nil end
    if avail == false then return false, reason end
    return true, nil
end

function M.is_available(name)
    local action = _actions[name]
    if action == nil then return false, "unknown action" end
    return is_available(action)
end

-- Whether the peer holds `name`, as of the last actions/register. An
-- actions/force may only name actions the peer holds.
function M.is_announced(name)
    return _announced[name] == true
end

-- The actions to show the peer right now.
function M.action_list()
    local list = {}
    for name, def in pairs(_actions) do
        if is_available(def) then
            table.insert(list, {
                name = name,
                description = def.description,
                schema = def.schema,
            })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Send the full available list and remember it as what the peer holds.
local function send_register()
    local list = M.action_list()
    mailbox.send({ command = "actions/register", game = GAME_NAME, data = { actions = list } })
    _announced = {}
    for _, a in ipairs(list) do _announced[a.name] = true end
    M.announced = true
    return list
end

-- Startup announcement (pragmata_main.lua).
function M.announce_all()
    return send_register()
end

-- Unregister `names` (those whose definition changed, or that are now hidden),
-- then register the WHOLE available list. Neuro-SDK ignores a register for a
-- name it already holds, so the others are no-ops there -- but a peer that reads
-- each actions/register as the complete catalogue (apitest does) otherwise
-- forgets every other action. The 2026-09-16 session lost pragmata_hack_rotate's
-- schema that way after a sequence-group switch.
function M.reannounce(names)
    if not M.announced then return end
    if names ~= nil and #names > 0 then
        mailbox.send({ command = "actions/unregister", game = GAME_NAME,
                       data = { action_names = names } })
    end
    send_register()
end

-- Re-announce if the available set differs from what the peer holds. Cheap
-- when nothing changed. Returns true when it sent something.
function M.sync()
    if not M.announced then return false end
    local now = {}
    for name, def in pairs(_actions) do
        if is_available(def) then now[name] = true end
    end
    local removed, added = {}, 0
    for name in pairs(_announced) do
        if not now[name] then removed[#removed + 1] = name end
    end
    for name in pairs(now) do
        if not _announced[name] then added = added + 1 end
    end
    if #removed == 0 and added == 0 then return false end
    table.sort(removed)
    log.info(string.format("dispatcher: action set changed (+%d, -%d)%s", added, #removed,
        #removed > 0 and (": hid " .. table.concat(removed, ", ")) or ""))
    M.reannounce(removed)
    return true
end

-- For the debug panel: every registered name with its availability.
function M.availability()
    local out = {}
    for name, def in pairs(_actions) do
        local ok, reason = is_available(def)
        out[#out + 1] = { name = name, available = ok, reason = reason, held = _announced[name] == true }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
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

    local avail, why = is_available(action)
    if not avail then
        send_fn({
            command = "action/result",
            game = GAME_NAME,
            data = { id = id, success = false,
                     message = name .. " is not available right now" .. (why and (": " .. why) or "") },
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
