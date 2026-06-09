--
-- Bindings for Diana's environmental Scan ability.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.ScanManager (singleton via app.AppSingleton`1<app.ScanManager>):
--     - requestScan(System.Boolean) -> System.Boolean
--         The single trigger entry point. The Boolean argument toggles a
--         scan-mode flag whose semantics line up with the ScanManager's
--         `isObjectiveOnly` property: true narrows the scan to objective
--         markers, false widens to candidates from the multiple bucket
--         lists (Objective/Item/Interest/EscapeHatch). We map this to:
--           * scan()         -> requestScan(false)   -- broad scan
--           * object_scan()  -> requestScan(false) too (see notes below)
--         Returns Boolean: presumably "scan accepted/queued" vs "rejected".
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
--   flag is set internally — that flag isn't surfaced as a binding-callable
--   field we can verify. We therefore:
--     * scan()        -> requestScan(false). Broad scan.
--     * object_scan() -> requestScan(false). The result set will *include*
--                        item icons iff the player has the upgrade; the
--                        engine handles the gating. This means the two
--                        functions are functionally identical right now
--                        and we mark object_scan() as low-confidence with
--                        a runtime warning so a future bind can split them
--                        if a separate trigger is found.

local log = require("pragmata.util.log")

local M = {}

-- Last scan-trigger outcome, surfaced to the abilities debug panel so the
-- failure mode ("singleton nil" vs "method returned false" vs "errored") is
-- visible in-game without tailing the log.
local _last_scan_msg = "(scan not triggered yet)"

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
}

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

    if _state.scan_mgr_td ~= nil then
        _state.m_request_scan = m(_state.scan_mgr_td, "requestScan(System.Boolean)")
        _state.m_request_scan_objective = m(_state.scan_mgr_td, "requestScanObjective()")
        _state.m_get_is_scanning = m(_state.scan_mgr_td, "get_isScanning()")
        _state.m_get_current_target_units = m(_state.scan_mgr_td, "get_currentTargetUnits()")
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

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Trigger a basic environmental scan. Returns (success_bool, message).
--
-- The trigger path itself is unverified in-game (this is the open "scan does
-- nothing" bug), so M.scan() now: (1) reports precisely which step failed,
-- and (2) falls back from requestScan(false) to requestScanObjective() if the
-- primary call is rejected/errors — they're distinct engine entry points, so
-- one may work where the other doesn't. The detailed outcome is stashed in
-- _last_scan_msg for the abilities debug panel.
function M.scan()
    ensure_init()
    local mgr = get_scan_singleton()
    if mgr == nil then
        _last_scan_msg = "FAIL: scan manager singleton unavailable"
        return false, _last_scan_msg
    end
    if _state.m_request_scan == nil and _state.m_request_scan_objective == nil then
        _last_scan_msg = "FAIL: no scan trigger method resolved from the dump"
        return false, _last_scan_msg
    end

    -- Primary: broad scan via requestScan(false).
    if _state.m_request_scan ~= nil then
        local ok, ret = pcall(function()
            return _state.m_request_scan:call(mgr, false)
        end)
        if ok and ret ~= false then
            _last_scan_msg = "OK: requestScan(false) -> " .. tostring(ret)
            return true, "scan started (" .. _last_scan_msg .. ")"
        end
        _last_scan_msg = "requestScan(false) "
            .. (ok and ("returned " .. tostring(ret)) or "raised an SDK error")
    end

    -- Fallback: objective-only scan. Only reached when the primary was
    -- rejected/errored, so this can't cause a double-scan on the happy path.
    if _state.m_request_scan_objective ~= nil then
        local ok = pcall(function()
            _state.m_request_scan_objective:call(mgr)
        end)
        if ok then
            _last_scan_msg = _last_scan_msg .. "; OK fallback requestScanObjective()"
            return true, "scan started via requestScanObjective() fallback (" .. _last_scan_msg .. ")"
        end
        _last_scan_msg = _last_scan_msg .. "; requestScanObjective() raised an SDK error"
    end

    log.warn("scan.scan: " .. _last_scan_msg)
    return false, "scan not accepted (" .. _last_scan_msg .. ")"
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

-- Trigger an Object-Scan-mode scan. Currently a thin alias of scan() with a
-- runtime warning — see file-level note. The engine includes item-category
-- pings in the result set automatically iff the player has the upgrade, so
-- callers should still inspect get_results() afterward to see whether items
-- were actually surfaced.
-- CONFIDENCE: low — we couldn't find a separate object-scan trigger in the
-- dump; treating this as a duplicate of scan() until proven otherwise.
function M.object_scan()
    local mgr = get_scan_singleton()
    if mgr == nil or _state.m_request_scan == nil then
        return false, "not implemented: scan manager unavailable"
    end

    log.warn("scan.object_scan: low confidence — no distinct Object-Scan trigger found in the dump; calling broad scan and relying on engine to include item pings if upgrade is owned.")

    local ok, accepted = pcall(function()
        return _state.m_request_scan:call(mgr, false)
    end)
    if not ok then
        return false, "scan request raised an SDK error"
    end
    if accepted == false then
        return false, "engine rejected scan request"
    end
    return true, "scan started (object-scan path treated as broad scan; see warning log)"
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
    local count = nil
    do
        local ok, c = pcall(function() return list:call("get_Count") end)
        if ok and type(c) == "number" then count = c end
        if count == nil then
            local ok2, c2 = pcall(function() return list:get_field("_size") end)
            if ok2 and type(c2) == "number" then count = c2 end
        end
    end
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

        if _state.m_su_get_context_id ~= nil then
            local ok, v = pcall(function()
                return _state.m_su_get_context_id:call(u)
            end)
            if ok and v ~= nil then
                -- ContextID is a struct; surface a stable scalar form if we
                -- can extract one, else stringify.
                local ok2, hash = pcall(function() return v:get_field("_Hash") end)
                if ok2 and hash ~= nil then
                    entry.context_id = hash
                else
                    entry.context_id = tostring(v)
                end
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

        return entry
    end

    local pings = {}
    for i = 0, count - 1 do
        local u = nil
        do
            local ok, v = pcall(function() return list:call("get_Item", i) end)
            if ok and v ~= nil then u = v end
        end
        if u == nil then
            local ok, items = pcall(function() return list:get_field("_items") end)
            if ok and items ~= nil then
                local ok2, v = pcall(function() return items:get_element(i) end)
                if ok2 and v ~= nil then u = v end
            end
        end

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


-- Snapshot for the abilities debug panel. Cheap to call every frame.
function M.debug_status()
    ensure_init()
    local mgr = get_scan_singleton()
    local ping_count = 0
    if mgr ~= nil then
        local results = M.get_results()
        if type(results) == "table" and type(results.pings) == "table" then
            ping_count = #results.pings
        end
    end
    return {
        singleton_present    = mgr ~= nil,
        request_scan_ok      = _state.m_request_scan ~= nil,
        request_objective_ok = _state.m_request_scan_objective ~= nil,
        is_scanning          = M.is_scanning(),
        ping_count           = ping_count,
        last_scan_msg        = _last_scan_msg,
    }
end


return M
