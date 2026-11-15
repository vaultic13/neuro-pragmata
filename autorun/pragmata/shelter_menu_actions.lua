-- Peer actions for the Shelter upgrade menus: Firmware Updater, Unit Printer
-- and the train terminal's mod menu.
--
-- pragmata_menu_list / pragmata_menu_info answer for whichever of these is
-- on screen (menu_actions.lua); none of them can be read closed:
--   list   every entry, one line each
--   info   full detail for up to 8 named entries
--
-- Formatting only: every read goes through bindings/shelter_menus.lua, which
-- hands back plain tables. Names in an info call are matched
-- case-insensitively, exact first, then as a substring; a name that matches
-- nothing, or several things, is answered as such rather than dropped.
--
-- The Unit Printer shows one tab at a time, and a tab's values are right
-- only once it has been shown this visit. Every list names all three tabs
-- (Weapon, Attachment, HackingNode), each marked:
--   on screen           read from the grid now;
--   as seen this visit  the rows kept from when it was on screen (a per-visit
--                       cache, refreshed about once a second while shown and
--                       dropped when the printer closes);
--   not viewed yet      rebuilt from game data by the binding, under a
--                       warning that levels and costs may be wrong; a tab
--                       that rebuilt empty says its units cannot be read yet.
--
-- Levels: the maximum shown is how far a unit can go at this point of the
-- game (its stage cap), not its full maximum; the levels the game still
-- hides are not mentioned at all, and a unit at its cap reads "no further
-- levels available yet" with no cost.

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

-- Shown as no further level: maxed, or at this point of the game's cap.
local CAPPED = ", no further levels available yet"

local function firmware_line(e)
    local name = e.subtitle and (e.name .. " (" .. e.subtitle .. ")") or e.name
    local s = name .. " - " .. (level_text(e.level, e.level_cap or e.level_max) or "level unknown")
    if e.maxed then return s .. ", fully upgraded" end
    if e.capped then return s .. CAPPED end
    local cost = cost_text(e.next_cost)
    if cost then s = s .. ", next level costs " .. cost end
    return s
end

local function firmware_detail(e)
    local lines = { firmware_line(e) }
    if not e.maxed and not e.capped and cost_text(e.next_cost) == nil then
        lines[#lines + 1] = "  The next level's cost could not be read."
    end
    local stats = {}
    for _, st in ipairs(e.stats or {}) do
        if st.next ~= nil and st.next ~= st.now and not e.capped then
            stats[#stats + 1] = string.format("%s %s -> %s", st.name, tostring(st.now), tostring(st.next))
        elseif st.now ~= nil then
            stats[#stats + 1] = string.format("%s %s", st.name, tostring(st.now))
        end
    end
    if #stats > 0 then
        lines[#lines + 1] = "  Stats" .. ((e.maxed or e.capped) and "" or " (now -> next level)")
            .. ": " .. join(stats, "; ") .. "."
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
        local lv = level_text(e.level, e.level_cap or e.level_max)
        if lv then s = s .. ", " .. lv end
        if e.maxed then
            s = s .. ", fully upgraded"
        elseif e.capped then
            s = s .. CAPPED
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
        -- Only the levels reachable at this point of the game.
        local last = e.level_cap or #per
        for i, t in ipairs(per) do
            if t ~= "" and i <= last then
                local mark = (i == cur and " (current)") or (i == cur + 1 and not e.capped and " (next)") or ""
                lines[#lines + 1] = string.format("  Lv %d%s: %s", i, mark, clean(t))
            end
        end
    end
    return join(lines, "\n")
end

-- Every tab, in the printer's order, with `status` = "on_screen" | "seen" |
-- "unviewed". Entries of an unviewed tab carry `unviewed_tab` for info.
local function printer_tabs()
    local all = read("printer_all")
    if all == nil then
        local p = read("printer")
        if p == nil then return nil end
        all = { tab = p.tab, tabs = {} }
        local listed = false
        for _, name in ipairs(menus.PRINTER_TABS or {}) do
            if name == p.tab then
                all.tabs[#all.tabs + 1] = { tab = name, entries = p.entries, on_screen = true }
                listed = true
            else
                all.tabs[#all.tabs + 1] = { tab = name, entries = {}, unread = true }
            end
        end
        if not listed then table.insert(all.tabs, 1, { tab = p.tab, entries = p.entries, on_screen = true }) end
    end
    local have = {}
    for _, t in ipairs(all.tabs) do
        have[t.tab or "?"] = true
        if t.on_screen then
            remember_tab(t.tab, t.entries)
            t.status = "on_screen"
        elseif t.tab ~= nil and _printer_tabs[t.tab] ~= nil then
            t.entries, t.status = _printer_tabs[t.tab], "seen"
        else
            t.status = "unviewed"
            for _, e in ipairs(t.entries) do e.unviewed_tab = t.tab end
        end
    end
    -- A tab seen this visit that the binding no longer lists.
    for _, tab in ipairs(_printer_tab_order) do
        if not have[tab] then
            all.tabs[#all.tabs + 1] = { tab = tab, entries = _printer_tabs[tab], status = "seen" }
        end
    end
    return all
end

local UNVIEWED = "not viewed yet this visit: levels and costs may be wrong; "
    .. "switch to this tab in game to read it"
local TAB_MARK = { on_screen = " (on screen)", seen = " (as seen this visit)",
                   unviewed = " (" .. UNVIEWED .. ")" }

local function printer_list()
    local all = printer_tabs()
    if all == nil then return false, NOT_OPEN end
    local lines = { "Unit Printer (tab on screen: " .. tostring(all.tab or "unknown") .. "):" }
    local unviewed = {}
    for _, t in ipairs(all.tabs) do
        lines[#lines + 1] = "Tab " .. tostring(t.tab or "?") .. (TAB_MARK[t.status] or "") .. ":"
        if t.status == "unviewed" then unviewed[#unviewed + 1] = tostring(t.tab) end
        if #t.entries == 0 then
            lines[#lines + 1] = (t.status == "unviewed")
                and "- its units cannot be read until this tab is shown in game"
                or "- nothing listed"
        end
        for _, e in ipairs(t.entries) do lines[#lines + 1] = "- " .. printer_line(e) end
    end
    if #unviewed > 0 then lines[#lines + 1] = "Tabs not viewed yet: " .. join(unviewed) .. "." end
    return true, join(lines, "\n")
end

local function printer_info_detail(e)
    local s = printer_detail(e)
    if e.unviewed_tab ~= nil then
        s = s .. "\n  (Its tab, " .. tostring(e.unviewed_tab) .. ", has not been viewed yet this "
            .. "visit: levels and costs may be wrong; switch to that tab in game to read it.)"
    end
    return s
end

local function printer_info(args)
    local all = printer_tabs()
    if all == nil then return false, NOT_OPEN end
    local entries = {}
    for _, t in ipairs(all.tabs) do
        for _, e in ipairs(t.entries) do entries[#entries + 1] = e end
    end
    return info_reply(entries, args, printer_info_detail)
end

-- ---------------------------------------------------------------------------
-- Mod terminal
-- ---------------------------------------------------------------------------

-- No slot numbers (the equipped list is in slot order) and no cost unless a
-- mod costs more than the usual 1.
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

    menu_actions.add({ key = "firmware", label = "the Firmware Updater", title = "Firmware Updater",
                       open_key = "firmware",
                       list = wrap(firmware_list), info = wrap(firmware_info) })
    menu_actions.add({ key = "printer", label = "the Unit Printer", title = "Unit Printer",
                       open_key = "printer",
                       list = wrap(printer_list), info = wrap(printer_info),
                       open_note = function()
                           local tab = menus and menus.printer_tab()
                           return tab and ("on the " .. tab .. " tab") or nil
                       end })
    menu_actions.add({ key = "mod_terminal", label = "the train terminal's mod menu",
                       title = "Train terminal mod menu", open_key = "mod_terminal",
                       list = wrap(mod_terminal_list), info = wrap(mod_terminal_info) })

    -- Keep the printer's per-tab cache: read the tab a few times a second
    -- while the printer is open, the full tab when it changes, and the tab on
    -- screen again every REFRESH_POLLS so a print or upgrade made on it is
    -- what the cache keeps once the player switches away.
    local REFRESH_POLLS = 5
    local last_tab, polls = nil, 0
    gates.on_before_sync(function()
        if menus == nil then return end
        if not gates.menu_is_open("printer") then
            if last_tab ~= nil or #_printer_tab_order > 0 then
                _printer_tabs, _printer_tab_order, last_tab = {}, {}, nil
            end
            return
        end
        polls = polls + 1
        local tab = menus.printer_tab()
        if tab ~= nil and (tab ~= last_tab or polls % REFRESH_POLLS == 0) then
            local p = menus.printer()
            if p ~= nil and p.tab == tab then
                remember_tab(tab, p.entries)
                last_tab = tab
            end
        end
    end)
end

return M
