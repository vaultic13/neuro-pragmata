--
-- Reader for the Stamp Club (the Cabin hub's shop tab): the board on screen,
-- its cells, the line bonuses, Cabin Coins and the other boards.
--
-- Like the Shelter upgrade menus it reads the OPEN screen's object, so it
-- answers only while the Cabin hub is open (gui_state reaches ui5132 through
-- ui5136._ShopUI). Read-only: ui5132.purchase(UInt32) exists and is never
-- called.
--
-- Engine layout (il2cpp dump + State Debug "Menu object", 2026-10-06):
--
--   app.gui.ui5132  Stamp Club screen
--     DispBoardId (UInt32), BoardListIndex
--     _BoardGui  app.gui.InGameShopBoardGridGui
--       BoardSetting  app.InGameShopBoardSetting { get_BoardId, get_Size (Int2),
--                     get_BingoRewardFilament, _BonusSettings[3] }
--       _GridCtrl     ScrollGridController -> InfoList of GridInfo
--                     { BoardId, Index (Int2), TargetId (shop item), SealId,
--                       IsBingo, isUnlocked(), isSealed() }; 9 on a 3x3 board
--       get_SelectedInfo(), <BingoNum> / <BingoMax> (8 / 8 on a 3x3: rows,
--       columns, diagonals)
--     _BonusGui.ListCtrl -> InfoList of ListInfo { HeaderMsg, TargetId,
--                     IsComplete, IsUnlocked, IsLast } (3)
--     _ListGui.ListCtrl  -> InfoList of ListInfo { BoardId, BoardIndex, Setting }
--     _InfoGui    the selected cell's header / body texts
--     BaseMoney   app.gui.ui2075 { ItemId = 701076331 "Cabin Coin", Num }
--     isUnlocked(UInt32), canUnlock()
--   app.InGameShopManager (singleton; ui5132.get__ShopManager())
--     getItemNameText / getItemDescriptionText / getItemBonusText(UInt32)
--     isHideItem(UInt32), getHideNameText / getHideDescriptionText(UInt32)
--     getRewardItemId(UInt32) -> UInt32[], getBoardNameTextMessageData(UInt32)
--
-- Cost: a hidden cell's text reads "Decode it by exchanging a Cabin Coin";
-- the item settings carry no price, so every cell is taken to cost one coin.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local gui = require("pragmata.bindings.gui_state")
local object_names = require("pragmata.bindings.object_names")

local inventory = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.inventory")
    if ok then inventory = mod end
end

local M = {}

M.CODE = "ui5132"
M.COST_PER_CELL = 1

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

local function infos(ctrl)
    return r.elements(r.field(ctrl, "<InfoList>k__BackingField") or call(ctrl, "get_InfoList"))
end

local function text(msg)
    if msg == nil then return nil end
    local t = object_names.text(msg)
    if type(t) ~= "string" or #t == 0 then return nil end
    return t
end

local function app_text(t)
    if t == nil then return nil end
    return text(r.field(t, "_TextMessageData"))
end

local function int2(v)
    if v == nil then return nil, nil end
    return int(r.field(v, "x")), int(r.field(v, "y"))
end

local _m = nil
local function methods()
    if _m ~= nil then return _m end
    local t = r.td("app.InGameShopManager")
    local s = "(System.UInt32)"
    _m = {
        name      = r.method(t, "getItemNameText" .. s),
        desc      = r.method(t, "getItemDescriptionText" .. s),
        bonus     = r.method(t, "getItemBonusText" .. s),
        hide      = r.method(t, "isHideItem" .. s),
        hide_name = r.method(t, "getHideNameText" .. s),
        rewards   = r.method(t, "getRewardItemId" .. s),
        reward_list = r.method(t, "getRewardList" .. s),
        board     = r.method(t, "getBoardNameTextMessageData" .. s),
        screen_unlocked = r.method(r.td("app.gui.ui5132"), "isUnlocked" .. s),
    }
    for k, v in pairs(_m) do
        if v == nil then log.warn("stamp_club: method unresolved: " .. k) end
    end
    return _m
end

local function manager(c)
    return call(c, "get__ShopManager") or r.singleton("app.InGameShopManager")
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

-- ---------------------------------------------------------------------------
-- Cells
-- ---------------------------------------------------------------------------

local function read_cell(g, mgr, m, c, sel_x, sel_y)
    local x, y = int2(r.field(g, "Index"))
    local id = int(r.field(g, "TargetId"))
    local hidden = bool(r.call(m.hide, mgr, id)) == true
    local cell = {
        x = x, y = y, target_id = id, seal_id = int(r.field(g, "SealId")),
        unlocked = bool(call(g, "isUnlocked")),
        sealed = bool(call(g, "isSealed")),
        on_line = bool(r.field(g, "IsBingo")),
        screen_unlocked = bool(r.call(m.screen_unlocked, c, id)),
        hidden = hidden,
        -- Wrappers of one object need not compare equal; the index does.
        selected = (sel_x ~= nil and x == sel_x and y == sel_y) or nil,
    }
    -- isHideItem stays true after a hidden cell is stamped (test 2,
    -- 2026-10-06), so only an unstamped hidden cell keeps its cover name; a
    -- stamped one is named by what it gave, as the screen does.
    cell.hide_name = hidden and text(r.call(m.hide_name, mgr, id)) or nil
    if hidden and cell.unlocked ~= true then
        cell.name = cell.hide_name or "???"
        return cell
    end
    cell.name = text(r.call(m.name, mgr, id)) or item_name(id)
    cell.description = text(r.call(m.desc, mgr, id))
    cell.bonus_text = text(r.call(m.bonus, mgr, id))
    local rewards = {}
    local ids = r.numbers(r.call(m.rewards, mgr, id))
    if #ids == 0 then ids = r.numbers(r.call(m.reward_list, mgr, id)) end
    for _, rid in ipairs(ids) do
        rewards[#rewards + 1] = item_name(rid) or tostring(rid)
    end
    cell.rewards = rewards
    -- A hidden cell's own name may still be the cover; then its rewards are
    -- what it held.
    if hidden and (cell.name == nil or cell.name == cell.hide_name) and #rewards > 0 then
        cell.name = table.concat(rewards, ", ")
    end
    return cell
end

local function cell_order(a, b)
    if (a.y or 0) ~= (b.y or 0) then return (a.y or 0) < (b.y or 0) end
    return (a.x or 0) < (b.x or 0)
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- The board on screen, or nil when the Stamp Club is not reachable:
-- { board_id, name, width, height, cabin_coins, coin_id, cost_per_cell,
--   lines_done, lines_max, line_filament, can_unlock,
--   cells = {{ x, y (0-based), name, hidden, unlocked, on_line, description,
--              bonus_text, rewards, selected, ... }},
--   bonuses = {{ header, reward, kind, earned, lines_needed, whole_board, ... }},
--   boards = {{ id, index, name, available, shown }} }
function M.board()
    local c = gui.control(M.CODE)
    if c == nil then return nil end
    local m = methods()
    local mgr = manager(c)
    local bg = r.field(c, "_BoardGui")
    local setting = r.field(bg, "BoardSetting")

    local out = {
        board_id = int(r.field(c, "DispBoardId")) or int(call(setting, "get_BoardId")),
        lines_done = int(call(bg, "get_BingoNum")) or int(r.field(bg, "<BingoNum>k__BackingField")),
        lines_max = int(call(bg, "get_BingoMax")) or int(r.field(bg, "<BingoMax>k__BackingField")),
        line_filament = int(call(setting, "get_BingoRewardFilament")),
        can_unlock = bool(call(c, "canUnlock")),
        cost_per_cell = M.COST_PER_CELL,
        cells = {}, bonuses = {}, boards = {},
    }
    out.name = app_text(r.field(c, "_TxtBoardName")) or text(r.call(m.board, mgr, out.board_id))
    out.width, out.height = int2(call(setting, "get_Size"))
    if out.width == nil then out.width, out.height = int2(r.field(bg, "_CurrNodeSize")) end

    local money = r.field(c, "BaseMoney")
    out.coin_id = int(r.field(money, "ItemId"))
    out.coin_name = app_text(r.field(money, "TxtName")) or item_name(out.coin_id)
    out.cabin_coins = have(out.coin_id) or int(r.field(money, "Num"))

    local sel_x, sel_y = int2(r.field(call(bg, "get_SelectedInfo"), "Index"))
    for _, g in ipairs(infos(r.field(bg, "_GridCtrl"))) do
        out.cells[#out.cells + 1] = read_cell(g, mgr, m, c, sel_x, sel_y)
    end
    table.sort(out.cells, cell_order)

    local stamped = 0
    for _, cell in ipairs(out.cells) do if cell.unlocked == true then stamped = stamped + 1 end end
    local kinds = {}
    for _, bs in ipairs(r.elements(call(setting, "get_BonusSettings") or r.field(setting, "_BonusSettings"))) do
        local sel = r.field(bs, "_InGameShopBonusKindSelector")
        kinds[#kinds + 1] = r.enum_name("app.InGameShopBonusKind", int(r.field(sel, "_TypeSelectHash"))) or false
    end
    for i, b in ipairs(infos(r.field(r.field(c, "_BonusGui"), "ListCtrl"))) do
        local id = int(r.field(b, "TargetId"))
        local kind = kinds[i] or nil
        local bonus = {
            header = text(r.field(b, "HeaderMsg")) or app_text(r.field(b, "TxtHeader")),
            target_id = id,
            reward = (id ~= nil and id ~= 0) and (text(r.call(m.name, mgr, id)) or item_name(id)) or nil,
            kind = kind,
            -- IsComplete reads true on every bonus once all three are earned
            -- and false on all of them before (test 2): a whole-list flag.
            complete = bool(r.field(b, "IsComplete")),
            unlocked_field = bool(r.field(b, "IsUnlocked")),
            unlocked_call = bool(call(b, "isUnlocked")),
        }
        -- Earned: from the bonus kind and the board's own counts when the kind
        -- is known (Single / Double / Triple lines, Complete = every cell),
        -- else the list entry's isUnlocked().
        local need = ({ Single = 1, Double = 2, Triple = 3 })[kind or ""]
        if need ~= nil and out.lines_done ~= nil then
            bonus.earned, bonus.lines_needed = out.lines_done >= need, need
        elseif kind == "Complete" and #out.cells > 0 then
            bonus.earned, bonus.whole_board = stamped == #out.cells, true
        elseif bonus.unlocked_call ~= nil then
            bonus.earned = bonus.unlocked_call
        else
            bonus.earned = bonus.unlocked_field
        end
        out.bonuses[#out.bonuses + 1] = bonus
    end

    for _, l in ipairs(infos(r.field(r.field(c, "_ListGui"), "ListCtrl"))) do
        local id = int(r.field(l, "BoardId"))
        out.boards[#out.boards + 1] = {
            id = id,
            index = int(r.field(l, "BoardIndex")),
            name = app_text(r.field(l, "TxtName")) or text(r.call(m.board, mgr, id)),
            available = bool(r.call(m.screen_unlocked, c, id)),
            shown = id == out.board_id,
        }
    end
    return out
end

-- For the debug panel: per cell, the three "owned" readings side by side, so
-- the one that matches the screen can be picked.
function M.debug_lines(b)
    local lines = {}
    if b == nil then return { "(Stamp Club not reachable)" } end
    lines[#lines + 1] = string.format("board %s %q  %sx%s  lines %s/%s  coins %s (id %s)  can_unlock %s",
        tostring(b.board_id), tostring(b.name), tostring(b.width), tostring(b.height),
        tostring(b.lines_done), tostring(b.lines_max), tostring(b.cabin_coins),
        tostring(b.coin_id), tostring(b.can_unlock))
    for _, cell in ipairs(b.cells) do
        lines[#lines + 1] = string.format("  (%s,%s) id %s  unlocked %s  sealed %s  screen_unlocked %s  line %s  hidden %s%s  %s",
            tostring(cell.x), tostring(cell.y), tostring(cell.target_id), tostring(cell.unlocked),
            tostring(cell.sealed), tostring(cell.screen_unlocked), tostring(cell.on_line),
            tostring(cell.hidden), cell.selected and "  [selected]" or "", tostring(cell.name))
    end
    for _, bo in ipairs(b.bonuses) do
        lines[#lines + 1] = string.format("  bonus %q -> %s (id %s) kind %s earned %s | IsComplete %s IsUnlocked %s isUnlocked() %s",
            tostring(bo.header), tostring(bo.reward), tostring(bo.target_id), tostring(bo.kind),
            tostring(bo.earned), tostring(bo.complete), tostring(bo.unlocked_field), tostring(bo.unlocked_call))
    end
    for _, bd in ipairs(b.boards) do
        lines[#lines + 1] = string.format("  board #%s %s %q available %s%s",
            tostring(bd.index), tostring(bd.id), tostring(bd.name), tostring(bd.available),
            bd.shown and " [shown]" or "")
    end
    return lines
end

return M
