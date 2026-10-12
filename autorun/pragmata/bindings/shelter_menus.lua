--
-- Readers for the Shelter upgrade menus: Firmware Updater, Unit Printer and
-- the train terminal's mod menu.
--
-- Each reads the OPEN menu's own object (gui_state.control), so levels and
-- costs come out exactly as the screen shows them. Every reader returns nil
-- when its menu is not open; the actions are gated on the menu anyway.
--
-- Engine layout (il2cpp dump + the State Debug "Menu object" dump, 2026-10-04):
--
--   Scroll controllers (ScrollListController`1 / ScrollGridController`1)
--     hold their entries in <InfoList>k__BackingField (List<T>); the
--     controller itself answers get_Count but has no get_Item.
--
--   app.gui.ui5120  Firmware Updater
--     _UpgradableUnits   List<GUIPerkData>  thin records (_ID, _StatusParameter
--                        only; _Name/_LevelData read nil) -- not used for text
--     _ui5174._ScrollList -> InfoList of app.gui.ui5174.AppSelectItem, one per
--                        unit on screen (3 in the test):
--       _TargetUnitInfo  UnitInfo { NameTextMessageData, NameSubTextMessageData,
--                        CurrentLevel, NextLevel, MaxLevel, UnlockMaxLevel,
--                        ObjectId, IsMainWeapon, PerkData }
--       _NextMoneyData   MoneyData._Money List<MoneyObjectData>
--                        { get_MoneyID(), get_Value() } -- next level's cost
--       _CurrDisplayParameters / _NextDisplayParameters
--                        List<DisplayParameter> { ParameterHash, ValueString }
--       _StatusParameters List<StatusParameterData> { _ID, _Name }
--     GUI_DISPLAY_LEVEL_OFFSET = 1 (static) -- added to levels for display
--
--   app.gui.ui5100  Unit Printer (one tab at a time)
--     GridCtrl -> InfoList of GridInfo { TxtName (AppText), ObjectId,
--       CurrentLevel, MaxLevel, TotalLevel, State (GadgetState), IsNew,
--       Costs UnlockCost[] { ItemId, NeedNum, HaveNum } }
--     Tab.get_SelectedCategory() -> app.GUIReinforceType
--       (Weapon / Attachment / Ability / HackingNode)
--     Status  the selected entry's detail: DispObjectId, DispLevel,
--             TxtDescription (AppText)
--
--   app.gui.ui5111  train terminal mod menu
--     _SkillInfoList List<SkillInfo>; SkillInfo.<Param>k__BackingField is a
--       SkillParam { <ID>, <IsUnlock>, <IsEquip>, <EquipIndex>, <IsNew>,
--       <GUIData> (GUIPerkData), get_Cost() }
--     _TotalCapacity, _CurrentCapacity, _MaxEquipNum
--
-- Names: an AppText's <_TextMessageData> through object_names.text; mods by
-- id through perks.perk_name.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local gui = require("pragmata.bindings.gui_state")
local object_names = require("pragmata.bindings.object_names")

local perks = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.perks")
    if ok then perks = mod else log.warn("shelter_menus: perks binding unavailable: " .. tostring(mod)) end
end

local inventory = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.inventory")
    if ok then inventory = mod end
end

local M = {}

-- Screen codes; the same values as mod_config.menu_gui.
M.CODES = { firmware = "ui5120", printer = "ui5100", mod_terminal = "ui5111" }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function call(obj, name)
    if obj == nil then return nil end
    return r.safe(function() return obj:call(name) end)
end

local function int(v) return r.to_int(v) end

local function bool(v)
    if type(v) == "boolean" then return v end
    return nil
end

-- Entries of a scroll controller.
local function infos(ctrl)
    return r.elements(r.field(ctrl, "<InfoList>k__BackingField") or call(ctrl, "get_InfoList"))
end

-- Text on an app.gui.AppText (its message, not the rendered string).
local function app_text(t)
    if t == nil then return nil end
    return object_names.text(r.field(t, "_TextMessageData"))
end

local function item_name(id)
    if id == nil then return nil end
    return object_names.display_name(id) or object_names.object_name(id)
end

local function have(id)
    if inventory == nil or id == nil then return nil end
    local ok, n = pcall(inventory.quantity, id)
    return ok and n or nil
end

local _enum_cache = {}
local function enum_name(type_name, v)
    if v == nil then return nil end
    local map = _enum_cache[type_name]
    if map == nil then
        map = r.enum_value_names(type_name)
        _enum_cache[type_name] = map
    end
    return map[int(v) or -1]
end

-- ---------------------------------------------------------------------------
-- Firmware Updater
-- ---------------------------------------------------------------------------

local function money_costs(money_data)
    local out = {}
    for _, m in ipairs(r.elements(r.field(money_data, "_Money") or call(money_data, "get_Money"))) do
        local id = int(call(m, "get_MoneyID")) or int(r.field(r.field(m, "_MoneyID"), "_ID"))
        local need = int(call(m, "get_Value")) or int(r.field(m, "_value"))
        if id ~= nil and need ~= nil and need > 0 then
            out[#out + 1] = { id = id, item = item_name(id) or "an unnamed item", need = need, have = have(id) }
        end
    end
    return out
end

-- Stat lines: "HP 120 -> 140", names from the unit's StatusParameterData.
local function stat_changes(sel)
    local names = {}
    for _, p in ipairs(r.elements(r.field(sel, "_StatusParameters"))) do
        local id = int(r.field(p, "_ID"))
        local n = object_names.text(r.field(p, "_Name"))
        if id ~= nil and n ~= nil then names[id] = n end
    end
    local function read(list_name)
        local out, order = {}, {}
        for _, d in ipairs(r.elements(r.field(sel, list_name))) do
            local h = int(r.field(d, "<ParameterHash>k__BackingField"))
            local s = r.field(d, "<ValueString>k__BackingField")
            if h ~= nil then
                -- ValueString read "" in the 2026-10-05 test; the number is the fallback.
                local v = (type(s) == "string" and s ~= "") and s or nil
                if v == nil then
                    local f = r.to_float(r.field(d, "<Value>k__BackingField") or call(d, "get_Value"))
                    if f ~= nil then v = (f == math.floor(f)) and string.format("%d", f) or string.format("%.2f", f) end
                end
                if v ~= nil then
                    if out[h] == nil then order[#order + 1] = h end
                    out[h] = v
                end
            end
        end
        return out, order
    end
    local curr, order = read("_CurrDisplayParameters")
    local nxt, order2 = read("_NextDisplayParameters")
    for _, h in ipairs(order2) do if curr[h] == nil then order[#order + 1] = h end end
    local out = {}
    for _, h in ipairs(order) do
        if curr[h] ~= nil or nxt[h] ~= nil then
            out[#out + 1] = { name = names[h] or "stat", now = curr[h], next = nxt[h] }
        end
    end
    return out
end

-- { entries = {{ id, name, subtitle, level, level_max, level_cap, maxed,
--   main_weapon, next_cost = {{id, item, need, have}}, stats = {{name, now, next}} }} }
function M.firmware()
    local c = gui.control(M.CODES.firmware)
    if c == nil then return nil end
    local offset = int(r.field(c, "GUI_DISPLAY_LEVEL_OFFSET")) or 1
    local list = r.field(r.field(c, "_ui5174"), "_ScrollList")
    local out = { entries = {}, level_offset = offset }
    for _, sel in ipairs(infos(list)) do
        local u = r.field(sel, "_TargetUnitInfo")
        if u ~= nil then
            local level = int(r.field(u, "CurrentLevel"))
            local level_max = int(r.field(u, "MaxLevel"))
            local level_cap = int(r.field(u, "UnlockMaxLevel"))
            local e = {
                id          = int(r.field(u, "ObjectId")),
                name        = object_names.text(r.field(u, "NameTextMessageData")),
                subtitle    = object_names.text(r.field(u, "NameSubTextMessageData")),
                raw_level   = level,
                level       = level and (level + offset) or nil,
                level_max   = level_max and (level_max + offset) or nil,
                level_cap   = level_cap and (level_cap + offset) or nil,
                main_weapon = bool(r.field(u, "IsMainWeapon")),
                next_cost   = money_costs(r.field(sel, "_NextMoneyData")),
                stats       = stat_changes(sel),
            }
            if e.level_cap ~= nil and e.level_max ~= nil and e.level_cap > e.level_max then
                e.level_cap = e.level_max
            end
            e.maxed = (e.level ~= nil and e.level_max ~= nil and e.level >= e.level_max)
            if e.name == nil then e.name = item_name(e.id) or "an unnamed unit" end
            out.entries[#out.entries + 1] = e
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Unit Printer
-- ---------------------------------------------------------------------------
--
-- GadgetState describes the NEXT step, not whether a unit is printed
-- (2026-10-05: Confuse, printed at Lv 2/3, reads UnlockDisable because its
-- next level is unaffordable; a maxed unit reads Unlocked). Printed or not
-- comes from the printer's own isAcquired(id).
--
-- The grid holds only the selected tab (ui5100.setupGrid(GUIReinforceType,
-- ...) rebuilds it on a switch), so the other tabs are rebuilt from game data:
--   GuiDataManager.getReinforceItemDataList() -> List<IGUIReinforceItemData>
--     (get_ID, get_ReinforceType, get_UnlockName / get_SimpleName, ...)
--     -- the 2026-10-05 check found it covers only part of each tab, so also
--   GuiDataManager._ReinforceDataTable  Dictionary<UInt32, GUIReinforceData
--     { Item (GUIReinforceUserDataItem: get_UnlockName, ...), ReinforceType }>
--   ReinforceManager.getCurrentLevel(UInt32) / getMaxLevel(UInt32)
--   ReinforceManager.getCurrentHideType(UInt32 id, UInt32 unlockType, Int32 level)
--     -> ReinforceHideType { Open, Secret, Hide }  (Hide = not listed)
--   ui5100 (the open printer): isAcquired(UInt32),
--     getUnlockCost(UInt32 id, UInt32 unlockType, GadgetState) -> UnlockCost[]
-- The unlock-type argument (taken from GridInfo.UnlockType; one value,
-- 132296270, in the test) and the engine-to-menu level offset (+1) are
-- calibrated from the visible tab. M.printer_check() compares the rebuild of
-- the visible tab against the grid for the debug panel.

local T_TAB = "app.GUIReinforceType"
local T_STATE = "app.gui.ui5100.GadgetState"

local _p = { inited = false }

local function sig(td, a, b)
    return r.method(td, a) or r.method(td, b)
end

local function printer_init()
    if _p.inited then return end
    _p.inited = true
    _p.m_items     = r.method(r.td("app.GuiDataManager"), "getReinforceItemDataList()")
    local rm = r.td("app.ReinforceManager")
    _p.m_level     = r.method(rm, "getCurrentLevel(System.UInt32)")
    _p.m_level_max = r.method(rm, "getMaxLevel(System.UInt32)")
    _p.m_hide      = sig(rm, "getCurrentHideType(System.UInt32,System.UInt32,System.Int32)",
                             "getCurrentHideType(System.UInt32, System.UInt32, System.Int32)")
    local ui = r.td("app.gui.ui5100")
    _p.m_acquired  = r.method(ui, "isAcquired(System.UInt32)")
    _p.m_cost      = sig(ui, "getUnlockCost(System.UInt32,System.UInt32,app.gui.ui5100.GadgetState)",
                             "getUnlockCost(System.UInt32, System.UInt32, app.gui.ui5100.GadgetState)")
end

-- What each unit does, and one line per level. `src` is an
-- IGUIReinforceItemData (GridInfo.ReinforceData, the item list) or a
-- GUIReinforceUserDataItem (the data table); either may lack a part.
local function reinforce_text(src, level_max)
    if src == nil then return nil, nil end
    local desc = object_names.text(call(src, "get_UnlockDescription"))
        or object_names.text(r.field(src, "_UnlockDescription"))
        or object_names.text(r.field(src, "_Description"))
    local levels = {}
    for _, ld in ipairs(r.elements(call(src, "get_LevelData") or r.field(src, "_LevelData"))) do
        levels[#levels + 1] = object_names.text(r.field(ld, "Description")) or ""
    end
    -- One description per menu level; a longer array has a level-0 entry first.
    local shift = 0
    if level_max ~= nil and #levels > level_max then shift = #levels - level_max end
    local per_level = {}
    for i = 1 + shift, #levels do per_level[#per_level + 1] = levels[i] end
    return desc, per_level
end

local function source_name(src)
    return object_names.text(call(src, "get_UnlockName"))
        or object_names.text(r.field(src, "_UnlockName"))
        or object_names.text(call(src, "get_SimpleName"))
        or object_names.text(r.field(src, "_SimpleName"))
end

-- UnlockCost[] -> {{ id, item, need, have }}
local function unlock_costs(arr)
    local out = {}
    for _, k in ipairs(r.elements(arr)) do
        local item = int(r.field(k, "ItemId"))
        local need = int(r.field(k, "NeedNum"))
        if item ~= nil and item ~= 0 and need ~= nil and need > 0 then
            out[#out + 1] = { id = item, item = item_name(item) or "an unnamed item",
                              need = need, have = int(r.field(k, "HaveNum")) or have(item) }
        end
    end
    return out
end

local function affordable(costs)
    for _, k in ipairs(costs or {}) do
        if (k.have or 0) < k.need then return false end
    end
    return true
end

-- Printed: isAcquired, or any engine level above 0. isAcquired answers
-- false for every Attachment (Mod Slot at 6/6 included, 2026-10-05), which
-- are upgrades rather than prints; their engine level is the tell.
local function is_printed(acquired, raw_level)
    return acquired == true or (raw_level ~= nil and raw_level >= 1)
end

-- Words for the peer: { state = "printed" | "not printed yet" | "not found
-- yet", maxed, affordable }.
local function settle(e)
    e.affordable = affordable(e.cost)
    local printed = is_printed(e.acquired, e.raw_level)
    e.maxed = (e.state_raw == "Unlocked")
        or (printed and e.level ~= nil and e.level_max ~= nil and e.level >= e.level_max)
    if printed or e.state_raw == "Unlocked" then
        e.state = "printed"
    elseif e.state_raw == "Secret" then
        e.state = "not found yet"
    else
        e.state = "not printed yet"
    end
end

-- { tab, entries = {{ id, data_id, name, state, state_raw, acquired, maxed,
--   affordable, level, level_max, total_level, is_new, cost = {{id, item,
--   need, have}}, description, level_texts, selected, unlock_type }} }
-- Secret entries carry no text, as on screen.
function M.printer()
    local c = gui.control(M.CODES.printer)
    if c == nil then return nil end
    printer_init()
    local tab = r.field(c, "Tab")
    local out = {
        tab = enum_name(T_TAB, call(tab, "get_SelectedCategory")),
        entries = {},
    }

    local status = r.field(c, "Status")
    local selected_id = int(r.field(status, "DispObjectId"))
    local selected_text = app_text(r.field(status, "TxtDescription"))

    for _, g in ipairs(infos(r.field(c, "GridCtrl"))) do
        local id = int(r.field(g, "ObjectId"))
        local state = enum_name(T_STATE, r.field(g, "State"))
        if id ~= nil and id ~= 0 and state ~= "Invalid" then
            local rd = r.field(g, "ReinforceData")
            local e = {
                id          = id,
                data_id     = int(call(rd, "get_ID")),
                data_tab    = enum_name(T_TAB, call(rd, "get_ReinforceType")),
                state_raw   = state,
                level       = int(r.field(g, "CurrentLevel")),
                level_max   = int(r.field(g, "MaxLevel")),
                total_level = int(r.field(g, "TotalLevel")),
                is_new      = bool(r.field(g, "IsNew")),
                cost        = unlock_costs(r.field(g, "Costs")),
                unlock_type = int(r.field(g, "UnlockType")),
                selected    = (selected_id == id),
            }
            local acq = r.call(_p.m_acquired, c, id)
            if type(acq) == "boolean" then e.acquired = acq end
            local rm = r.singleton("app.ReinforceManager")
            e.raw_level = rm and (int(r.call(_p.m_level, rm, e.data_id or id))
                                  or int(r.call(_p.m_level, rm, id))) or nil
            -- A secret entry stays nameless, as on screen.
            if state ~= "Secret" then
                e.name = app_text(r.field(g, "TxtName")) or item_name(id)
                e.description, e.level_texts = reinforce_text(rd, e.level_max)
                if e.description == nil and e.selected then e.description = selected_text end
            end
            e.name = e.name or "???"
            settle(e)
            out.entries[#out.entries + 1] = e
        end
    end
    return out
end

-- Just the printer's current tab, cheaply (for the per-tab cache).
function M.printer_tab()
    local c = gui.control(M.CODES.printer)
    if c == nil then return nil end
    return enum_name(T_TAB, call(r.field(c, "Tab"), "get_SelectedCategory"))
end

-- Calibration learned from the visible grid.
local _unlock_type_of = {}      -- id -> GridInfo.UnlockType
local _unlock_type_votes = {}
local _offset_votes = {}        -- menu level - engine level -> count
local _max_offset_votes = {}
local _calibrated = {}          -- id -> true, so one unit votes once

local function vote(t, k) if k ~= nil then t[k] = (t[k] or 0) + 1 end end
local function winner(t, default)
    local best, n = default, 0
    for k, c in pairs(t) do if c > n then best, n = k, c end end
    return best
end

local function enum_value(type_name, name)
    for v, n in pairs(r.enum_value_names(type_name)) do if n == name then return v end end
    return nil
end

local function calibrate(grid)
    local rm = r.singleton("app.ReinforceManager")
    for _, e in ipairs(grid.entries) do
        if e.unlock_type ~= nil and _unlock_type_of[e.id] == nil then
            _unlock_type_of[e.id] = e.unlock_type
            vote(_unlock_type_votes, e.unlock_type)
        end
        if e.acquired == true and rm ~= nil and not _calibrated[e.id] then
            _calibrated[e.id] = true
            local lv = int(r.call(_p.m_level, rm, e.id))
            local mx = int(r.call(_p.m_level_max, rm, e.id))
            if lv ~= nil and e.level ~= nil then vote(_offset_votes, e.level - lv) end
            if mx ~= nil and e.level_max ~= nil then vote(_max_offset_votes, e.level_max - mx) end
        end
    end
end

-- Every printer unit the game data knows: {{ id, tab, rd, item }}, from the
-- item list first (the game's own order), then the data table's extras.
local function candidates(gdm)
    local out, by_id = {}, {}
    local function add(id, tab, rd, item, source)
        if id == nil or id == 0 then return end
        local cand = by_id[id]
        if cand == nil then
            cand = { id = id, sources = {} }
            by_id[id] = cand
            out[#out + 1] = cand
        end
        cand.tab = cand.tab or tab
        cand.rd = cand.rd or rd
        cand.item = cand.item or item
        cand.sources[source] = true
    end
    for _, rd in ipairs(r.elements(r.call(_p.m_items, gdm))) do
        add(int(call(rd, "get_ID")), enum_name(T_TAB, call(rd, "get_ReinforceType")), rd, nil, "list")
    end
    for _, kv in ipairs(r.dict_pairs(r.field(gdm, "_ReinforceDataTable"))) do
        local v = kv.value
        add(int(kv.key), enum_name(T_TAB, r.field(v, "ReinforceType")), nil, r.field(v, "Item"), "table")
    end
    return out, by_id
end

-- One entry rebuilt from game data, in the same shape as printer()'s.
local function rebuild(c, rm, cand)
    local id = cand.id
    local unlock_type = _unlock_type_of[id] or winner(_unlock_type_votes, 0)
    local raw = int(r.call(_p.m_level, rm, id)) or 0
    local raw_max = int(r.call(_p.m_level_max, rm, id))
    -- The level argument: the current engine level answered "Hide" for every
    -- unit at engine level 0 that the grid shows (Heat, Auto-hacking, ...,
    -- 2026-10-05), so a Hide is re-asked for the next level before it counts.
    local hide = enum_name("app.ReinforceHideType", r.call(_p.m_hide, rm, id, unlock_type, raw))
    if hide == "Hide" then
        hide = enum_name("app.ReinforceHideType", r.call(_p.m_hide, rm, id, unlock_type, raw + 1))
    end
    local acq = r.call(_p.m_acquired, c, id)
    -- A printed unit is always listed. Units whose only level is 1 (the
    -- hacking modes, the scans, 2026-10-05) answer Hide for both levels asked.
    if hide == "Hide" and not is_printed(acq, raw) then return nil end

    local e = {
        id = id, raw_level = raw, unlock_type = unlock_type, hide = hide, from_data = true,
        level = raw + winner(_offset_votes, 0),
        level_max = raw_max and (raw_max + winner(_max_offset_votes, 0)) or nil,
    }
    if type(acq) == "boolean" then e.acquired = acq end

    local maxed = is_printed(e.acquired, raw) and e.level_max ~= nil and e.level >= e.level_max
    if hide == "Secret" and not is_printed(e.acquired, raw) then
        e.state_raw, e.cost = "Secret", {}
    elseif maxed then
        e.state_raw, e.cost = "Unlocked", {}
    else
        local enable = enum_value(T_STATE, "UnlockEnable") or 0
        e.cost = unlock_costs(r.call(_p.m_cost, c, id, unlock_type, enable))
        e.state_raw = affordable(e.cost) and "UnlockEnable" or "UnlockDisable"
    end

    local src = cand.rd or cand.item
    if e.state_raw ~= "Secret" then
        e.name = source_name(cand.rd) or source_name(cand.item) or item_name(id)
        e.description, e.level_texts = reinforce_text(src, e.level_max)
        if e.description == nil and cand.rd ~= nil and cand.item ~= nil then
            e.description = (reinforce_text(cand.item, e.level_max))
        end
    end
    e.name = e.name or "???"
    settle(e)
    return e
end

-- What a Unit Printer unit does, by its id or, failing that, its name -- for
-- pragmata_status's equipped-weapon lines, read anywhere (no menu open).
-- Built from the same game data the printer's off-screen tabs are rebuilt
-- from (candidates above), once per session after it first reads non-empty:
-- the text is static. By name too, because a printer unit's id can differ
-- from the id the weapon itself is known by (GridInfo.ObjectId vs the
-- ReinforceData id). Nil when neither answers.
local _unit_desc = nil      -- { by_id = {}, by_name = {} }

local function unit_desc_table()
    if _unit_desc ~= nil then return _unit_desc end
    printer_init()
    local gdm = r.singleton("app.GuiDataManager")
    if gdm == nil then return nil end
    local by_id, by_name, n = {}, {}, 0
    for _, cand in ipairs((candidates(gdm))) do
        local src = cand.rd or cand.item
        local desc = (reinforce_text(src)) or (cand.item and (reinforce_text(cand.item)))
        if desc ~= nil and desc ~= "" then
            by_id[cand.id] = desc
            local name = source_name(src) or (cand.item and source_name(cand.item))
            if name ~= nil then by_name[name] = desc end
            n = n + 1
        end
    end
    if n == 0 then return nil end   -- data not loaded yet: try again later
    _unit_desc = { by_id = by_id, by_name = by_name }
    return _unit_desc
end

function M.unit_description(id, name)
    local ok, t = pcall(unit_desc_table)
    if not ok or t == nil then return nil end
    return (id ~= nil and t.by_id[id]) or (name ~= nil and t.by_name[name]) or nil
end

-- { tab = <visible tab>, tabs = {{ tab, entries, from_data }} }: the visible
-- tab read from the grid, every other tab rebuilt from game data.
function M.printer_all()
    local c = gui.control(M.CODES.printer)
    if c == nil then return nil end
    local grid = M.printer()
    if grid == nil then return nil end
    calibrate(grid)

    local out = { tab = grid.tab, tabs = { { tab = grid.tab, entries = grid.entries } } }
    local gdm = r.singleton("app.GuiDataManager")
    local rm = r.singleton("app.ReinforceManager")
    if gdm == nil or rm == nil then return out end

    local on_grid = {}
    for _, e in ipairs(grid.entries) do
        on_grid[e.id] = true
        if e.data_id ~= nil then on_grid[e.data_id] = true end
    end
    local by_tab, order = {}, {}
    for _, cand in ipairs((candidates(gdm))) do
        local tab = cand.tab
        if tab ~= nil and tab ~= "Invalid" and tab ~= grid.tab and not on_grid[cand.id] then
            local ok, e = pcall(rebuild, c, rm, cand)
            if ok and e ~= nil then
                if by_tab[tab] == nil then by_tab[tab] = {} order[#order + 1] = tab end
                table.insert(by_tab[tab], e)
            end
        end
    end
    for _, tab in ipairs(order) do
        out.tabs[#out.tabs + 1] = { tab = tab, entries = by_tab[tab], from_data = true }
    end
    return out
end

-- Debug: the visible tab rebuilt from game data next to the grid's own rows,
-- one line per unit that differs. Proves the rebuild before it is trusted.
function M.printer_check()
    local c = gui.control(M.CODES.printer)
    if c == nil then return nil end
    local grid = M.printer()
    if grid == nil then return nil end
    calibrate(grid)
    local gdm = r.singleton("app.GuiDataManager")
    local rm = r.singleton("app.ReinforceManager")
    if gdm == nil or rm == nil then return { "managers missing" } end

    local cands, by_id = candidates(gdm)
    local n_list, n_table, per_tab = 0, 0, {}
    for _, cand in ipairs(cands) do
        if cand.sources.list then n_list = n_list + 1 end
        if cand.sources.table then n_table = n_table + 1 end
        per_tab[cand.tab or "?"] = (per_tab[cand.tab or "?"] or 0) + 1
    end
    local tabs = {}
    for t, n in pairs(per_tab) do tabs[#tabs + 1] = t .. "=" .. n end
    table.sort(tabs)
    local lines = {
        string.format("methods: items=%s level=%s hide=%s acquired=%s cost=%s",
            tostring(_p.m_items ~= nil), tostring(_p.m_level ~= nil), tostring(_p.m_hide ~= nil),
            tostring(_p.m_acquired ~= nil), tostring(_p.m_cost ~= nil)),
        string.format("level offset %s, max offset %s, unlock type %s",
            tostring(winner(_offset_votes, "?")), tostring(winner(_max_offset_votes, "?")),
            tostring(winner(_unlock_type_votes, "?"))),
        string.format("data: %d units (list %d, table %d); per tab %s",
            #cands, n_list, n_table, table.concat(tabs, " ")),
    }

    local function costs(list)
        local p = {}
        for _, k in ipairs(list or {}) do p[#p + 1] = k.need .. "x" .. k.item end
        return table.concat(p, "+")
    end
    local function row(e)
        return string.format("%s %s %s/%s %s", e.acquired and "acq" or "-", tostring(e.state_raw),
            tostring(e.level), tostring(e.level_max), costs(e.cost))
    end

    local same, diff = 0, 0
    for _, g in ipairs(grid.entries) do
        local cand = by_id[g.id] or (g.data_id and by_id[g.data_id])
        local e = nil
        if cand ~= nil then
            local ok, v = pcall(rebuild, c, rm, cand)
            e = ok and v or nil
            if not ok then lines[#lines + 1] = g.name .. ": rebuild raised " .. tostring(v) end
        end
        local a, b = row(g), e and row(e) or "(not rebuilt)"
        if a == b then
            same = same + 1
        else
            diff = diff + 1
            lines[#lines + 1] = string.format("%s  grid: %s | data: %s  [id %s, data id %s, data tab %s, cand %s %s, hide %s]",
                g.name, a, b, tostring(g.id), tostring(g.data_id), tostring(g.data_tab),
                cand and "yes" or "no", cand and tostring(cand.tab) or "-", e and tostring(e.hide) or "-")
        end
    end
    table.insert(lines, 4, string.format("tab %s: %d match, %d differ", tostring(grid.tab), same, diff))
    return lines
end


-- ---------------------------------------------------------------------------
-- Mod terminal
-- ---------------------------------------------------------------------------

-- { capacity_current, capacity_total, max_equipped, locked,
--   entries = {{ id, name, cost, equipped, slot, is_new, description }} }
-- capacity_total matched the printer's "Mod Slot" level (6) in the test; all
-- mods cost 1 there.
-- Locked mods are only counted: the menu hides what they are.
function M.mod_terminal()
    local c = gui.control(M.CODES.mod_terminal)
    if c == nil then return nil end
    local out = {
        capacity_current = int(r.field(c, "_CurrentCapacity")),
        capacity_total   = int(r.field(c, "_TotalCapacity")),
        max_equipped     = int(r.field(c, "_MaxEquipNum")),
        locked = 0,
        entries = {},
    }
    local seen = {}
    for _, info in ipairs(r.elements(r.field(c, "_SkillInfoList"))) do
        local p = r.field(info, "<Param>k__BackingField")
        local id = int(r.field(p, "<ID>k__BackingField"))
        if id ~= nil and id ~= 0 and not seen[id] then
            seen[id] = true
            if r.field(p, "<IsUnlock>k__BackingField") ~= true then
                out.locked = out.locked + 1
            else
                local gd = r.field(p, "<GUIData>k__BackingField")
                local slot = int(r.field(p, "<EquipIndex>k__BackingField"))
                out.entries[#out.entries + 1] = {
                    id          = id,
                    name        = (perks and perks.perk_name(id))
                                  or object_names.text(r.field(gd, "_Name")) or "an unnamed mod",
                    cost        = int(call(p, "get_Cost")) or int(call(info, "get_Cost")),
                    equipped    = r.field(p, "<IsEquip>k__BackingField") == true,
                    slot        = (slot ~= nil and slot >= 0) and (slot + 1) or nil,
                    is_new      = bool(r.field(p, "<IsNew>k__BackingField")),
                    description = object_names.text(r.field(gd, "_Description")),
                }
            end
        end
    end
    return out
end

function M.debug_status()
    return {
        firmware_open = gui.is_open(M.CODES.firmware),
        printer_open = gui.is_open(M.CODES.printer),
        mod_terminal_open = gui.is_open(M.CODES.mod_terminal),
    }
end

return M
