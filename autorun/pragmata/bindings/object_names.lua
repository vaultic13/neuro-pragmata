--
-- Hash -> readable name resolution for engine object/icon identifiers.
--
-- The engine identifies almost everything by a UInt32 name hash. Scan results,
-- in particular, are pure hashes (`objectIDHash`, `iconTypeHash`), which is why
-- the AI used to be told things like "hash:1984889503". Every one of those
-- hashes IS resolvable from the running game; this module is the single place
-- that does it.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.ScanIconType : app.EnumLikeArrayBase
--     - getName(System.UInt32) -> System.String
--       A "smart enum" with exactly seven members: Goal, SubGoal, Stopover,
--       Interest, Item, Hatch, Hide. Same shape as app.PuzzleSnakeGridType,
--       which bindings/puzzle_snake.lua already resolves this way.
--
--   app.ObjectIDs (plain static class)
--     - ~7000 static UInt32 literals, one per object ID, e.g.
--         Archive = 4083672819, Assort00000 = 539454927
--       There is no getName() here, so we build the reverse map ourselves by
--       reflecting the static fields. That is a lot of fields, so the build is
--       chunked across frames (see the frame callback at the bottom) and never
--       blocks a scan; lookups just report "unknown" until it completes.
--     - getKindHash(System.UInt32) -> System.UInt32
--       Maps an object ID to its *category* hash.
--   app.ObjectIDs.Variety (plain static class)
--     - 89 static UInt32 literals naming those categories: Enemy, Item,
--       HackingBox, Filament, Gimmick, Character, Goal, ... Small enough to
--       build eagerly on first use.
--
--   app.GuiDataManager (managed singleton via app.AppSingleton`1)
--     - getItemData(System.UInt32) -> app.GUIItemData
--         .get_Name() -> app.TextMessageData
--     - getCharaName(System.UInt32) -> app.TextMessageData
--   app.TextMessageData
--     - getMessage() -> System.String     (the LOCALISED, player-facing text)
--
-- So there are three tiers of name, best first:
--   1. display  -- localised UI string ("Upgrade Module"). Only exists for
--                  things the game shows in a menu.
--   2. internal -- the app.ObjectIDs field name ("Assort00012"). Stable and
--                  always available, but developer-facing.
--   3. hash     -- "hash:1984889503". Only when the ID isn't in the catalog at
--                  all, which is real information, not a resolver failure.
-- Callers get all three plus the category so they can decide how to phrase it.

local log = require("pragmata.util.log")

local M = {}

-- Chunk size for the app.ObjectIDs reverse-map build. ~7000 fields at 400 per
-- frame finishes in well under a second of gameplay, with no visible hitch;
-- the build starts at boot so it's long done before the first scan.
local OBJECT_ID_CHUNK = 400

-- Literal fallbacks from the IL2CPP dump, used only if app.ScanIconType.getName
-- isn't reflectable on a future build. Mirrors the _DF_HASH_NAMES pattern in
-- bindings/puzzle_snake.lua.
local SCAN_ICON_FALLBACK = {
    [1599924820] = "Goal",
    [3357324359] = "SubGoal",
    [3522227121] = "Stopover",
    [3607487661] = "Interest",
    [4253710839] = "Item",
    [562752433]  = "Hatch",
    [8967142]    = "Hide",
}

-- Player-facing phrasing for a marker whose object id the catalogs cannot
-- name. The AI gains nothing from "sm90_129_00"; it gains a great deal from
-- knowing the thing is an objective.
--
-- Keyed on the icon NAME rather than its hash, so it works identically whether
-- the name came from app.ScanIconType.getName or from SCAN_ICON_FALLBACK above,
-- and so a future build that renumbers a hash costs nothing here.
--
-- Singular and plural are both spelled out: "hatch" pluralises with -es, and a
-- naive .. "s" would produce "escape hatchs".
local SCAN_ICON_PHRASE = {
    Goal     = { one = "objective marker",     many = "objective markers" },
    SubGoal  = { one = "sub-objective marker", many = "sub-objective markers" },
    Stopover = { one = "stopover",             many = "stopovers" },
    Interest = { one = "point of interest",    many = "points of interest" },
    Item     = { one = "item marker",          many = "item markers" },
    Hatch    = { one = "escape hatch",         many = "escape hatches" },
    Hide     = { one = "hidden marker",        many = "hidden markers" },
}
-- Deliberately not nil-able: the caller's only alternative is a raw hash.
local SCAN_ICON_PHRASE_UNKNOWN = { one = "marker", many = "markers" }

-- ---------------------------------------------------------------------------
-- SDK plumbing
-- ---------------------------------------------------------------------------

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function td(name)
    return safe(function() return sdk.find_type_definition(name) end)
end

local function method(type_def, signature)
    if type_def == nil then return nil end
    return safe(function() return type_def:get_method(signature) end)
end

local function to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    return safe(function() return value:get_field("value__") end)
end

-- TypeDefinition:get_fields() normally includes inherited fields, but that is
-- not guaranteed across REFramework builds, so walk parents explicitly and
-- de-duplicate by name. Same approach as bindings/command_input.lua:all_fields.
local function all_fields(type_def)
    local result, seen = {}, {}
    local current = type_def
    while current ~= nil do
        for _, field in ipairs(safe(function() return current:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            if type(name) ~= "string" or not seen[name] then
                result[#result + 1] = field
                if type(name) == "string" then seen[name] = true end
            end
        end
        current = safe(function() return current:get_parent_type() end)
    end
    return result
end

local UINT32_MAX = 4294967295

-- Read one static UInt32 name constant. Returns (name, value), or nil for any
-- field that isn't one.
--
-- The classes we reflect over also hold static Dictionary/List fields. If a
-- REFramework build doesn't expose Field:get_type() we can't filter on the
-- declared type, so the value is range-checked as well: a managed pointer read
-- as an integer is far outside UInt32, and would otherwise be entered into the
-- map as a bogus hash.
local function static_uint32(field)
    if safe(function() return field:is_static() end) ~= true then return nil end
    local field_type = safe(function() return field:get_type() end)
    if field_type ~= nil then
        if safe(function() return field_type:get_full_name() end) ~= "System.UInt32" then
            return nil
        end
    end
    local value = to_int(safe(function() return field:get_data(nil) end))
    if type(value) ~= "number" or value < 0 or value > UINT32_MAX then return nil end
    if value ~= math.floor(value) then return nil end
    local name = safe(function() return field:get_name() end)
    if type(name) ~= "string" then return nil end
    return name, value
end

-- Read every static UInt32 constant off a type into a hash -> name map.
-- Returns the map and the number of entries.
local function build_uint32_map(type_name)
    local type_def = td(type_name)
    if type_def == nil then return nil, 0 end
    local map, count = {}, 0
    for _, field in ipairs(all_fields(type_def)) do
        local name, value = static_uint32(field)
        if name ~= nil and map[value] == nil then
            map[value] = name
            count = count + 1
        end
    end
    return map, count
end

-- ---------------------------------------------------------------------------
-- app.ScanIconType
-- ---------------------------------------------------------------------------

local _icon = { inited = false, get_name = nil, cache = {} }

local function icon_init()
    if _icon.inited then return end
    _icon.inited = true
    _icon.get_name = method(td("app.ScanIconType"), "getName(System.UInt32)")
    if _icon.get_name == nil then
        log.warn("object_names: app.ScanIconType.getName unavailable; using dumped fallbacks")
    end
end

-- Scan icon-type name ("Item", "Goal", ...) for an iconTypeHash.
-- CONFIDENCE: high -- getName is the engine's own resolver and the seven
-- member hashes are also pinned as literals.
function M.icon_name(hash)
    if hash == nil then return nil end
    local cached = _icon.cache[hash]
    if cached ~= nil then return cached end
    icon_init()
    local name = nil
    if _icon.get_name ~= nil then
        local value = safe(function() return _icon.get_name:call(nil, hash) end)
        if type(value) == "string" and #value > 0 then name = value end
    end
    name = name or SCAN_ICON_FALLBACK[hash]
    if name == nil then return nil end
    _icon.cache[hash] = name
    return name
end

-- Phrase pair for an iconTypeHash: { one = "escape hatch", many = "escape
-- hatches", name = "Hatch" }. Never nil.
function M.icon_phrase(hash)
    local name = M.icon_name(hash)
    local phrase = (name ~= nil and SCAN_ICON_PHRASE[name]) or SCAN_ICON_PHRASE_UNKNOWN
    return { one = phrase.one, many = phrase.many, name = name }
end

-- Phrase for an iconTypeHash at a given count: "escape hatch" / "escape hatches".
function M.icon_phrase_text(hash, count)
    local phrase = M.icon_phrase(hash)
    if (tonumber(count) or 1) == 1 then return phrase.one end
    return phrase.many
end

-- ---------------------------------------------------------------------------
-- app.ObjectIDs -- internal name + category
-- ---------------------------------------------------------------------------

-- The object-ID map is large, so it is built incrementally. `state` is one of
-- "idle" (not started), "building", "ready", or "unavailable".
local _objects = {
    state = "idle",
    map = {},
    count = 0,
    fields = nil,
    cursor = 1,
    scanned = 0,
    started_frame = nil,
    finished_frame = nil,
}

local _variety = { inited = false, map = nil, count = 0, get_kind_hash = nil, cache = {} }

local function object_ids_begin()
    if _objects.state ~= "idle" then return end
    local type_def = td("app.ObjectIDs")
    if type_def == nil then
        _objects.state = "unavailable"
        log.warn("object_names: app.ObjectIDs unavailable; object IDs stay unresolved")
        return
    end
    _objects.fields = all_fields(type_def)
    _objects.state = "building"
    log.info("object_names: building app.ObjectIDs map from "
          .. tostring(#_objects.fields) .. " fields")
end

-- Process one chunk. Returns true once the whole map is built.
local function object_ids_step()
    if _objects.state ~= "building" then return _objects.state == "ready" end
    local fields = _objects.fields
    local last = math.min(_objects.cursor + OBJECT_ID_CHUNK - 1, #fields)
    for i = _objects.cursor, last do
        local name, value = static_uint32(fields[i])
        if name ~= nil and _objects.map[value] == nil then
            _objects.map[value] = name
            _objects.count = _objects.count + 1
        end
    end
    _objects.cursor = last + 1
    _objects.scanned = last
    if _objects.cursor > #fields then
        _objects.state = "ready"
        _objects.fields = nil
        log.info("object_names: app.ObjectIDs map ready with "
              .. tostring(_objects.count) .. " ids")
        return true
    end
    return false
end

local function variety_init()
    if _variety.inited then return end
    _variety.inited = true
    _variety.get_kind_hash = method(td("app.ObjectIDs"), "getKindHash(System.UInt32)")
    -- Only 89 entries, so this one is cheap enough to build in one go.
    local map, count = build_uint32_map("app.ObjectIDs.Variety")
    _variety.map, _variety.count = map, count
    if map == nil then
        log.warn("object_names: app.ObjectIDs.Variety unavailable; kinds stay unresolved")
    end
end

-- Internal developer-facing name for an objectIDHash ("Assort00012"), or nil.
function M.object_name(hash)
    if hash == nil then return nil end
    object_ids_begin()
    if _objects.state ~= "ready" then return nil end
    return _objects.map[hash]
end

-- Category name for an objectIDHash ("Item", "Enemy", "HackingBox", ...), or
-- nil. Uses the engine's own getKindHash, so it stays correct across content
-- the mod has never seen.
function M.object_kind(hash)
    if hash == nil then return nil end
    local cached = _variety.cache[hash]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    variety_init()
    if _variety.get_kind_hash == nil or _variety.map == nil then return nil end
    local kind_hash = to_int(safe(function()
        return _variety.get_kind_hash:call(nil, hash)
    end))
    local name = kind_hash ~= nil and _variety.map[kind_hash] or nil
    -- Cache misses too: getKindHash is a dictionary probe per call and scans
    -- re-resolve the same ids every few frames.
    _variety.cache[hash] = name or false
    return name
end

-- ---------------------------------------------------------------------------
-- Localised display names (app.GuiDataManager)
-- ---------------------------------------------------------------------------

local _display = {
    inited = false,
    m_get_item_data = nil,
    m_get_chara_name = nil,
    m_item_get_name = nil,
    m_text_get_message = nil,
    cache = {},
    -- Counted so "names got worse" can be told apart from a resolver
    -- regression; the sample says which string triggered it.
    placeholder_rejected = 0,
    last_placeholder = nil,
}

local function display_init()
    if _display.inited then return end
    _display.inited = true
    local gui_data_td = td("app.GuiDataManager")
    _display.m_get_item_data  = method(gui_data_td, "getItemData(System.UInt32)")
    _display.m_get_chara_name = method(gui_data_td, "getCharaName(System.UInt32)")
    _display.m_item_get_name  = method(td("app.GUIItemData"), "get_Name()")
    -- getMessage has a params overload too; pin the no-arg one.
    _display.m_text_get_message = method(td("app.TextMessageData"), "getMessage()")
end

-- RE Engine does not fail a message lookup -- it returns the unresolved
-- reference verbatim, e.g. "<REF Proper_asset>". That is not a name, and
-- treating one as a name is worse than reporting nothing: the AI repeats it
-- back as though a real object were called that.
--
-- Two forms are rejected: a string that is entirely one <...> engine token, and
-- anything beginning with an unresolved <REF. Plain Lua patterns only -- the %f
-- frontier pattern is avoided here for the same reason bitwise operators are
-- avoided elsewhere in this codebase (REFramework's Lua version varies).
--
-- Deliberately NOT rejected: internal developer codes like "sm90_129_00". Those
-- are legitimately what app.ObjectIDs calls the object. Whether they are fit to
-- show a reader is a name-TIER question, answered by `named` in resolve_object,
-- not by pattern-matching game data.
local function is_placeholder_name(text)
    if type(text) ~= "string" then return true end
    local trimmed = text:match("^%s*(.-)%s*$")
    if #trimmed == 0 then return true end
    if trimmed:match("^<[^<>]*>$") then return true end
    if trimmed:match("^<REF[%s>]") then return true end
    return false
end

M.is_placeholder_name = is_placeholder_name

local function message_text(text_message_data)
    if text_message_data == nil or _display.m_text_get_message == nil then return nil end
    local text = safe(function()
        return _display.m_text_get_message:call(text_message_data)
    end)
    if type(text) ~= "string" or #text == 0 then return nil end
    if is_placeholder_name(text) then
        _display.placeholder_rejected = (_display.placeholder_rejected or 0) + 1
        _display.last_placeholder = text
        return nil
    end
    return text
end

-- Localised, player-facing name for an objectIDHash ("Upgrade Module"), or nil
-- when the id isn't something the game ever shows in a menu (most world props).
-- CONFIDENCE: medium -- the lookup chain is verified in the dump, but the
-- catalogs are populated by the GUI layer, so this returns nil before they load.
function M.display_name(hash)
    if hash == nil then return nil end
    local cached = _display.cache[hash]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    display_init()
    local manager = safe(function()
        return sdk.get_managed_singleton("app.GuiDataManager")
    end)
    if manager == nil then return nil end  -- not loaded yet; don't poison the cache

    local text = nil
    if _display.m_get_item_data ~= nil and _display.m_item_get_name ~= nil then
        local item = safe(function() return _display.m_get_item_data:call(manager, hash) end)
        if item ~= nil then
            text = message_text(safe(function()
                return _display.m_item_get_name:call(item)
            end))
        end
    end
    if text == nil and _display.m_get_chara_name ~= nil then
        text = message_text(safe(function()
            return _display.m_get_chara_name:call(manager, hash)
        end))
    end
    _display.cache[hash] = text or false
    return text
end

-- ---------------------------------------------------------------------------
-- Combined resolution
-- ---------------------------------------------------------------------------

-- Resolve everything known about one objectIDHash.
--   {
--     hash     = <u32>,
--     display  = "Upgrade Module" | nil,   -- localised, may be nil
--     internal = "Assort00012"    | nil,   -- app.ObjectIDs field name
--     kind     = "Item"           | nil,   -- app.ObjectIDs.Variety category
--     label    = "Upgrade Module",         -- best available, never nil
--     resolved = true,                     -- false when only the hash is known
--     named    = true,                     -- a LOCALISED name exists
--   }
--
-- `named` is the field callers should branch on when deciding whether a thing
-- can be shown to a player or an AI. `resolved` is weaker -- it is also true
-- for a developer code like "Assort00012", which is traceable but not readable.
function M.resolve_object(hash)
    if hash == nil then
        return { hash = nil, label = "unknown", resolved = false }
    end
    local display  = M.display_name(hash)
    local internal = M.object_name(hash)
    local kind     = M.object_kind(hash)
    local label    = display or internal or ("hash:" .. tostring(hash))
    return {
        hash     = hash,
        display  = display,
        internal = internal,
        kind     = kind,
        label    = label,
        resolved = display ~= nil or internal ~= nil,
        named    = display ~= nil,
    }
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Snapshot for the abilities debug panel. Cheap to call every frame.
function M.debug_status()
    icon_init()
    variety_init()
    return {
        icon_resolver_ok  = _icon.get_name ~= nil,
        object_ids_state  = _objects.state,
        object_ids_count  = _objects.count,
        object_ids_scanned = _objects.scanned,
        object_ids_total  = _objects.fields and #_objects.fields or _objects.scanned,
        variety_count     = _variety.count,
        variety_kind_ok   = _variety.get_kind_hash ~= nil,
        display_singleton = safe(function()
            return sdk.get_managed_singleton("app.GuiDataManager")
        end) ~= nil,
        placeholder_rejected = _display.placeholder_rejected or 0,
        last_placeholder     = _display.last_placeholder,
    }
end

-- True once app.ObjectIDs has finished building (or has been ruled out).
function M.is_ready()
    return _objects.state == "ready" or _objects.state == "unavailable"
end

-- Build the object-ID map in the background from boot, so the first scan of a
-- session already has names. Nothing else in the mod has to wait on it.
re.on_frame(function()
    if _objects.state == "ready" or _objects.state == "unavailable" then return end
    object_ids_begin()
    object_ids_step()
end)

return M
