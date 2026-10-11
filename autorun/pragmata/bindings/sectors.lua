--
-- The tram terminal's sector selection (screen ui5141): the sectors, the
-- stations in each, and what is collected at each.
--
-- Everything comes from the open screen. Screen code ui5141's control is an
-- app.gui.ui5110 (the type dump has no ui5141 class), and it holds every
-- sector at once, not only the one under the cursor:
--
--   ui5110.StageInfos : List<ui5110.ListInfo>, one per sector
--     Name (TextMessageData), ProgressRate (the screen's %)
--     StageData : ui5110.StageInfo { StageIdHash, AllCheckPoints : CheckPointInfo[] }
--     StageItemNum / StageItemMax : Int32[station][kind]   found / present
--   ui5110.UserData5110._ProgressItems[kind] { _Name }   "Safe Boxes", ...
--   app.CheckPointInfo  get_CheckPointName / get_CheckAreaName
--   app.CheckPointManager.isContaineReleasedList(UInt32)  station reached
--
-- Not used, and why:
--   - ListInfo.IsNoData is not "not reached": the Hidden Chamber carries it
--     with its station reached and 100%.
--   - The map data (MapDataManager.calcAreaItemGatherRate, isGotStageItem)
--     reads nil for every area the player is not in.
-- The per-station counts are the AREA's: two stations in one area carry the
-- same numbers (sector_actions.lua groups them).

local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")
local gui = require("pragmata.bindings.gui_state")

local M = {}

M.CODE = "ui5141"

local _s = { inited = false }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local cpi = r.td("app.CheckPointInfo")
    _s.m_is_released  = r.method(r.td("app.CheckPointManager"), "isContaineReleasedList(System.UInt32)")
    _s.m_cp_name      = r.method(cpi, "get_CheckPointName()")
    _s.m_cp_area_name = r.method(cpi, "get_CheckAreaName()")
end

-- Names of the collectible kinds, in the order of the per-station arrays.
local function kind_names(c)
    local out = {}
    local data = r.field(c, "UserData5110")
    for i, p in ipairs(r.elements(r.field(data, "_ProgressItems"))) do
        out[i] = object_names.text(r.field(p, "_Name")) or ("collectible kind " .. i)
    end
    return out
end

-- { {kind, found, max} } for the kinds present at one station (max > 0).
-- The two arrays must line up; when they do not, nothing is claimed.
local function station_items(kinds, nums, maxs)
    local out = {}
    local n, m = r.numbers(nums), r.numbers(maxs)
    if #n ~= #m then return out end
    for i = 1, #m do
        if m[i] > 0 then
            out[#out + 1] = { kind = kinds[i] or ("collectible kind " .. i), found = n[i], max = m[i] }
        end
    end
    return out
end

-- Nil unless the sector screen is open, else
--   { sectors = { { id, name, progress, locked,
--                   stations = { { id, name, area, items = {{kind, found, max}} } } } } }
-- Stations not reached yet are only counted (`locked`).
function M.sectors()
    ensure_init()
    local c = gui.control(M.CODE)
    if c == nil then return nil end
    local kinds = kind_names(c)
    local cpm = r.singleton("app.CheckPointManager")
    local out = { sectors = {} }
    for _, info in ipairs(r.elements(r.field(c, "StageInfos"))) do
        local sd = r.field(info, "StageData")
        local s = {
            id       = r.to_int(r.field(sd, "StageIdHash")),
            name     = object_names.text(r.field(info, "Name")),
            progress = r.to_int(r.field(info, "ProgressRate")),
            locked   = 0,
            stations = {},
        }
        local nums = r.elements(r.field(info, "StageItemNum"))
        local maxs = r.elements(r.field(info, "StageItemMax"))
        for i, cp in ipairs(r.elements(r.field(sd, "AllCheckPoints"))) do
            local hash = r.to_int(r.field(cp, "_CheckPointHash"))
            local released = nil
            if cpm ~= nil and hash ~= nil then released = r.call(_s.m_is_released, cpm, hash) end
            if released == false then
                s.locked = s.locked + 1
            else
                s.stations[#s.stations + 1] = {
                    id    = hash,
                    name  = object_names.text(r.call(_s.m_cp_name, cp)),
                    area  = object_names.text(r.call(_s.m_cp_area_name, cp)),
                    items = station_items(kinds, nums[i], maxs[i]),
                }
            end
        end
        out.sectors[#out.sectors + 1] = s
    end
    return out
end

return M
