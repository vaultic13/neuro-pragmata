--
-- Bindings for Diana's environmental Scan ability.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.ScanManager (singleton via app.AppSingleton`1<app.ScanManager>):
--     - requestScan(System.Boolean) -> System.Boolean
--         The manager's own trigger entry point. A manual runtime trace calls
--         it with true and receives true. This module does NOT call it: it
--         hooks it, so request_progressed() can tell that the engine reached
--         it after we pressed the native Scan command. Calling it directly
--         works but skips the action-driver chain that draws the scan.
--     - requestScanObjective() -> Void
--         Fires an objective-only scan. Distinct from requestScan(true) at
--         the API level even though semantics overlap. We do not surface
--         this directly because both target abilities (basic Scan and
--         Object Scan upgrade) widen results, not narrow.
--     - get_isScanning() -> Boolean
--         Currently scanning?
--     - get_currentTargetUnits() -> List<app.ScanManager.ScanUnit>
--         Most-recent scan output. Each ScanUnit exposes:
--           contextID    : app.ContextID
--           iconTypeHash : UInt32
--           objectIDHash : UInt32
--           offset       : via.vec3
--         get_currentTargetUnits is a private getter in the dump but is
--         also surfaced as a property; we try the property accessor first.
--
-- Re: basic Scan vs. Object Scan upgrade:
--   The dump exposes exactly one trigger entry point that takes a single
--   bool, plus the objective-only convenience. There is no second
--   "Object Scan" entry point in app.ScanManager that can be reached
--   independently. Public sources describe the upgrade as adding extra
--   item categories to the result set, which matches the manager's
--   ItemTargets/InterestTargets/EscapeHatchTargets bucket lists being
--   collected during requestScan based on whether the item-pickup upgrade
--   flag is set internally. So there is nothing for this module to select:
--   one trigger, and the engine decides whether item icons are included.

local log = require("pragmata.util.log")
local command_input = require("pragmata.bindings.command_input")
local object_names = require("pragmata.bindings.object_names")
local config = require("pragmata.mod_config")

-- Fallback for mod_config.scan_report_distance_limit: how many individual
-- distances one row prints before summarising the rest as "+N farther". Bounds
-- the context cost of one crowded room. Distances are all COLLECTED either way;
-- only the rendering is capped, so the "+N" count is exact.
local DEFAULT_DISTANCE_LIMIT = 12

local M = {}

-- Last scan-trigger outcome, surfaced to the abilities debug panel so the
-- failure mode ("singleton nil" vs "method returned false" vs "errored") is
-- visible in-game without tailing the log.
local _last_scan_msg = "(scan not triggered yet)"
local _frame, _request_serial = 0, 0
local _last_request = nil
local REQUEST_DEBOUNCE_FRAMES = 8

-- ---------------------------------------------------------------------------
-- One-time SDK lookups
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    scan_mgr_td = nil,
    scan_unit_td = nil,
    m_request_scan = nil,            -- requestScan(bool) -> bool
    m_request_scan_objective = nil,  -- requestScanObjective() -> void
    m_get_is_scanning = nil,
    m_get_current_target_units = nil, -- private; we try the property
    m_su_get_context_id = nil,
    m_su_get_icon_type_hash = nil,
    m_su_get_object_id_hash = nil,
    m_su_get_offset = nil,
    request_observer_installed = false,
}

local CANDIDATE_FIELDS = {
    { field = "ObjectiveTargets",   label = "objective" },
    { field = "ItemTargets",        label = "item" },
    { field = "InterestTargets",    label = "interest" },
    { field = "EscapeHatchTargets", label = "escape_hatch" },
}

local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local function to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    return safe(function() return value:get_field("value__") end)
end

local function ensure_init()
    if _state.inited then return end
    _state.inited = true

    local function td(name)
        local ok, v = pcall(function() return sdk.find_type_definition(name) end)
        if ok then return v end
        return nil
    end
    local function m(td_obj, sig)
        if td_obj == nil then return nil end
        local ok, v = pcall(function() return td_obj:get_method(sig) end)
        if ok then return v end
        return nil
    end

    _state.scan_mgr_td = td("app.ScanManager")
    _state.scan_unit_td = td("app.ScanManager.ScanUnit")

    -- Per-instance join key (see context_hash).
    _state.m_ctx_hash_code = m(td("app.ContextID"), "GetHashCode()")

    -- Liveness sources. Each is optional: a nil here means the corresponding
    -- filter layer permanently answers "no evidence", which never hides
    -- anything (see classify_ping).
    _state.m_get_scan_display_timer = m(_state.scan_mgr_td, "get_scanDisplayTimer()")
    _state.m_timer_completed = m(td("app.Timer"), "get_Completed()")

    _state.m_find_context  = m(td("app.ContextManager"), "findContext(app.ContextID)")
    _state.m_ctx_get_valid = m(td("app.Context"), "get_Valid()")

    _state.m_is_acquired_cached = m(td("app.ItemManager"),
        "isAcquiredItemFromCache(System.UInt32)")
    _state.m_is_acquired = m(td("app.ItemManager"), "isAcquiredItem(System.UInt32)")

    _state.m_get_backup_ref = m(td("app.PropManager"), "getBackupRef(app.ContextID)")
    -- The non-generic overload, so it can be called with an sdk.typeof value.
    --
    -- NOTE the sibling we deliberately do NOT resolve: LevelObjectBackup also
    -- exposes readyStructureData(...), which CREATES the record when it is
    -- missing. A read path must never be able to reach it, so it is not looked
    -- up at all rather than merely not called.
    _state.m_get_structure_data = m(td("app.LevelObjectBackup"),
        "getStructureData(System.Type)")
    _state.m_is_vanished  = m(td("app.structure.VanishStateData"), "get_IsVanished()")
    _state.m_is_activated = m(td("app.structure.ActiveStateData"), "get_IsActivated()")
    _state.m_box_acquired = m(td("app.structure.TreasureBoxData"), "get_AcquiredItem()")
    _state.m_cont_empty   = m(td("app.structure.ItemContainerData"), "get_IsEmpty()")

    -- Pickup / interaction layer.
    --
    -- getFirstAcquisitionItem() READS the container. Its neighbour
    -- pickFirstAcquisitionItem() CONSUMES it, and is likewise never resolved.
    local cont_td = td("app.structure.ItemContainerData")
    _state.m_cont_first_item = m(cont_td, "getFirstAcquisitionItem()")
    _state.m_cont_slot_id    = m(cont_td, "getFirstSlotItemID()")
    _state.m_cont_perk_id    = m(cont_td, "getFirstPerkItemID()")
    _state.m_acq_get_id      = m(td("app.AcquisitionItemInfo"), "get_ID()")
    _state.m_acq_get_qty     = m(td("app.AcquisitionItemInfo"), "get_Quantity()")
    _state.m_is_restrict     = m(td("app.structure.RestrictInteractData"), "get_IsRestrict()")
    _state.m_is_drawing      = m(td("app.structure.DrawGuiData"), "get_IsDrawing()")
    _state.m_weapon_is_get   = m(td("app.structure.GetWeaponPropData"), "get_IsGet()")
    _state.m_item_kind       = m(td("app.structure.ItemKindData"), "get_Kind()")
    _state.m_is_acquired_earth = m(td("app.ItemManager"),
        "isAcquiredEarthItem(System.UInt32)")

    -- Scene residency. ScanCandidateUnit carries the SceneIDHash it belongs to,
    -- and the environment manager will say whether that scene is currently
    -- activated -- which is the difference between "there is a hatch 40 m that
    -- way" and "there is a hatch 40 m that way, in a room that has not been
    -- streamed in".
    local env_td = td("app.EnvironmentSceneManager")
    _state.m_is_activated_scene  = m(env_td, "isActivatedScene(System.UInt32)")
    _state.m_is_registered_scene = m(env_td, "isRegisteredScene(System.UInt32)")

    -- System.Type arguments, resolved once. Calling sdk.typeof per ping per
    -- frame would be absurd.
    _state.t_vanish    = safe(function() return sdk.typeof("app.structure.VanishStateData") end)
    _state.t_active    = safe(function() return sdk.typeof("app.structure.ActiveStateData") end)
    _state.t_treasure  = safe(function() return sdk.typeof("app.structure.TreasureBoxData") end)
    _state.t_container = safe(function() return sdk.typeof("app.structure.ItemContainerData") end)
    _state.t_restrict  = safe(function() return sdk.typeof("app.structure.RestrictInteractData") end)
    _state.t_draw_gui  = safe(function() return sdk.typeof("app.structure.DrawGuiData") end)
    _state.t_weapon    = safe(function() return sdk.typeof("app.structure.GetWeaponPropData") end)
    _state.t_item_kind = safe(function() return sdk.typeof("app.structure.ItemKindData") end)

    if _state.scan_mgr_td ~= nil then
        _state.m_request_scan = m(_state.scan_mgr_td, "requestScan(System.Boolean)")
        _state.m_request_scan_objective = m(_state.scan_mgr_td, "requestScanObjective()")
        _state.m_get_is_scanning = m(_state.scan_mgr_td, "get_isScanning()")
        _state.m_get_current_target_units = m(_state.scan_mgr_td, "get_currentTargetUnits()")

        -- Observe the normal input-driven manager call so an input request is
        -- confirmed by the engine rather than by the long-lived isScanning
        -- flag. This hook never changes the return value.
        if _state.m_request_scan ~= nil then
            local ok = pcall(function()
                sdk.hook(_state.m_request_scan,
                    function(_args) end,
                    function(retval)
                        if _last_request ~= nil and _last_request.input and retval ~= false then
                            _last_request.engine_called = true
                        end
                        return retval
                    end)
            end)
            _state.request_observer_installed = ok
        end
    end

    if _state.scan_unit_td ~= nil then
        _state.m_su_get_context_id    = m(_state.scan_unit_td, "get_contextID()")
        _state.m_su_get_icon_type_hash = m(_state.scan_unit_td, "get_iconTypeHash()")
        _state.m_su_get_object_id_hash = m(_state.scan_unit_td, "get_objectIDHash()")
        _state.m_su_get_offset         = m(_state.scan_unit_td, "get_offset()")
    end
end

local function get_scan_singleton()
    ensure_init()
    if _state.scan_mgr_td == nil then return nil end
    local ok, inst = pcall(function()
        return sdk.get_managed_singleton("app.ScanManager")
    end)
    if ok and inst ~= nil then return inst end
    return nil
end

local function read_field(object, names)
    if object == nil then return nil end
    for _, name in ipairs(names) do
        local ok, value = pcall(function() return object:get_field(name) end)
        if ok and value ~= nil then return value end
    end
    return nil
end

local function expansion_length(manager)
    return read_field(manager, {
        "_scanExpansionLength_k__BackingField", "<scanExpansionLength>k__BackingField",
    })
end

local function list_count(list)
    if list == nil then return nil end
    local ok, count = pcall(function() return list:call("get_Count") end)
    if ok and type(count) == "number" then return count end
    local ok2, size = pcall(function() return list:get_field("_size") end)
    if ok2 and type(size) == "number" then return size end
    return nil
end

local function list_item(list, index)
    if list == nil then return nil end
    local ok, value = pcall(function() return list:call("get_Item", index) end)
    if ok and value ~= nil then return value end
    local ok_items, items = pcall(function() return list:get_field("_items") end)
    if ok_items and items ~= nil then
        local ok_element, element = pcall(function() return items:get_element(index) end)
        if ok_element then return element end
    end
    return nil
end

-- Normalise to the signed Int32 range.
--
-- ScanCandidateUnit.ContextHash is declared Int32 and ContextID.GetHashCode
-- returns Int32, but REFramework may hand either back as an unsigned value
-- depending on build. Both sides of the join go through this, so a signedness
-- mismatch cannot silently break it. Arithmetic rather than bitwise: this
-- codebase never uses Lua 5.3+ operators, because REFramework's Lua version
-- varies across builds and `&`/`|` can be a syntax error that kills the file.
local function norm_i32(n)
    if type(n) ~= "number" then return nil end
    n = math.floor(n)
    if n >= 2147483648 then n = n - 4294967296 end
    return n
end

-- Per-instance join key for a ping's ContextID.
--
-- app.ContextID is a value type and REFramework exposes those inconsistently
-- across builds, so try the instance call first and the resolved method with
-- the value as `this` second. If neither works, return nil and let the caller
-- fall back to the object/icon pair -- NEVER synthesise a key from RawID, since
-- a fabricated key would join the wrong record silently, which is worse than
-- not joining at all.
local function context_hash(value)
    if value == nil then return nil end
    local direct = to_int(safe(function() return value:call("GetHashCode") end))
    if direct ~= nil then return norm_i32(direct) end
    if _state.m_ctx_hash_code ~= nil then
        local via_method = to_int(safe(function()
            return _state.m_ctx_hash_code:call(value)
        end))
        if via_method ~= nil then return norm_i32(via_method) end
    end
    return nil
end

local function hash_key(object_id, icon_type)
    return tostring(object_id or "?") .. ":" .. tostring(icon_type or "?")
end

local function stable_context_id(value)
    if value == nil then return nil end

    -- ContextID contains a System.Guid. Different REFramework builds expose
    -- value types differently, so try the managed ToString route first and
    -- retain the raw identity only as an explicitly unstable fallback.
    local function as_string(candidate)
        if candidate == nil then return nil end
        local ok, text = pcall(function() return candidate:call("ToString") end)
        if ok and type(text) == "string" and #text > 0 then return text end
        return nil
    end
    local direct = as_string(value)
    if direct ~= nil then return direct end
    local raw = read_field(value, { "_RawID", "<RawID>k__BackingField" })
    local raw_text = as_string(raw)
    if raw_text ~= nil then return raw_text end
    return "unstable:" .. tostring(value)
end

-- Read a via.vec3 into a plain table. REFramework builds expose value types
-- slightly differently, so each component is read defensively.
local function read_vec3(value)
    if value == nil then return nil end
    local x, y, z
    local okx, vx = pcall(function() return value.x end); if okx then x = vx end
    local oky, vy = pcall(function() return value.y end); if oky then y = vy end
    local okz, vz = pcall(function() return value.z end); if okz then z = vz end
    if x == nil and y == nil and z == nil then return nil end
    return { x = x, y = y, z = z }
end

-- Collect the ScanManager's own candidate records, keyed by the same
-- (objectID, iconType) pair the pings use so the two can be joined.
--
-- app.ScanManager.ScanCandidateUnit carries much more than the ScanUnit ping
-- does: a WORLD Position, the engine's own Distance to the player, and the
-- scene/context the candidate belongs to. The ping's `offset` is only a scan-UI
-- offset, so distance and position have to come from here.
local function collect_candidates(manager)
    local by_context, by_pair = {}, {}
    local total, context_keyed, collisions = 0, 0, 0

    for _, spec in ipairs(CANDIDATE_FIELDS) do
        local list = read_field(manager, { spec.field })
        local count = list_count(list) or 0
        for i = 0, count - 1 do
            local candidate = list_item(list, i)
            if candidate ~= nil then
                total = total + 1
                local object_id = read_field(candidate, { "ObjectIDHash" })
                local icon_type = read_field(candidate, { "IconTypeHash" })
                local distance  = read_field(candidate, { "Distance" })
                local position  = read_vec3(read_field(candidate, { "Position" }))
                local scene_id  = read_field(candidate, { "SceneIDHash" })
                local ctx       = norm_i32(read_field(candidate, { "ContextHash" }))

                -- Per-instance index. One record per context, NOT an aggregate:
                -- that is the entire point of this key.
                if ctx ~= nil then
                    context_keyed = context_keyed + 1
                    if by_context[ctx] == nil then
                        by_context[ctx] = {
                            distance = type(distance) == "number" and distance or nil,
                            position = position,
                            scene_id = scene_id,
                            bucket = spec.label,
                            object_id = object_id,
                            icon_type = icon_type,
                        }
                    else
                        -- Two candidates sharing a context hash would falsify
                        -- the per-instance assumption, so count it rather than
                        -- quietly overwriting.
                        collisions = collisions + 1
                    end
                end

                -- Aggregate index, unchanged from the original implementation.
                -- Retained verbatim so the fallback path behaves exactly as it
                -- did before the context key existed.
                local key = hash_key(object_id, icon_type)
                local entry = by_pair[key]
                if entry == nil then
                    entry = { buckets = {}, bucket_order = {}, positions = {},
                              distances = {}, records = {}, scene_ids = {},
                              scene_id_count = 0 }
                    by_pair[key] = entry
                end
                -- One row per candidate, with its fields kept together. The
                -- `distances` and `positions` lists below are appended
                -- independently and can therefore be different lengths, so they
                -- cannot be indexed against each other -- that is exactly the
                -- confusion this list exists to avoid.
                entry.records[#entry.records + 1] = {
                    distance = type(distance) == "number" and distance or nil,
                    position = position,
                    scene_id = scene_id,
                    context_hash = ctx,
                }
                local scene_key = to_int(scene_id)
                if scene_key ~= nil and not entry.scene_ids[scene_key] then
                    entry.scene_ids[scene_key] = true
                    entry.scene_id_count = entry.scene_id_count + 1
                end
                if not entry.buckets[spec.label] then
                    entry.buckets[spec.label] = true
                    table.insert(entry.bucket_order, spec.label)
                end
                if type(distance) == "number" then
                    table.insert(entry.distances, distance)
                    if entry.nearest_distance == nil or distance < entry.nearest_distance then
                        entry.nearest_distance = distance
                    end
                end
                if position ~= nil then table.insert(entry.positions, position) end
                if entry.scene_id == nil then entry.scene_id = scene_id end
                if entry.context_hash == nil then entry.context_hash = ctx end
            end
        end
    end

    return {
        by_context = by_context,
        by_pair = by_pair,
        total = total,
        context_keyed = context_keyed,
        collisions = collisions,
    }
end


-- ---------------------------------------------------------------------------
-- Liveness classification
-- ---------------------------------------------------------------------------
--
-- The scan result list contains far more than is really in front of the
-- player: objects that have been deactivated, containers already looted, items
-- already collected. app.ScanManager.ScanUnit itself carries no state at all --
-- it has exactly four fields (offset, contextID, objectIDHash, iconTypeHash) --
-- so liveness has to be resolved through the ping's ContextID into the systems
-- that do track it.
--
-- THE THREE-VALUED RULE
--
-- Every check below returns one of:
--     true   positive evidence the marker is DEAD
--     false  positive evidence the marker is LIVE
--     nil    no evidence (API missing, call threw, object not found)
--
-- A marker is hidden ONLY on a definite `true`. Absence of evidence never
-- hides anything. That is what makes it structurally impossible for a broken
-- or unavailable layer to empty the report -- it degrades to showing more,
-- never to showing less.

-- Classification costs several managed calls per ping, so it runs only when
-- something is actually going to use the verdict.
--
-- get_results is the neutral raw path -- ability_state's compatibility fallback
-- and the diagnostic traces both call it, and neither looks at liveness. Making
-- every one of those callers pay for a per-ping context lookup would be a real
-- cost for no benefit, so build_inventory raises this flag around its own call
-- and lowers it again afterwards.
local _classify_pings = false

local function bool_result(value)
    if type(value) == "boolean" then return value end
    local n = to_int(value)
    if n == nil then return nil end
    return n ~= 0
end

-- Is this ping's context in the manager's own active set?
-- Inverse polarity: absence is the dead signal, which is why the batch guard in
-- build_inventory disables this layer wholesale if NOTHING matches.
local function check_active_context(manager, ctx)
    if ctx == nil then return nil end
    local set = read_field(manager, { "ActiveContextIDs" })
    if set == nil then return nil end
    local count = to_int(safe(function() return set:call("get_Count") end))
    if count == nil or count == 0 then return nil end
    local contains = bool_result(safe(function() return set:call("Contains", ctx) end))
    if contains == nil then return nil end
    return not contains
end

-- Does the context still resolve to a valid live Context?
local function check_context_valid(ctx)
    if ctx == nil or _state.m_find_context == nil then return nil end
    local manager = safe(function()
        return sdk.get_managed_singleton("app.ContextManager")
    end)
    if manager == nil then return nil end
    local context = safe(function() return _state.m_find_context:call(manager, ctx) end)
    -- A context that no longer exists is not evidence of death: it may simply
    -- belong to an unloaded scene.
    if context == nil then return nil end
    if _state.m_ctx_get_valid == nil then return nil end
    local valid = bool_result(safe(function() return _state.m_ctx_get_valid:call(context) end))
    if valid == nil then return nil end
    return not valid
end

-- Fetch one structure record off a prop backup, or nil when this object simply
-- does not carry that kind of state. All the persisted-state reads share a
-- single getBackupRef call -- one context lookup per read per ping per frame
-- would be indefensible.
local function struct_data(backup, type_value)
    if backup == nil or type_value == nil then return nil end
    if _state.m_get_structure_data == nil then return nil end
    return safe(function()
        return _state.m_get_structure_data:call(backup, type_value)
    end)
end

-- Three-valued read of one boolean structure field.
local function structure_state(backup, type_value, getter)
    if getter == nil then return nil end
    local data = struct_data(backup, type_value)
    if data == nil then return nil end
    return bool_result(safe(function() return getter:call(data) end))
end

-- Everything this marker knows about the item it holds and whether the player
-- could take it right now.
--
-- This is the answer to "is that Upgrade Component still there", and it does
-- not rest on the objectIDHash-is-an-item-id guess that the acquired_items
-- filter rests on: the item ID comes out of the object's OWN container record,
-- so it is an item ID by construction. That also means it can NAME markers the
-- objectIDHash could not -- app.GuiDataManager.getItemData takes exactly this
-- ID space (see object_names.display_name).
--
-- Every field is optional and independently three-valued. An object with no
-- ItemContainerData is not "empty", it is "not a container", and says nothing.
local function inspect_pickup(backup)
    if backup == nil then return nil end

    local info = nil
    local function set(k, v)
        if v == nil then return end
        info = info or {}
        info[k] = v
    end

    local container = struct_data(backup, _state.t_container)
    if container ~= nil then
        set("container", true)
        set("empty", bool_result(safe(function()
            return _state.m_cont_empty:call(container)
        end)))
        if _state.m_cont_slot_id ~= nil then
            local id = to_int(safe(function() return _state.m_cont_slot_id:call(container) end))
            -- 0 is the engine's "no item", not an item whose id is zero.
            if id ~= nil and id ~= 0 then set("item_id", id) end
        end
        if _state.m_cont_perk_id ~= nil then
            local id = to_int(safe(function() return _state.m_cont_perk_id:call(container) end))
            if id ~= nil and id ~= 0 then set("perk_id", id) end
        end
        if _state.m_cont_first_item ~= nil then
            local acq = safe(function() return _state.m_cont_first_item:call(container) end)
            if acq ~= nil then
                if info == nil or info.item_id == nil then
                    local id = to_int(safe(function() return _state.m_acq_get_id:call(acq) end))
                    if id ~= nil and id ~= 0 then set("item_id", id) end
                end
                local qty = to_int(safe(function() return _state.m_acq_get_qty:call(acq) end))
                if qty ~= nil and qty > 0 then set("quantity", qty) end
            end
        end
    end

    set("restricted", structure_state(backup, _state.t_restrict, _state.m_is_restrict))
    set("drawing", structure_state(backup, _state.t_draw_gui, _state.m_is_drawing))
    set("weapon_taken", structure_state(backup, _state.t_weapon, _state.m_weapon_is_get))

    local kind_data = struct_data(backup, _state.t_item_kind)
    if kind_data ~= nil and _state.m_item_kind ~= nil then
        set("kind", to_int(safe(function() return _state.m_item_kind:call(kind_data) end)))
    end

    if info == nil then return nil end

    -- Has this specific item already been collected? Asked with the container's
    -- real item ID, so unlike acquired_items it is not a guess about ID spaces.
    -- Reported regardless; only the earth_item_acquired layer acts on it.
    if info.item_id ~= nil and _state.m_is_acquired_earth ~= nil then
        local item_mgr = safe(function()
            return sdk.get_managed_singleton("app.ItemManager")
        end)
        if item_mgr ~= nil then
            info.earth_acquired = bool_result(safe(function()
                return _state.m_is_acquired_earth:call(item_mgr, info.item_id)
            end))
        end
    end

    -- Three-valued verdict, same rule as everywhere else: only positive
    -- evidence decides, and "this object carries no item state at all" stays
    -- nil rather than becoming a no.
    if info.empty == true or info.weapon_taken == true then
        info.pickable = false
        info.blocked_by = info.empty == true and "empty" or "taken"
    elseif info.restricted == true then
        info.pickable = false
        info.blocked_by = "restricted"
    elseif info.container == true and info.empty == false then
        info.pickable = true
    end

    return info
end

local function prop_backup(ctx)
    if ctx == nil or _state.m_get_backup_ref == nil then return nil end
    local manager = safe(function()
        return sdk.get_managed_singleton("app.PropManager")
    end)
    if manager == nil then return nil end
    return safe(function() return _state.m_get_backup_ref:call(manager, ctx) end)
end

-- Is this scene currently streamed in?
--
-- Note the failure mode, which is why this layer needs no batch guard: if the
-- SceneIDHash were not the ID space isActivatedScene expects, it would answer
-- false for every scene -- but isRegisteredScene would answer false too, and a
-- scene the engine has never heard of is scored `nil`, not `false`. A wrong key
-- therefore degrades to "no evidence" and hides nothing.
--
--   true   the scene is activated -- the marker is somewhere reachable
--   false  the scene is registered but NOT activated -- the object is real, but
--          it is in a room the engine has not loaded, so reporting a distance
--          to it invites the peer to walk at a wall
--   nil    no evidence: no scene id, no manager, or the scene is not even
--          registered (which happens for scenes outside the current chapter and
--          is not the same claim)
--
-- Memoised per inventory build: dozens of pings share a handful of scenes, and
-- this is a managed call.
local _scene_cache = {}

local function scene_active(scene_id)
    local key = to_int(scene_id)
    if key == nil then return nil end
    local cached = _scene_cache[key]
    if cached ~= nil then
        if cached == "unknown" then return nil end
        return cached
    end

    local verdict = nil
    if _state.m_is_activated_scene ~= nil then
        local manager = safe(function()
            return sdk.get_managed_singleton("app.EnvironmentSceneManager")
        end)
        if manager ~= nil then
            local active = bool_result(safe(function()
                return _state.m_is_activated_scene:call(manager, key)
            end))
            if active == true then
                verdict = true
            elseif active == false then
                -- Distinguish "loaded elsewhere / not loaded" from "the engine
                -- has never heard of this scene". Only the former is evidence.
                local known = nil
                if _state.m_is_registered_scene ~= nil then
                    known = bool_result(safe(function()
                        return _state.m_is_registered_scene:call(manager, key)
                    end))
                end
                if known ~= false then verdict = false end
            end
        end
    end

    _scene_cache[key] = verdict == nil and "unknown" or verdict
    return verdict
end

-- Classify one ping. `ctx` is the LIVE managed ContextID -- this runs inside
-- read_unit while it is still in scope, and nothing managed is retained on the
-- returned table, which stays scalars-only.
local function classify_ping(manager, ctx, object_id, icon_name, has_candidate)
    local filters = config.scan_filters or {}
    local checks = {}
    local dead, reason = false, nil

    -- A layer must be explicitly enabled. A missing key counts as OFF, so an
    -- older mod_config without scan_filters degrades to "no filtering" rather
    -- than silently switching every layer on.
    local function apply(layer, verdict)
        checks[layer] = verdict
        if dead then return end
        if verdict == true and filters[layer] == true then
            dead, reason = true, layer
        end
    end

    apply("active_context", check_active_context(manager, ctx))
    apply("context_valid", check_context_valid(ctx))

    local backup = prop_backup(ctx)
    apply("prop_vanished", structure_state(backup, _state.t_vanish, _state.m_is_vanished))

    -- Written as an if, NOT as `activated == nil and nil or (not activated)`.
    -- That idiom is broken for exactly this shape: with activated == nil it
    -- evaluates to `nil or (not nil)` == true, i.e. "no evidence" would have
    -- been reported as "definitely dead" -- inverting the one rule this whole
    -- design rests on.
    local activated = structure_state(backup, _state.t_active, _state.m_is_activated)
    local inactive = nil
    if activated ~= nil then inactive = not activated end
    apply("prop_inactive", inactive)

    -- Three independent "the thing that was here has been taken" flags, on
    -- three different kinds of prop. Any one true is enough; a nil from one
    -- must not overwrite a true from another, hence the ordering.
    local looted = structure_state(backup, _state.t_treasure, _state.m_box_acquired)
    if looted ~= true then
        local empty = structure_state(backup, _state.t_container, _state.m_cont_empty)
        if empty ~= nil then looted = empty end
    end
    if looted ~= true then
        local taken = structure_state(backup, _state.t_weapon, _state.m_weapon_is_get)
        if taken ~= nil then looted = taken end
    end
    apply("prop_looted", looted)

    -- Item ownership. Evaluated even while the filter is off, because the
    -- per-icon breakdown is the only way to test the assumption behind it: that
    -- ScanUnit.objectIDHash lives in the same ID space as item IDs. If a Goal
    -- or Hatch marker ever comes back "acquired", it does not.
    local acquired = nil
    local getter = _state.m_is_acquired_cached or _state.m_is_acquired
    if getter ~= nil and object_id ~= nil then
        local item_mgr = safe(function()
            return sdk.get_managed_singleton("app.ItemManager")
        end)
        if item_mgr ~= nil then
            acquired = bool_result(safe(function()
                return getter:call(item_mgr, object_id)
            end))
        end
    end
    checks.acquired_raw = acquired
    -- Only Item-icon markers can be hidden by it, even when the layer is on.
    local acquired_verdict = nil
    if icon_name == "Item" then acquired_verdict = acquired end
    apply("acquired_items", acquired_verdict)

    apply("hide_icon", icon_name == "Hide" or nil)
    apply("candidate_match", (has_candidate == false) or nil)

    -- Item / interaction detail. Read off the same backup, so it costs no
    -- further context lookup. Two more layers hang off it, both off by default
    -- (see mod_config): "restricted" is temporary, and "already acquired" is
    -- not per-instance for a stackable resource.
    local pickup = nil
    if config.scan_pickup_checks ~= false then
        pickup = inspect_pickup(backup)
        if pickup ~= nil then
            apply("interact_restricted", pickup.restricted == true or nil)
            apply("earth_item_acquired", pickup.earth_acquired == true or nil)
        end
    end

    return { dead = dead, reason = reason, checks = checks, pickup = pickup }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Scan is fired ONE way: scan_input(), below.
--
-- requestScan(bool) is still resolved and hooked in ensure_init -- the hook is
-- how request_progressed() learns the engine called it -- but this module never
-- calls it. Driving the manager directly skips the action-driver chain that
-- produces the scan's presentation, and the direct-call variants that used to
-- live here (scan, scan_manual_candidate, scan_false_control, object_scan) had
-- no callers left once the diagnostics were removed.

-- Native player-input route. This injects the game's own command-level
-- trigger/down/release press (the default keyboard binding is C), preserving
-- the complete Scan action-driver chain including presentation/VFX. It does
-- not listen for, or generate, an operating-system key event.
function M.scan_input()
    ensure_init()
    local mgr = get_scan_singleton()
    if mgr == nil then
        _last_scan_msg = "FAIL: scan manager singleton unavailable"
        return false, _last_scan_msg
    end
    if _last_request ~= nil and (_frame - _last_request.frame) < REQUEST_DEBOUNCE_FRAMES then
        _last_scan_msg = "FAIL: scan request is locally debounced"
        return false, _last_scan_msg
    end
    local before = expansion_length(mgr)
    local ok, message = command_input.queue_scan()
    if not ok then
        _last_scan_msg = "FAIL: command input unavailable (" .. tostring(message) .. ")"
        return false, _last_scan_msg
    end
    _request_serial = _request_serial + 1
    _last_request = {
        serial = _request_serial,
        frame = _frame,
        before_expansion_length = before,
        after_expansion_length = before,
        input = true,
    }
    _last_scan_msg = "OK: native Scan command queued"
    return true, "native Scan command queued; awaiting engine scan progression"
end

function M.last_request_serial()
    return _last_request and _last_request.serial or nil
end

-- requestScan(true) starts by resetting or advancing the expansion timer.
-- This is a per-request signal and avoids treating the long-lived
-- get_isScanning flag as an exclusivity or success condition.
function M.request_progressed(serial)
    if _last_request == nil or _last_request.serial ~= serial then return false end
    local mgr = get_scan_singleton()
    if mgr == nil then return false end
    if _last_request.input and _last_request.engine_called then return true end
    local current = expansion_length(mgr)
    if type(current) ~= "number" then return false end
    local before, after = _last_request.before_expansion_length, _last_request.after_expansion_length
    return current ~= after or (type(before) == "number" and after ~= before)
end


-- True iff the manager reports a scan currently in flight. Used by the scan-
-- result observer to gate emission on an actual scan (rather than re-reading
-- stale currentTargetUnits after every loading screen).
function M.is_scanning()
    ensure_init()
    local mgr = get_scan_singleton()
    if mgr == nil or _state.m_get_is_scanning == nil then return false end
    local ok, v = pcall(function()
        return _state.m_get_is_scanning:call(mgr)
    end)
    return ok and v == true
end

-- Return the most recent ping results in a neutral, JSON-friendly form.
--   {
--     scanning = bool,
--     pings = {
--       { context_id = <number-ish>, icon_type = <u32>, object_id = <u32>,
--         offset = { x=, y=, z= } },
--       ...
--     }
--   }
-- Returns nil if no manager / no recent results / empty list.
-- CONFIDENCE: medium — get_currentTargetUnits is private in the dump; we
-- try the property accessor first and fall through to a backing-field read.
-- Per-element field reads use the public property accessors which the dump
-- shows exist on ScanUnit.
function M.get_results()
    local mgr = get_scan_singleton()
    if mgr == nil then return nil end

    local list = nil
    if _state.m_get_current_target_units ~= nil then
        local ok, l = pcall(function()
            return _state.m_get_current_target_units:call(mgr)
        end)
        if ok and l ~= nil then list = l end
    end
    if list == nil then
        local ok, l = pcall(function()
            return mgr:get_field("<currentTargetUnits>k__BackingField")
        end)
        if ok and l ~= nil then list = l end
    end
    if list == nil then return nil end

    -- Try to enumerate the managed List<ScanUnit>. REFramework exposes
    -- _items + Count or get_Item(i); cover both.
    local count = list_count(list)
    if count == nil or count <= 0 then
        -- Surface scanning state even with an empty ping list so callers
        -- can distinguish "no recent scan" from "scan in flight."
        local scanning = false
        if _state.m_get_is_scanning ~= nil then
            local ok, v = pcall(function()
                return _state.m_get_is_scanning:call(mgr)
            end)
            if ok and v == true then scanning = true end
        end
        if scanning then
            return { scanning = true, pings = {} }
        end
        return nil
    end

    local function read_unit(u)
        if u == nil then return nil end
        local entry = {}

        local context_value = nil
        if _state.m_su_get_context_id ~= nil then
            local ok, v = pcall(function()
                return _state.m_su_get_context_id:call(u)
            end)
            if ok and v ~= nil then
                -- ContextID is a struct; surface a stable scalar form if we
                -- can extract one, else stringify.
                entry.context_id = stable_context_id(v)
                -- Per-instance join key, and the handle every liveness check
                -- needs. Held only for the body of this function -- nothing
                -- managed is stored on `entry`, which stays scalars-only.
                entry.context_hash = context_hash(v)
                context_value = v
            end
        end

        if _state.m_su_get_icon_type_hash ~= nil then
            local ok, v = pcall(function()
                return _state.m_su_get_icon_type_hash:call(u)
            end)
            if ok then entry.icon_type = v end
        end

        if _state.m_su_get_object_id_hash ~= nil then
            local ok, v = pcall(function()
                return _state.m_su_get_object_id_hash:call(u)
            end)
            if ok then entry.object_id = v end
        end

        if _state.m_su_get_offset ~= nil then
            local ok, v = pcall(function()
                return _state.m_su_get_offset:call(u)
            end)
            if ok and v ~= nil then
                local x, y, z
                local okx, vx = pcall(function() return v.x end); if okx then x = vx end
                local oky, vy = pcall(function() return v.y end); if oky then y = vy end
                local okz, vz = pcall(function() return v.z end); if okz then z = vz end
                entry.offset = { x = x, y = y, z = z }
            end
        end

        -- Classify while the managed ContextID is still in scope. This only
        -- ANNOTATES: get_results never drops a ping, because it is the neutral
        -- data path and ability_state's fallback reads it directly. The drop
        -- happens in build_inventory.
        --
        -- candidate_match is deliberately left unevaluated here (the candidate
        -- index is not built yet); build_inventory applies that layer.
        if _classify_pings then
            local verdict = classify_ping(mgr, context_value, entry.object_id,
                                          object_names.icon_name(entry.icon_type), nil)
            entry.live = not verdict.dead
            entry.filter_reason = verdict.reason
            entry.checks = verdict.checks
            -- Scalars only, like the rest of `entry` -- inspect_pickup never
            -- returns a managed reference.
            entry.pickup = verdict.pickup
        end

        return entry
    end

    local pings = {}
    for i = 0, count - 1 do
        local u = list_item(list, i)

        local entry = read_unit(u)
        if entry ~= nil then table.insert(pings, entry) end
    end

    if #pings == 0 then return nil end

    local scanning = false
    if _state.m_get_is_scanning ~= nil then
        local ok, v = pcall(function()
            return _state.m_get_is_scanning:call(mgr)
        end)
        if ok and v == true then scanning = true end
    end

    return { scanning = scanning, pings = pings }
end

-- Build the inventory. Do not call directly -- M.get_inventory memoises this.
--
-- Returns the last scan's pings, every hash resolved through the engine's own
-- catalogs (bindings/object_names.lua), joined to the ScanManager candidate
-- record for world position and distance, and filtered to what the game still
-- considers live.
--
-- Groups stay keyed by resolved label + icon, i.e. per object id. That keeps
-- full fidelity for the debug tree and the log; collapsing distinct objects
-- into one readable phrase is a PRESENTATION concern and happens in
-- render_rows, downstream of here.
local function build_inventory()
    local mgr = get_scan_singleton()
    -- Ask get_results for liveness verdicts on this one call only.
    _classify_pings = true
    local ok_results, results = pcall(M.get_results)
    _classify_pings = false
    if not ok_results then return nil end
    if mgr == nil or type(results) ~= "table" or type(results.pings) ~= "table" then return nil end

    local candidates = collect_candidates(mgr)
    local filters = config.scan_filters or {}
    local filtering = config.scan_live_candidates_only ~= false

    -- BATCH GUARDS.
    --
    -- Two layers can misfire wholesale rather than per-ping, and both fail in
    -- the direction of hiding everything:
    --   active_context is an inverse-polarity membership test. If the key type
    --     is wrong, Contains returns false for every ping and the whole scan
    --     reads as dead.
    --   context_valid depends on findContext resolving at all.
    -- "Nothing in the level matched" is far more likely to mean the lookup is
    -- wrong than that every marker is dead, so a layer that matched NOTHING is
    -- switched off for this batch instead of being trusted.
    local evidence = { active_context = 0, context_valid = 0, prop = 0 }
    for _, ping in ipairs(results.pings) do
        local checks = ping.checks or {}
        if checks.active_context == false then
            evidence.active_context = evidence.active_context + 1
        end
        if checks.context_valid ~= nil then
            evidence.context_valid = evidence.context_valid + 1
        end
        if checks.prop_vanished ~= nil or checks.prop_inactive ~= nil
            or checks.prop_looted ~= nil then
            evidence.prop = evidence.prop + 1
        end
    end
    local layers_disabled = {
        active_context = evidence.active_context == 0,
        context_valid  = evidence.context_valid == 0,
        prop_state     = evidence.prop == 0,
    }
    local function layer_live(layer)
        if layer == "active_context" then return not layers_disabled.active_context end
        if layer == "context_valid" then return not layers_disabled.context_valid end
        if layer == "prop_vanished" or layer == "prop_inactive" or layer == "prop_looted" then
            return not layers_disabled.prop_state
        end
        return true
    end

    -- Scene activation is live state, so the memo lasts exactly one build.
    _scene_cache = {}

    local grouped, order = {}, {}
    local dropped, filtered_by = {}, {}
    local join = { context = 0, pair = 0, none = 0 }
    local acquired_probe = { asked = 0, true_count = 0, true_by_icon = {} }
    local kept_total = 0

    -- Cursor per (object, icon) pair, so successive pings that fall back to the
    -- aggregate index consume DIFFERENT candidate records. Without this every
    -- ping of a type received the same `nearest_distance`, which is what
    -- produced reports like "4x Upgrade Components (51 / 51 / 51 / 51 m)".
    local pair_cursor = {}

    -- Instance identity, for suppressing repeats. A scan can return several
    -- pings for one physical object (multiple contexts, or the same object
    -- reached through more than one candidate bucket), and each of them is a
    -- separate line in the report describing the same thing in the same place.
    local seen_instances = {}
    local scene_evidence, duplicates = 0, 0
    local dedupe_on = config.scan_dedupe_markers ~= false
    local radius = tonumber(config.scan_dedupe_radius) or 0.5
    if radius <= 0 then radius = 0.5 end

    -- Quantise so that two reads of the same object's position agree even if
    -- the floats differ in the last bits. Two DIFFERENT objects of the same
    -- type closer together than this are merged, which is the intended
    -- trade -- at half a metre they are one pickup as far as the peer cares.
    local function quantise(n)
        if type(n) ~= "number" then return nil end
        return math.floor(n / radius + 0.5)
    end

    local function instance_key(object_id, icon_type, position, distance)
        local head = tostring(object_id) .. "|" .. tostring(icon_type)
        if position ~= nil then
            local qx, qy, qz = quantise(position.x), quantise(position.y), quantise(position.z)
            if qx ~= nil or qy ~= nil or qz ~= nil then
                return head .. "|p:" .. tostring(qx) .. "," .. tostring(qy)
                    .. "," .. tostring(qz)
            end
        end
        -- Distance-only fallback, used when the candidate carries no world
        -- position. WEAKER than the position key on purpose: two distinct
        -- objects of one type at equal range in different directions collapse
        -- into one. That is the cost of the only identity available.
        local qd = quantise(distance)
        if qd ~= nil then return head .. "|d:" .. tostring(qd) end
        -- No position and no distance: nothing to compare, so never suppressed.
        return nil
    end

    local pickup_stats = { asked = 0, containers = 0, pickable = 0, blocked = 0,
                           named_from_container = 0, blocked_by = {} }

    for _, ping in ipairs(results.pings) do
        local object = object_names.resolve_object(ping.object_id)
        local icon = object_names.icon_name(ping.icon_type)

        -- A container knows the real ID of the item inside it, and that ID is
        -- in the same catalog space app.GuiDataManager.getItemData indexes. So
        -- an object whose own objectIDHash the catalogs cannot name can still
        -- be named by what it CONTAINS -- which is what turns a line like
        -- "1x sm72_035_10 (Item)" into "1x Upgrade Components".
        local pickup = ping.pickup
        if pickup ~= nil then
            pickup_stats.asked = pickup_stats.asked + 1
            if pickup.container then pickup_stats.containers = pickup_stats.containers + 1 end
            if pickup.pickable == true then
                pickup_stats.pickable = pickup_stats.pickable + 1
            elseif pickup.pickable == false then
                pickup_stats.blocked = pickup_stats.blocked + 1
                local why = tostring(pickup.blocked_by or "unknown")
                pickup_stats.blocked_by[why] = (pickup_stats.blocked_by[why] or 0) + 1
            end
            if not object.named and pickup.item_id ~= nil then
                local contained = object_names.display_name(pickup.item_id)
                if contained ~= nil then
                    -- Copy rather than mutate: resolve_object's result is
                    -- rebuilt per ping, but treating it as owned here would be
                    -- a trap the day it starts being cached.
                    object = {
                        hash = object.hash, display = contained,
                        internal = object.internal, kind = object.kind,
                        label = contained, resolved = true, named = true,
                        named_from_container = true,
                    }
                    pickup_stats.named_from_container =
                        pickup_stats.named_from_container + 1
                end
            end
        end

        -- Join, per instance first.
        local candidate, join_mode = nil, nil
        if ping.context_hash ~= nil then
            candidate = candidates.by_context[ping.context_hash]
            if candidate ~= nil then join_mode = "context" end
        end
        local pair, pair_record = nil, nil
        if candidate == nil then
            local pair_key = hash_key(ping.object_id, ping.icon_type)
            pair = candidates.by_pair[pair_key]
            if pair ~= nil then
                join_mode = "pair"
                -- Take the NEXT unused candidate of this type rather than the
                -- aggregate nearest. When the pings outnumber the candidates
                -- the surplus gets no distance at all, which is honest: there
                -- is no record left to describe them.
                local n = (pair_cursor[pair_key] or 0) + 1
                pair_cursor[pair_key] = n
                pair_record = (pair.records or {})[n]
            end
        end
        join[join_mode or "none"] = join[join_mode or "none"] + 1

        -- Where in the world this ping is, if anywhere. Resolved once, here,
        -- because the scene check, the duplicate check and the group all need
        -- the same answer and must not disagree about it.
        local ping_position, ping_distance, ping_scene = nil, nil, nil
        if candidate ~= nil then
            ping_position, ping_distance = candidate.position, candidate.distance
            ping_scene = candidate.scene_id
        elseif pair_record ~= nil then
            ping_position, ping_distance = pair_record.position, pair_record.distance
            ping_scene = pair_record.scene_id
        elseif pair ~= nil and pair.scene_id_count == 1 then
            -- No record left, but every candidate of this type lives in one
            -- scene, so the scene answer is still unambiguous.
            ping_scene = pair.scene_id
        end

        -- Item-ownership probe, tallied by icon. A non-zero count against any
        -- non-Item icon disproves the assumption that objectIDHash is an item
        -- id, which is the whole reason the acquired_items filter ships off.
        if (ping.checks or {}).acquired_raw ~= nil then
            acquired_probe.asked = acquired_probe.asked + 1
            if ping.checks.acquired_raw == true then
                local key = tostring(icon or "unknown")
                acquired_probe.true_count = acquired_probe.true_count + 1
                acquired_probe.true_by_icon[key] = (acquired_probe.true_by_icon[key] or 0) + 1
            end
        end

        -- Apply the LIVENESS layers that need the join, and so could not be
        -- decided inside read_unit. Kept in its own variable because the master
        -- switch applies to these and only these.
        local live_reason = ping.filter_reason
        if live_reason ~= nil and not layer_live(live_reason) then live_reason = nil end
        if live_reason == nil and filters.candidate_match and join_mode == nil then
            live_reason = "candidate_match"
        end

        -- Scene residency. A marker in a scene the engine has not streamed in
        -- is real, but the distance to it is a direction to walk into unloaded
        -- geometry, so it must not be reported as if it were reachable.
        -- `== true`, like every other layer: a mod_config without the key
        -- counts as OFF rather than silently switching a filter on.
        if filters.scene_loaded == true then
            local active = scene_active(ping_scene)
            -- Counted even when the layer decides nothing, because "did the
            -- scene manager answer at all" is the diagnostic.
            if active ~= nil then scene_evidence = scene_evidence + 1 end
            if live_reason == nil and active == false then live_reason = "scene_loaded" end
        end

        local reason = nil
        if filtering then reason = live_reason end

        -- Duplicate suppression runs whether or not the liveness filter is on:
        -- it is a data-quality fix, not a judgement about what is alive. Hence
        -- it is tested against `reason` AFTER the master switch has been
        -- applied -- testing it against live_reason would have quietly disabled
        -- deduplication for every ping that had a liveness reason while the
        -- filter was switched off.
        --
        -- It cannot empty the report by construction: the FIRST ping at any
        -- given identity is always the one that is kept.
        if reason == nil and dedupe_on then
            local id = instance_key(ping.object_id, ping.icon_type,
                                    ping_position, ping_distance)
            if id ~= nil then
                if seen_instances[id] then
                    reason = "duplicate"
                    duplicates = duplicates + 1
                else
                    seen_instances[id] = true
                end
            end
        end

        if reason ~= nil then
            filtered_by[reason] = (filtered_by[reason] or 0) + 1
            if #dropped < 40 then
                dropped[#dropped + 1] = {
                    label = object.label,
                    internal = object.internal,
                    icon = icon,
                    reason = reason,
                    distance = ping_distance,
                    scene_id = ping_scene,
                }
            end
        else
            kept_total = kept_total + 1
            local key = tostring(object.label) .. "|" .. tostring(icon or ping.icon_type)
            local item = grouped[key]
            if item == nil then
                local buckets = nil
                if pair ~= nil and #pair.bucket_order > 0 then
                    buckets = table.concat(pair.bucket_order, "+")
                elseif candidate ~= nil then
                    buckets = candidate.bucket
                end
                item = {
                    key       = key,
                    label     = object.label,
                    display   = object.display,
                    internal  = object.internal,
                    kind      = object.kind,
                    resolved  = object.resolved,
                    named     = object.named,
                    named_from_container = object.named_from_container,
                    icon      = icon,
                    buckets   = buckets,
                    object_id = ping.object_id,
                    icon_type = ping.icon_type,
                    -- `name` and `category` keep their old meaning for existing
                    -- consumers; both carry a resolved value when one exists.
                    name      = object.label,
                    category  = object.kind or buckets or "unresolved",
                    nearest_distance = nil,
                    distances = {},
                    scene_id  = candidate and candidate.scene_id
                        or (pair and pair.scene_id) or nil,
                    positions = {},
                    count     = 0,
                    contexts  = {},
                    offsets   = {},
                    pair_joined = 0,
                    -- Pickup rollup for this group.
                    pickable  = 0,
                    blocked   = 0,
                    blocked_by = nil,
                    quantity  = 0,
                    item_id   = nil,
                }
                grouped[key] = item
                table.insert(order, item)
            end
            item.count = item.count + 1
            if ping.context_id ~= nil then table.insert(item.contexts, ping.context_id) end
            if ping.offset ~= nil then table.insert(item.offsets, ping.offset) end

            if pickup ~= nil then
                if pickup.pickable == true then
                    item.pickable = item.pickable + 1
                elseif pickup.pickable == false then
                    item.blocked = item.blocked + 1
                    item.blocked_by = item.blocked_by or {}
                    local why = tostring(pickup.blocked_by or "unknown")
                    item.blocked_by[why] = (item.blocked_by[why] or 0) + 1
                end
                if type(pickup.quantity) == "number" then
                    item.quantity = item.quantity + pickup.quantity
                end
                if item.item_id == nil then item.item_id = pickup.item_id end
            end

            -- Distance accumulates PER PING, from the one record resolved for
            -- this ping above. The original code copied the whole aggregate
            -- list onto every group sharing an object id, so a group's
            -- distances were pooled from unrelated instances; the version after
            -- that handed every pair-joined ping the same `nearest_distance`.
            -- Both showed up as repeated numbers in the report.
            if pair_record ~= nil then item.pair_joined = item.pair_joined + 1 end
            if ping_position ~= nil then
                table.insert(item.positions, ping_position)
            end
            if type(ping_distance) == "number" then
                table.insert(item.distances, ping_distance)
                if item.nearest_distance == nil or ping_distance < item.nearest_distance then
                    item.nearest_distance = ping_distance
                end
            end
        end
    end

    -- SAFETY NET. If filtering removed everything, it is wrong -- a scan that
    -- returned pings did find something. Report unfiltered and say so, loudly,
    -- rather than telling the AI the area is empty.
    local raw_count = #results.pings
    local bypassed, note = false, nil
    if filtering and kept_total == 0 and raw_count > 0 then
        bypassed = true
        note = "every marker was filtered out, which cannot be right; reporting unfiltered"
        log.warn("scan: " .. note)
        -- Rebuild without filtering rather than trying to unwind the loop.
        local saved = config.scan_live_candidates_only
        config.scan_live_candidates_only = false
        local unfiltered = build_inventory()
        config.scan_live_candidates_only = saved
        if unfiltered ~= nil then
            unfiltered.filter_bypassed = true
            unfiltered.filter_note = note
            unfiltered.layers_disabled = layers_disabled
            unfiltered.filtered_by = filtered_by
            return unfiltered
        end
    elseif filtering and kept_total > 0 and kept_total < raw_count * 0.05 then
        log.warn(string.format(
            "scan: filter kept only %d of %d markers; plausible late in a level, "
            .. "but worth checking the Filtered-out list", kept_total, raw_count))
    end

    table.sort(order, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.label) < tostring(b.label)
    end)

    -- Staleness is reported, never acted on. Dropping stale results would make
    -- pragmata_scan_results return "nothing" seconds after every scan, which
    -- destroys the point of that action.
    local stale = nil
    if _state.m_get_scan_display_timer ~= nil then
        local timer = safe(function() return _state.m_get_scan_display_timer:call(mgr) end)
        if timer ~= nil then
            local completed = safe(function() return timer:call("get_Completed") end)
            if completed == nil and _state.m_timer_completed ~= nil then
                completed = safe(function() return _state.m_timer_completed:call(timer) end)
            end
            if type(completed) == "boolean" then stale = completed end
        end
    end

    return {
        scanning = results.scanning,
        total_count = kept_total,
        raw_count = raw_count,
        filtered_count = raw_count - kept_total,
        groups = order,
        dropped = dropped,
        filtered_by = filtered_by,
        layers_disabled = layers_disabled,
        filter_enabled = filtering,
        filter_bypassed = bypassed,
        filter_note = note,
        join = join,
        candidates_total = candidates.total,
        candidates_context_keyed = candidates.context_keyed,
        context_collisions = candidates.collisions,
        active_context_count = list_count(read_field(mgr, { "ActiveContextIDs" })),
        acquired_probe = acquired_probe,
        pickup_stats = pickup_stats,
        duplicates_removed = duplicates,
        scene_evidence = scene_evidence,
        stale = stale,
    }
end

-- How long a built inventory stays reusable. Six frames matches
-- ability_state's 10 Hz poll.
local INVENTORY_CACHE_FRAMES = 6
local _inventory_cache = { frame = -1, serial = nil, value = nil, recomputes = 0 }

-- Memoised inventory.
--
-- Two reasons, and the second is the important one:
--
--  1. Cost. The debug panel calls get_inventory() AND describe_results() every
--     frame, and describe_results calls get_inventory again -- three full
--     passes of several managed calls per ping, per frame.
--
--  2. Correctness. ability_state calls describe_results up to 20 times per
--     scan window and deduplicates on the fingerprint. Filter verdicts are live
--     state: if the player loots a chest mid-window, a verdict flips, the
--     fingerprint changes, the dedup accepts it as new, and the AI is told
--     "Diana scanned:" twice for one scan. Pinning the result per request
--     serial makes that impossible.
function M.get_inventory()
    local serial = M.last_request_serial()
    local cache = _inventory_cache
    if cache.value ~= nil and cache.serial == serial
        and (_frame - cache.frame) < INVENTORY_CACHE_FRAMES then
        return cache.value
    end
    local built = build_inventory()
    _inventory_cache = {
        frame = _frame,
        serial = serial,
        value = built,
        recomputes = cache.recomputes + 1,
    }
    return built
end

-- Technical fingerprint of the current inventory. Deliberately hash-based and
-- distance-free: ability_state uses it to deduplicate emissions within one scan
-- window, so it must not change as the player walks around.
function M.inventory_summary(inventory)
    inventory = inventory or M.get_inventory()
    if inventory == nil then return nil end
    local parts = {}
    for _, group in ipairs(inventory.groups) do
        table.insert(parts, string.format("%dx %s/%s (%s)", group.count,
            tostring(group.object_id), tostring(group.icon_type), group.category))
    end
    return {
        scanning = inventory.scanning,
        total_count = inventory.total_count,
        group_count = #inventory.groups,
        fingerprint = table.concat(parts, " | "),
    }
end

-- Render the distance qualifier for one row.
--
-- "located" (the default) lists EVERY instance the engine could place, which is
-- the difference between "there are twelve of these somewhere" and "there are
-- twelve, and four of them are at 51, 63, 70 and 88 metres". A peer that has to
-- walk to one of them cannot act on the first sentence.
--
-- "grouped" keeps the old nearest-only phrasing.
local function distance_phrase(row)
    local n = #row.distances
    if n == 0 then return nil end
    if n == 1 then return string.format("%.0f m", row.distances[1]) end
    if config.scan_report_detail == "grouped" then
        return string.format("nearest %.0f m", row.nearest_distance)
    end

    local limit = tonumber(config.scan_report_distance_limit) or DEFAULT_DISTANCE_LIMIT
    if limit < 1 then limit = 1 end
    local sorted = {}
    for i = 1, n do sorted[i] = row.distances[i] end
    table.sort(sorted)
    local shown = n
    if shown > limit then shown = limit end
    local rendered = {}
    for i = 1, shown do rendered[i] = string.format("%.0f", sorted[i]) end
    local text = table.concat(rendered, " / ") .. " m"
    if n > shown then
        text = text .. string.format(", +%d farther", n - shown)
    end
    return text
end

-- Collapse inventory groups into what a reader would actually say.
--
-- get_inventory keys groups per object id, which is right for the log and the
-- debug tree. It is wrong for a sentence: fifteen separate objects that all
-- render as "sub-objective marker" should be one phrase, not fifteen.
--
-- Two groups merge only when they render identically -- same localised name, or
-- same icon type when there is no name. Distinct objects sharing an icon DO
-- merge, and that is the point; the unmerged detail is still in get_inventory
-- and log_inventory.
local function render_rows(inventory)
    local rows, order = {}, {}
    for _, group in ipairs(inventory.groups) do
        -- `named` means a localised, player-facing name exists. Internal
        -- developer codes like "sm90_129_00" are `resolved` but not `named`,
        -- and are never shown to the AI.
        local key = (group.named and ("n:" .. tostring(group.display))
            or ("i:" .. tostring(group.icon))) .. "|" .. tostring(group.icon)
        local row = rows[key]
        if row == nil then
            row = {
                named = group.named == true,
                display = group.display,
                icon = group.icon,
                icon_type = group.icon_type,
                count = 0,
                distances = {},
                nearest_distance = nil,
                pickable = 0,
                blocked = 0,
                quantity = 0,
                blocked_by = nil,
            }
            rows[key] = row
            order[#order + 1] = row
        end
        row.named = row.named or (group.named == true)
        if row.display == nil then row.display = group.display end
        row.count = row.count + (group.count or 0)
        if type(group.nearest_distance) == "number"
            and (row.nearest_distance == nil or group.nearest_distance < row.nearest_distance) then
            row.nearest_distance = group.nearest_distance
        end
        -- Every distance is kept. Truncating here would make the renderer's
        -- "+N farther" count a lie, and one float per ping is not a cost worth
        -- lying about; distance_phrase caps what is actually printed.
        for _, d in ipairs(group.distances) do
            row.distances[#row.distances + 1] = d
        end
        row.pickable = (row.pickable or 0) + (group.pickable or 0)
        row.blocked = (row.blocked or 0) + (group.blocked or 0)
        row.quantity = (row.quantity or 0) + (group.quantity or 0)
        if group.blocked_by ~= nil then
            row.blocked_by = row.blocked_by or {}
            for why, n in pairs(group.blocked_by) do
                row.blocked_by[why] = (row.blocked_by[why] or 0) + n
            end
        end
    end

    table.sort(order, function(a, b)
        -- Located things first. A marker the engine can place is one the peer
        -- can walk to; everything else is trivia, and under the default report
        -- settings it will not be printed at all.
        local al, bl = #a.distances > 0, #b.distances > 0
        if al ~= bl then return al end
        -- Then nearest, because that is the one it will act on.
        local ad = a.nearest_distance or math.huge
        local bd = b.nearest_distance or math.huge
        if ad ~= bd then return ad < bd end
        -- Named things ahead of anonymous markers at the same range.
        if a.named ~= b.named then return a.named end
        if a.count ~= b.count then return a.count > b.count end
        return tostring(a.display or a.icon) < tostring(b.display or b.icon)
    end)
    return order
end

-- Phrase for one rendered row.
--   named, Item icon   "4x Upgrade Components (51 / 63 / 70 / 88 m)"
--   named, other icon  "1x Reactor Core (Goal, 12 m)"
--   unnamed            "3x escape hatches (28 / 44 / 61 m)"
--
-- The leading count is the number of instances actually being described -- the
-- located ones -- because that is what the distance list enumerates. Instances
-- the engine could not place are not mentioned at all: a count the distance
-- list cannot account for was noise to the peer, which can only act on things
-- it can walk to. They remain visible in get_inventory() and the debug panel.
--
-- The icon qualifier is dropped for named items because "(Item)" after a name
-- the player reads in their own inventory is pure token cost, and dropped for
-- unnamed markers because the phrase already IS the icon type -- "objective
-- marker (Goal)" says the same thing twice.
local function row_text(row)
    local located = #row.distances
    local shown_count = located > 0 and located or row.count

    local subject
    local qualifiers = {}
    if row.named then
        subject = tostring(row.display)
        if row.icon ~= nil and row.icon ~= "Item" then
            table.insert(qualifiers, tostring(row.icon))
        end
    else
        subject = object_names.icon_phrase_text(row.icon_type, shown_count)
    end

    local distance = distance_phrase(row)
    if distance ~= nil then table.insert(qualifiers, distance) end

    -- Only worth saying when it is not the whole story: if every instance is
    -- blocked the row is about something you cannot take, and if none is, the
    -- default assumption is already right.
    --
    -- No count on the partial case. `blocked` is counted across the WHOLE
    -- group, but the row describes only its located instances, so "15 blocked"
    -- could sit next to a leading "2x" and read as a contradiction. The
    -- all-blocked test still uses row.count, which is sound in the other
    -- direction: if every instance is blocked then every shown one is too.
    if (row.blocked or 0) > 0 then
        if row.blocked >= row.count then
            table.insert(qualifiers, "cannot be taken yet")
        else
            table.insert(qualifiers, "some cannot be taken yet")
        end
    end

    local text = string.format("%dx %s", shown_count, subject)
    if #qualifiers > 0 then
        text = text .. " (" .. table.concat(qualifiers, ", ") .. ")"
    end
    return text
end

-- A player/AI-readable result summary, e.g.
--   "4x Upgrade Components (51 / 63 / 70 / 88 m),
--    3x escape hatches (28 / 44 / 61 m),
--    2x sub-objective markers (12 / 90 m)"
--
-- No hashes and no internal codes reach this string. A marker the catalogs
-- cannot name is described by what it is, not by what it is called internally.
--
-- Every number here is a distance in metres, and each row's leading count is
-- exactly how many distances follow it. Nothing else is counted: totals of
-- markers the report is not enumerating told the peer nothing it could act on,
-- so they stay in get_inventory() and the debug panel instead. The one
-- remaining suffix, "(+N more marker types)", reports whole ROWS cut by the
-- display cap, so no kind of marker vanishes without a word.
function M.describe_results()
    local inventory = M.get_inventory()
    if inventory == nil or inventory.total_count <= 0 then return nil end

    local all_rows = render_rows(inventory)

    -- LOCATED-ONLY CUT.
    --
    -- A row with no distance is a marker the engine knows about but cannot
    -- place. Saying "there are 15 sub-objective markers" without being able to
    -- point at one of them is close to worthless to a peer that has to act, and
    -- it was most of the old report by volume.
    --
    -- Same safety rule as the liveness filter: if the cut would leave NOTHING,
    -- it is abandoned for this scan rather than reporting an empty area. That
    -- is not a hypothetical -- it is exactly what happens when the candidate
    -- join fails wholesale (see the `join` counters).
    local rows = all_rows
    local unlocated_rows, unlocated_markers, distance_bypassed = 0, 0, false
    if config.scan_report_require_distance ~= false then
        local located = {}
        for _, row in ipairs(all_rows) do
            if #row.distances > 0 then
                located[#located + 1] = row
            else
                unlocated_rows = unlocated_rows + 1
                unlocated_markers = unlocated_markers + row.count
            end
        end
        if #located > 0 then
            rows = located
        elseif #all_rows > 0 then
            distance_bypassed = true
            unlocated_rows, unlocated_markers = 0, 0
        end
    end

    local cap = tonumber(config.scan_report_max_groups) or 8
    local parts, shown = {}, 0
    local cut_rows = 0
    for _, row in ipairs(rows) do
        if shown < cap then
            parts[#parts + 1] = row_text(row)
            shown = shown + 1
        else
            cut_rows = cut_rows + 1
        end
    end

    local text = table.concat(parts, ", ")
    -- A suffix rather than another comma item, so a count of ROWS cut by the
    -- display cap cannot be misread as one more kind of marker.
    if cut_rows > 0 then
        text = text .. string.format(" (+%d more marker %s)",
            cut_rows, cut_rows == 1 and "type" or "types")
    end
    if config.scan_report_diagnostics and inventory.filtered_count > 0 then
        text = text .. string.format(" [filtered %d of %d]",
            inventory.filtered_count, inventory.raw_count)
    end

    -- The fingerprint stays hash-based and is built from the per-object groups,
    -- NOT from the rendered rows: dedup must key on what was found, not on how
    -- it happened to be phrased.
    local technical = M.inventory_summary(inventory)
    return {
        text = text,
        total_count = inventory.total_count,
        group_count = #inventory.groups,
        row_count = #rows,
        row_count_all = #all_rows,
        unlocated_rows = unlocated_rows,
        unlocated_markers = unlocated_markers,
        distance_bypassed = distance_bypassed,
        stale = inventory.stale,
        filtered_count = inventory.filtered_count,
        raw_count = inventory.raw_count,
        filter_bypassed = inventory.filter_bypassed,
        fingerprint = technical and technical.fingerprint or nil,
    }
end

function M.log_inventory()
    local inventory = M.get_inventory()
    if inventory == nil then
        log.info("scan inventory: unavailable")
        return false, "scan inventory unavailable"
    end
    log.info(string.format(
        "scan inventory: %d reported / %d raw (%d filtered) in %d groups%s%s",
        inventory.total_count, inventory.raw_count, inventory.filtered_count,
        #inventory.groups,
        inventory.scanning and " (scan active)" or "",
        inventory.filter_bypassed and " [FILTER BYPASSED]" or ""))
    if inventory.filter_note then
        log.warn("scan inventory: " .. tostring(inventory.filter_note))
    end
    log.info(string.format("scan inventory: join ctx=%d pair=%d none=%d, candidates %d (%d keyed), activeContexts=%s",
        inventory.join.context, inventory.join.pair, inventory.join.none,
        inventory.candidates_total or 0, inventory.candidates_context_keyed or 0,
        tostring(inventory.active_context_count)))
    log.info(string.format(
        "scan inventory: %d duplicate ping(s) collapsed, %d scene verdict(s) from EnvironmentSceneManager",
        inventory.duplicates_removed or 0, inventory.scene_evidence or 0))

    local readable = M.describe_results()
    -- Logged next to the raw data on purpose: the AI-facing string and the
    -- groups it came from should be comparable at a glance.
    if readable ~= nil then log.info("scan inventory (readable): " .. readable.text) end

    for _, group in ipairs(inventory.groups) do
        log.info(string.format(
            "scan inventory: %dx %s named=%s display=%s internal=%s kind=%s icon=%s dist=%s object=%s iconhash=%s contexts=%d",
            group.count, tostring(group.label), tostring(group.named),
            tostring(group.display), tostring(group.internal),
            tostring(group.kind), tostring(group.icon),
            group.nearest_distance and string.format("%.1f", group.nearest_distance) or "?",
            tostring(group.object_id), tostring(group.icon_type), #group.contexts))
        if (group.pickable or 0) > 0 or (group.blocked or 0) > 0
            or group.item_id ~= nil then
            local why = {}
            for reason, n in pairs(group.blocked_by or {}) do
                why[#why + 1] = string.format("%s=%d", tostring(reason), n)
            end
            log.info(string.format(
                "scan inventory:   pickup pickable=%d blocked=%d%s itemID=%s qty=%d%s",
                group.pickable or 0, group.blocked or 0,
                #why > 0 and (" [" .. table.concat(why, " ") .. "]") or "",
                tostring(group.item_id), group.quantity or 0,
                group.named_from_container and " (named from contents)" or ""))
        end
    end
    for _, drop in ipairs(inventory.dropped or {}) do
        log.info(string.format("scan filtered out: %s (%s) icon=%s reason=%s dist=%s scene=%s",
            tostring(drop.label), tostring(drop.internal), tostring(drop.icon),
            tostring(drop.reason),
            drop.distance and string.format("%.1f", drop.distance) or "?",
            tostring(drop.scene_id)))
    end
    return true, string.format("logged %d of %d scan entries in %d groups",
        inventory.total_count, inventory.raw_count, #inventory.groups)
end

function M.debug_status()
    ensure_init()
    local mgr = get_scan_singleton()
    -- Raw ping count comes off the memoised inventory rather than a second
    -- get_results pass: this runs every frame the debug panel is open.
    local inventory = M.get_inventory()
    local ping_count = inventory and inventory.raw_count or 0
    local last_request = nil
    if _last_request ~= nil then
        -- Copy scalar fields only: this status is also written to the compact
        -- input-test trace and must not retain a managed object reference.
        last_request = {
            serial = _last_request.serial,
            frame = _last_request.frame,
            input = _last_request.input == true,
            engine_called = _last_request.engine_called == true,
            before_expansion_length = _last_request.before_expansion_length,
            after_expansion_length = _last_request.after_expansion_length,
        }
    end
    return {
        singleton_present    = mgr ~= nil,
        request_scan_ok      = _state.m_request_scan ~= nil,
        request_objective_ok = _state.m_request_scan_objective ~= nil,
        is_scanning          = M.is_scanning(),
        -- RAW ping count, deliberately unfiltered: it is the denominator the
        -- filter counts below are measured against.
        ping_count           = ping_count,
        ping_count_reported  = inventory and inventory.total_count or 0,
        filter_enabled       = inventory and inventory.filter_enabled or false,
        filter_bypassed      = inventory and inventory.filter_bypassed or false,
        filter_note          = inventory and inventory.filter_note or nil,
        filtered_by          = inventory and inventory.filtered_by or {},
        layers_disabled      = inventory and inventory.layers_disabled or {},
        dropped              = inventory and inventory.dropped or {},
        join                 = inventory and inventory.join or nil,
        candidates_total     = inventory and inventory.candidates_total or nil,
        candidates_context_keyed = inventory and inventory.candidates_context_keyed or nil,
        context_collisions   = inventory and inventory.context_collisions or nil,
        active_context_count = inventory and inventory.active_context_count or nil,
        acquired_probe       = inventory and inventory.acquired_probe or nil,
        pickup_stats         = inventory and inventory.pickup_stats or nil,
        duplicates_removed   = inventory and inventory.duplicates_removed or 0,
        scene_evidence       = inventory and inventory.scene_evidence or 0,
        dedupe_enabled       = config.scan_dedupe_markers ~= false,
        pickup_enabled       = config.scan_pickup_checks ~= false,
        require_distance     = config.scan_report_require_distance ~= false,
        stale                = inventory and inventory.stale,
        inventory_recomputes = _inventory_cache.recomputes,
        last_scan_msg        = _last_scan_msg,
        last_request_serial  = M.last_request_serial(),
        last_request         = last_request,
        command_input        = command_input.status(),
    }
end


re.on_frame(function()
    _frame = _frame + 1
end)


return M
