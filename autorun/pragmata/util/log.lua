-- Logging. Every line goes to REFramework's log (re2_framework_log.txt) AND to
-- a file of the mod's own, one per game session:
--   reframework/data/pragmata_logs/pragmata_<date>_<time>.log
--
-- REFramework rewrites its log each time it starts, so a test that spans a
-- restart (loading a save, returning to the title screen) used to lose
-- everything before it. The session files are never overwritten or cleaned up
-- by the mod; delete old ones by hand. If pragmata_logs/ is missing (io is
-- sandboxed to reframework/data/ and cannot create directories) the files go
-- to pragmata_mailbox/ instead, and if that fails too only REFramework's log
-- is written.

local M = {}

local PREFIX = "[pragmata] "

local function stamp(fmt)
    local ok, v = pcall(os.date, fmt)
    if ok and type(v) == "string" then return v end
    return nil
end

local SESSION = stamp("%Y-%m-%d_%H-%M-%S") or tostring(os.time and os.time() or "session")
local CANDIDATES = {
    "pragmata_logs/pragmata_" .. SESSION .. ".log",
    "pragmata_mailbox/pragmata_" .. SESSION .. ".log",
}
local _path = nil          -- the file that worked; false once all failed

local function write_file(level, msg)
    if _path == false then return end
    local line = (stamp("%H:%M:%S") or "") .. " [" .. level .. "] " .. msg .. "\n"
    if _path ~= nil then
        local f = io.open(_path, "a")
        if f then f:write(line); f:close() end
        return
    end
    for _, p in ipairs(CANDIDATES) do
        local f = io.open(p, "a")
        if f then
            f:write(line)
            f:close()
            _path = p
            return
        end
    end
    _path = false
end

-- The session file in use (nil before the first line, false if none worked).
function M.session_file() return _path end

function M.info(msg)
    log.info(PREFIX .. tostring(msg))
    pcall(write_file, "info", tostring(msg))
end

function M.warn(msg)
    log.warn(PREFIX .. tostring(msg))
    pcall(write_file, "warn", tostring(msg))
end

function M.error(msg)
    log.error(PREFIX .. tostring(msg))
    pcall(write_file, "error", tostring(msg))
end

return M
