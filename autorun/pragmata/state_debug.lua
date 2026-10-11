-- ImGui debug panel for the game-state actions.
--
-- Renders under "Pragmata State Debug" in the REFramework menu (Insert). For
-- each of the six read-only actions it shows:
--   - the binding's debug_status() (which singletons / methods resolved),
--   - the raw state table the binding returned,
--   - the exact text the peer would receive from the action.
--
-- The raw tables are what settle the open mappings in the bindings -- which
-- perk list is the "Mods" menu, whether weapon ammo is right, which item is
-- the repair kit -- by comparing them with the game's own menus.
--
-- F9 snapshots all six peer texts into a short history with timestamps, so
-- state can be captured mid-fight (you cannot click a button while aiming)
-- and read afterwards.
--
-- More sections serve the Shelter and tram menu actions:
--   - Open menus: the screens open right now, and a latched log of opens and
--     closes with their age, so screens that flash by can be read afterwards.
--     That is how mod_config.menu_gui is confirmed.
--   - Weapon events: the equipped-weapon ids the last poll read, and what the
--     weapon push saw (baselines, equips / unequips, loads), with their age.
--   - Gates: whether the player is in the Shelter, which configured menus are
--     open, the Cabin hub's selected tab and how it was read, and every action
--     with whether the peer currently holds it.
--   - Shelter menus: the raw tables the Firmware / Printer / mod-menu readers
--     return and the list text the peer would get, while the menu is open.
--   - Stamp Club: the text pragmata_stamps would give, and per cell the three
--     "stamped" readings side by side, while that tab is open.
--   - Catalogs: the Data Library / Bot Database / Training list texts, each
--     catalog's data read against its open screen (and the state bits the
--     Bot Database's "collected" is guessed from), and the push events.
--   - Menu object: for each open Shelter menu screen, the screen's own object
--     and the fields the menu readers will use (the Stamp Club's ui5132 is
--     reached through the Cabin hub ui5136). F10 latches it into a history,
--     because the menu has to be open while it is read.
--
-- F11 appends every catalog's peer text and check, and the tram sector
-- replies while that screen is open, to data/pragmata_mailbox/catalog_dump.log;
-- nothing else here writes files.

local M = {}

local log = require("pragmata.util.log")
local game_state = require("pragmata.game_state")
local dispatcher = require("pragmata.dispatcher")
local gates = require("pragmata.action_gates")

local scene = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.scene")
    if ok then scene = mod end
end

-- The raw reads walk live game containers, which are torn down during loads
-- (the 2026-10-01 elevator freeze). The panel pauses them while loading.
local function world_loaded()
    if scene == nil then return true end
    local ok, v = pcall(scene.is_loaded)
    return not (ok and v == false)
end

local gui = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.gui_state")
    if ok then gui = mod end
end

local VK_F9 = 0x78
local VK_F10 = 0x79
local VK_F11 = 0x7A
local CATALOG_DUMP_PATH = "pragmata_mailbox/catalog_dump.log"
local HISTORY_MAX = 6
local SHAPE_HISTORY_MAX = 4

local SECTIONS = {
    { title = "Health",    binding = "vitals",    read = "read",          describe = "describe_health" },
    { title = "Weapons",   binding = "loadout",   read = "read",          describe = "describe_weapons" },
    { title = "Mods",      binding = "perks",     read = "read_mods",     describe = "describe_mods" },
    { title = "Upgrades",  binding = "perks",     read = "read_upgrades", describe = "describe_upgrades" },
    { title = "Inventory", binding = "inventory", read = "read",          describe = "describe_inventory" },
    { title = "Location",  binding = "area",      read = "read",          describe = "describe_location" },
}

local _history = {}
local _shape_history = {}       -- newest first: { frame, code, shape }

-- Shelter menu screens open right now that have a probe list.
local function open_probe_codes()
    local out = {}
    if gui == nil or gui.PROBE_FIELDS == nil then return out end
    for code in pairs(gui.PROBE_FIELDS) do
        if gui.reachable(code) == true then out[#out + 1] = code end
    end
    table.sort(out)
    return out
end

local function describe(section)
    local fn = game_state[section.describe]
    local ok, success, text = pcall(fn)
    if not ok then return "RAISED: " .. tostring(success) end
    return string.format("[%s] %s", tostring(success), tostring(text))
end

-- Flatten a plain Lua table into indented lines. Depth-capped; tables here
-- are small and acyclic, but a cap costs nothing.
local function dump(value, indent, out, depth)
    out = out or {}
    indent = indent or ""
    depth = depth or 0
    if type(value) ~= "table" then
        out[#out + 1] = indent .. tostring(value)
        return out
    end
    if depth > 5 then out[#out + 1] = indent .. "{...}" return out end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
        local v = value[k]
        if type(v) == "table" then
            out[#out + 1] = indent .. tostring(k) .. ":"
            dump(v, indent .. "  ", out, depth + 1)
        else
            out[#out + 1] = indent .. tostring(k) .. " = " .. tostring(v)
        end
    end
    return out
end

local _f9_was = false
local _f10_was = false
local _f11_was = false
local _frame = 0
local _catalog_cache = nil      -- Catalogs section, refreshed once a second

re.on_frame(function()
    _frame = _frame + 1
    local ok, down = pcall(function() return reframework:is_key_down(VK_F9) end)
    down = ok and down == true
    if down and not _f9_was and world_loaded() then
        local snap = { frame = _frame, lines = {} }
        for _, s in ipairs(SECTIONS) do
            snap.lines[#snap.lines + 1] = s.title .. ": " .. describe(s)
        end
        table.insert(_history, 1, snap)
        while #_history > HISTORY_MAX do table.remove(_history) end
        log.info("state_debug: F9 snapshot taken")
    end
    _f9_was = down

    local ok10, down10 = pcall(function() return reframework:is_key_down(VK_F10) end)
    down10 = ok10 and down10 == true
    if down10 and not _f10_was and world_loaded() then
        local codes = open_probe_codes()
        for _, code in ipairs(codes) do
            local ok_s, sh = pcall(gui.debug_shape, code)
            table.insert(_shape_history, 1, { frame = _frame, code = code,
                shape = ok_s and sh or { route = "RAISED", type = tostring(sh), lines = {} } })
        end
        while #_shape_history > SHAPE_HISTORY_MAX do table.remove(_shape_history) end
        log.info("state_debug: F10 menu snapshot (" .. #codes .. " screens)")
    end
    _f10_was = down10

    local ok11, down11 = pcall(function() return reframework:is_key_down(VK_F11) end)
    down11 = ok11 and down11 == true
    if down11 and not _f11_was and world_loaded() then
        local ok_d, err = pcall(M.write_catalog_dump)
        if not ok_d then log.warn("state_debug: F11 catalog dump failed: " .. tostring(err)) end
    end
    _f11_was = down11
end)

-- F11: every catalog's peer text and data-vs-screen check, appended to
-- data/pragmata_mailbox/catalog_dump.log, so the readings can be compared
-- with a menu that is open at the time and read back without copying.
function M.write_catalog_dump()
    local cats = package.loaded["pragmata.bindings.catalogs"]
    local acts = package.loaded["pragmata.catalog_actions"]
    local open = "?"
    if gui ~= nil then
        local ok_o, codes = pcall(gui.open_codes)
        if ok_o and codes then open = table.concat(codes, " ") end
    end
    local out = { string.format("===== F11 catalog dump, frame %d, open screens: %s", _frame, open) }
    local texts = {}
    if acts and acts.debug_texts then
        local ok_t, t = pcall(acts.debug_texts)
        texts = ok_t and t or {}
        if not ok_t then out[#out + 1] = "debug_texts RAISED: " .. tostring(t) end
    end
    for _, key in ipairs({ "library", "archive", "bot_database", "simulations", "earth_memories" }) do
        out[#out + 1] = "----- " .. key .. " (peer text)"
        out[#out + 1] = tostring(texts[key] or "(none)")
        out[#out + 1] = "----- " .. key .. " (check)"
        local fn = cats and cats[key .. "_check"]
        if fn == nil then
            out[#out + 1] = "(no check: catalogs binding not loaded)"
        else
            local ok_c, lines = pcall(fn)
            for _, line in ipairs(ok_c and (lines or {}) or { "RAISED: " .. tostring(lines) }) do
                out[#out + 1] = line
            end
        end
    end
    -- The tram's sector selection, while it is open: the list reply and one
    -- info reply.
    local sector_acts = package.loaded["pragmata.sector_actions"]
    if sector_acts and sector_acts.debug_text and gates.menu_is_open("train_sector") then
        out[#out + 1] = "----- pragmata_sectors_list (peer text)"
        out[#out + 1] = sector_acts.debug_text()
    end

    local f = io.open(CATALOG_DUMP_PATH, "a")
    if f == nil then error("cannot open " .. CATALOG_DUMP_PATH) end
    f:write(table.concat(out, "\n"), "\n")
    f:close()
    log.info("state_debug: F11 catalog dump written")
end

re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata State Debug") then return end

    imgui.text("F9: snapshot every peer text into the history below.")
    local obs = game_state.observed_kit_heal
    imgui.text("Measured repair-kit heal: " .. (obs and tostring(obs.heal) .. " HP" or "(none yet)"))

    local loaded = world_loaded()
    if not loaded then imgui.text("World is loading: state reads paused.") end

    for _, s in ipairs(SECTIONS) do
        if loaded and imgui.tree_node(s.title) then
            local mod = game_state[s.binding]
            if mod == nil then
                imgui.text("(binding not loaded -- see log.txt)")
            else
                imgui.text("Peer text: " .. describe(s))
                if mod.debug_status then
                    local ok, st = pcall(mod.debug_status)
                    imgui.text("-- status --")
                    for _, line in ipairs(dump(ok and st or ("RAISED: " .. tostring(st)))) do
                        imgui.text(line)
                    end
                end
                local ok, raw = pcall(mod[s.read])
                imgui.text("-- raw " .. s.read .. "() --")
                for _, line in ipairs(dump(ok and raw or ("RAISED: " .. tostring(raw)))) do
                    imgui.text(line)
                end
            end
            imgui.tree_pop()
        end
    end

    if imgui.tree_node("Weapon events") then
        local obs = package.loaded["pragmata.game_state_observer"]
        local events = obs and obs.weapon_events or {}
        local live = obs and obs.weapon_live
        if live ~= nil then
            imgui.text(string.format("Last poll: %s  |  equipped weapons: %s  |  hacking mods: %s",
                live.frame and string.format("%.1fs ago", (_frame - live.frame) / 60) or "never",
                tostring(live.equipped), tostring(live.hacking)))
        end
        imgui.text("Equipped-weapon changes the push saw (newest first; ammo ignored).")
        if #events == 0 then imgui.text("(none yet)") end
        for _, e in ipairs(events) do
            imgui.text(string.format("%6.1fs ago  %s", (_frame - e.frame) / 60, e.text))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Open menus") then
        if gui == nil then
            imgui.text("(gui_state binding not loaded -- see log.txt)")
        else
            local ok, st = pcall(gui.debug_status)
            for _, line in ipairs(dump(ok and st or ("RAISED: " .. tostring(st)))) do imgui.text(line) end
            imgui.text("-- open/close events (newest first) --")
            local ok_e, events = pcall(gui.events)
            events = ok_e and events or {}
            if #events == 0 then imgui.text("(none yet)") end
            for _, e in ipairs(events) do
                imgui.text(string.format("%4ds ago  %-6s %s", e.age,
                    e.opened and "OPENED" or "closed", e.code))
            end
        end
        imgui.tree_pop()
    end

    if loaded and imgui.tree_node("Shelter menus") then
        local menus = package.loaded["pragmata.bindings.shelter_menus"]
        local acts = package.loaded["pragmata.shelter_menu_actions"]
        if menus == nil then
            imgui.text("(shelter_menus binding not loaded -- see log.txt)")
        else
            local any = false
            for _, key in ipairs({ "firmware", "printer", "mod_terminal" }) do
                if gates.menu_is_open(key) then
                    any = true
                    if imgui.tree_node(key) then
                        if acts and acts.debug_texts then
                            local ok_t, texts = pcall(acts.debug_texts)
                            imgui.text("Peer list text:")
                            local text = ok_t and texts[key] or ("RAISED: " .. tostring(texts))
                            for line in tostring(text):gmatch("[^\n]+") do imgui.text("  " .. line) end
                        end
                        if key == "printer" and menus.printer_check then
                            imgui.text("-- other-tab rebuild vs this tab's grid --")
                            local ok_c, lines = pcall(menus.printer_check)
                            for _, line in ipairs(ok_c and (lines or {}) or { "RAISED: " .. tostring(lines) }) do
                                imgui.text("  " .. line)
                            end
                        end
                        local ok_r, raw = pcall(menus[key])
                        imgui.text("-- raw " .. key .. "() --")
                        for _, line in ipairs(dump(ok_r and raw or ("RAISED: " .. tostring(raw)))) do
                            imgui.text(line)
                        end
                        imgui.tree_pop()
                    end
                end
            end
            if not any then imgui.text("(none of the three menus is open)") end
        end
        imgui.tree_pop()
    end

    if loaded and imgui.tree_node("Stamp Club") then
        local club = package.loaded["pragmata.bindings.stamp_club"]
        local acts = package.loaded["pragmata.stamp_actions"]
        if club == nil then
            imgui.text("(stamp_club binding not loaded -- see log.txt)")
        elseif not gates.menu_is_open("stamps") then
            imgui.text("(the Stamp Club tab is not open)")
        else
            if acts and acts.debug_text then
                imgui.text("Peer text:")
                for line in tostring(acts.debug_text()):gmatch("[^\n]+") do imgui.text("  " .. line) end
            end
            imgui.text("-- raw cells (unlocked / sealed / screen_unlocked: which matches the screen?) --")
            local ok_b, b = pcall(club.board)
            local ok_l, lines = pcall(club.debug_lines, ok_b and b or nil)
            if not ok_b then lines = { "RAISED: " .. tostring(b) }
            elseif not ok_l then lines = { "RAISED: " .. tostring(lines) } end
            for _, line in ipairs(lines) do imgui.text(line) end
        end
        imgui.tree_pop()
    end

    if loaded and imgui.tree_node("Catalogs") then
        local cats = package.loaded["pragmata.bindings.catalogs"]
        local acts = package.loaded["pragmata.catalog_actions"]
        if cats == nil then
            imgui.text("(catalogs binding not loaded -- see log.txt)")
        else
            -- The reads walk whole catalogs: refresh once a second, not per frame.
            if _catalog_cache == nil or _frame - _catalog_cache.frame >= 60 then
                local c = { frame = _frame, checks = {} }
                if acts and acts.debug_texts then
                    local ok_t, texts = pcall(acts.debug_texts)
                    c.texts = ok_t and texts or { error = "RAISED: " .. tostring(texts) }
                end
                for _, key in ipairs({ "library", "archive", "bot_database", "simulations", "earth_memories" }) do
                    local ok_c, lines = pcall(cats[key .. "_check"])
                    c.checks[key] = ok_c and (lines or {}) or { "RAISED: " .. tostring(lines) }
                end
                _catalog_cache = c
            end
            if acts and imgui.tree_node("Push events") then
                if #acts.events == 0 then imgui.text("(none yet)") end
                for _, e in ipairs(acts.events) do
                    imgui.text(string.format("%.1fs ago  %s", (_frame - e.frame) / 60, e.text))
                end
                imgui.tree_pop()
            end
            for _, key in ipairs({ "library", "archive", "bot_database", "simulations", "earth_memories" }) do
                if imgui.tree_node(key) then
                    imgui.text("Peer list text:")
                    local text = _catalog_cache.texts and _catalog_cache.texts[key] or "(catalog_actions not loaded)"
                    for line in tostring(text):gmatch("[^\n]+") do imgui.text("  " .. line) end
                    imgui.text("-- data vs screen check --")
                    for _, line in ipairs(_catalog_cache.checks[key]) do imgui.text(line) end
                    imgui.tree_pop()
                end
            end
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Menu object") then
        if gui == nil or gui.debug_shape == nil then
            imgui.text("(gui_state binding not loaded -- see log.txt)")
        else
            imgui.text("F10: snapshot the open menu's object into the history below.")
            local function show(code, sh)
                imgui.text(string.format("%s  ->  %s  (route: %s)", code, tostring(sh.type), tostring(sh.route)))
                for _, line in ipairs(sh.lines or {}) do imgui.text("  " .. line) end
            end
            if loaded and imgui.tree_node("Live") then
                local codes = open_probe_codes()
                if #codes == 0 then imgui.text("(no Shelter menu open)") end
                for _, code in ipairs(codes) do
                    local ok_s, sh = pcall(gui.debug_shape, code)
                    show(code, ok_s and sh or { route = "RAISED", type = tostring(sh), lines = {} })
                end
                imgui.tree_pop()
            end
            imgui.text("-- F10 history (newest first) --")
            if #_shape_history == 0 then imgui.text("(no snapshots yet)") end
            for i, e in ipairs(_shape_history) do
                if imgui.tree_node(string.format("#%d  %.1fs ago  %s", i, (_frame - e.frame) / 60, e.code)) then
                    show(e.code, e.shape)
                    imgui.tree_pop()
                end
            end
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("Gates") then
        local ok, st = pcall(gates.debug_status)
        for _, line in ipairs(dump(ok and st or ("RAISED: " .. tostring(st)))) do imgui.text(line) end
        imgui.text("-- actions (held = the peer currently has it) --")
        local ok2, list = pcall(dispatcher.availability)
        for _, a in ipairs(ok2 and list or {}) do
            imgui.text(string.format("%-5s %-5s %s%s", a.available and "shown" or "HIDE",
                a.held and "held" or "-", a.name, a.reason and ("  (" .. a.reason .. ")") or ""))
        end
        imgui.tree_pop()
    end

    if imgui.tree_node("F9 history") then
        if #_history == 0 then imgui.text("(no snapshots yet)") end
        for i, snap in ipairs(_history) do
            imgui.text(string.format("#%d  %.1fs ago", i, (_frame - snap.frame) / 60))
            for _, line in ipairs(snap.lines) do imgui.text("  " .. line) end
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

return M
