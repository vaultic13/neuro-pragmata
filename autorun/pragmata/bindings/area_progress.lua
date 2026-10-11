--
-- The map area the player is in, and what is still left to collect there.
--
-- Engine layout (verified against the IL2CPP dump; invocation still to be
-- confirmed in-game through the State Debug panel):
--
--   app.GuiManager (managed singleton)
--     - get_MapDataManager() -> app.MapDataManager   (not itself a singleton)
--   app.MapDataManager  -- the data behind the map screen
--     - _CurrentSceneId : UInt32
--     - getAreaIdFromSceneId(UInt32) -> UInt32
--     - calcAreaItemGatherRate(UInt32 areaId, UInt32[] kinds = null) -> Int32
--         the map screen's own "collected" percentage for one area
--     - _StageItemDict : Dictionary<UInt32, List<app.StageItemData.Param>>
--         every placed collectible, grouped by area
--     - isGotStageItem(System.Guid, UInt32) -> Boolean   (private)
--   app.StageItemData.Param
--     - _ObjectId (System.Guid), _ItemId (UInt32), _ItemKind (UInt32),
--       _StageId (UInt32), _NewGamePlus (Boolean)
--   app.MessageManager (managed singleton)
--     - getCheckAreaName(UInt32) -> app.TextMessageData   localised area name
--
-- The current scene comes from MapDataManager's own _CurrentSceneId first,
-- then from each active chunk hash bindings/scene.lua reports, taking the
-- first that maps to an area.
--
-- Only the player-facing area NAME ever leaves this module (plus the opaque
-- area id, used for edge detection). Internal scene codes stay here.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")
local scene = require("pragmata.bindings.scene")

local M = {}

local _s = { inited = false, last_error = nil }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local gui = r.td("app.GuiManager")
    local map = r.td("app.MapDataManager")
    local msg = r.td("app.MessageManager")
    _s.m_map_mgr     = r.method(gui, "get_MapDataManager()")
    _s.m_area_of     = r.method(map, "getAreaIdFromSceneId(System.UInt32)")
    _s.m_gather_rate = r.method(map, "calcAreaItemGatherRate(System.UInt32,System.UInt32[])")
    _s.m_is_got      = r.method(map, "isGotStageItem(System.Guid,System.UInt32)")
    _s.m_area_name   = r.method(msg, "getCheckAreaName(System.UInt32)")
    _s.m_cp_name     = r.method(msg, "getCheckPointName(System.UInt32)")
    _s.m_stage_params = r.method(map, "getCheckPointStageParams()")
    _s.m_hud_broad    = r.method(r.td("app.HudManager"), "get_CurrentAssignBroadSceneIdHash()")
    _s.m_broad_of     = r.method(r.td("app.EnvironmentSceneIDExtension"), "getBroadSceneID(System.UInt32)")
    if _s.m_map_mgr == nil or _s.m_area_of == nil then
        log.warn("area_progress: map data accessors unresolved")
    end
end

local function map_data()
    ensure_init()
    local gui = r.singleton("app.GuiManager")
    if gui == nil then return nil end
    return r.call(_s.m_map_mgr, gui)
end

local function area_of(map, scene_id)
    if scene_id == nil or scene_id == 0 then return nil end
    local a = r.to_int(r.call(_s.m_area_of, map, scene_id))
    if a == nil or a == 0 then return nil end
    return a
end

-- (area_id, scene_id) for where the player is now, or nil.
local function current_area(map)
    local own = r.to_int(r.field(map, "_CurrentSceneId"))
    local a = area_of(map, own)
    if a ~= nil then return a, own end
    for _, h in ipairs(scene.get_current_hashes() or {}) do
        a = area_of(map, h)
        if a ~= nil then return a, h end
    end
    return nil
end

local _area_names = {}

local function message_text(method_def, key)
    local msg = r.singleton("app.MessageManager")
    if msg == nil or key == nil or key == 0 then return nil end
    return object_names.text(r.call(method_def, msg, key))
end

-- Localised area name. The first test run got nothing from
-- getCheckAreaName(area id), so the scene id is tried as the key too; which
-- one answered is kept for the debug panel. Nil when neither does.
function M.area_name(area_id, scene_id)
    if area_id == nil then return nil end
    local cached = _area_names[area_id]
    if cached ~= nil then return cached end
    ensure_init()
    local name = message_text(_s.m_area_name, area_id)
    if name ~= nil then _s.name_key = "area id"
    else
        name = message_text(_s.m_area_name, scene_id)
        if name ~= nil then _s.name_key = "scene id" end
    end
    if name ~= nil then _area_names[area_id] = name end
    return name
end

-- Hash of the last checkpoint reached, from bindings/checkpoint.lua.
local function last_checkpoint_id()
    local ok, cp = pcall(require, "pragmata.bindings.checkpoint")
    if not ok or cp == nil or cp.get_last_id == nil then return nil end
    local ok_id, id = pcall(cp.get_last_id)
    if not ok_id then return nil end
    id = r.to_int(id)
    if id == nil or id == 0 then return nil end
    return id
end

-- Name of the last checkpoint reached: the fallback when the area itself has
-- no name, so the peer still gets "near <checkpoint>" instead of nothing.
local function checkpoint_name()
    return message_text(_s.m_cp_name, last_checkpoint_id())
end

-- Stage ids the map lists for one area (_StageAreaList entries are
-- { _StageId, _AreaId }).
local function stages_of(map, area_id)
    local out = {}
    for _, p in ipairs(r.elements(r.field(map, "_StageAreaList"))) do
        if r.to_int(r.field(p, "_AreaId")) == area_id then
            local sid = r.to_int(r.field(p, "_StageId"))
            if sid ~= nil then out[#out + 1] = sid end
        end
    end
    return out
end

-- Sector ("stage"). The map names places at two levels: the sector and the
-- areas inside it; getCheckAreaName answers only for the finer level, and not
-- for every area.
--
-- MapDataManager.getCheckPointStageParams() -> List<GuiCheckPointData.StageParam>
--   { _StageIdHash, _StageName, _StageNameEx (TextMessageData) }
--
-- The list always holds all eight sectors (Shelter is 1557490666, Solar Power
-- Plant 2097087376), keyed by a hash that matches none of the scene, area or
-- _StageAreaList ids. What it does match -- by the dump -- is the engine's
-- "broad scene" id, which is how the game itself names a sector (the store's
-- stage-progress conditions key sectors by EnvironmentBroadID). The current
-- one is asked two ways, first answer that is in the list wins:
--   1. app.HudManager.get_CurrentAssignBroadSceneIdHash() -> UInt32
--        the sector the HUD is currently showing
--   2. app.EnvironmentSceneIDExtension.getBroadSceneID(UInt32) -> UInt32
--        STATIC; converts each currently loaded scene id to its sector
-- Both follow the loaded scene, so walking into a new sector is seen at
-- once. The last checkpoint is deliberately NOT used: it only changes at an
-- elevator, so it lags every walk between sectors.

local function stage_param_name(p)
    if p == nil then return nil end
    local name = object_names.text(r.field(p, "_StageName"))
    if name ~= nil then _s.stage_key = "_StageName" return name end
    name = object_names.text(r.field(p, "_StageNameEx"))
    if name ~= nil then _s.stage_key = "_StageNameEx" return name end
    -- The record exists but carries no readable name: last try the message
    -- catalog with the record's own hash.
    local hash = r.to_int(r.field(p, "_StageIdHash"))
    name = message_text(_s.m_area_name, hash) or message_text(_s.m_cp_name, hash)
    if name ~= nil then _s.stage_key = "message catalog by hash" end
    return name
end

-- Sector ids the game reports for "now", in order of preference, each tagged
-- with where it came from.
local function sector_candidates(map)
    local out = {}
    local hud = r.singleton("app.HudManager")
    local h = hud and r.to_int(r.call(_s.m_hud_broad, hud)) or nil
    if h ~= nil and h ~= 0 then out[#out + 1] = { id = h, via = "hud" } end

    local scenes = {}
    local own = r.to_int(r.field(map, "_CurrentSceneId"))
    if own ~= nil then scenes[#scenes + 1] = own end
    for _, s in ipairs(scene.get_current_hashes() or {}) do scenes[#scenes + 1] = s end
    for _, s in ipairs(scenes) do
        local b = r.to_int(r.call(_s.m_broad_of, nil, s))
        if b ~= nil and b ~= 0 then out[#out + 1] = { id = b, via = "scene " .. tostring(s) } end
    end
    return out
end

-- (sector_hash, sector_name) of the current sector, or nil.
local function current_sector(map)
    local records = r.elements(r.call(_s.m_stage_params, map))
    _s.stage_record_count = #records
    local by_hash = {}
    for _, p in ipairs(records) do
        local h = r.to_int(r.field(p, "_StageIdHash"))
        if h ~= nil then by_hash[h] = p end
    end

    local candidates = sector_candidates(map)
    _s.sector_candidates = candidates
    for _, c in ipairs(candidates) do
        local p = by_hash[c.id]
        if p ~= nil then
            _s.sector_via = c.via
            return c.id, stage_param_name(p)
        end
    end
    _s.sector_via = #candidates == 0 and "no sector id reported"
        or "sector ids reported but none is in the map's list"
    return nil
end

-- The collectibles placed in one area, each marked collected or not.
-- _StageItemDict's key is not documented: the area id is tried first, then
-- the area's stage ids. Returns a list of { item_id, label, got } or nil.
local function area_items(map, area_id)
    local dict = r.field(map, "_StageItemDict")
    if dict == nil then return nil end
    local function lookup(key) return r.dict_get(dict, key) end
    local lists = {}
    local direct = lookup(area_id)
    if direct ~= nil then
        lists[1] = direct
        _s.items_key = "area id"
    else
        for _, sid in ipairs(stages_of(map, area_id)) do
            local l = lookup(sid)
            if l ~= nil then lists[#lists + 1] = l end
        end
        if #lists == 0 then _s.items_key = "none matched" return nil end
        _s.items_key = "stage id"
    end
    local params = {}
    for _, l in ipairs(lists) do
        for _, p in ipairs(r.elements(l)) do params[#params + 1] = p end
    end
    local out = {}
    for _, p in ipairs(params) do
        local item_id = r.to_int(r.field(p, "_ItemId"))
        local guid = r.field(p, "_ObjectId")
        local got = nil
        if guid ~= nil and item_id ~= nil then
            local v = r.call(_s.m_is_got, map, guid, item_id)
            if type(v) == "boolean" then got = v end
        end
        out[#out + 1] = {
            item_id = item_id,
            label   = item_id and object_names.resolve_object(item_id).label or "item",
            got     = got,
        }
    end
    return out
end

-- Returns nil outside gameplay, else:
--   { area_id, sector (whole-map sector name), name (area inside it),
--     near (last checkpoint's name, only when both are nil), gather_pct,
--     total, collected, remaining = { {label, count} }, per_item_known }
-- `remaining` is grouped by label and sorted by count. Any field may be nil
-- when its read failed; `per_item_known` is false when the per-item collected
-- flag could not be read, in which case only gather_pct is meaningful.
function M.read()
    ensure_init()
    local map = map_data()
    if map == nil then _s.last_error = "no map data manager" return nil end
    local area_id, scene_id = current_area(map)
    local sector_hash, sector = current_sector(map)
    if area_id == nil and sector_hash == nil then
        _s.last_error = "no area or sector for current scene"
        return nil
    end

    local out = { area_id = area_id, sector_hash = sector_hash, sector = sector }
    if area_id ~= nil then out.name = M.area_name(area_id, scene_id) end
    -- Two levels saying the same thing is one name, not two.
    if out.sector ~= nil and out.sector == out.name then out.name = nil end
    -- Last resort only, and labelled as such by the caller: the checkpoint
    -- changes at elevators, not when walking between places.
    if out.name == nil and out.sector == nil then out.near = checkpoint_name() end
    if area_id == nil then _s.last_error = nil return out end

    -- The kinds filter is optional in C# but REFramework passes arguments
    -- positionally; if a null array is refused, an empty one means the same.
    out.gather_pct = r.to_int(r.call(_s.m_gather_rate, map, area_id, nil))
    if out.gather_pct == nil then
        local empty = r.safe(function() return sdk.create_managed_array("System.UInt32", 0) end)
        if empty ~= nil then
            out.gather_pct = r.to_int(r.call(_s.m_gather_rate, map, area_id, empty))
        end
    end

    local items = area_items(map, area_id)
    if items ~= nil then
        local groups, order = {}, {}
        local known, collected = true, 0
        for _, it in ipairs(items) do
            if it.got == nil then known = false
            elseif it.got then collected = collected + 1
            else
                if groups[it.label] == nil then
                    groups[it.label] = 0
                    order[#order + 1] = it.label
                end
                groups[it.label] = groups[it.label] + 1
            end
        end
        out.total, out.per_item_known = #items, known
        if known then
            out.collected = collected
            out.remaining = {}
            for _, label in ipairs(order) do
                out.remaining[#out.remaining + 1] = { label = label, count = groups[label] }
            end
            table.sort(out.remaining, function(a, b)
                if a.count ~= b.count then return a.count > b.count end
                return a.label < b.label
            end)
        end
    end
    _s.last_error = nil
    return out
end

-- Opaque key for "where the player is": sector hash + area id, both derived
-- from what is loaded now (the scene), never from the last checkpoint. The
-- observer polls this for edges, so walking into a new area or sector is
-- noticed without an elevator; a scene change inside the same area is not.
-- The current sector's stage hash alone, or nil when it cannot be read
-- (menus, loading screens). action_gates compares it with the Shelter's.
function M.current_sector_hash()
    local map = map_data()
    if map == nil then return nil end
    return (current_sector(map))
end

-- (sector_hash, sector_name) of the current sector, or nil. The name is the
-- map's own display name, i.e. in the game's language.
function M.current_sector()
    local map = map_data()
    if map == nil then return nil end
    return current_sector(map)
end

function M.current_location_key()
    local map = map_data()
    if map == nil then return nil end
    local area_id = current_area(map)
    local sector_hash = current_sector(map)
    if area_id == nil and sector_hash == nil then return nil end
    return tostring(sector_hash) .. ":" .. tostring(area_id)
end

function M.debug_status()
    ensure_init()
    local map = map_data()
    local area_id, scene_id = nil, nil
    if map ~= nil then
        area_id, scene_id = current_area(map)
        current_sector(map)   -- refreshes sector_via / sector_candidates below
    end
    return {
        gui_manager     = r.singleton("app.GuiManager") ~= nil,
        map_data        = map ~= nil,
        own_scene_id    = map and r.to_int(r.field(map, "_CurrentSceneId")) or nil,
        matched_scene   = scene_id,
        area_id         = area_id,
        is_got_ok       = _s.m_is_got ~= nil,
        area_name_ok    = _s.m_area_name ~= nil,
        area_name_key   = _s.name_key,      -- which key getCheckAreaName answered to
        items_key       = _s.items_key,     -- which key _StageItemDict answered to
        stage_key       = _s.stage_key,     -- how the sector name was found
        stage_record_count = _s.stage_record_count,
        sector_via      = _s.sector_via,    -- which source matched a record
        sector_candidates = (function()
            local out = {}
            for _, c in ipairs(_s.sector_candidates or {}) do
                out[#out + 1] = tostring(c.id) .. " via " .. c.via
            end
            return out
        end)(),
        location_key    = M.current_location_key(),
        last_checkpoint = last_checkpoint_id(),
        -- Every stage record the map holds, as "hash = name", so the key
        -- space can be compared with stage_ids / last_checkpoint above.
        stage_records   = (function()
            if map == nil then return nil end
            local out = {}
            for _, p in ipairs(r.elements(r.call(_s.m_stage_params, map))) do
                out[#out + 1] = tostring(r.to_int(r.field(p, "_StageIdHash")))
                    .. " = " .. tostring(stage_param_name(p))
            end
            return out
        end)(),
        stage_ids       = (map and area_id) and stages_of(map, area_id) or nil,
        last_error      = _s.last_error,
    }
end

return M
