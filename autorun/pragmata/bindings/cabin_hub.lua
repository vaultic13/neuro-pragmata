--
-- Which tab of the Cabin hub is selected: the Stamp Club or Training
-- Simulations. Both live on one screen (app.gui.ui5136), so the screen bitset
-- alone cannot tell them apart.
--
-- Engine facts (sdk dump; confirmed in game 2026-10-06):
--   app.gui.ui5136
--     _TabControl  ScrollListController<ui5136.TabInfo>
--                    <InfoList>k__BackingField, <SelectedIndex>k__BackingField
--     TabInfo      { Title, SubTitle (TextMessageData), TabTypeHash (UInt32) }
--     _ShopUI      app.gui.ui5132 (Stamp Club)
--     _MissionUI   app.gui.ui5133 (Training Simulations)
--   app.ConciergeTabType   smart enum; TabTypeHash is one of its members
--                          (static getName(UInt32)).
--
-- selected_tab() tries, in order:
--   1. the selected TabInfo's TabTypeHash, named through ConciergeTabType;
--   2. the selected tab's Title text (English names only).
-- Each step records what it saw in debug_status(), so the panel shows which
-- one answered and the raw values when none did.

local r = require("pragmata.bindings.reflect")

local object_names = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.object_names")
    if ok then object_names = mod end
end

local gui = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.gui_state")
    if ok then gui = mod end
end

local M = {}

M.CODE = "ui5136"

local TAB_ENUM = "app.ConciergeTabType"

-- Words in a tab's enum name or title -> our tab key. Checked lower-case.
local KEYWORDS = {
    { "stamp", "stamps" }, { "shop", "stamps" }, { "bingo", "stamps" },
    { "mission", "simulations" }, { "simulat", "simulations" }, { "training", "simulations" },
}

local _last = { route = "not read yet" }

local function classify(s)
    if type(s) ~= "string" then return nil end
    local low = s:lower()
    for _, kw in ipairs(KEYWORDS) do
        if low:find(kw[1], 1, true) then return kw[2] end
    end
    return nil
end

local function selected_info(hub)
    local ctrl = r.field(hub, "_TabControl")
    if ctrl == nil then return nil, nil end
    local idx = r.to_int(r.field(ctrl, "<SelectedIndex>k__BackingField"))
    if idx == nil then idx = r.to_int(r.safe(function() return ctrl:call("get_SelectedIndex") end)) end
    local list = r.elements(r.field(ctrl, "<InfoList>k__BackingField")
        or r.safe(function() return ctrl:call("get_InfoList") end))
    if idx == nil or idx < 0 then return nil, idx end
    return list[idx + 1], idx
end

-- "stamps", "simulations", or nil when the hub is not open or the tab
-- cannot be read.
function M.selected_tab()
    if gui == nil then return nil end
    local hub = gui.control(M.CODE)
    if hub == nil then _last = { route = "hub not reachable" } return nil end
    local info, idx = selected_info(hub)
    local seen = { index = idx }
    if info ~= nil then
        seen.hash = r.to_int(r.field(info, "TabTypeHash"))
        seen.enum = r.enum_name(TAB_ENUM, seen.hash)
        local tab = classify(seen.enum)
        if tab ~= nil then
            seen.route, seen.tab = "TabTypeHash", tab
            _last = seen
            return tab
        end
        seen.title = object_names and object_names.text(r.field(info, "Title")) or nil
        tab = classify(seen.title)
        if tab ~= nil then
            seen.route, seen.tab = "Title", tab
            _last = seen
            return tab
        end
    end
    seen.route = "no answer"
    _last = seen
    return nil
end

-- The Stamp Club screen object (app.gui.ui5132) while the hub is open.
function M.shop_ui()
    if gui == nil then return nil end
    return r.field(gui.control(M.CODE), "_ShopUI")
end

-- For Pragmata State Debug: what the last selected_tab() saw.
function M.debug_status()
    return {
        route = _last.route,
        tab = _last.tab,
        index = _last.index,
        tab_type_hash = _last.hash,
        tab_type_name = _last.enum,
        title = _last.title,
    }
end

return M
