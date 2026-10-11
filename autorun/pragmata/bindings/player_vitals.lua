--
-- Player health and repair kits.
--
-- Engine layout (verified against the IL2CPP dump; invocation still to be
-- confirmed in-game through the State Debug panel):
--
--   app.CharacterManager (managed singleton)
--     - getPlayerHandle() -> app.PlayerHandle
--   app.PlayerHandle : app.CharacterHandle
--     - get_CurrentHitPoint() -> System.Single
--     - get_DefaultHitPoint() -> System.Single   (the handle's max)
--     - get_HitPointRatio()   -> System.Single   (current / max, 0..1)
--     - get_PlayerCoreData()  -> app.PlayerCoreData
--   app.PlayerUpdater
--     - get_MaxHitPointValue() -> System.Int32   STATIC; upgraded max, used
--       only as a fallback when the handle's own max is unreadable
--   app.PlayerCoreData
--     - get_HealingValueOnItem() -> System.Int32 (base heal of one kit)
--   app.EnhanceManager (managed singleton)
--     - getRepairKitCapacity() -> System.Int32   (kits you can carry)
--     - getMultiplyRate(System.UInt32) / getAdditionalRate(System.UInt32)
--         -> System.Single, keyed by an app.PlayerParameterType hash. The
--         heal upgrade is PlayerParameterType.HealReparikitRate (sic).
--   app.InventoryManager (managed singleton)
--     - getItemQuantity(System.UInt32) -> System.Int32   (kits carried)
--
-- The kit's item id is not hard-coded. mod_config.state_repair_kit_item names
-- it by its app.ObjectIDs field name when known; otherwise the held item whose
-- localised name contains "repair" is used, and the debug panel lists every
-- held item so the right one can be pinned.
--
-- The computed heal (base x multiplier + addition) is a reading of the data
-- tables, not an observation. game_state_observer records the HP actually
-- gained the last time a kit was used, and that wins when present.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")
local config = require("pragmata.mod_config")

local M = {}

local _s = { inited = false }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local char_mgr_td = r.td("app.CharacterManager")
    local handle_td   = r.td("app.CharacterHandle")
    local player_td   = r.td("app.PlayerHandle")
    local updater_td  = r.td("app.PlayerUpdater")
    local core_td     = r.td("app.PlayerCoreData")
    local enhance_td  = r.td("app.EnhanceManager")
    local inv_td      = r.td("app.InventoryManager")

    _s.m_player_handle = r.method(char_mgr_td, "getPlayerHandle()")
    _s.m_hp            = r.method(handle_td, "get_CurrentHitPoint()")
    _s.m_hp_default    = r.method(handle_td, "get_DefaultHitPoint()")
    _s.m_hp_ratio      = r.method(handle_td, "get_HitPointRatio()")
    _s.m_core_data     = r.method(player_td, "get_PlayerCoreData()")
    _s.m_max_hp_static = r.method(updater_td, "get_MaxHitPointValue()")
    _s.m_heal_value    = r.method(core_td, "get_HealingValueOnItem()")
    _s.m_kit_capacity  = r.method(enhance_td, "getRepairKitCapacity()")
    _s.m_mult_rate     = r.method(enhance_td, "getMultiplyRate(System.UInt32)")
    _s.m_add_rate      = r.method(enhance_td, "getAdditionalRate(System.UInt32)")
    _s.m_item_ids      = r.method(inv_td, "getItemIDs()")
    _s.m_item_qty      = r.method(inv_td, "getItemQuantity(System.UInt32)")

    if _s.m_player_handle == nil or _s.m_hp == nil then
        log.warn("player_vitals: player handle / hit point accessors unresolved")
    end
end

local function player_handle()
    ensure_init()
    local mgr = r.singleton("app.CharacterManager")
    if mgr == nil then return nil end
    local h = r.call(_s.m_player_handle, mgr)
    if h ~= nil and r.is_live(h) then return h end
    return nil
end

M.player_handle = player_handle

-- ---------------------------------------------------------------------------
-- Repair kit item id
-- ---------------------------------------------------------------------------

local _kit = { id = nil, source = nil }

local function held_item_ids()
    local inv = r.singleton("app.InventoryManager")
    if inv == nil then return nil, nil end
    return r.numbers(r.call(_s.m_item_ids, inv)), inv
end

local function resolve_kit_id()
    if _kit.id ~= nil then return _kit.id end
    local ids = held_item_ids()
    if ids == nil then return nil end

    local want = config.state_repair_kit_item
    for _, id in ipairs(ids) do
        if want ~= nil and object_names.object_name(id) == want then
            _kit.id, _kit.source = id, "config"
            return id
        end
    end
    if want == nil then
        for _, id in ipairs(ids) do
            local name = object_names.display_name(id)
            if type(name) == "string" and name:lower():find("repair", 1, true) then
                _kit.id, _kit.source = id, "display name"
                log.info("player_vitals: repair kit resolved as " .. tostring(name)
                      .. " (" .. tostring(object_names.object_name(id)) .. ")")
                return id
            end
        end
    end
    -- Not held right now (0 kits drops it from the list) -- try again later
    -- rather than latching a miss.
    return nil
end

-- ---------------------------------------------------------------------------
-- Public read
-- ---------------------------------------------------------------------------

-- Returns nil when not in gameplay, else:
--   { hp, hp_max, hp_ratio, kits, kits_max, heal_base, heal_mult, heal_add,
--     heal_per_kit }
-- Any individual field may be nil when that read failed.
function M.read()
    ensure_init()
    local handle = player_handle()
    if handle == nil then return nil end

    local out = {}
    out.hp       = r.to_float(r.call(_s.m_hp, handle))
    out.hp_ratio = r.to_float(r.call(_s.m_hp_ratio, handle))
    local default_max = r.to_float(r.call(_s.m_hp_default, handle))
    local static_max  = r.to_int(r.call(_s.m_max_hp_static, nil))
    out.hp_default, out.hp_static_max = default_max, static_max

    -- The ratio is what the HUD bar shows, so a max derived from it is the one
    -- that agrees with the screen; the declared maxima are fallbacks.
    if out.hp ~= nil and out.hp_ratio ~= nil and out.hp_ratio > 0 then
        out.hp_max = math.floor(out.hp / out.hp_ratio + 0.5)
    elseif default_max ~= nil and default_max > 0 then
        out.hp_max = default_max
    elseif static_max ~= nil and static_max > 0 then
        out.hp_max = static_max
    end
    if out.hp_ratio == nil and out.hp ~= nil and out.hp_max ~= nil and out.hp_max > 0 then
        out.hp_ratio = out.hp / out.hp_max
    end

    local enhance = r.singleton("app.EnhanceManager")
    if enhance ~= nil then
        out.kits_max = r.to_int(r.call(_s.m_kit_capacity, enhance))
        local rate_hash = r.enum_hash("app.PlayerParameterType", "HealReparikitRate")
        if rate_hash ~= nil then
            out.heal_mult = r.to_float(r.call(_s.m_mult_rate, enhance, rate_hash))
            out.heal_add  = r.to_float(r.call(_s.m_add_rate, enhance, rate_hash))
        end
    end

    local core = r.call(_s.m_core_data, handle)
    if core ~= nil then
        out.heal_base = r.to_int(r.call(_s.m_heal_value, core))
    end
    if out.heal_base ~= nil then
        local mult = out.heal_mult
        if mult == nil or mult <= 0 then mult = 1 end
        out.heal_per_kit = math.floor(out.heal_base * mult + (out.heal_add or 0) + 0.5)
    end

    -- Once resolved the id stays latched, so running out reads as 0 rather
    -- than as "unknown". Before the first kit is ever seen it stays nil.
    local kit_id = resolve_kit_id()
    local inv = r.singleton("app.InventoryManager")
    if kit_id ~= nil and inv ~= nil then
        out.kits = r.to_int(r.call(_s.m_item_qty, inv, kit_id))
    end
    out.kit_item = kit_id
    return out
end

function M.debug_status()
    ensure_init()
    return {
        handle_ok      = player_handle() ~= nil,
        hp_method_ok   = _s.m_hp ~= nil,
        core_method_ok = _s.m_core_data ~= nil,
        kit_id         = _kit.id,
        kit_id_source  = _kit.source,
        kit_internal   = _kit.id and object_names.object_name(_kit.id) or nil,
        heal_rate_hash = r.enum_hash("app.PlayerParameterType", "HealReparikitRate"),
    }
end

return M
