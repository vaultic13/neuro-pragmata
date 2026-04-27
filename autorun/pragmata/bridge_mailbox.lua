-- File-mailbox transport between this Lua mod and the Python sidecar.
--
-- Two newline-delimited JSON files in reframework/data/pragmata_mailbox/:
--   lua_to_bridge.jsonl  (Lua appends, sidecar tails)
--   bridge_to_lua.jsonl  (sidecar appends, Lua tails)
--
-- Append-only writes are atomic for line-sized payloads on Windows; readers
-- track their byte offset and only re-read newly-appended lines.

local M = {}

local log = require("pragmata.util.log")
local json_encode = require("pragmata.util.json_encode")

local OUTBOX_PATH = "pragmata_mailbox/lua_to_bridge.jsonl"
local INBOX_PATH  = "pragmata_mailbox/bridge_to_lua.jsonl"

local _inbox_offset = 0
local _ready = false

local function probe_outbox()
    -- io is sandboxed to reframework/data/. Append mode auto-creates the file
    -- if its parent directory exists; if the user hasn't created the mailbox
    -- dir yet this fails and we retry next frame.
    local f = io.open(OUTBOX_PATH, "a")
    if f then
        f:close()
        return true
    end
    return false
end

function M.ensure_ready()
    if _ready then return true end
    if not probe_outbox() then
        return false
    end
    -- Seek to end of inbox so we only consume NEW messages, not stale state
    -- left by a previous session.
    local inbox = io.open(INBOX_PATH, "r")
    if inbox then
        inbox:seek("end")
        _inbox_offset = inbox:seek()
        inbox:close()
    else
        _inbox_offset = 0
    end
    _ready = true
    log.info("mailbox ready outbox=" .. OUTBOX_PATH .. " inbox_offset=" .. tostring(_inbox_offset))
    return true
end

function M.send(obj)
    -- Use our UTF-8-safe encoder; REFramework's json.dump_string was stripping
    -- non-ASCII bytes (em dashes etc.) before they reached the sidecar.
    local ok, line = pcall(json_encode.encode, obj)
    if not ok then
        log.warn("mailbox.send: json encode failed")
        return false
    end
    local f = io.open(OUTBOX_PATH, "a")
    if not f then
        log.warn("mailbox.send: cannot open outbox")
        return false
    end
    f:write(line .. "\n")
    f:close()
    return true
end

function M.recv()
    local f = io.open(INBOX_PATH, "r")
    if not f then return nil end
    f:seek("set", _inbox_offset)
    local line = f:read("*l")
    if line == nil then
        f:close()
        return nil
    end
    _inbox_offset = f:seek()
    f:close()

    if line == "" then return nil end

    local ok, parsed = pcall(json.load_string, line)
    if not ok or type(parsed) ~= "table" then
        log.warn("mailbox.recv: bad JSON line: " .. tostring(line))
        return nil
    end
    return parsed
end

return M
