-- Peer actions for the Shelter upgrade menus: Firmware Updater, Unit Printer
-- and the train terminal's mod menu.
--
-- Each menu is one value of pragmata_menu_list / pragmata_menu_info
-- (menu_actions.lua), readable only while that menu is on screen
-- (action_gates.menu_open):
--   list   every entry, one line each
--   info   full detail for up to 8 named entries
--
-- Formatting only: every read goes through bindings/shelter_menus.lua, which
-- hands back plain tables. Names in an info call are matched
-- case-insensitively, exact first, then as a substring; a name that matches
-- nothing, or several things, is answered as such rather than dropped.
--
-- The Unit Printer shows one tab at a time. The other tabs are rebuilt from
-- game data by the binding; as a fallback, the entries of every tab the
-- player has looked at are kept while the menu is open (marked as last seen)
-- and dropped when it closes.

local M = {}

local log = require("pragmata.util.log")
local name_match = require("pragmata.util.name_match")

local menus = nil               -- bindings/shelter_menus.lua, set by register()

-- ---------------------------------------------------------------------------
-- Text helpers
-- ---------------------------------------------------------------------------

local function join(list, sep) return table.concat(list, sep or ", ") end

local function read(fn_name)
    if menus == nil or menus[fn_name] == nil then return nil end
    local ok, v = pcall(menus[fn_name])
    if not ok then
        log.warn("shelter_menu_actions: " .. fn_name .. " raised: " .. tostring(v))
        return nil
    end
    return v
end

local function level_text(level, level_max)
    if level == nil then return nil end
    if level_max ~= nil and level_max > 0 then return string.format("Lv %d/%d", level, level_max) end
    return "Lv " .. tostring(level)
end

-- "3x Upgrade Component (have 1)"
local function cost_text(costs)
    local parts = {}
    for _, k in ipairs(costs or {}) do
        local s = string.format("%dx %s", k.need, k.item)
        if k.have ~= nil then
            s = s .. string.format(" (have %d%s)", k.have, k.have < k.need and ", not enough" or "")
        end
        parts[#parts + 1] = s
    end
    if #parts == 0 then return nil end
    return join(parts, " + ")
end

-- Name matching for the info actions: util/name_match.lua.
local function info_reply(entries, args, detail_fn)
    return name_match.info_reply(entries, args, detail_fn)
end

local NOT_OPEN = "That menu is not open (or could not be read just now)."

-- ---------------------------------------------------------------------------
-- Firmware Updater
-- ---------------------------------------------------------------------------

local function firmware_line(e)
    local name = e.subtitle and (e.name .. " (" .. e.subtitle .. ")") or e.name
    local s = name .. " - " .. (level_text(e.level, e.level_max) or "level unknown")
    if e.maxed then return s .. ", fully upgraded" end
    if e.level_cap ~= nil and e.level ~= nil and e.level_cap <= e.level then
        return s .. ", cannot be upgraded further yet"
    end
    local cost = cost_text(e.next_cost)
    if cost then s = s .. ", next level costs " .. cost end
    return s
end

local function firmware_detail(e)
    local lines = { firmware_line(e) }
    if not e.maxed and cost_text(e.next_cost) == nil then
        lines[#lines + 1] = "  The next level's cost could not be read."
    end
    if e.level_cap ~= nil and e.level_max ~= nil and e.level_cap < e.level_max then
        lines[#lines + 1] = "  Upgradable up to Lv " .. e.level_cap .. " for now."
    end
    local stats = {}
    for _, st in ipairs(e.stats or {}) do
        if st.next ~= nil and st.next ~= st.now then
            stats[#stats + 1] = string.format("%s %s -> %s", st.name, tostring(st.now), tostring(st.next))
        elseif st.now ~= nil then
            stats[#stats + 1] = string.format("%s %s", st.name, tostring(st.now))
        end
    end
    if #stats > 0 then
        lines[#lines + 1] = "  Stats (now -> next level): " .. join(stats, "; ") .. "."
    else
        lines[#lines + 1] = "  Stat values could not be read from the menu."
    end
    return join(lines, "\n")
end

local function firmware_list()
    local f = read("firmware")
    if f == nil then return false, NOT_OPEN end
    if #f.entries == 0 then return true, "Firmware Updater: nothing listed." end
    local lines = { "Firmware Updater:" }
    for _, e in ipairs(f.entries) do lines[#lines + 1] = "- " .. firmware_line(e) end
    return true, join(lines, "\n")
end

local function firmware_info(args)
    local f = read("firmware")
    if f == nil then return false, NOT_OPEN end
    return info_reply(f.entries, args, firmware_detail)
end

-- ---------------------------------------------------------------------------
-- Unit Printer
-- ---------------------------------------------------------------------------

local _printer_tabs = {}        -- tab -> entries, while the menu stays open
local _printer_tab_order = {}

local function remember_tab(tab, entries)
    if tab == nil then return end
    if _printer_tabs[tab] == nil then _printer_tab_order[#_printer_tab_order + 1] = tab end
    _printer_tabs[tab] = entries
end

-- "Heat - printed, Lv 1/3, next level costs 900x Lunafilament (have 594,
-- not enough)" / "Homing Missiles - not printed yet, printing costs ..." /
-- "??? - not found yet". The binding decides printed (acquired) vs not.
local function printer_line(e)
    local s = e.name .. " - " .. tostring(e.state)
    local cost = cost_text(e.cost)
    if e.state == "printed" then
        local lv = level_text(e.level, e.level_max)
        if lv then s = s .. ", " .. lv end
        if e.maxed then
            s = s .. ", fully upgraded"
        elseif cost then
            s = s .. ", next level costs " .. cost
        end
    elseif e.state == "not printed yet" then
        if cost then s = s .. ", printing costs " .. cost end
    end
    if e.is_new then s = s .. " (new)" end
    return s
end

local function clean(text)
    return (tostring(text):gsub("<[^>]*>", ""):gsub("%s+", " "))
end

local function printer_detail(e)
    local lines = { printer_line(e) }
    if e.description then lines[#lines + 1] = "  " .. clean(e.description) end
    local per = e.level_texts or {}
    if #per > 1 or (#per == 1 and per[1] ~= "") then
        local cur = (e.state == "printed") and e.level or 0
        for i, t in ipairs(per) do
            if t ~= "" then
                local mark = (i == cur and " (current)") or (i == cur + 1 and " (next)") or ""
                lines[#lines + 1] = string.format("  Lv %d%s: %s", i, mark, clean(t))
            end
        end
    end
    return join(lines, "\n")
end

-- Every tab: the visible one from the grid, the others rebuilt from game
-- data (shelter_menus.printer_all). A tab the rebuild could not produce falls
-- back to what was seen on screen earlier this visit.
local function printer_tabs()
    local all = read("printer_all")
    if all == nil then
        local p = read("printer")
        if p == nil then return nil end
        all = { tab = p.tab, tabs = { { tab = p.tab, entries = p.entries } } }
    end
    remember_tab(all.tab, all.tabs[1].entries)
    local have = {}
    for _, t in ipairs(all.tabs) do have[t.tab or "?"] = true end
    for _, tab in ipairs(_printer_tab_order) do
        if not have[tab] then
            all.tabs[#all.tabs + 1] = { tab = tab, entries = _printer_tabs[tab], last_seen = true }
        end
    end
    return all
end

local function printer_list()
    local all = printer_tabs()
    if all == nil then return false, NOT_OPEN end
    local lines = {}
    for i, t in ipairs(all.tabs) do
        local label = (i == 1) and " (on screen)" or (t.last_seen and " (as last seen this visit)" or "")
        lines[#lines + 1] = (i == 1 and "Unit Printer, tab " or "Tab ") .. tostring(t.tab or "?") .. label .. ":"
        if #t.entries == 0 then lines[#lines + 1] = "- nothing listed" end
        for _, e in ipairs(t.entries) do lines[#lines + 1] = "- " .. printer_line(e) end
    end
    return true, join(lines, "\n")
end

local function printer_info(args)
    local all = printer_tabs()
    if all == nil then return false, NOT_OPEN end
    local entries = {}
    for _, t in ipairs(all.tabs) do
        for _, e in ipairs(t.entries) do entries[#entries + 1] = e end
    end
    return info_reply(entries, args, printer_detail)
end

-- ---------------------------------------------------------------------------
-- Mod terminal
-- ---------------------------------------------------------------------------

-- No slot numbers (the equipped list is in slot order) and no cost unless a
-- mod costs more than the usual 1 (every mod cost 1 in the 2026-10-05 test).
local function mod_line(e)
    local s = e.name
    local bits = {}
    if e.cost ~= nil and e.cost ~= 1 then bits[#bits + 1] = "cost " .. e.cost end
    if e.is_new then bits[#bits + 1] = "new" end
    if #bits > 0 then s = s .. " (" .. join(bits) .. ")" end
    return s
end

local function mod_detail(e)
    local s = mod_line(e) .. (e.equipped and " [equipped]" or " [not equipped]")
    if e.description then s = s .. ": " .. clean(e.description) end
    return s
end

local function mod_terminal_list()
    local m = read("mod_terminal")
    if m == nil then return false, NOT_OPEN end
    local equipped, owned, used = {}, {}, 0
    for _, e in ipairs(m.entries) do
        if e.equipped then
            equipped[#equipped + 1] = e
            used = used + (e.cost or 1)
        else
            owned[#owned + 1] = mod_line(e)
        end
    end
    table.sort(equipped, function(a, b) return (a.slot or 99) < (b.slot or 99) end)
    -- Slots in order; the free ones as "empty slot".
    local slots = {}
    for _, e in ipairs(equipped) do slots[#slots + 1] = mod_line(e) end
    local total = m.capacity_total or #equipped
    for _ = used + 1, total do slots[#slots + 1] = "empty slot" end
    local lines = { string.format("Mod capacity: %d used of %s.", used, tostring(m.capacity_total or "?")) }
    lines[#lines + 1] = "Equipped: " .. (#slots > 0 and join(slots, "; ") or "none") .. "."
    lines[#lines + 1] = "Not equipped: " .. (#owned > 0 and join(owned, "; ") or "none") .. "."
    if (m.locked or 0) > 0 then lines[#lines + 1] = m.locked .. " more mods not unlocked yet." end
    return true, join(lines, "\n")
end

local function mod_terminal_info(args)
    local m = read("mod_terminal")
    if m == nil then return false, NOT_OPEN end
    return info_reply(m.entries, args, mod_detail)
end

-- ---------------------------------------------------------------------------
-- Registration (called once from pragmata_main.lua at startup)
-- ---------------------------------------------------------------------------

local function unavailable() return false, "the Shelter menu reader failed to load" end

function M.register(menu_actions, gates, binding)
    menus = binding
    local function wrap(fn) return function(args) if menus == nil then return unavailable() end return fn(args) end end

    menu_actions.add({ key = "firmware", label = "the Firmware Updater",
                       about = "units, levels, next-level costs",
                       list = wrap(firmware_list), info = wrap(firmware_info),
                       gate = gates.menu_open("firmware") })
    menu_actions.add({ key = "printer", label = "the Unit Printer",
                       about = "every tab: printed or not, levels, costs",
                       list = wrap(printer_list), info = wrap(printer_info),
                       gate = gates.menu_open("printer") })
    menu_actions.add({ key = "mod_terminal", label = "the train terminal's mod menu",
                       about = "capacity, equipped and owned mods",
                       list = wrap(mod_terminal_list), info = wrap(mod_terminal_info),
                       gate = gates.menu_open("mod_terminal") })

    -- Keep the printer's per-tab cache: read the tab a few times a second
    -- while the printer is open, and the full tab when it changes.
    local last_tab = nil
    gates.on_before_sync(function()
        if menus == nil then return end
        if not gates.menu_is_open("printer") then
            if last_tab ~= nil or #_printer_tab_order > 0 then
                _printer_tabs, _printer_tab_order, last_tab = {}, {}, nil
            end
            return
        end
        local tab = menus.printer_tab()
        if tab ~= nil and tab ~= last_tab then
            local p = menus.printer()
            if p ~= nil and p.tab == tab then
                remember_tab(tab, p.entries)
                last_tab = tab
            end
        end
    end)
end

-- For Pragmata State Debug: the exact peer texts.
function M.debug_texts()
    local out = {}
    for _, pair in ipairs({ { "firmware", firmware_list }, { "printer", printer_list },
                            { "mod_terminal", mod_terminal_list } }) do
        local ok, success, text = pcall(pair[2])
        out[pair[1]] = ok and string.format("[%s] %s", tostring(success), tostring(text))
                          or ("RAISED: " .. tostring(success))
    end
    return out
end

return M
