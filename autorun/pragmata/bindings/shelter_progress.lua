--
-- How far the player has come into the Shelter: the game's own Shelter level.
--
-- Why: the game's opening tutorial runs in the Shelter's sector (the same
-- stage hash), but none of the Shelter's machines (Unit Printer, Firmware
-- Updater, the train) are there yet. action_gates combines this level with
-- the Archive's Help note about the Shelter (bindings/catalogs.lua,
-- found_tutorials) to tell the tutorial from the main Shelter chamber.
--
-- Engine facts:
--   app.GuiManager (managed singleton)
--     getSafeRoomLevel() -> Int32          instance method
--     checkChangeSafeRoomLevel(Boolean)    (not used)
--   app.structure.SafeRoomLevelData._CurrentLevel (Int32) is the stored
--   value on the Shelter's props (sm90_127_00 / sm95_001_00 PropDrivers);
--   app.ConciergeHandle / Ch06000Updater.onLevelUpSafeRoom fire on a raise.

local r = require("pragmata.bindings.reflect")

local M = {}

local _m = nil
local function method()
    if _m == nil then
        _m = { level = r.method(r.td("app.GuiManager"), "getSafeRoomLevel()") or false }
    end
    return _m.level or nil
end

-- The Shelter level, or nil when it cannot be read (no GuiManager yet).
function M.level()
    local m = method()
    if m == nil then return nil end
    local gm = r.singleton("app.GuiManager")
    if gm == nil then return nil end
    return r.to_int(r.call(m, gm))
end

return M
