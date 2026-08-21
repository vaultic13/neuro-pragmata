-- Native command-level input synthesis for PRAGMATA abilities.
--
-- This operates above HID/XInput: the game asks PlayerInputDriver whether a
-- command is triggered/down/released and the post-hook supplies a queued
-- press/release state. No controller state is written and no device
-- is created or exposed to Windows.

local log = require("pragmata.util.log")

local M = {}

local TD_INPUT = "app.PlayerInputDriver"
local TD_COMMANDS = "app.hid.PlayerInputCommand"
local PHASES = { "trigger", "down", "release" }

local _state = {
    initialized = false,
    error = nil,
    input_td = nil,
    command_td = nil,
    methods = {},
    hashes = {},
    hash_fields_scanned = 0,
    installed = false,
    hook_error = nil,
}

local _frame = 0
local _queue = {}
local _active = nil
local _inject = { trigger = {}, down = {}, release = {} }
-- Hook callbacks can nest (and are not guaranteed to share one call stack),
-- so retain a small stack for each queried phase rather than one global last
-- value.  The old shared value could pair a post-hook with the wrong command.
local _query_stack = { trigger = {}, down = {}, release = {} }
local _last_consumed = nil
local _last_injected = nil

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function value_to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    return safe(function() return value:get_field("value__") end)
end

local function resolve_field(td, name)
    if td == nil then return nil end
    local field = safe(function() return td:get_field(name) end)
    if field == nil then return nil end
    local value = safe(function() return field:get_data(nil) end)
    return value_to_int(value)
end

-- TypeDefinition:get_fields() normally includes inherited fields, but that is
-- not guaranteed across REFramework builds.  PlayerInputCommand derives from
-- EnumLikeArrayBase, so walk its parents explicitly and de-duplicate by name.
-- This is reflection over the game's declared command table, not a probe of
-- possible hashes or button names.
local function all_fields(td)
    local result, seen = {}, {}
    local current = td
    while current ~= nil do
        for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            if type(name) ~= "string" or not seen[name] then
                result[#result + 1] = field
                if type(name) == "string" then seen[name] = true end
            end
        end
        current = safe(function() return current:get_parent_type() end)
    end
    return result
end

local function resolve()
    if _state.initialized then return _state.error == nil end
    _state.initialized = true

    _state.input_td = safe(function() return sdk.find_type_definition(TD_INPUT) end)
    _state.command_td = safe(function() return sdk.find_type_definition(TD_COMMANDS) end)
    if _state.input_td == nil then
        _state.error = TD_INPUT .. " type definition unavailable"
        return false
    end
    if _state.command_td == nil then
        _state.error = TD_COMMANDS .. " type definition unavailable"
        return false
    end

    for _, phase in ipairs(PHASES) do
        local signature = phase == "trigger" and "isTrigger(System.UInt32)"
            or phase == "down" and "isDown(System.UInt32)"
            or "isRelease(System.UInt32)"
        _state.methods[phase] = safe(function() return _state.input_td:get_method(signature) end)
        if _state.methods[phase] == nil then
            _state.error = "missing PlayerInputDriver." .. signature
            return false
        end
    end

    -- Enumerate the command constants from the running game instead of
    -- maintaining a short, guessed list. This is important for Overdrive:
    -- a real X press can now identify its exact PlayerInputCommand before we
    -- inject it. Only static *Hash fields are commands; other static fields
    -- on this type are ignored.
    local fields = all_fields(_state.command_td)
    _state.hash_fields_scanned = #fields
    for _, field in ipairs(fields) do
        local name = safe(function() return field:get_name() end)
        local is_static = safe(function() return field:is_static() end)
        if is_static == true and type(name) == "string" and name:match("Hash$") then
            local value = value_to_int(safe(function() return field:get_data(nil) end))
            if type(value) == "number" then
                _state.hashes[name:gsub("Hash$", "")] = value
            end
        end
    end
    _state.error = nil
    return true
end

local function command_name_for_hash(hash)
    for name, value in pairs(_state.hashes) do
        if value == hash then return name end
    end
    return "0x" .. string.format("%08X", hash or 0)
end

local function command_from_arg(args)
    -- REFramework Lua hook arguments are [function, this, command].
    return value_to_int(type(args) == "table" and args[3] or nil)
end

local function bool_return(value)
    -- sdk.hook post callbacks must return the ABI value of the method, not a
    -- Lua Boolean. Returning `true` only changed our diagnostic bookkeeping;
    -- the native caller could still receive the original false result.
    local pointer = safe(function() return sdk.to_ptr(value and 1 or 0) end)
    return pointer ~= nil and pointer or (value and 1 or 0)
end

local function contains(list, hash)
    if list == nil or hash == nil then return false end
    for _, value in ipairs(list) do
        if value == hash then return true end
    end
    return false
end

local function install_hooks()
    if _state.installed then return true end
    if not resolve() then return false end

    for _, phase in ipairs(PHASES) do
        local method = _state.methods[phase]
        local ok, err = pcall(function()
            sdk.hook(method,
                function(args)
                    local stack = _query_stack[phase]
                    stack[#stack + 1] = command_from_arg(args)
                end,
                function(retval)
                    local stack = _query_stack[phase]
                    local hash = table.remove(stack)
                    local injected = hash ~= nil and contains(_inject[phase], hash)
                    if injected then
                        _last_consumed = {
                            frame = _frame,
                            phase = phase,
                            hash = hash,
                            command = command_name_for_hash(hash),
                        }
                        return bool_return(true)
                    end
                    return retval
                end)
        end)
        if not ok then
            _state.hook_error = phase .. ": " .. tostring(err)
            return false
        end
    end
    _state.installed = true
    log.info("command_input: PlayerInputDriver command hooks installed")
    return true
end

local function normalize_phase_list(value)
    if value == nil then return {} end
    if type(value) ~= "table" then value = { value } end
    local result = {}
    for _, item in ipairs(value) do
        local hash = item
        if type(item) == "string" then
            hash = _state.hashes[item] or resolve_field(_state.command_td, item .. "Hash")
        end
        if type(hash) == "number" then result[#result + 1] = hash end
    end
    return result
end

function M.queue(name, recipe)
    if not install_hooks() then return false, _state.error or _state.hook_error end
    if type(recipe) ~= "table" or #recipe == 0 then return false, "empty command recipe" end
    if _active ~= nil or #_queue > 0 then return false, "command input is busy" end
    local frames = {}
    local command_count = 0
    for _, item in ipairs(recipe) do
        local frame = {
            trigger = normalize_phase_list(item.trigger),
            down = normalize_phase_list(item.down),
            release = normalize_phase_list(item.release),
        }
        command_count = command_count + #frame.trigger + #frame.down + #frame.release
        frames[#frames + 1] = frame
    end
    if command_count == 0 then return false, "command recipe resolved no known input hashes" end
    _last_consumed = nil
    _last_injected = nil
    _queue[#_queue + 1] = { name = name or "command", frames = frames }
    return true, "queued " .. tostring(name or "command")
end

-- Inject one complete native button press.  A real press is visible to the
-- game's command layer as trigger + down, followed on the next game frame by
-- release.  The original one-frame trigger-only probe was not a complete
-- button state and can be ignored by action code which reads isDown() first.
-- `command` may be a PlayerInputCommand name (for example "Scan") or its
-- numeric hash.  This never calls SendInput and never modifies Windows,
-- keyboard HID state, a controller, or an OS-visible device.
function M.press(command, label)
    local name = label or (type(command) == "string" and command) or "command"
    return M.queue(name, {
        { trigger = { command }, down = { command } },
        { release = { command } },
    })
end

function M.queue_scan()
    return M.press("Scan", "scan")
end

function M.tick()
    _frame = _frame + 1
    _inject = { trigger = {}, down = {}, release = {} }
    if _active == nil and #_queue > 0 then
        _active = table.remove(_queue, 1)
        _active.index = 1
    end
    if _active == nil then return end
    local frame = _active.frames[_active.index]
    if frame == nil then
        _active = nil
        return
    end
    _inject = frame
    _last_injected = {
        frame = _frame,
        name = _active.name,
        step = _active.index,
        trigger = #frame.trigger,
        down = #frame.down,
        release = #frame.release,
    }
    _active.index = _active.index + 1
    if _active.index > #_active.frames then _active = nil end
end

function M.clear()
    _queue, _active = {}, nil
    _inject = { trigger = {}, down = {}, release = {} }
    _query_stack = { trigger = {}, down = {}, release = {} }
end

function M.status()
    resolve()
    return {
        initialized = _state.error == nil,
        resolve_error = _state.error,
        hooks_installed = _state.installed,
        hook_error = _state.hook_error,
        hashes = _state.hashes,
        queue_size = #_queue,
        busy = _active ~= nil or #_queue > 0,
        last_injected = _last_injected,
        last_consumed = _last_consumed,
    }
end

return M
