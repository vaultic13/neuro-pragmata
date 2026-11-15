-- pragmata_menu_list / pragmata_menu_info: the Shelter menu open right now.
--
-- The Shelter menus read right only while their screen is open, so naming
-- one that is closed could only ever be refused. The two actions take no menu
-- at all: they read whichever menu is on screen, and the reply's first line
-- names it. The peer learns
-- that a menu opened from menu_observer.lua's push.
--
-- The catalogs (Data Library, Bot Database, Training Simulations, Earth
-- Memories) read right with their screens closed, so they moved to the
-- Archive pair (catalog_actions.lua), where a `catalog` choice still makes
-- sense.
--
-- The two actions are announced while in the main Shelter or while one of
-- these screens is open (the tram's sector selection can be opened outside
-- the Shelter). Elsewhere there is nothing they could read.
--
-- Menu modules hand their readers to add():
--
--   menu_actions.add({ key = "printer", label = "the Unit Printer",
--                      title = "Unit Printer", open_key = "printer",
--                      list = fn(), info = fn(args) or nil,
--                      info_refusal = "..." (when info is nil),
--                      open_note = fn() -> "on the Weapon tab" or nil })
--
-- `open_key` is the menu's mod_config.menu_gui key (action_gates.menu_is_open).
-- `label` names the menu in running text, `title` heads a reply. Only one of
-- these menus can be on screen at a time (they are full-screen; the Cabin hub
-- shows one tab); if two ever read open, add() order decides, and State
-- Debug -> Gates lists both.

local M = {}

local name_match = require("pragmata.util.name_match")

local _menus = {}       -- key -> entry
local _order = {}       -- keys in add() order
local _gates = nil      -- action_gates, set by register()

function M.add(entry)
    assert(type(entry.key) == "string", "menu key required")
    assert(type(entry.list) == "function", "list function required for " .. entry.key)
    entry.open_key = entry.open_key or entry.key
    entry.title = entry.title or entry.label or entry.key
    if _menus[entry.key] == nil then _order[#_order + 1] = entry.key end
    _menus[entry.key] = entry
end

function M.entry(key) return _menus[key] end
function M.keys()
    local out = {}
    for i, k in ipairs(_order) do out[i] = k end
    return out
end

-- The entries whose screens are open now, in add() order.
function M.open_entries()
    local out = {}
    if _gates == nil then return out end
    for _, k in ipairs(_order) do
        local e = _menus[k]
        if _gates.menu_is_open(e.open_key) then out[#out + 1] = e end
    end
    return out
end

local function labels()
    local parts = {}
    for _, k in ipairs(_order) do parts[#parts + 1] = tostring(_menus[k].label or k) end
    if #parts <= 1 then return table.concat(parts) end
    return table.concat(parts, ", ", 1, #parts - 1) .. " or " .. parts[#parts]
end

local function none_open()
    return "No menu is open. Open one of: " .. labels() .. ". "
        .. "The Archive and the Shelter's catalogs are read with pragmata_archive_list."
end

-- Every reply starts by naming the menu it read, unless its text already does.
local function headed(entry, success, text)
    text = tostring(text or "")
    if text:sub(1, #entry.title) == entry.title then return success, text end
    return success, entry.title .. ":\n" .. text
end

local function call(entry, fn, ...)
    local ok, success, message = pcall(fn, ...)
    if not ok then return false, entry.title .. " could not be read: " .. tostring(success) end
    return headed(entry, success, message)
end

-- In the main Shelter, or while one of these menus is open.
local function available()
    if _gates == nil then return false, "the menu readers failed to load" end
    if _gates.in_main_shelter() or #M.open_entries() > 0 then return true end
    return false, "only in the main Shelter, or while one of its menus is open"
end

-- Called once from pragmata_main.lua, after every menu module has added its
-- entries.
function M.register(dispatcher, gates)
    _gates = gates
    if #_order == 0 then return end
    local info_schema = name_match.schema("entries of the open menu")

    dispatcher.register("pragmata_menu_list", {
        description = "Read the Shelter menu open on screen right now (" .. labels() .. "): "
            .. "what it lists, with levels, costs, counts or completion. The reply names the "
            .. "menu it read; with none open it says which can be opened. You are told when "
            .. "one opens or closes. Read-only.",
        short = "Read the Shelter menu open on screen right now. Read-only.",
        schema = { type = "object" },
        available = available,
        handler = function()
            local entry = M.open_entries()[1]
            if entry == nil then return false, none_open() end
            return call(entry, entry.list)
        end,
    })
    dispatcher.register("pragmata_menu_info", {
        description = "Details for up to 8 entries of the Shelter menu open on screen right now, "
            .. "by the names pragmata_menu_list gives. Read-only.",
        short = "Details for up to 8 entries of the open Shelter menu, by name. Read-only.",
        schema = info_schema,
        available = available,
        handler = function(args)
            local entry = M.open_entries()[1]
            if entry == nil then return false, none_open() end
            if entry.info == nil then
                return false, entry.title .. ": " .. tostring(entry.info_refusal
                    or "this menu has no details beyond what pragmata_menu_list gives") .. "."
            end
            return call(entry, entry.info, args)
        end,
    })
end

return M
