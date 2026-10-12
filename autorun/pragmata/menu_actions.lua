-- pragmata_menu_list / pragmata_menu_info: every Shelter menu and catalog
-- behind two actions.
--
-- These used to be nineteen actions (pragmata_firmware_list, _info,
-- pragmata_printer_list, ... pragmata_stamps), each announced only while its
-- menu was open. BEST_PRACTICES.md asks for the opposite on both counts: a
-- stable action set (every register / unregister slows the peer down, and
-- the Shelter's menus open and close constantly) and one parameterized action
-- instead of many near-identical ones (the peer fixates on a few of them).
-- So the menu is now an enum argument, both actions are registered once and
-- never hidden, and a menu that cannot be read right now refuses with the
-- same reason its gate used to give.
--
-- The menu modules keep their formatting and their gates; they hand them to
-- add() instead of registering actions of their own:
--
--   menu_actions.add({ key = "printer", label = "the Unit Printer",
--                      about = "every tab: printed or not, levels, costs",
--                      list = fn(), info = fn(args) or nil,
--                      gate = fn() -> ok, reason or nil })
--
-- `label` names the menu in a refusal; `about` explains the enum value in the
-- schema, so the peer can tell the values apart without a long description.

local M = {}

local name_match = require("pragmata.util.name_match")

local _menus = {}       -- key -> entry
local _order = {}       -- keys in add() order (the enum order the peer sees)

function M.add(entry)
    assert(type(entry.key) == "string", "menu key required")
    assert(type(entry.list) == "function", "list function required for " .. entry.key)
    if _menus[entry.key] == nil then _order[#_order + 1] = entry.key end
    _menus[entry.key] = entry
end

local function keys(with_info)
    local out = {}
    for _, k in ipairs(_order) do
        if not with_info or _menus[k].info ~= nil then out[#out + 1] = k end
    end
    return out
end

local function menu_lines(with_info)
    local parts = {}
    for _, k in ipairs(keys(with_info)) do
        local e = _menus[k]
        parts[#parts + 1] = k .. " = " .. tostring(e.label or k)
            .. (e.about and (" (" .. e.about .. ")") or "")
    end
    return table.concat(parts, "; ")
end

-- The entry for args.menu, or nil + an actionable refusal.
local function pick(args, with_info)
    local key = type(args) == "table" and args.menu or nil
    local entry = type(key) == "string" and _menus[key] or nil
    if entry == nil or (with_info and entry.info == nil) then
        return nil, "Unknown menu '" .. tostring(key) .. "'. Use one of: "
            .. menu_lines(with_info) .. "."
    end
    if entry.gate ~= nil then
        local ok, avail, reason = pcall(entry.gate)
        if ok and avail == false then
            local label = tostring(entry.label or key)
            return nil, (label:gsub("^%l", string.upper)) .. " cannot be read right now"
                .. (reason and (": " .. reason) or "") .. "."
        end
    end
    return entry
end

local function call(fn, ...)
    local ok, success, message = pcall(fn, ...)
    if not ok then return false, "that menu could not be read: " .. tostring(success) end
    return success, message
end

-- Called once from pragmata_main.lua, after every menu module has added its
-- entries (the enum is built from them).
function M.register(dispatcher)
    if #_order == 0 then return end
    local list_schema = {
        type = "object",
        required = { "menu" },
        properties = {
            menu = { type = "string", ["enum"] = keys(false),
                     description = "Which menu or catalog to read: " .. menu_lines(false) .. "." },
        },
    }
    local info_schema = name_match.schema("entries, exactly as pragmata_menu_list gives them")
    info_schema.properties.menu = { type = "string", ["enum"] = keys(true),
                                    description = "Which menu or catalog the names are from: "
                                        .. menu_lines(true) .. "." }
    info_schema.required = { "menu", "names" }
    info_schema.properties.__keyorder = { "menu", "names" }

    dispatcher.register("pragmata_menu_list", {
        description = "Read a Shelter menu or catalog: what it lists, with levels, costs, counts "
            .. "or completion. Most work only while that menu is open or in the Shelter; "
            .. "a call that cannot be answered says why. Read-only.",
        schema = list_schema,
        handler = function(args)
            local entry, why = pick(args, false)
            if entry == nil then return false, why end
            return call(entry.list)
        end,
    })
    dispatcher.register("pragmata_menu_info", {
        description = "Details for up to 8 entries of a Shelter menu or catalog, by the names "
            .. "pragmata_menu_list gives. Same availability as pragmata_menu_list. Read-only.",
        schema = info_schema,
        handler = function(args)
            local entry, why = pick(args, true)
            if entry == nil then return false, why end
            return call(entry.info, args)
        end,
    })
end

-- For Pragmata State Debug.
function M.menus()
    local out = {}
    for _, k in ipairs(_order) do
        local e = _menus[k]
        local ok, avail, reason = true, true, nil
        if e.gate ~= nil then ok, avail, reason = pcall(e.gate) end
        out[#out + 1] = { key = k, label = e.label, about = e.about, has_info = e.info ~= nil,
                          available = (not ok) or avail ~= false, reason = reason }
    end
    return out
end

return M
