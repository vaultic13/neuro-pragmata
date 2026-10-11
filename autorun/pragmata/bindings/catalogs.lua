--
-- Readers for the catalogs: Data Library, Archive, Bot Database, Training
-- Simulations and Earth Memories.
--
-- Unlike the upgrade menus these read the game's DATA, not an open screen, so
-- they answer anywhere in the Shelter. When the matching screen is open it is
-- read too, for a check in the debug panel (and, for Training, the rewards,
-- which only the screen holds).
--
-- Engine layout (il2cpp dump, 2026-10-06; NOT yet confirmed in game):
--
--   Data Library
--     GuiDataManager.getNarrativeCategories() -> NarrativeTextData.Category[]
--       Category { get_CategoryId, get_CategoryName, get_Params() -> Param[],
--                  get_HeaderInfos() -> HeaderInfo { get_HeaderId, get_Name },
--                  get_IsHideView, get_IsTerminalMenu, get_IsPauseMenu,
--                  get_IsTutorial, get_SortNo }
--       Param    { get_IdHash, get_Title, get_Body, get_Pages() -> Page
--                  { get_Body }, get_HeaderId, get_IsIgnoreList, get_SortNo }
--     static GuiUtil.getOpenedNarrativeData(UInt32 categoryId)
--       -> List<Param>: the entries found so far.
--     Screen ui5140._NarrativeMenu (ui5060).CateListCtrl InfoList of
--       CategoryInfo { CategoryId, CategoryName, UnlockNum, UnlockTotalNum }.
--
--   Bot Database
--     FigureDataHolder.getAllAssort() -> FigureDescriptionUnit[]
--       { get_ID, get_FigureNameText, get_DescriptionText,
--         get_OverallLengthText, get_LockDescriptionText, get_IsNewGamePlus }
--     Owned: StateManager.findState(id) -> state bits. WHICH bit means owned
--     is not in the dump; owned = bits ~= 0 until the debug check says
--     otherwise. GuiManager.getFigureNum() is the game's own count.
--     Screen ui5145.DetailListCtrl InfoList of FigureInfo
--       { get_FigureIDHash, get_HasFigure }.
--
--   Training Simulations
--     MissionManager.getShowableUnits() / getSelectableUnits()
--       -> List<MissionUserdata.Unit { ID (ObjectDefine .Hash), NameText,
--          DescText, CategoryHash, Difficulty, IsExtraMission }>
--     MissionManager.isClearedMission(UInt32)
--     MissionManager.get_userdata().get_categoryDefineUnits()
--       -> { Hash, NameText }
--     Screen ui5133._MissionMenuInfo: MissionSelectInfo[] { MissionID,
--       IsLocked, MissionLevel, MissionTimeLimit, _MissionRewardInfos[]
--       { GetItemID, GetItemNum, IsClear, RewardTitle } }.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")

local gui = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.gui_state")
    if ok then gui = mod end
end

local M = {}

M.CODES = { library = "ui5140", bot_database = "ui5145", simulations = "ui5133" }

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

local function text(tmd) return object_names.text(tmd) end

local function infos(ctrl)
    return r.elements(r.field(ctrl, "<InfoList>k__BackingField") or call(ctrl, "get_InfoList"))
end

local function object_hash(def)
    if def == nil then return nil end
    return int(r.field(def, "Hash")) or int(call(def, "get_hash"))
end

local function item_name(id)
    if id == nil then return nil end
    return object_names.display_name(id) or object_names.object_name(id)
end

local _m = nil
local function methods()
    if _m ~= nil then return _m end
    _m = {
        opened_narrative = r.method(r.td("app.GuiUtil"), "getOpenedNarrativeData(System.UInt32)"),
        narrative_params = r.method(r.td("app.GuiDataManager"), "getNarrativeParams(System.UInt32)"),
        item_data = r.method(r.td("app.GuiDataManager"), "getItemData(System.UInt32)"),
        find_state = r.method(r.td("app.StateManager"), "findState(System.UInt32)"),
        is_cleared = r.method(r.td("app.MissionManager"), "isClearedMission(System.UInt32)"),
        earth_acquired = r.method(r.td("app.ItemManager"), "isAcquiredEarthItem(System.UInt32)"),
    }
    return _m
end

-- StateManager bits for an id (figures, narrative entries, ...); nil when
-- unreadable. Which bit means what is not in the dump: the debug checks
-- show the values next to the screens' answers.
local function state_bits(id)
    local sm = r.singleton("app.StateManager")
    if sm == nil or id == nil then return nil end
    return int(r.call(methods().find_state, sm, id))
end

-- ---------------------------------------------------------------------------
-- Data Library (terminal) and Archive (pause menu)
-- ---------------------------------------------------------------------------
--
-- One narrative data set behind both: a category is the Library's when
-- get_IsTerminalMenu, the Archive's when get_IsPauseMenu (the Library screen
-- ui5060 carries IsTerminalMenu = true, 2026-10-06). Hidden categories are
-- skipped.
--
-- Found: the 2026-10-06 test found nothing through
-- GuiUtil.getOpenedNarrativeData alone, so three answers are kept, in order
-- of trust: the screen (CategoryInfo.Infos -> DetailInfo.IsUnlock, remembered
-- for the session once a Library / Archive screen has been open), the
-- GuiUtil list when it has anything for the category, and state bits ~= 0
-- (the rule that held for Bot Database figures).

local function narrative_categories(menu)
    local gdm = r.singleton("app.GuiDataManager")
    local cats = r.elements(call(gdm, "getNarrativeCategories"))
    if #cats == 0 then cats = r.elements(r.field(gdm, "_NarrativeCategoryList")) end
    local out = {}
    for _, c in ipairs(cats) do
        local e = {
            obj = c,
            id = int(call(c, "get_CategoryId")),
            hidden = bool(call(c, "get_IsHideView")),
            terminal = bool(call(c, "get_IsTerminalMenu")),
            pause = bool(call(c, "get_IsPauseMenu")),
            tutorial = bool(call(c, "get_IsTutorial")),
            sort = int(call(c, "get_SortNo")) or 0,
        }
        -- The terminal shows "Secrets", which is flagged hidden (2026-10-06
        -- dump): IsHideView is about the pause menu, so the Library ignores it.
        e.library = e.id ~= nil and e.terminal == true
        e.archive = e.id ~= nil and e.hidden ~= true and e.pause == true
        out[#out + 1] = e
    end
    local shown = {}
    for _, e in ipairs(out) do
        if menu == nil or e[menu] then shown[#shown + 1] = e end
    end
    table.sort(shown, function(a, b) return a.sort < b.sort end)
    return shown, out
end

local function category_params(c)
    local params = r.elements(call(c.obj, "get_Params"))
    if #params == 0 and c.id ~= nil then
        params = r.elements(r.call(methods().narrative_params, r.singleton("app.GuiDataManager"), c.id))
    end
    return params
end

local function opened_ids(category_id)
    local set, n = {}, 0
    if category_id == nil then return set, n end
    local list = r.call(methods().opened_narrative, nil, category_id)
    for _, p in ipairs(r.elements(list)) do
        local id = int(call(p, "get_IdHash"))
        if id ~= nil then set[id] = true n = n + 1 end
    end
    return set, n
end

-- Screen answers per entry id, for the session.
local _narrative_screen = {}

-- Library ui5140._NarrativeMenu, or a ui5060 opened on its own (the pause
-- menu's Archive, if that is how it opens).
local function narrative_screens()
    local out = {}
    if gui == nil then return out end
    local lib = r.field(gui.control(M.CODES.library), "_NarrativeMenu")
    if lib ~= nil then out[#out + 1] = lib end
    local own = gui.control("ui5060")
    if own ~= nil then out[#out + 1] = own end
    return out
end

local function read_narrative_screens()
    local any = false
    for _, screen in ipairs(narrative_screens()) do
        for _, ci in ipairs(infos(r.field(screen, "CateListCtrl"))) do
            for _, di in ipairs(r.elements(r.field(ci, "Infos"))) do
                if bool(r.field(di, "IsHeader")) ~= true then
                    local id = int(r.field(di, "IdHash"))
                    local un = bool(r.field(di, "IsUnlock"))
                    if id ~= nil and un ~= nil then _narrative_screen[id] = un any = true end
                end
            end
        end
    end
    return any
end

-- found(id) for one category: screen, else GuiUtil (when it lists any), else bits.
local function found_fn(category_id)
    local opened, n = opened_ids(category_id)
    return function(id)
        if id == nil then return false end
        if _narrative_screen[id] ~= nil then return _narrative_screen[id] end
        if n > 0 then return opened[id] == true end
        local bits = state_bits(id)
        return bits ~= nil and bits ~= 0
    end
end

-- Ids of every entry found so far, as { [id] = category id }. For the push.
function M.narrative_ids(menu)
    local out = {}
    for _, c in ipairs((narrative_categories(menu))) do
        local found = found_fn(c.id)
        for _, p in ipairs(category_params(c)) do
            local id = int(call(p, "get_IdHash"))
            if bool(call(p, "get_IsIgnoreList")) ~= true and found(id) then out[id] = c.id end
        end
    end
    return out
end

-- { categories = { { id, name, found, total, entries = { { id, title,
--   group, body, pages = {...} } } } } } -- only found entries carry text.
-- with_text = false skips bodies (the list action).
function M.narrative(menu, with_text)
    read_narrative_screens()
    local shown = narrative_categories(menu)
    if #shown == 0 then return nil end
    local cats = {}
    for _, c in ipairs(shown) do
        local found = found_fn(c.id)
        local headers = {}
        for _, h in ipairs(r.elements(call(c.obj, "get_HeaderInfos"))) do
            local hid = int(call(h, "get_HeaderId"))
            if hid ~= nil then headers[hid] = text(call(h, "get_Name")) end
        end
        local cat = { id = c.id, name = text(call(c.obj, "get_CategoryName")),
                      found = 0, total = 0, entries = {} }
        for _, p in ipairs(category_params(c)) do
            if bool(call(p, "get_IsIgnoreList")) ~= true then
                cat.total = cat.total + 1
                local id = int(call(p, "get_IdHash"))
                if found(id) then
                    cat.found = cat.found + 1
                    local e = {
                        id = id,
                        title = text(call(p, "get_Title")),
                        group = headers[int(call(p, "get_HeaderId")) or -1],
                        sort = int(call(p, "get_SortNo")) or 0,
                        category = cat.name,
                    }
                    if with_text ~= false then
                        e.body = text(call(p, "get_Body"))
                        e.pages = {}
                        for _, pg in ipairs(r.elements(call(p, "get_Pages"))) do
                            local t = text(call(pg, "get_Body"))
                            if t ~= nil then e.pages[#e.pages + 1] = t end
                        end
                    end
                    cat.entries[#cat.entries + 1] = e
                end
            end
        end
        table.sort(cat.entries, function(a, b) return a.sort < b.sort end)
        -- As the screens do: no empty categories (Archive "Help" 0/0), and the
        -- terminal hides a category with nothing found ("Artwork" 0/75).
        if cat.total > 0 and (menu ~= "library" or cat.found > 0) then cats[#cats + 1] = cat end
    end
    return { categories = cats }
end

function M.library(with_text) return M.narrative("library", with_text) end
function M.library_ids() return M.narrative_ids("library") end
function M.archive(with_text) return M.narrative("archive", with_text) end
function M.archive_ids() return M.narrative_ids("archive") end

-- Debug: every category with its flags and the three "found" answers, and
-- the open screen's own counts.
function M.narrative_check()
    local screen_now = read_narrative_screens()
    local _, all = narrative_categories(nil)
    local lines = {}
    for _, c in ipairs(all) do
        local params = category_params(c)
        local _, n_opened = opened_ids(c.id)
        local n_bits, n_screen, n_screen_seen = 0, 0, 0
        for _, p in ipairs(params) do
            local id = int(call(p, "get_IdHash"))
            local bits = state_bits(id)
            if bits ~= nil and bits ~= 0 then n_bits = n_bits + 1 end
            if id ~= nil and _narrative_screen[id] ~= nil then
                n_screen_seen = n_screen_seen + 1
                if _narrative_screen[id] then n_screen = n_screen + 1 end
            end
        end
        lines[#lines + 1] = string.format("cat %s '%s' library=%s archive=%s (hidden=%s terminal=%s pause=%s tutorial=%s) params=%d | found: GuiUtil=%d bits~=0=%d screen=%d of %d seen",
            tostring(c.id), tostring(text(call(c.obj, "get_CategoryName"))), tostring(c.library), tostring(c.archive),
            tostring(c.hidden), tostring(c.terminal), tostring(c.pause), tostring(c.tutorial), #params,
            n_opened, n_bits, n_screen, n_screen_seen)
    end
    local gm = r.singleton("app.GuiManager")
    lines[#lines + 1] = string.format("categories=%d  GuiManager.getNarrativeDataNum=%s  screen read now=%s",
        #all, tostring(int(call(gm, "getNarrativeDataNum"))), tostring(screen_now))
    for _, screen in ipairs(narrative_screens()) do
        lines[#lines + 1] = string.format("Screen (IsTerminalMenu=%s IsPauseMenu=%s):",
            tostring(r.field(screen, "IsTerminalMenu")), tostring(r.field(screen, "IsPauseMenu")))
        for _, ci in ipairs(infos(r.field(screen, "CateListCtrl"))) do
            local rows, unl = 0, 0
            for _, di in ipairs(r.elements(r.field(ci, "Infos"))) do
                if bool(r.field(di, "IsHeader")) ~= true then
                    rows = rows + 1
                    if bool(r.field(di, "IsUnlock")) then unl = unl + 1 end
                end
            end
            lines[#lines + 1] = string.format("  cat %s '%s' %s/%s; rows %d, IsUnlock %d",
                tostring(int(r.field(ci, "CategoryId"))), tostring(text(r.field(ci, "CategoryName"))),
                tostring(int(r.field(ci, "UnlockNum"))), tostring(int(r.field(ci, "UnlockTotalNum"))), rows, unl)
        end
    end
    return lines
end
M.library_check = M.narrative_check
M.archive_check = M.narrative_check

-- ---------------------------------------------------------------------------
-- Bot Database
-- ---------------------------------------------------------------------------

-- The open screen's answer per figure id, kept for the session: it is the
-- authority the state-bit guess is checked against.
local _screen_has = {}

local function read_figure_screen()
    if gui == nil then return false end
    local ui = gui.control(M.CODES.bot_database)
    if ui == nil then return false end
    local any = false
    for _, fi in ipairs(infos(r.field(ui, "DetailListCtrl"))) do
        local id = int(call(fi, "get_FigureIDHash"))
        local has = bool(call(fi, "get_HasFigure"))
        if id ~= nil and has ~= nil then _screen_has[id] = has any = true end
    end
    return any
end

local function figure_owned(id, bits)
    if _screen_has[id] ~= nil then return _screen_has[id] end
    if bits == nil then return nil end
    return bits ~= 0
end

local function figure_units()
    local holder = r.singleton("app.FigureDataHolder")
    return r.elements(call(holder, "getAllAssort"))
end

function M.bot_database_ids()
    local out = {}
    for _, u in ipairs(figure_units()) do
        local id = int(call(u, "get_ID"))
        if id ~= nil and figure_owned(id, state_bits(id)) == true then out[id] = true end
    end
    return out
end

-- { entries = { { id, name, owned, description, length, lock_text } } }
function M.bot_database()
    read_figure_screen()
    local units = figure_units()
    if #units == 0 then return nil end
    local out = { entries = {} }
    for _, u in ipairs(units) do
        local id = int(call(u, "get_ID"))
        local bits = state_bits(id)
        local e = {
            id = id,
            bits = bits,
            owned = figure_owned(id, bits),
            name = text(call(u, "get_FigureNameText")),
            description = text(call(u, "get_DescriptionText")),
            length = text(call(u, "get_OverallLengthText")),
            lock_text = text(call(u, "get_LockDescriptionText")),
            new_game_plus = bool(call(u, "get_IsNewGamePlus")),
        }
        out.entries[#out.entries + 1] = e
    end
    return out
end

-- Debug: per-figure state bits against the screen, and the game's count.
function M.bot_database_check()
    local screen = read_figure_screen()
    local lines = {}
    local gm = r.singleton("app.GuiManager")
    local by_bits, guess_owned, differ = {}, 0, 0
    for _, u in ipairs(figure_units()) do
        local id = int(call(u, "get_ID"))
        local bits = state_bits(id)
        local guess = bits ~= nil and bits ~= 0
        if guess then guess_owned = guess_owned + 1 end
        local sh = _screen_has[id]
        if sh ~= nil and sh ~= guess then differ = differ + 1 end
        local key = tostring(bits)
        by_bits[key] = (by_bits[key] or 0) + 1
        lines[#lines + 1] = string.format("  %s '%s' bits=%s screen=%s",
            tostring(id), tostring(text(call(u, "get_FigureNameText"))), key, tostring(sh))
    end
    local dist = {}
    for k, n in pairs(by_bits) do dist[#dist + 1] = k .. ":" .. n end
    table.sort(dist)
    table.insert(lines, 1, string.format("figures=%d  bits~=0: %d  GuiManager.getFigureNum=%s  screen read now=%s  screen-vs-bits differ=%d  bits histogram %s",
        #lines, guess_owned, tostring(int(call(gm, "getFigureNum"))), tostring(screen), differ, table.concat(dist, " ")))
    return lines
end

-- ---------------------------------------------------------------------------
-- Training Simulations
-- ---------------------------------------------------------------------------

-- What only the screen holds (rewards, time limit, level), kept for the
-- session by mission id once the Training tab has been open.
local _mission_screen = {}

local function read_mission_screen()
    if gui == nil then return false end
    local ui = gui.control(M.CODES.simulations)
    if ui == nil then return false end
    local any = false
    for _, si in ipairs(r.elements(r.field(ui, "_MissionMenuInfo"))) do
        local id = int(r.field(si, "MissionID"))
        if id ~= nil and id ~= 0 then
            local rewards = {}
            for _, ri in ipairs(r.elements(r.field(si, "_MissionRewardInfos"))) do
                local item = int(r.field(ri, "GetItemID"))
                rewards[#rewards + 1] = {
                    title = text(r.field(ri, "RewardTitle")),
                    item = item and item ~= 0 and item_name(item) or nil,
                    count = int(r.field(ri, "GetItemNum")),
                    done = bool(r.field(ri, "IsClear")),
                }
            end
            local info = r.field(si, "_MissionInfo")
            local rules = {}
            for _, t in ipairs(r.elements(r.field(info, "_SpecialRuleArray"))) do
                local s = text(t)
                if s ~= nil then rules[#rules + 1] = s end
            end
            _mission_screen[id] = {
                locked = bool(r.field(si, "IsLocked")),
                level = int(r.field(si, "MissionLevel")),
                time_limit = r.to_float(r.field(si, "MissionTimeLimit")),
                rewards = rewards,
                rules = rules,
            }
            any = true
        end
    end
    return any
end

local function mission_manager() return r.singleton("app.MissionManager") end

local function unit_id(u)
    return object_hash(r.field(u, "ID") or call(u, "get_id"))
end

local function is_cleared(mm, id)
    if mm == nil or id == nil then return nil end
    return bool(r.call(methods().is_cleared, mm, id))
end

-- Why a mission is not one of the Training Simulations, or nil. Extra
-- missions (the event ones) are not run from the Training tab, and an
-- unnamed one is not shown there (user test 2026-10-06). NOT IsNewGamePlus:
-- every real Training Simulation carries it.
local function skip_reason(u)
    if bool(r.field(u, "IsExtraMission")) == true then return "extra" end
    local name = text(r.field(u, "NameText"))
    if name == nil or name:match("^%s*$") then return "unnamed" end
    return nil
end

function M.simulation_ids()
    local out = {}
    for _, u in ipairs(r.elements(call(mission_manager(), "getSelectableUnits"))) do
        local id = unit_id(u)
        if id ~= nil and skip_reason(u) == nil then out[id] = true end
    end
    return out
end

-- { entries = { { id, name, description, category, available, cleared,
--   extra, skip, screen = {...} or nil } } } -- `skip` set (a reason) on
-- missions that are not Training Simulations; the actions leave them out.
function M.simulations()
    read_mission_screen()
    local mm = mission_manager()
    if mm == nil then return nil end
    local selectable = {}
    for _, u in ipairs(r.elements(call(mm, "getSelectableUnits"))) do
        local id = unit_id(u)
        if id ~= nil then selectable[id] = true end
    end
    local cat_names = {}
    local ud = call(mm, "get_userdata")
    for _, c in ipairs(r.elements(call(ud, "get_categoryDefineUnits"))) do
        local h = int(r.field(c, "Hash"))
        if h ~= nil then cat_names[h] = text(r.field(c, "NameText")) end
    end
    local out = { entries = {} }
    local seen = {}
    local function add(u)
        local id = unit_id(u)
        if id == nil or seen[id] then return end
        seen[id] = true
        out.entries[#out.entries + 1] = {
            id = id,
            name = text(r.field(u, "NameText")),
            description = text(r.field(u, "DescText")),
            category = cat_names[int(r.field(u, "CategoryHash")) or -1],
            available = selectable[id] == true,
            cleared = is_cleared(mm, id),
            extra = bool(r.field(u, "IsExtraMission")),
            new_game_plus = bool(r.field(u, "IsNewGamePlus")),
            skip = skip_reason(u),
            difficulty = int(r.field(u, "Difficulty")),
            screen = _mission_screen[id],
        }
    end
    for _, u in ipairs(r.elements(call(mm, "getShowableUnits"))) do add(u) end
    for _, u in ipairs(r.elements(call(mm, "getSelectableUnits"))) do add(u) end
    if #out.entries == 0 then return nil end
    return out
end

-- Debug: the manager's view against the open screen.
function M.simulations_check()
    local screen = read_mission_screen()
    local s = M.simulations()
    local lines = {}
    local gm = r.singleton("app.GuiManager")
    lines[#lines + 1] = string.format("entries=%d  GuiManager.getMissionNum=%s  screen read now=%s",
        s and #s.entries or 0, tostring(int(call(gm, "getMissionNum"))), tostring(screen))
    for _, e in ipairs(s and s.entries or {}) do
        local sc = e.screen
        lines[#lines + 1] = string.format("  %s '%s' skip=%s cat=%s available=%s cleared=%s extra=%s ng+=%s diff=%s | screen locked=%s level=%s rewards=%s",
            tostring(e.id), tostring(e.name), tostring(e.skip), tostring(e.category), tostring(e.available),
            tostring(e.cleared), tostring(e.extra), tostring(e.new_game_plus), tostring(e.difficulty), tostring(sc and sc.locked), tostring(sc and sc.level),
            tostring(sc and #sc.rewards))
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Earth Memories (the Rem Replicators)
-- ---------------------------------------------------------------------------
--
-- Earth items Hugh gives Diana in the Shelter; each is placed there with a
-- cutscene. They come in groups. (il2cpp dump, 2026-10-06; not yet confirmed.)
--
--   CharacterManager.getPartnerHandle().get_Updater()   app.Ch05000Updater
--     ._SafeRoomTalkDriver   Ch05000SafeRoomTalkDriver (Diana in the Shelter)
--       ._GiftInfos      Ch05000GiftInfo[] { _ItemID, _CategoryType
--                        (EarthItemCategoryTypeSelector), _GiftItemID / Num }
--       ._GiftCompInfos  Ch05000GiftCompInfo[] { get_CategoryType(),
--                        get_ItemIDs() } -- one per group
--   ItemManager
--     isAcquiredEarthItem(UInt32)
--     _EarthItems  Dictionary<UInt32, EarthItem { <ItemID>, <PropDriver> }>:
--                  the earth-item props in the loaded scene; the prop's
--                  EarthItemPropDriver._IsPrintComp = printed by a Replicator
--     _PlayedEventEarthItems  List<UInt32> -- NOT placement: it changed for
--                  one item mid-session with nothing placed (2026-10-06)
--     _EarthItemStateUnits    List<StateManager.Unit { Hash, StateBits }>
--   Names: GuiDataManager.getItemData(id)._UIPageData[1].Header ("Globe",
--   "CRT TV"); the display-name route gives only "It10010". An item without
--   one (It10000) is not a Replicator item and is left out.
--
-- Owned = acquired or held. Placed = a printed prop of it is in the scene
-- (all 16 owned read placed with everything placed, 2026-10-06; the "none
-- placed" case is not yet checked). Only readable in the Shelter.

local inventory = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.inventory")
    if ok then inventory = mod end
end

local function talk_driver()
    local cm = r.singleton("app.CharacterManager")
    local upd = call(call(cm, "getPartnerHandle"), "get_Updater")
    return r.field(upd, "_SafeRoomTalkDriver") or call(upd, "get_SafeRoomTalkDriver")
end

local function selector_hash(sel)
    if sel == nil then return nil end
    if type(sel) == "number" then return sel end
    return int(r.field(sel, "_TypeSelectHash")) or int(call(sel, "get_typeSelectHash"))
end

local function earth_state()
    local im = r.singleton("app.ItemManager")
    local played = {}
    for _, id in ipairs(r.numbers(r.field(im, "_PlayedEventEarthItems"))) do played[id] = true end
    local bits = {}
    for _, u in ipairs(r.elements(r.field(im, "_EarthItemStateUnits"))) do
        local h = int(r.field(u, "Hash"))
        if h ~= nil then bits[h] = int(r.field(u, "StateBits")) end
    end
    local printed = {}
    for _, kv in ipairs(r.dict_pairs(r.field(im, "_EarthItems"))) do
        local ei = kv.value
        local id = int(r.field(ei, "<ItemID>k__BackingField")) or int(kv.key)
        local drv = r.field(ei, "<PropDriver>k__BackingField")
        if id ~= nil and bool(r.field(drv, "_IsPrintComp")) == true then printed[id] = true end
    end
    return im, played, bits, printed
end

local function item_page(id)
    local data = r.call(methods().item_data, r.singleton("app.GuiDataManager"), id)
    return r.elements(r.field(data, "_UIPageData"))
end

local function memory_name(id)
    for _, page in ipairs(item_page(id)) do
        local h = text(r.field(page, "<Header>k__BackingField"))
        if h ~= nil then return h end
    end
    return nil
end

local function held(id)
    if inventory == nil or id == nil then return nil end
    local ok, n = pcall(inventory.quantity, id)
    return ok and n or nil
end

local function item_text(id)
    for _, page in ipairs(item_page(id)) do
        local d = text(r.field(page, "<Description>k__BackingField"))
        if d ~= nil then return d end
    end
    return nil
end

-- { groups = { { index, kind, total, owned, placed, entries = { ... } } },
--   driver = bool } -- every item, owned or not; the actions name only owned.
function M.earth_memories(with_text)
    local driver = talk_driver()
    local im, played, bits, printed = earth_state()
    local groups, group_of, order = {}, {}, {}
    for i, comp in ipairs(r.elements(r.field(driver, "_GiftCompInfos"))) do
        local g = { index = i, kind = r.enum_name("app.EarthItemCategoryType",
                        int(call(comp, "get_CategoryType")) or selector_hash(r.field(comp, "_CategoryType"))),
                    entries = {} }
        groups[#groups + 1] = g
        for _, id in ipairs(r.numbers(call(comp, "get_ItemIDs") or r.field(comp, "_ItemIDs"))) do
            if group_of[id] == nil then group_of[id] = g order[#order + 1] = id end
        end
    end
    for _, gi in ipairs(r.elements(r.field(driver, "_GiftInfos") or call(driver, "get_GiftInfos"))) do
        local id = int(r.field(gi, "_ItemID"))
        if id ~= nil and id ~= 0 and group_of[id] == nil then group_of[id] = false order[#order + 1] = id end
    end
    -- Without Diana's driver (outside the Shelter) the state list still
    -- names every earth item, ungrouped.
    for h in pairs(bits) do
        if group_of[h] == nil then group_of[h] = false order[#order + 1] = h end
    end
    if #order == 0 then return nil end
    local loose = { index = #groups + 1, entries = {} }
    local skipped = {}
    for _, id in ipairs(order) do
        local acquired = bool(r.call(methods().earth_acquired, im, id))
        local n = held(id)
        local e = {
            id = id,
            name = memory_name(id),
            internal = item_name(id),
            acquired = acquired,
            placed = printed[id] == true,
            played = played[id] == true,
            held = n,
            bits = bits[id],
        }
        e.owned = acquired == true or e.placed or (n ~= nil and n > 0)
        if e.name == nil then
            skipped[#skipped + 1] = e
        else
            if with_text ~= false and e.owned then e.description = item_text(id) end
            local g = group_of[id] or loose
            g.entries[#g.entries + 1] = e
        end
    end
    if #loose.entries > 0 then groups[#groups + 1] = loose end
    -- Drop groups left empty by the unnamed items, and number the rest.
    local kept = {}
    for _, g in ipairs(groups) do
        if #g.entries > 0 then kept[#kept + 1] = g g.index = #kept end
    end
    groups = kept
    for _, g in ipairs(groups) do
        g.total, g.owned, g.placed = #g.entries, 0, 0
        for _, e in ipairs(g.entries) do
            if e.owned then g.owned = g.owned + 1 end
            if e.placed then g.placed = g.placed + 1 end
        end
    end
    return { groups = groups, skipped = skipped, driver = driver ~= nil,
             grouped = #groups > (#loose.entries > 0 and 1 or 0) }
end

function M.earth_memory_ids()
    local m = M.earth_memories(false)
    local owned, placed = {}, {}
    for _, g in ipairs(m and m.groups or {}) do
        for _, e in ipairs(g.entries) do
            if e.owned then owned[e.id] = true end
            if e.placed then placed[e.id] = true end
        end
    end
    return owned, placed
end
function M.earth_owned_ids() return (M.earth_memory_ids()) end
function M.earth_placed_ids() local _, p = M.earth_memory_ids() return p end

-- Debug: every item with all four readings.
function M.earth_memories_check()
    local m = M.earth_memories(false)
    if m == nil then return { "no earth items read (driver and state list both empty)" } end
    local lines = { string.format("Diana's Shelter driver read=%s  groups=%d", tostring(m.driver), #m.groups) }
    -- Other "placed" candidates: the earth-item props registered in the
    -- loaded scene, and whether the Replicator finished printing each.
    local im = r.singleton("app.ItemManager")
    local props = {}
    for _, kv in ipairs(r.dict_pairs(r.field(im, "_EarthItems"))) do
        local ei = kv.value
        local drv = r.field(ei, "<PropDriver>k__BackingField")
        local id = int(r.field(ei, "<ItemID>k__BackingField")) or int(kv.key)
        if id ~= nil then
            props[id] = string.format("prop(key=%s print_comp=%s valid=%s item_hash=%s)",
                tostring(int(kv.key)), tostring(r.field(drv, "_IsPrintComp")),
                tostring(call(drv, "get_Valid")), tostring(int(call(drv, "get_ItemHash"))))
        end
    end
    local np = 0
    for _ in pairs(props) do np = np + 1 end
    lines[#lines + 1] = string.format("earth-item props in the scene: %d", np)
    local function line(e)
        return string.format("  %s '%s' (%s) acquired=%s held=%s bits=%s played=%s %s -> owned=%s placed=%s",
            tostring(e.id), tostring(e.name), tostring(e.internal), tostring(e.acquired), tostring(e.held),
            tostring(e.bits), tostring(e.played), props[e.id] or "no prop", tostring(e.owned), tostring(e.placed))
    end
    for _, g in ipairs(m.groups) do
        lines[#lines + 1] = string.format("group %d (%s): %d items, owned %d, placed %d",
            g.index, tostring(g.kind), g.total, g.owned, g.placed)
        for _, e in ipairs(g.entries) do lines[#lines + 1] = line(e) end
    end
    if #m.skipped > 0 then
        lines[#lines + 1] = "left out (no name):"
        for _, e in ipairs(m.skipped) do lines[#lines + 1] = line(e) end
    end
    return lines
end

-- Screen-held facts are kept per session; a new game or load may change
-- them, so the observer drops them when the world unloads.
function M.forget_screens()
    _screen_has, _mission_screen, _narrative_screen = {}, {}, {}
end

-- Keep the screen caches warm while a catalog screen is open (called by the
-- catalog observer a few times a second).
function M.tick_screens()
    if gui == nil then return end
    if gui.is_open(M.CODES.bot_database) == true then read_figure_screen() end
    if gui.reachable(M.CODES.simulations) == true then read_mission_screen() end
    if gui.is_open(M.CODES.library) == true or gui.is_open("ui5060") == true then read_narrative_screens() end
end

log.info("catalogs: loaded")

return M
