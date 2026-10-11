--
-- Which game menus (GUI screens) are open.
--
-- Engine facts (il2cpp dump + in-game tests, 2026-09-29):
--   app.GuiTypeHash   smart enum, one member per screen ("ui5100", ...).
--     - static getHashes() -> List<UInt32>, getName(UInt32) -> String
--       The catalog. (Its `<code>Hash` members are literals that get_data
--       cannot read -- the first version knew no hash at all because of it.)
--   app.GuiManager    managed singleton
--     - getGuiTypeBitIndex(System.UInt32 guiTypeHash) -> Int32
--     - getOpenedGuiTypeBits() -> UInt32[]   one bit per open screen
--
-- Test results: the bitset is the one route that tracks screens. isOpen() and
-- hooks on addOpenedGuiList/removeOpenedGuiList never reported anything and
-- were removed. Every screen code the game has starts with "ui".
--
-- The open screen's own object (the menu's data, as the screen shows it):
--   static GuiManager.getGuiBehaviorV2(UInt32 guiTypeHash) -> app.GuiBehaviorV2
--   GuiManager.OpenedGuiDict  Dictionary<UInt32, List<GuiObjectInfo>> (fallback;
--     GuiObjectInfo.GuiBehavior)
--   GuiBehaviorV2.get_Control() -> app.gui.GuiControlV2, i.e. app.gui.ui5120 ...
-- Route found in the dump 2026-10-04; control() is not yet confirmed in game.
--
-- tick() reads the bitset once, turns set bits back into codes through the
-- cached index map, and records open/close transitions in a short latched log,
-- so a screen that is only on for a few frames is still visible afterwards.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")

local M = {}

local _s = { inited = false }

local EVENTS_MAX = 40
local _events = {}              -- newest first: { clock, code, opened }
local _open = nil               -- code -> true, from the last tick; nil before the first

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local gm = r.td("app.GuiManager")
    _s.m_bits = r.method(gm, "getOpenedGuiTypeBits()")
    _s.m_bit_index = r.method(gm, "getGuiTypeBitIndex(System.UInt32)")
    _s.m_behavior = r.method(gm, "getGuiBehaviorV2(System.UInt32)")
    _s.m_get_control = r.method(r.td("app.GuiBehaviorV2"), "get_Control()")
    local t = r.td("app.GuiTypeHash")
    _s.m_hashes = r.method(t, "getHashes()")
    _s.m_name = r.method(t, "getName(System.UInt32)")
    if _s.m_bits == nil or _s.m_bit_index == nil then
        log.warn("gui_state: GuiManager bitset accessors unresolved")
    end
end

-- ---------------------------------------------------------------------------
-- Catalog: code <-> bit index
-- ---------------------------------------------------------------------------

local _code_of_bit = nil        -- bit index -> code
local _bit_of_code = nil        -- code -> bit index
local _hash_of_code = nil       -- code -> GuiTypeHash value

local function load_catalog(gm)
    if _code_of_bit ~= nil then return true end
    local code_of_bit, bit_of_code, hash_of_code, n = {}, {}, {}, 0
    for _, h in ipairs(r.numbers(r.call(_s.m_hashes, nil))) do
        local name = r.call(_s.m_name, nil, h)
        local idx = r.to_int(r.call(_s.m_bit_index, gm, h))
        if type(name) == "string" and #name > 0 and idx ~= nil and idx >= 0 then
            code_of_bit[idx], bit_of_code[name], n = name, idx, n + 1
            hash_of_code[name] = h
        end
    end
    _s.catalog_size = n
    if n == 0 then return false end          -- retry next tick
    _code_of_bit, _bit_of_code, _hash_of_code = code_of_bit, bit_of_code, hash_of_code
    return true
end

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------

local function read_open(gm)
    local words = r.numbers(r.call(_s.m_bits, gm))
    if #words == 0 then return nil end
    local open = {}
    for w, word in ipairs(words) do
        local v = word % 4294967296
        local bit = 0
        while v > 0 and bit < 32 do
            if v % 2 == 1 then
                local idx = (w - 1) * 32 + bit
                open[_code_of_bit[idx] or ("bit" .. idx)] = true
            end
            v = math.floor(v / 2)
            bit = bit + 1
        end
    end
    return open
end

-- Call a few times a second (action_gates does). Cheap: one managed call.
function M.tick()
    ensure_init()
    local gm = r.singleton("app.GuiManager")
    if gm == nil or _s.m_bits == nil then return end
    if not load_catalog(gm) then return end
    local now = read_open(gm)
    if now == nil then return end
    if _open ~= nil then
        local t = os.time()
        for code in pairs(now) do
            if not _open[code] then table.insert(_events, 1, { clock = t, code = code, opened = true }) end
        end
        for code in pairs(_open) do
            if not now[code] then table.insert(_events, 1, { clock = t, code = code, opened = false }) end
        end
        while #_events > EVENTS_MAX do table.remove(_events) end
    end
    _open = now
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- true / false as of the last tick, or nil before the first one.
function M.is_open(code)
    if _open == nil or type(code) ~= "string" then return nil end
    return _open[code] == true
end

-- Codes open as of the last tick, sorted.
function M.open_codes()
    local out = {}
    for code in pairs(_open or {}) do out[#out + 1] = code end
    table.sort(out)
    return out
end

-- Newest-first events for the debug panel: { age, code, opened }.
function M.events()
    local now = os.time()
    local out = {}
    for _, e in ipairs(_events) do
        out[#out + 1] = { age = now - e.clock, code = e.code, opened = e.opened }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The open screen's object
-- ---------------------------------------------------------------------------

-- Which route answered last, for the debug panel.
_s.control_route = "none yet"

local function control_of(behavior)
    if behavior == nil then return nil end
    local c = r.call(_s.m_get_control, behavior)
    if c == nil then c = r.field(behavior, "<_Control>k__BackingField") end
    if c == nil then c = r.field(behavior, "_Control") end
    return c
end

-- Screens that never appear in the bitset themselves: they are fields of a
-- hub screen that is open instead (the Cabin hub holds the Stamp Club and
-- Training Simulations screens).
M.CHILD_SCREENS = {
    ui5132 = { parent = "ui5136", field = "_ShopUI" },     -- Stamp Club
    ui5133 = { parent = "ui5136", field = "_MissionUI" },  -- Training Simulations
}

-- Whether control(code) can answer now: the screen is open, or its hub is.
function M.reachable(code)
    if M.is_open(code) == true then return true end
    local child = M.CHILD_SCREENS[code]
    return child ~= nil and M.is_open(child.parent) == true
end

-- The control object of an open screen (e.g. app.gui.ui5120 for "ui5120"), or
-- nil when that screen is not open or cannot be reached. Never cached: the
-- object is destroyed when the menu closes, so callers ask again each time.
function M.control(code)
    ensure_init()
    local child = M.CHILD_SCREENS[code]
    if child ~= nil and M.is_open(code) ~= true then
        return r.field(M.control(child.parent), child.field)
    end
    if M.is_open(code) ~= true or _hash_of_code == nil then return nil end
    local h = _hash_of_code[code]
    if h == nil then return nil end

    local c = control_of(r.call(_s.m_behavior, nil, h))
    if c ~= nil then _s.control_route = "getGuiBehaviorV2" return c end

    local gm = r.singleton("app.GuiManager")
    local list = r.dict_get(r.field(gm, "OpenedGuiDict"), h)
    for _, info in ipairs(r.elements(list)) do
        c = control_of(r.field(info, "GuiBehavior"))
        if c ~= nil then _s.control_route = "OpenedGuiDict" return c end
    end
    _s.control_route = "failed for " .. code
    return nil
end

-- ---------------------------------------------------------------------------
-- Shape dump (Pragmata State Debug only)
-- ---------------------------------------------------------------------------
--
-- Fields worth looking at on each menu's control, so the readers can be
-- written against what the game really holds rather than the dump's guess.
M.PROBE_FIELDS = {
    ui5120 = { "_UpgradableUnits", "_ui5174", "_Param", "_CurrentPhase",
               "GUI_LEVEL_OFFSET", "GUI_DISPLAY_LEVEL_OFFSET" },
    ui5100 = { "GridCtrl", "Tab", "Status", "OpenParam", "LevelMax" },
    ui5111 = { "_SkillInfoList", "_CategoryTabCtrl", "_TotalCapacity",
               "_CurrentCapacity", "_MaxEquipNum" },
    ui5136 = { "_TabControl", "_CurrentStep" },
    -- Stamp Club (reached through ui5136._ShopUI): where the board, the cells,
    -- their costs and the Cabin Points currency live.
    ui5132 = { "DispBoardId", "BoardListIndex", "_BoardGui", "_BonusGui", "_InfoGui",
               "BaseMoney", "_TxtBoardName", "_TxtBingoNum", "_TxtBingoMax",
               "_TxtBingoBonus", "_CurrentRewardItem" },
    -- Not yet mapped: an empty list dumps every field, unexpanded.
    ui0071 = {},        -- train terminal hub
    ui5112 = {},        -- train weapon selection
    ui5113 = {},        -- train elevator
    -- Train sector selection: the control is an app.gui.ui5110 holding every
    -- sector (bindings/sectors.lua).
    ui5141 = { "StageInfos", "SelectedStageIndex", "HeaderStageId", "UserData5110" },
    -- Catalogs (bindings/catalogs.lua reads their data; these are the
    -- screens it checks against).
    ui5140 = { "_NarrativeMenu" },                         -- Data Library
    ui5145 = { "DetailListCtrl", "Step", "menuData" },     -- Bot Database
    ui5133 = { "_MissionMenuInfo", "_NowSelectionInfo", "_Flow" },  -- Training Simulations (through ui5136._MissionUI)
}

local SHAPE_MAX_LINES = 160

local function type_name(obj)
    return r.safe(function() return obj:get_type_definition():get_full_name() end)
end

local function count_of(obj)
    local n = r.safe(function() return obj:get_size() end)
    if type(n) == "number" then return n end
    return r.to_int(r.safe(function() return obj:call("get_Count") end))
end

-- Declared fields of obj's type and its parents, stopping at engine bases.
local function fields_of(obj)
    local out = {}
    local t = r.safe(function() return obj:get_type_definition() end)
    local guard = 0
    while t ~= nil and guard < 6 do
        guard = guard + 1
        local tn = r.safe(function() return t:get_full_name() end) or ""
        if tn:find("^System%.") or tn:find("^via%.") or tn == "app.gui.GuiControlV2" then break end
        for _, f in ipairs(r.safe(function() return t:get_fields() end) or {}) do
            out[#out + 1] = f
        end
        t = r.safe(function() return t:get_parent_type() end)
    end
    return out
end

local function field_value(obj, f)
    if r.safe(function() return f:is_static() end) == true then
        return r.safe(function() return f:get_data(nil) end)
    end
    local name = r.safe(function() return f:get_name() end)
    return r.field(obj, name)
end

local function render(v)
    if v == nil then return "nil" end
    local tv = type(v)
    if tv ~= "userdata" and tv ~= "table" then return tostring(v) end
    local tn = type_name(v) or tv
    local n = r.to_int(v)
    if n ~= nil and (tn:find("^System%.U?Int") or tn:find("^System%.Boolean")) then return tostring(n) end
    if tn == "app.TextMessageData" then
        local names = package.loaded["pragmata.bindings.object_names"]
        local text = names and r.safe(function() return names.text(v) end)
        return string.format("%q", tostring(text))
    end
    local c = count_of(v)
    if c ~= nil then return tn .. " [" .. tostring(c) .. "]" end
    return tn
end

local shape

-- Below a field's line: a collection's count and its first element expanded,
-- or a nested object's own fields, `depth` more levels.
local function expand(v, indent, depth, out)
    if depth < 0 or v == nil or type(v) ~= "userdata" then return end
    if count_of(v) ~= nil then
        local first = r.elements(v)[1]
        if first ~= nil and type(first) == "userdata" then
            out[#out + 1] = indent .. "[0] " .. render(first)
            shape(first, indent .. "  ", depth - 1, out)
        end
    elseif type_name(v) ~= "app.TextMessageData" then
        shape(v, indent, depth - 1, out)
    end
end

-- One line per field (name = value), expanding as above.
shape = function(obj, indent, depth, out)
    for _, f in ipairs(fields_of(obj)) do
        if #out >= SHAPE_MAX_LINES then return end
        local name = r.safe(function() return f:get_name() end) or "?"
        local v = field_value(obj, f)
        out[#out + 1] = indent .. name .. " = " .. render(v)
        if depth > 0 then expand(v, indent .. "  ", depth, out) end
    end
end

-- For the panel: { route, type, lines } for an open screen's control. Only
-- PROBE_FIELDS[code] when it names fields (expanded three levels), else every
-- field unexpanded.
function M.debug_shape(code)
    local c = M.control(code)
    if c == nil then return { route = _s.control_route, type = "(not reachable)", lines = {} } end
    local out = {}
    local probe = M.PROBE_FIELDS[code]
    if probe == nil or #probe == 0 then
        shape(c, "", 0, out)
    else
        local by_name = {}
        for _, f in ipairs(fields_of(c)) do
            local n = r.safe(function() return f:get_name() end)
            if n ~= nil then by_name[n] = f end
        end
        for _, name in ipairs(probe) do
            local f = by_name[name]
            if f == nil then
                out[#out + 1] = name .. " = (no such field)"
            else
                local v = field_value(c, f)
                out[#out + 1] = name .. " = " .. render(v)
                expand(v, "  ", 2, out)
            end
        end
    end
    return { route = _s.control_route, type = type_name(c) or "?", lines = out }
end

function M.debug_status()
    ensure_init()
    return {
        manager = r.singleton("app.GuiManager") ~= nil,
        bits_ok = _s.m_bits ~= nil and _s.m_bit_index ~= nil,
        control_route = _s.control_route,
        behavior_ok = _s.m_behavior ~= nil and _s.m_get_control ~= nil,
        catalog_size = _s.catalog_size or 0,
        open_now = table.concat(M.open_codes(), " "),
    }
end

return M
