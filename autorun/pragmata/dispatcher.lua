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
--
-- THE 20-SECOND RULE: the Neuro server counts an action with no result after
-- ~20 s as failed and throws away anything later. A deferred result that has
-- not resolved within mod_config.deferred_result_max_seconds is therefore
-- answered "accepted, still running" by tick(), and the handler's eventual
-- ctx.resolve goes out as a context line instead. ctx.resolve returns which
-- of the two happened ("result" / "context", nil if already answered), so a
-- caller that wants the server to retry a failure can tell whether there is
-- still a result for the server to retry.
--
-- RECONNECTS: `actions/reregister_all` (sent by the server, and by the sidecar
-- every time its WebSocket connects) re-sends startup and the full action list,
-- then runs the on_reregister hooks so observers can release force slots that
-- belonged to the old connection.

local M = {}

local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local config = require("pragmata.mod_config")
local emit = require("pragmata.util.emit")

local _actions = {}
local GAME_NAME = "Pragmata"

-- Unique sentinel a handler returns (via ctx.defer()) to suppress the immediate
-- action/result. Compared by identity, so it can never collide with a real
-- success value.
M.DEFER = {}

-- description, rules for a definition. A def may carry `short`, a one- or
-- two-sentence description: with mod_config.action_descriptions = "short"
-- that is what the peer sees, and the full `description` becomes the rules
-- delivered another way (below). Otherwise the full text is the description.
local function pick_description(def)
    if config.action_descriptions == "short" and type(def.short) == "string" then
        return def.short, def.description
    end
    return def.description or "", nil
end

function M.register(name, def)
    assert(type(name) == "string" and name ~= "", "action name required")
    assert(type(def.handler) == "function", "handler required for " .. name)
    local description, rules = pick_description(def)
    _actions[name] = {
        description = description,
        schema = def.schema or { type = "object" },
        handler = def.handler,
        available = def.available,
        rules = rules,
        rules_in_force = def.rules_in_force,
    }
    log.info("registered action " .. name)
end

-- ---------------------------------------------------------------------------
-- Rules kept out of descriptions (mod_config.action_descriptions = "short")
-- ---------------------------------------------------------------------------
-- An action registered with `rules` has a short description, and the long
-- text goes to the peer another way: `rules_in_force` actions get it at the
-- top of every force's state (hacking_observer), the rest once as context at
-- startup and after a reconnect. BEST_PRACTICES.md: one or two sentences per
-- description, longer rules in context.

function M.rules(name)
    local a = _actions[name]
    return a and a.rules or nil
end

-- The startup rules text, or nil when no action carries any.
function M.startup_rules()
    local names = {}
    for name, a in pairs(_actions) do
        if a.rules ~= nil and not a.rules_in_force then names[#names + 1] = name end
    end
    if #names == 0 then return nil end
    table.sort(names)
    local parts = { "## How the Pragmata actions work" }
    for _, name in ipairs(names) do
        parts[#parts + 1] = "- " .. name .. ": " .. _actions[name].rules
    end
    return table.concat(parts, "\n")
end

local function send_startup_rules()
    local text = M.startup_rules()
    if text ~= nil then emit.narrative(text) end
end

-- Replaces an action's description and schema, keeping its handler. For an
-- action whose wording can change while the game runs (the sequence hack's
-- group); re-announcing it to the peer is the caller's job.
function M.update(name, fields)
    local action = _actions[name]
    if action == nil then return false end
    if fields.description ~= nil then
        action.description, action.rules = pick_description(fields)
    end
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
    local list = send_register()
    send_startup_rules()
    return list
end

-- Unregister `names` (those whose definition changed, or that are now hidden),
-- then register the WHOLE available list. Neuro-SDK ignores a register for a
-- name it already holds, so the others are no-ops there -- but a peer that reads
-- each actions/register as the complete catalogue (apitest does) otherwise
-- forgets every other action. The 2026-09-16 session lost pragmata_enviro_hack_rotate's
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

-- ---------------------------------------------------------------------------
-- Reconnects
-- ---------------------------------------------------------------------------

local _reregister_hooks = {}

-- fn() runs after a re-registration, e.g. to drop an in-flight force that the
-- old connection will never answer.
function M.on_reregister(fn) _reregister_hooks[#_reregister_hooks + 1] = fn end

local function reregister_all()
    log.info("dispatcher: re-sending startup + actions/register")
    mailbox.send({ command = "startup", game = GAME_NAME })
    send_register()
    send_startup_rules()
    for _, fn in ipairs(_reregister_hooks) do
        local ok, err = pcall(fn)
        if not ok then log.warn("dispatcher: reregister hook failed: " .. tostring(err)) end
    end
end

-- ---------------------------------------------------------------------------
-- Deferred-result deadlines
-- ---------------------------------------------------------------------------

-- id -> { name, deadline (os.time), answer = function(success, message) }
local _deferred = {}

local function max_defer_seconds()
    local v = tonumber(config.deferred_result_max_seconds)
    if v == nil or v <= 0 then return 12 end
    return v
end

-- Called every frame from pragmata_main.lua. os.time() is whole seconds, which
-- is plenty against a 20 s server window and, unlike a frame count, does not
-- depend on the frame rate.
function M.tick()
    if next(_deferred) == nil then return end
    local now = os.time()
    for id, d in pairs(_deferred) do
        if now >= d.deadline then
            _deferred[id] = nil
            log.info("dispatcher: " .. d.name .. " still running at the deadline; answering now")
            d.answer(true, d.name .. " was accepted and is still running; its outcome "
                .. "will follow as a context message.")
        end
    end
end

local function registered_names()
    local list = {}
    for _, a in ipairs(M.action_list()) do list[#list + 1] = a.name end
    return table.concat(list, ", ")
end

function M.handle_incoming(msg, send_fn)
    local cmd = msg.command
    if cmd == "actions/reregister_all" then
        reregister_all()
        return
    end
    if cmd ~= "action" then
        log.warn("ignoring incoming command " .. tostring(cmd))
        return
    end
    local d = msg.data or {}
    local id = d.id
    local name = d.name
    local raw_args = d.data

    local function refuse(message)
        send_fn({
            command = "action/result",
            game = GAME_NAME,
            data = { id = id, success = false, message = message },
        })
    end

    local action = _actions[name]
    if not action then
        log.warn("unknown action " .. tostring(name))
        refuse("Unknown action '" .. tostring(name) .. "'. The actions available now are: "
            .. registered_names() .. ".")
        return
    end

    local avail, why = is_available(action)
    if not avail then
        refuse(name .. " is not available right now" .. (why and (": " .. why) or "") .. ".")
        return
    end

    -- No arguments at all is a no-argument call. Arguments that are there but
    -- do not parse are the peer's mistake and are refused as such, instead of
    -- being run as if nothing had been sent.
    local args = {}
    if raw_args ~= nil and raw_args ~= "" then
        local ok, parsed = pcall(json.load_string, raw_args)
        if not ok or type(parsed) ~= "table" then
            refuse("The arguments for " .. name .. " were not a valid JSON object; "
                .. "send them again matching the action's schema.")
            return
        end
        args = parsed
    end

    -- Send the action/result at most once, whether synchronously or later via
    -- ctx.resolve (deferred handlers). Past the deadline the result has
    -- already gone out, and a late outcome becomes a context line instead.
    local sent = false
    local late = false
    local function send_result(success, message)
        if sent then return end
        sent = true
        _deferred[id] = nil
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

    -- An interim answer: the result goes out now, and the deferred outcome,
    -- whenever ctx.resolve brings it, follows as context.
    local function answer_now(success, message)
        send_result(success, message)
        late = true
    end

    local resolved = false
    local ctx = {
        id = id,
        defer = function() return M.DEFER end,
        -- Whether the server is still waiting for this action's result.
        pending = function() return not sent end,
        -- For a handler that defers but already knows the outcome will take
        -- long (a plan parked on a target the player looked away from).
        answer_now = answer_now,
        resolve = function(success, message)
            if resolved then return nil end
            resolved = true
            if not sent then
                send_result(success, message)
                return "result"
            end
            if late and message ~= nil and message ~= "" then
                emit.narrative(name .. " finished: " .. message, { silent = false })
                return "context"
            end
            return nil
        end,
    }

    local h_ok, success, message = pcall(action.handler, args, ctx)
    if not h_ok then
        log.error("handler crashed for " .. name .. ": " .. tostring(success))
        send_result(false, name .. " failed inside the mod and did nothing; "
            .. "try again, or use another action.")
        return
    end

    -- A deferred handler will call ctx.resolve later. Send nothing now, but
    -- answer by the deadline if it has not resolved.
    if success == M.DEFER then
        if not sent and id ~= nil then
            _deferred[id] = {
                name = name,
                deadline = os.time() + max_defer_seconds(),
                answer = answer_now,
            }
        end
        return
    end

    send_result(success, message)
end

return M
