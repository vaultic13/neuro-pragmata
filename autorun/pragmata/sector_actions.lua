-- The tram terminal's sector selection, as pragmata_menu_list / _info
-- { menu = "sectors" } (menu_actions.lua):
--
--   list   every sector with its completion %, and each location (area) in
--          it with the stations that lead there and its collected count
--   info   up to 8 locations, stations or sectors: which sector, the
--          completion, and every kind of collectible present there with how
--          many are found
--
-- Readable only while the sector selection screen is open
-- (action_gates.menu_open("train_sector")): the counts are read from that
-- screen, which holds every sector at once. Stations not reached yet are only
-- counted. Formatting only: the reads go through bindings/sectors.lua.

local M = {}

local log = require("pragmata.util.log")
local name_match = require("pragmata.util.name_match")

local sectors = nil             -- bindings/sectors.lua, set by register()

local function join(list, sep) return table.concat(list, sep or ", ") end

local function read()
    if sectors == nil then return nil, "the sector reader failed to load" end
    local ok, v = pcall(sectors.sectors)
    if not ok then
        log.warn("sector_actions: sectors raised: " .. tostring(v))
        return nil, "The sector screen could not be read just now."
    end
    if v == nil then return nil, "The sector selection screen is not open." end
    return v
end

local function sector_name(s) return s.name or "an unnamed sector" end
local function station_name(st) return st.name or "an unnamed station" end

local function totals(items)
    local found, max = 0, 0
    for _, it in ipairs(items) do found, max = found + it.found, max + it.max end
    return found, max
end

local function collected_text(found, max)
    if max == 0 then return "nothing to collect" end
    if found >= max then return string.format("all %d collected", max) end
    return string.format("%d of %d collected", found, max)
end

-- A sector counts as reached when it has a station reached. The screen's
-- IsNoData flag is not that: the Hidden Chamber carries it with its station
-- reached and 100% (F11, 2026-10-07).
local function reached(s) return #s.stations > 0 end

local function sector_head(s)
    if not reached(s) then return sector_name(s) .. " - not reached yet" end
    local h = sector_name(s)
    if s.progress ~= nil then h = h .. string.format(" - %d%% complete", s.progress) end
    return h
end

-- The screen's counts belong to the AREA: two stations in one area carry the
-- same numbers. So a sector is reported as its locations (areas), each with
-- the stations that lead there, and counted once.
--   -> { { name, sector, stations = {names}, items } } in screen order
local function locations(s)
    local out, by_name = {}, {}
    for _, st in ipairs(s.stations) do
        local key = st.area or station_name(st)
        local loc = by_name[key]
        if loc == nil then
            loc = { name = key, sector = s, stations = {}, items = st.items }
            by_name[key] = loc
            out[#out + 1] = loc
        end
        loc.stations[#loc.stations + 1] = station_name(st)
    end
    return out
end

local function stations_text(loc)
    if #loc.stations == 1 and loc.stations[1] == loc.name then return "" end
    return " (station" .. (#loc.stations > 1 and "s" or "") .. ": " .. join(loc.stations, "; ") .. ")"
end

-- ---------------------------------------------------------------------------
-- List
-- ---------------------------------------------------------------------------

local function list_action()
    local data, err = read()
    if data == nil then return false, err end
    local lines = { string.format("Tram sectors (%d):", #data.sectors) }
    for _, s in ipairs(data.sectors) do
        if not reached(s) then
            lines[#lines + 1] = sector_head(s) .. "."
        else
            lines[#lines + 1] = sector_head(s) .. ":"
            for _, loc in ipairs(locations(s)) do
                lines[#lines + 1] = "- " .. loc.name .. stations_text(loc) .. " - " .. collected_text(totals(loc.items))
            end
        end
        if s.locked > 0 then
            lines[#lines + 1] = string.format("  %d more station%s not reached yet.", s.locked, s.locked == 1 and "" or "s")
        end
    end
    return true, join(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- Info
-- ---------------------------------------------------------------------------

local function item_lines(items)
    local out = {}
    for _, it in ipairs(items) do
        out[#out + 1] = string.format("- %s: %d of %d", it.kind, it.found, it.max)
    end
    return out
end

local function location_detail(loc)
    local found, max = totals(loc.items)
    local head = string.format("%s (in %s)%s: %s", loc.name, sector_name(loc.sector),
        stations_text(loc), collected_text(found, max))
    if max > 0 then head = head .. string.format(" (%d%%)", math.floor(100 * found / max)) end
    local lines = { head .. "." }
    for _, l in ipairs(item_lines(loc.items)) do lines[#lines + 1] = l end
    return join(lines, "\n")
end

-- A sector: its own %, its locations, and the kinds summed over them.
local function sector_detail(s)
    if not reached(s) then return sector_name(s) .. " (sector): not reached yet." end
    local sum, order, names = {}, {}, {}
    for _, loc in ipairs(locations(s)) do
        names[#names + 1] = loc.name
        for _, it in ipairs(loc.items) do
            local t = sum[it.kind]
            if t == nil then
                t = { kind = it.kind, found = 0, max = 0 }
                sum[it.kind] = t
                order[#order + 1] = t
            end
            t.found, t.max = t.found + it.found, t.max + it.max
        end
    end
    local head = sector_name(s) .. " (sector)"
    if s.progress ~= nil then head = head .. string.format(" - %d%% complete", s.progress) end
    local lines = { head .. "." }
    lines[#lines + 1] = "Locations: " .. join(names, "; ") .. "."
    if s.locked > 0 then lines[#lines + 1] = string.format("%d more stations not reached yet.", s.locked) end
    for _, l in ipairs(item_lines(order)) do lines[#lines + 1] = l end
    return join(lines, "\n")
end

-- Names answer to a sector, a location, or a station (which gives its
-- location). Sectors first, so a location named like its sector (the Hidden
-- Chamber) gives the sector, which includes it.
local function info_action(args)
    local data, err = read()
    if data == nil then return false, err end
    local entries = {}
    for _, s in ipairs(data.sectors) do
        entries[#entries + 1] = { name = sector_name(s), sector = s }
    end
    for _, s in ipairs(data.sectors) do
        for _, loc in ipairs(locations(s)) do
            entries[#entries + 1] = { name = loc.name, loc = loc }
            for _, st in ipairs(loc.stations) do
                if st ~= loc.name then entries[#entries + 1] = { name = st, loc = loc } end
            end
        end
    end
    return name_match.info_reply(entries, args, function(e)
        if e.loc then return location_detail(e.loc) end
        return sector_detail(e.sector)
    end, "\n\n")
end

-- ---------------------------------------------------------------------------
-- Registration (called once from pragmata_main.lua at startup)
-- ---------------------------------------------------------------------------

-- pragmata_menu_list / pragmata_menu_info { menu = "sectors" } (menu_actions.lua).
function M.register(menu_actions, gates, binding)
    sectors = binding
    menu_actions.add({ key = "sectors", label = "the tram's sector selection",
                       about = "sectors with completion %, their locations and stations, "
                           .. "collectibles found; info takes locations, stations or sectors; "
                           .. "only while that screen is open",
                       list = function() return list_action() end,
                       info = function(args) return info_action(args) end,
                       gate = gates.menu_open("train_sector") })
end

-- For Pragmata State Debug: the exact peer text of the list action, and of
-- the info action for the first sector and its first location.
function M.debug_text()
    local ok, success, text = pcall(list_action)
    if not ok then return "RAISED: " .. tostring(success) end
    local out = string.format("[%s] %s", tostring(success), tostring(text))
    local data = read()
    local s = data and data.sectors[1]
    if s ~= nil then
        local names = { sector_name(s) }
        local loc = locations(s)[1]
        if loc ~= nil then names[2] = loc.name end
        local ok_i, success_i, text_i = pcall(info_action, { names = names })
        out = out .. "\n----- pragmata_menu_info sectors " .. join(names, " + ") .. "\n"
            .. (ok_i and string.format("[%s] %s", tostring(success_i), tostring(text_i))
                     or ("RAISED: " .. tostring(success_i)))
    end
    return out
end

return M
