-- When the last scan happened, and whether pragmata_scan should scan again or
-- answer from the results already held.
--
-- pragmata_scan and pragmata_scan_results used to be two actions, and the peer
-- had to know that one costs a scan and the other does not. Now there is one
-- action, and the rule is the mod's:
--
--   scan again   when the last scan is at least mod_config.scan_cache_seconds
--                old
--   cached       otherwise -- the reply says it is cached and how old it is,
--                because its distances are from where the scan was made
--
-- Any scan counts, not only the peer's: the player pressing Scan themselves
-- is noted by ability_state when the engine starts one.
--
-- A "has Hugh moved 5 m" condition was tried on 2026-10-12 and removed: the
-- player's position could not be read through the handle -> core -> updater
-- -> GameObject chain, and time alone proved enough in testing.

local M = {}

local config = require("pragmata.mod_config")

local _last_at = nil   -- os.time() of the last scan

function M.min_seconds()
    return tonumber(config.scan_cache_seconds) or 7
end

-- A scan has just started (the engine confirmed it).
function M.note_scan()
    _last_at = os.time()
end

-- "scan" or "cached", and { age = seconds } about the last scan (nil before
-- the first one).
function M.decide()
    if _last_at == nil then return "scan", nil end
    local info = { age = os.time() - _last_at }
    if info.age < M.min_seconds() then return "cached", info end
    return "scan", info
end

-- For the debug panel.
function M.status()
    local choice, info = M.decide()
    return { choice = choice, age = info and info.age or nil }
end

return M
