-- When the last scan happened, and whether pragmata_scan should scan again or
-- answer from the results already held.
--
-- One action covers both, so the peer never has to know that a scan costs
-- something and a re-read does not; the rule is the mod's:
--
--   scan again   when the last scan is at least mod_config.scan_cache_seconds
--                old
--   cached       otherwise -- the reply says it is cached and how old it is,
--                because its distances are from where the scan was made
--
-- Any scan counts, not only the peer's: the player pressing Scan themselves
-- is noted by ability_state when the engine starts one. Time alone decides:
-- the player's position cannot be read through the handle -> core -> updater
-- -> GameObject chain, so "has Hugh moved" is not an option.

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

return M
