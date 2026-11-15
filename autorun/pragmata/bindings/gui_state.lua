--
-- Which game menus (GUI screens) are open.
--
-- Engine facts (il2cpp dump + in-game tests):
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
-- tick() reads the bitset once, turns set bits back into codes through the
-- cached index map, and records open/close transitions in a short latched log,
-- so a screen that is only on for a few frames is still visible afterwards.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")

local M = {}

local _s = { inited = false }

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

-- The catalog is built from getGuiTypeBitIndex, which answers only for the
-- screens loaded at that moment. Built at the title screen or during a new
-- game's load, it lacked the Shelter menus' screens for the whole session,
-- and they read as always closed. So an open bit with no code
-- rebuilds the catalog, at most once every REBUILD_EVERY ticks, and
-- M.reset_catalog() (called after a world load) rebuilds it outright.
-- A bit still unnamed right after a rebuild has no name to find (kept in
-- _nameless), so it does not trigger rebuilds forever.
local REBUILD_EVERY = 10
local _since_rebuild = 0
local _nameless = {}            -- bit index -> true
_s.catalog_builds = 0

function M.reset_catalog() _code_of_bit = nil _nameless = {} end

local function read_open(gm)
    local words = r.numbers(r.call(_s.m_bits, gm))
    if #words == 0 then return nil end
    local open, unknown = {}, nil
    for w, word in ipairs(words) do
        local v = word % 4294967296
        local bit = 0
        while v > 0 and bit < 32 do
            if v % 2 == 1 then
                local idx = (w - 1) * 32 + bit
                local code = _code_of_bit[idx]
                if code == nil then
                    unknown = unknown or {}
                    unknown[#unknown + 1] = idx
                end
                open[code or ("bit" .. idx)] = true
            end
            v = math.floor(v / 2)
            bit = bit + 1
        end
    end
    return open, unknown
end

-- Call a few times a second (action_gates does). Cheap: one managed call.
function M.tick()
    ensure_init()
    local gm = r.singleton("app.GuiManager")
    if gm == nil or _s.m_bits == nil then return end
    if _code_of_bit == nil then _s.catalog_builds = _s.catalog_builds + 1 end
    if not load_catalog(gm) then return end
    _since_rebuild = _since_rebuild + 1
    local now, unknown = read_open(gm)
    if now == nil then return end
    local fresh = false
    for _, idx in ipairs(unknown or {}) do
        if not _nameless[idx] then fresh = true end
    end
    if fresh and _since_rebuild >= REBUILD_EVERY then
        -- A screen the catalog does not know: rebuild and read again.
        _since_rebuild = 0
        _code_of_bit = nil
        _s.catalog_builds = _s.catalog_builds + 1
        if not load_catalog(gm) then return end
        now, unknown = read_open(gm)
        if now == nil then return end
        for _, idx in ipairs(unknown or {}) do _nameless[idx] = true end
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

-- ---------------------------------------------------------------------------
-- The open screen's object
-- ---------------------------------------------------------------------------

-- Which route answered last.
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

return M
