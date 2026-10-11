--
-- The player's weapons: what is owned, what is equipped, ammo and level.
--
-- Engine layout (verified against the IL2CPP dump; invocation still to be
-- confirmed in-game through the State Debug panel):
--
--   app.WeaponManager (managed singleton)
--     - getUnlockedWeaponIDs()      -> System.UInt32[]   every owned weapon
--     - getUnlockedMainWeaponIDs()  -> System.UInt32[]   the main-weapon subset
--     - getWeaponLevel(UInt32)      -> Int32
--     - getMaxWeaponLevel(UInt32)   -> Int32
--     - getNameData(UInt32)         -> app.TextMessageData   localised name
--     - getMaxRemainingBulletNum(UInt32, Int32 level) -> Int32
--   app.InventoryManager (managed singleton)
--     - getCurrentSlotMode()        -> UInt32   (private; main game vs mission)
--     - getGadgetSlotsImpl(UInt32 slotMode) -> List<app.GadgetSlotInfo>
--         (private) the equipped sub-weapon slots. Each GadgetSlotInfo has
--         _ID (weapon id), _GadgetSlotType (app.GadgetSlotType enum) and
--         _RemainingBulletNum.
--     - getGadgetSlotHashes()       -> UInt64[]   public alternative
--     - getGadgetRemainingBulletNum(UInt64) / getGadgetMaxRemainingBulletNum(UInt64)
--     - isWeaponEquipped(UInt32)    -> Boolean
--
-- The slot list is the preferred ammo source because it names the weapon id
-- directly. The UInt64 slot hashes are the fallback; how they encode the id is
-- not documented, so the debug panel prints them raw.

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")

local M = {}

local _s = { inited = false }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local wm = r.td("app.WeaponManager")
    local inv = r.td("app.InventoryManager")
    _s.m_unlocked       = r.method(wm, "getUnlockedWeaponIDs()")
    _s.m_unlocked_main  = r.method(wm, "getUnlockedMainWeaponIDs()")
    _s.m_level          = r.method(wm, "getWeaponLevel(System.UInt32)")
    _s.m_level_max      = r.method(wm, "getMaxWeaponLevel(System.UInt32)")
    _s.m_name           = r.method(wm, "getNameData(System.UInt32)")
    _s.m_max_bullets    = r.method(wm, "getMaxRemainingBulletNum(System.UInt32,System.Int32)")
    _s.m_slot_mode      = r.method(inv, "getCurrentSlotMode()")
    _s.m_gadget_slots   = r.method(inv, "getGadgetSlotsImpl(System.UInt32)")
    _s.m_slot_hashes    = r.method(inv, "getGadgetSlotHashes()")
    _s.m_slot_ammo      = r.method(inv, "getGadgetRemainingBulletNum(System.UInt64)")
    _s.m_slot_ammo_max  = r.method(inv, "getGadgetMaxRemainingBulletNum(System.UInt64)")
    _s.m_is_equipped    = r.method(inv, "isWeaponEquipped(System.UInt32)")
    if _s.m_unlocked == nil then
        log.warn("loadout: WeaponManager.getUnlockedWeaponIDs unresolved")
    end
end

local _name_cache = {}

-- Localised weapon name, falling back to the item catalog, then the internal
-- object id name. Never nil.
function M.weapon_name(id)
    ensure_init()
    local cached = _name_cache[id]
    if cached ~= nil then return cached end
    local wm = r.singleton("app.WeaponManager")
    local name = nil
    if wm ~= nil then name = object_names.text(r.call(_s.m_name, wm, id)) end
    local resolved = name ~= nil
    name = name or object_names.display_name(id)
    resolved = resolved or name ~= nil
    -- A bare number means nothing to the peer; the id is in the debug panel.
    name = name or object_names.object_name(id) or "an unnamed weapon"
    -- Only cache a real name: the catalogs load after the singleton does.
    if resolved then _name_cache[id] = name end
    return name
end

-- Owned weapon ids, or nil outside gameplay. Cheap: one managed call.
function M.owned_ids()
    ensure_init()
    local wm = r.singleton("app.WeaponManager")
    if wm == nil then return nil end
    local arr = r.call(_s.m_unlocked, wm)
    if arr == nil then return nil end
    return r.numbers(arr)
end

-- Weapon ids in the equipped gadget slots (no ammo), or nil.
local function slot_ids(inv)
    local mode = r.to_int(r.call(_s.m_slot_mode, inv))
    if mode == nil then return nil end
    local out = {}
    for _, info in ipairs(r.elements(r.call(_s.m_gadget_slots, inv, mode))) do
        local id = r.to_int(r.field(info, "_ID"))
        if id ~= nil and id ~= 0 then out[#out + 1] = id end
    end
    return out
end

-- Ids of the weapons equipped right now, sorted: whatever sits in a gadget
-- slot, plus every owned weapon the game reports as equipped -- the same rule
-- read() uses for its `equipped` field. Ammo is deliberately not part of it.
-- Nil outside gameplay.
--
-- Round-5 test (2026-10-01): a field pickup does not change the owned list
-- (that only moves at checkpoints / reloads); what changes at the pickup is
-- which weapons are equipped. game_state_observer compares this list.
function M.equipped_ids()
    ensure_init()
    local owned = M.owned_ids()
    if owned == nil then return nil end
    local set = {}
    local inv = r.singleton("app.InventoryManager")
    if inv ~= nil then
        for _, id in ipairs(slot_ids(inv) or {}) do set[id] = true end
        if _s.m_is_equipped ~= nil then
            for _, id in ipairs(owned) do
                if not set[id] and r.call(_s.m_is_equipped, inv, id) == true then set[id] = true end
            end
        end
    end
    local out = {}
    for id in pairs(set) do out[#out + 1] = id end
    table.sort(out)
    return out
end

local function slot_type_name(v)
    local n = r.to_int(v)
    if n == nil then return nil end
    return r.enum_value_names("app.GadgetSlotType")[n] or tostring(n)
end

-- Returns nil outside gameplay, else:
--   { weapons = { { id, name, main, equipped, slot, ammo, ammo_max, level, level_max } },
--     slot_hashes = { {hash, ammo, ammo_max} } }   -- raw, for the debug panel
function M.read()
    ensure_init()
    local wm = r.singleton("app.WeaponManager")
    local inv = r.singleton("app.InventoryManager")
    if wm == nil then return nil end

    local owned = r.numbers(r.call(_s.m_unlocked, wm))
    local main = {}
    for _, id in ipairs(r.numbers(r.call(_s.m_unlocked_main, wm))) do main[id] = true end

    -- Equipped slots, keyed by weapon id.
    local slots = {}
    if inv ~= nil then
        local mode = r.to_int(r.call(_s.m_slot_mode, inv))
        if mode ~= nil then
            for _, info in ipairs(r.elements(r.call(_s.m_gadget_slots, inv, mode))) do
                local id = r.to_int(r.field(info, "_ID"))
                if id ~= nil and id ~= 0 then
                    slots[id] = {
                        slot = slot_type_name(r.field(info, "_GadgetSlotType")),
                        ammo = r.to_int(r.field(info, "_RemainingBulletNum")),
                    }
                end
            end
        end
    end

    local out = { weapons = {}, slot_hashes = {} }
    for _, id in ipairs(owned) do
        local level = r.to_int(r.call(_s.m_level, wm, id))
        local w = {
            id        = id,
            name      = M.weapon_name(id),
            main      = main[id] == true,
            level     = level,
            level_max = r.to_int(r.call(_s.m_level_max, wm, id)),
        }
        local slot = slots[id]
        if slot ~= nil then
            w.equipped, w.slot, w.ammo = true, slot.slot, slot.ammo
        elseif inv ~= nil and _s.m_is_equipped ~= nil then
            w.equipped = r.call(_s.m_is_equipped, inv, id) == true
        end
        if level ~= nil then
            w.ammo_max = r.to_int(r.call(_s.m_max_bullets, wm, id, level))
        end
        out.weapons[#out.weapons + 1] = w
    end

    -- Raw slot hashes, only for diagnosis of the id encoding.
    if inv ~= nil then
        for _, h in ipairs(r.numbers(r.call(_s.m_slot_hashes, inv))) do
            out.slot_hashes[#out.slot_hashes + 1] = {
                hash     = h,
                ammo     = r.to_int(r.call(_s.m_slot_ammo, inv, h)),
                ammo_max = r.to_int(r.call(_s.m_slot_ammo_max, inv, h)),
            }
        end
    end
    return out
end

function M.debug_status()
    ensure_init()
    return {
        weapon_manager    = r.singleton("app.WeaponManager") ~= nil,
        inventory_manager = r.singleton("app.InventoryManager") ~= nil,
        unlocked_ok       = _s.m_unlocked ~= nil,
        gadget_slots_ok   = _s.m_gadget_slots ~= nil,
        slot_mode_ok      = _s.m_slot_mode ~= nil,
    }
end

return M
