--
-- Mods, hacking mods and permanent upgrades.
--
-- The game keeps all three in one "perk" system, split by app.PerkType, a
-- smart enum with three members: Passive, Active and Permanent.
--
-- Engine layout (verified against the IL2CPP dump; which menu each list
-- corresponds to is the open question the State Debug panel answers):
--
--   app.EnhanceManager (managed singleton)
--     - getEquippedPassiveSkillIDs()  -> UInt32[]
--     - getAcquiredPassiveSkillIDs()  -> UInt32[]
--     - getPassiveCapacity()          -> Int32
--     - getEquippedActiveSkillInfos() -> app.ActiveSkillItemInfo[]
--         each: <ID>k__BackingField (UInt32), <Count>k__BackingField (Int32,
--         uses left)
--     - getAcquiredActiveSkillIDs()   -> UInt32[]
--     - getActiveCapacity()           -> Int32
--     - getActiveSkillReinforceLevel(UInt32)         -> Int32
--     - getActiveSkillCurrentLevelMaxUseNum(UInt32)  -> Int32
--     - getAcquiredPerkIDs(UInt32 perkTypeHash)      -> UInt32[]   (private)
--     - getPerkLevel(UInt32) / getMaxReinforceLevel(UInt32) -> Int32
--     - isHackingPerk(UInt32)         -> Boolean
--     - _ConvertDictFromActiveSkillToObjectIDs : Dictionary<UInt32,UInt32>
--         active-skill id -> object id, which is what the item catalog names
--   app.ReinforceManager (managed singleton)
--     - getCurrentLevel(UInt32) / getMaxLevel(UInt32) -> Int32
--       fallback level source for perks EnhanceManager reports nothing for
--
-- Working hypothesis, to be confirmed against the menus:
--   Passive   -> "mods" (suit/weapon modifiers, slot-limited)
--   Active    -> "hacking mods" (limited uses per equip)
--   Permanent -> Firmware upgrades
--   Unit Printer -> weapon levels (loadout.lua) + active-skill reinforce levels

local log = require("pragmata.util.log")
local r = require("pragmata.bindings.reflect")
local object_names = require("pragmata.bindings.object_names")

local M = {}

local _s = { inited = false }

local function ensure_init()
    if _s.inited then return end
    _s.inited = true
    local em = r.td("app.EnhanceManager")
    local rm = r.td("app.ReinforceManager")
    _s.m_eq_passive     = r.method(em, "getEquippedPassiveSkillIDs()")
    _s.m_acq_passive    = r.method(em, "getAcquiredPassiveSkillIDs()")
    _s.m_cap_passive    = r.method(em, "getPassiveCapacity()")
    _s.m_eq_active      = r.method(em, "getEquippedActiveSkillInfos()")
    _s.m_acq_active     = r.method(em, "getAcquiredActiveSkillIDs()")
    _s.m_cap_active     = r.method(em, "getActiveCapacity()")
    _s.m_active_level   = r.method(em, "getActiveSkillReinforceLevel(System.UInt32)")
    _s.m_active_uses    = r.method(em, "getActiveSkillCurrentLevelMaxUseNum(System.UInt32)")
    _s.m_acq_perks      = r.method(em, "getAcquiredPerkIDs(System.UInt32)")
    _s.m_perk_level     = r.method(em, "getPerkLevel(System.UInt32)")
    _s.m_perk_level_max = r.method(em, "getMaxReinforceLevel(System.UInt32)")
    _s.m_is_hacking     = r.method(em, "isHackingPerk(System.UInt32)")
    _s.m_rf_level       = r.method(rm, "getCurrentLevel(System.UInt32)")
    _s.m_rf_level_max   = r.method(rm, "getMaxLevel(System.UInt32)")
    _s.m_gui_perk       = r.method(r.td("app.GuiDataManager"), "getPerkData(System.UInt32)")
    _s.m_current_ep     = r.method(em, "get_CurrentEquipmentPerk()")
    if _s.m_eq_passive == nil and _s.m_eq_active == nil then
        log.warn("perks: EnhanceManager equip accessors unresolved")
    end
end

local function enhance() return r.singleton("app.EnhanceManager") end

-- ---------------------------------------------------------------------------
-- Names
-- ---------------------------------------------------------------------------

local _names = {}

-- GUIPerkData for one perk id, through app.GuiDataManager.getPerkData. This
-- is the perk menu's own record: _Name, _SimpleName, _Description, and
-- _ReinforceType (kept raw for the debug panel -- it is the best candidate
-- for telling suit / weapon / hacking Firmware apart).
local function gui_perk(id)
    ensure_init()
    local mgr = r.singleton("app.GuiDataManager")
    if mgr == nil then return nil end
    return r.call(_s.m_gui_perk, mgr, id)
end

local function gui_perk_name(id)
    local data = gui_perk(id)
    if data == nil then return nil end
    return object_names.text(r.field(data, "_Name"))
        or object_names.text(r.field(data, "_SimpleName"))
end

-- Localised name for a perk / skill id. The perk menu's own catalog first;
-- then the item catalog; active-skill ids are not object ids, so the
-- manager's conversion table maps them across for one more try of each.
function M.perk_name(id)
    local cached = _names[id]
    if cached ~= nil then return cached end
    local name = gui_perk_name(id) or object_names.display_name(id)
    if name == nil then
        local dict = r.field(enhance(), "_ConvertDictFromActiveSkillToObjectIDs")
        local obj_id = r.to_int(r.dict_get(dict, id))
        if obj_id ~= nil then
            name = gui_perk_name(obj_id) or object_names.display_name(obj_id)
        end
    end
    if name ~= nil then _names[id] = name return name end
    -- No catalog names it. Say so plainly; the internal code rides along only
    -- so two unnamed mods are not indistinguishable.
    local code = object_names.object_name(id)
    return code and ("unnamed mod (" .. code .. ")") or "an unnamed mod"
end

local _descriptions = {}

-- What a perk does: GUIPerkData._Description, the text the mod terminal shows
-- (shelter_menus.mod_terminal reads the same record). Hacking-mod ids are
-- active-skill ids, so the conversion table gets one more try, as for names.
-- Nil when neither answers.
function M.perk_description(id)
    local cached = _descriptions[id]
    if cached ~= nil then return cached end
    local function desc_of(key)
        local data = gui_perk(key)
        return data and object_names.text(r.field(data, "_Description")) or nil
    end
    local text = desc_of(id)
    if text == nil then
        local dict = r.field(enhance(), "_ConvertDictFromActiveSkillToObjectIDs")
        local obj_id = r.to_int(r.dict_get(dict, id))
        if obj_id ~= nil then text = desc_of(obj_id) end
    end
    if text ~= nil then _descriptions[id] = text end
    return text
end

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- The owned-perk record: EquipmentPerk._PossessionPerkDict[id] -> PossessionPerkUnit
-- { _ID, _Level, _Unlock }. This is what the save stores, and the second test
-- run showed getPerkLevel answering 0 for perks that are levelled (Multihack
-- maxed read 0), so it is read first.
local function possession(em, id)
    local ep = r.call(_s.m_current_ep, em) or r.field(em, "_EquipmentPerkMainGame")
    local dict = r.field(ep, "_PossessionPerkDict")
    return r.dict_get(dict, id)
end

-- Level of one perk, on the MENU's scale.
--
-- Engine levels count upgrades from 0: Multihack, shown as "Lv 3" maxed in
-- game, has an engine maximum of 2. How far the menu is offset from the
-- engine differs by perk kind (a Firmware node reads 0 until bought), so the
-- offset is measured per perk rather than assumed: GUIPerkData._LevelData
-- holds one description per level the menu shows, so its length is the
-- menu's maximum, and menu max - engine max is the offset.
--
-- The engine level is the highest any source reports: the possession record,
-- getPerkLevel, ReinforceManager.getCurrentLevel, and for active skills
-- getActiveSkillReinforceLevel. Each is kept in `level_sources` for the debug
-- panel, since at least one of them was demonstrably reading 0.
local function perk_entry(em, id)
    local sources = {}
    local unit = possession(em, id)
    if unit ~= nil then
        sources.possession = r.to_int(r.field(unit, "_Level"))
        sources.unlocked = r.field(unit, "_Unlock")
    end
    sources.perk_level = r.to_int(r.call(_s.m_perk_level, em, id))
    sources.active_level = r.to_int(r.call(_s.m_active_level, em, id))
    local rm = r.singleton("app.ReinforceManager")
    if rm ~= nil then sources.reinforce = r.to_int(r.call(_s.m_rf_level, rm, id)) end

    local level = nil
    for _, k in ipairs({ "possession", "perk_level", "active_level", "reinforce" }) do
        local v = sources[k]
        if type(v) == "number" and (level == nil or v > level) then level = v end
    end

    local engine_max = r.to_int(r.call(_s.m_perk_level_max, em, id))
    if (engine_max == nil or engine_max <= 0) and rm ~= nil then
        local m = r.to_int(r.call(_s.m_rf_level_max, rm, id))
        if m ~= nil and m > 0 then engine_max = m end
    end
    sources.engine_max = engine_max

    local gui = gui_perk(id)
    local menu_max = nil
    if gui ~= nil then
        local n = #r.elements(r.field(gui, "_LevelData"))
        if n > 0 then menu_max = n end
    end
    sources.menu_max = menu_max

    local offset = 0
    if menu_max ~= nil and engine_max ~= nil and menu_max > engine_max then
        offset = menu_max - engine_max
    end
    local level_max = menu_max or engine_max
    if level ~= nil then level = level + offset end
    if level ~= nil and level_max ~= nil and level > level_max then level = level_max end

    return {
        id             = id,
        name           = M.perk_name(id),
        reinforce_type = gui and r.to_int(r.field(gui, "_ReinforceType")) or nil,
        level          = level,
        level_max      = level_max,
        level_sources  = sources,
        hacking        = r.call(_s.m_is_hacking, em, id) == true,
    }
end

-- Returns nil outside gameplay, else:
--   { mods         = { equipped = {entry + description}, owned = {entry}, capacity = n },
--     hacking_mods = { equipped = {entry + uses, uses_max, description}, owned = {entry}, capacity = n } }
-- Only equipped entries carry a description; pragmata_mods reports nothing else.
function M.read_mods()
    ensure_init()
    local em = enhance()
    if em == nil then return nil end

    local mods = { equipped = {}, owned = {}, capacity = r.to_int(r.call(_s.m_cap_passive, em)) }
    local equipped = {}
    for _, id in ipairs(r.numbers(r.call(_s.m_eq_passive, em))) do
        if id ~= 0 then
            equipped[id] = true
            local e = perk_entry(em, id)
            e.description = M.perk_description(id)
            mods.equipped[#mods.equipped + 1] = e
        end
    end
    for _, id in ipairs(r.numbers(r.call(_s.m_acq_passive, em))) do
        if id ~= 0 and not equipped[id] then mods.owned[#mods.owned + 1] = perk_entry(em, id) end
    end

    local hm = { equipped = {}, owned = {}, capacity = r.to_int(r.call(_s.m_cap_active, em)) }
    local eq_active = {}
    for _, info in ipairs(r.elements(r.call(_s.m_eq_active, em))) do
        local id = r.to_int(r.field(info, "<ID>k__BackingField"))
        if id ~= nil and id ~= 0 then
            eq_active[id] = true
            local e = perk_entry(em, id)
            e.uses     = r.to_int(r.field(info, "<Count>k__BackingField"))
            e.uses_max = r.to_int(r.call(_s.m_active_uses, em, id))
            e.description = M.perk_description(id)
            hm.equipped[#hm.equipped + 1] = e
        end
    end
    for _, id in ipairs(r.numbers(r.call(_s.m_acq_active, em))) do
        if id ~= 0 and not eq_active[id] then
            local e = perk_entry(em, id)
            hm.owned[#hm.owned + 1] = e
        end
    end

    return { mods = mods, hacking_mods = hm }
end

-- Ids of the equipped hacking mods (Active perks), sorted. Ids only -- the
-- remaining-uses count is deliberately left out, so using a mod never reads
-- as a change. Nil outside gameplay. For game_state_observer's equip push.
function M.equipped_hacking_ids()
    ensure_init()
    local em = enhance()
    if em == nil then return nil end
    local arr = r.call(_s.m_eq_active, em)
    if arr == nil then return nil end
    local out, seen = {}, {}
    for _, info in ipairs(r.elements(arr)) do
        local id = r.to_int(r.field(info, "<ID>k__BackingField"))
        if id ~= nil and id ~= 0 and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    table.sort(out)
    return out
end

-- Returns nil outside gameplay, else:
--   { firmware = { {entry} },          -- Permanent perks, with levels
--     abilities = { {entry} } }        -- active skills with their printer level
function M.read_upgrades()
    ensure_init()
    local em = enhance()
    if em == nil then return nil end

    local out = { firmware = {}, abilities = {} }
    local permanent = r.enum_hash("app.PerkType", "Permanent")
    if permanent ~= nil then
        for _, id in ipairs(r.numbers(r.call(_s.m_acq_perks, em, permanent))) do
            if id ~= 0 then out.firmware[#out.firmware + 1] = perk_entry(em, id) end
        end
    end
    for _, id in ipairs(r.numbers(r.call(_s.m_acq_active, em))) do
        if id ~= 0 then
            local e = perk_entry(em, id)
            out.abilities[#out.abilities + 1] = e
        end
    end
    return out
end

function M.debug_status()
    ensure_init()
    return {
        enhance_manager   = enhance() ~= nil,
        reinforce_manager = r.singleton("app.ReinforceManager") ~= nil,
        acquired_perks_ok = _s.m_acq_perks ~= nil,
        permanent_hash    = r.enum_hash("app.PerkType", "Permanent"),
        passive_hash      = r.enum_hash("app.PerkType", "Passive"),
        active_hash       = r.enum_hash("app.PerkType", "Active"),
    }
end

return M
