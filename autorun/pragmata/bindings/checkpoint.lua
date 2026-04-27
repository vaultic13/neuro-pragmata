--
-- Bindings for "save/checkpoint state." Used by callers to detect when a
-- save point has been activated, without learning the engine's internal
-- name for that save point (which is often the area / story-section name
-- and therefore spoilery).
--
-- Engine layout (verified against the IL2CPP dump):
--
--   Two singleton managers are involved:
--
--   * Checkpoint registry (registered through app.AppSingleton`1<...>):
--       - private field _LastAccessCheckPoint (System.UInt32)
--           The hash of the most recently activated checkpoint. Already
--           opaque numeric — no name string.
--       - private field _CurrentBasementRespawnPointHash (System.UInt32)
--           Sub-area respawn point hash, used in some sections.
--       - private field _CurrentLocalStageCheckPointHash (System.UInt32)
--           Sub-stage checkpoint hash, used in others.
--       - get_CurrentBasementRespawnPointHash() -> UInt32
--           Engine-internal accessor for the basement respawn hash.
--       - getLastAccessCheckPointInfo() -> app.CheckPointInfo
--           Returns the rich info object for the last-accessed checkpoint.
--           The info object's name fields ARE spoilery, so we never reach
--           into it; the UInt32 hash field is the only thing we use.
--
--     We treat _LastAccessCheckPoint as the canonical "last id" and fall
--     back to the two sub-area hashes when it's zero (typical at session
--     start when no checkpoint has been touched yet, or in sections that
--     use one of the localized hash fields instead).
--
--   * Save data manager (registered through app.AppSingleton`1<...>):
--       - get_IsBusy() -> System.Boolean
--           True while a save or load is mid-process. The dump shows the
--           manager has both a request queue and a current-process word;
--           IsBusy collapses both into a single bool.
--           Note: this covers BOTH save and load operations — there's no
--           split predicate in the dump. We treat any busy state as
--           "saving" for narration purposes; misclassifying a load as a
--           save in narration is acceptable, both are world-pause events
--           the listener will hear about anyway.
--
-- All hash fields are already engine-internal numeric ids. We pass them
-- through verbatim — there is nothing to redact at this layer.

local log = require("pragmata.util.log")

local M = {}

-- ---------------------------------------------------------------------------
-- One-time SDK lookups
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    cp_mgr_td = nil,
    save_mgr_td = nil,
    m_get_basement_respawn = nil,   -- get_CurrentBasementRespawnPointHash()
    m_get_is_busy = nil,            -- save manager get_IsBusy()
}

-- Engine names confined to this file; never returned to callers.
-- CONFIDENCE: high — verified against the IL2CPP dump.
local _CP_TYPE = "app.CheckPointManager"
local _SAVE_TYPE = "app.SaveDataManager"
local _M_GET_BASEMENT_RESPAWN = "get_CurrentBasementRespawnPointHash()"
local _M_GET_IS_BUSY = "get_IsBusy()"

-- Internal hash-field names on the checkpoint manager. All UInt32.
local _F_LAST_ACCESS = "_LastAccessCheckPoint"
local _F_BASEMENT_RESPAWN = "_CurrentBasementRespawnPointHash"
local _F_LOCAL_STAGE_CP = "_CurrentLocalStageCheckPointHash"

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

    _state.cp_mgr_td   = td(_CP_TYPE)
    _state.save_mgr_td = td(_SAVE_TYPE)

    if _state.cp_mgr_td ~= nil then
        _state.m_get_basement_respawn = m(_state.cp_mgr_td, _M_GET_BASEMENT_RESPAWN)
    end
    if _state.save_mgr_td ~= nil then
        _state.m_get_is_busy = m(_state.save_mgr_td, _M_GET_IS_BUSY)
    end
end

local function get_cp_singleton()
    ensure_init()
    if _state.cp_mgr_td == nil then return nil end
    local ok, inst = pcall(function() return sdk.get_managed_singleton(_CP_TYPE) end)
    if ok and inst ~= nil then return inst end
    return nil
end

local function get_save_singleton()
    ensure_init()
    if _state.save_mgr_td == nil then return nil end
    local ok, inst = pcall(function() return sdk.get_managed_singleton(_SAVE_TYPE) end)
    if ok and inst ~= nil then return inst end
    return nil
end

-- Read a UInt32 field, returning a Lua number or nil.
local function read_u32_field(obj, name)
    if obj == nil then return nil end
    local ok, v = pcall(function() return obj:get_field(name) end)
    if not ok then return nil end
    if type(v) == "number" then return v end
    -- Boxed/userdata coercion fallback.
    local nok, n = pcall(tonumber, tostring(v))
    if nok and type(n) == "number" then return n end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns an OPAQUE numeric id for the most recently activated checkpoint,
-- or nil if no checkpoint has been activated this session.
--
-- We prefer the top-level "last access" hash; if that's zero (initial-state
-- sentinel) we fall back to the two sub-area hashes. The returned value is
-- always a UInt32-shaped engine hash with NO recoverable name string.
-- CONFIDENCE: high on the field reads (all three fields are present and
-- typed UInt32 in the dump). The "0 means no checkpoint yet" assumption
-- is the engine's standard "unset hash" sentinel and is consistent with
-- how speakerID == 0 is treated elsewhere in this codebase.
function M.get_last_id()
    local cp = get_cp_singleton()
    if cp == nil then return nil end

    local v = read_u32_field(cp, _F_LAST_ACCESS)
    if type(v) == "number" and v ~= 0 then return v end

    -- Fall back to the basement-respawn accessor (preferred) or its field.
    if _state.m_get_basement_respawn ~= nil then
        local ok, mv = pcall(function() return _state.m_get_basement_respawn:call(cp) end)
        if ok and type(mv) == "number" and mv ~= 0 then return mv end
    end
    local fb = read_u32_field(cp, _F_BASEMENT_RESPAWN)
    if type(fb) == "number" and fb ~= 0 then return fb end

    -- And the local-stage checkpoint hash as a final fallback.
    local fl = read_u32_field(cp, _F_LOCAL_STAGE_CP)
    if type(fl) == "number" and fl ~= 0 then return fl end

    return nil
end

-- Returns true while the save subsystem is busy (save OR load in flight),
-- false otherwise. Best-effort.
-- CONFIDENCE: medium — get_IsBusy is a public-via-family accessor in the
-- dump, but its semantics conflate save and load. Callers should treat
-- this as "world is paused for a save/load operation" rather than strictly
-- "saving." If the singleton is unreachable, returns false (the spec
-- allows stubbing to always-false; we go further and try the real call
-- whenever possible).
function M.is_saving()
    local mgr = get_save_singleton()
    if mgr == nil or _state.m_get_is_busy == nil then return false end

    local ok, v = pcall(function() return _state.m_get_is_busy:call(mgr) end)
    if ok and v == true then return true end
    return false
end

return M
