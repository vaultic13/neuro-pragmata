--
-- Bindings for "what world chunk is currently loaded" — used by callers to
-- detect transitions between distinct world areas without ever learning the
-- engine's real names for those areas.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   The engine ships a singleton (registered through app.AppSingleton`1<...>)
--   that tracks the player's currently-active world chunks. Internally it
--   exposes its own opaque-by-default API: it stores chunk identity as
--   System.UInt32 hash arrays, never as string names. The accessors we use:
--
--     - getCurrentSceneIDHashes() -> System.UInt32[]
--         The set of chunk hashes currently considered "the player's
--         present location." Multi-element because adjacent chunks can be
--         simultaneously active during streaming.
--     - getDestSceneIDHashes()    -> System.UInt32[]
--         Pending destination set during a transition. Useful as a
--         secondary signal: when this is non-empty and differs from the
--         current set, a transition is in flight.
--     - app.ISystemLoadingElement.get_IsLoaded() -> System.Boolean
--         Implemented via interface dispatch; true once the singleton's
--         active chunk set has finished loading. We treat false as
--         "menu / loading screen / unloaded."
--     - private field _IsLoaded (Private | ExposeMember, System.Boolean)
--         Direct backing-field fallback if the interface getter isn't
--         reachable through reflection.
--
-- All three of those signals are already engine-internal hashes / booleans
-- with NO name strings touched, so this binding does not need to do its own
-- hashing — the dump-level surface is already opaque. We still combine the
-- hashes into a single stable scalar id so callers have one simple value to
-- compare for "did the area change."
--
-- The combined scalar id is computed as a small Fletcher-style fold over the
-- sorted hash array; it's deterministic per chunk-set, so callers can
-- equality-compare across frames to detect transitions. The fold space is
-- 32-bit so collisions are theoretically possible but practically irrelevant
-- for transition detection (false-equal across two truly different chunk
-- sets is extremely unlikely, and a missed transition would just be a
-- one-frame lag in narration).
--
-- Method-visibility caveat:
--   getCurrentSceneIDHashes / getDestSceneIDHashes are FamANDAssem | Family
--   in the dump (engine-internal, not Public). Same situation as the
--   speaker resolver's get_CurrentParam — REFramework's :call may or may
--   not honor that scope depending on build. We try the method-call path
--   first and fall back to reading the private List<UInt32> backing
--   fields _CurrentSceneID / _DestSceneID (also ExposeMember-tagged).

local log = require("pragmata.util.log")

local M = {}

-- ---------------------------------------------------------------------------
-- One-time SDK lookups (cached at first use)
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    mgr_td = nil,                       -- the world-chunk manager type def
    m_get_current_hashes = nil,         -- getCurrentSceneIDHashes()
    m_get_dest_hashes = nil,            -- getDestSceneIDHashes()
    m_get_is_loaded = nil,              -- ISystemLoadingElement.get_IsLoaded
}

-- Engine type/method names live ONLY here, never returned to callers.
-- CONFIDENCE: high — names verified against the IL2CPP dump.
local _MGR_TYPE = "app.EnvironmentSceneManager"
local _M_GET_CURRENT = "getCurrentSceneIDHashes()"
local _M_GET_DEST = "getDestSceneIDHashes()"
-- The interface-method form REFramework uses for explicit-interface impls.
local _M_GET_IS_LOADED = "app.ISystemLoadingElement.get_IsLoaded()"

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

    _state.mgr_td = td(_MGR_TYPE)
    if _state.mgr_td ~= nil then
        _state.m_get_current_hashes = m(_state.mgr_td, _M_GET_CURRENT)
        _state.m_get_dest_hashes    = m(_state.mgr_td, _M_GET_DEST)
        _state.m_get_is_loaded      = m(_state.mgr_td, _M_GET_IS_LOADED)
    end
end

local function get_singleton()
    ensure_init()
    if _state.mgr_td == nil then return nil end
    local ok, inst = pcall(function() return sdk.get_managed_singleton(_MGR_TYPE) end)
    if ok and inst ~= nil then return inst end
    return nil
end

-- ---------------------------------------------------------------------------
-- Hash-array helpers
-- ---------------------------------------------------------------------------

-- Read a UInt32[] return value into a plain Lua array of numbers, sorted
-- ascending so equal sets fold to equal scalars regardless of ordering.
-- Returns an empty table if anything goes wrong; caller distinguishes
-- "empty" from "missing" via a separate path (see _gather_hashes).
local function array_to_sorted_numbers(arr)
    if arr == nil then return {} end

    local size = nil
    pcall(function() size = arr:get_size() end)
    if size == nil then pcall(function() size = arr:call("get_Length") end) end
    if size == nil then pcall(function() size = #arr end) end
    if type(size) ~= "number" or size <= 0 then return {} end

    local out = {}
    for i = 0, size - 1 do
        local v = nil
        pcall(function() v = arr:get_element(i) end)
        if v == nil then pcall(function() v = arr:call("Get", i) end) end
        if v == nil then pcall(function() v = arr[i + 1] end) end
        if type(v) ~= "number" then
            local ok, n = pcall(tonumber, tostring(v))
            if ok and type(n) == "number" then v = n end
        end
        if type(v) == "number" then
            table.insert(out, v)
        end
    end
    table.sort(out)
    return out
end

-- Read a List<UInt32> (the backing field shape) into the same kind of
-- sorted Lua number array.
local function list_to_sorted_numbers(list)
    if list == nil then return {} end

    local count = nil
    pcall(function() count = list:call("get_Count") end)
    if count == nil then pcall(function() count = list:get_field("_size") end) end
    if type(count) ~= "number" or count <= 0 then return {} end

    local out = {}
    for i = 0, count - 1 do
        local v = nil
        pcall(function() v = list:call("get_Item", i) end)
        if v == nil then
            local items = nil
            pcall(function() items = list:get_field("_items") end)
            if items ~= nil then
                pcall(function() v = items:get_element(i) end)
                if v == nil then pcall(function() v = items[i + 1] end) end
            end
        end
        if type(v) ~= "number" then
            local ok, n = pcall(tonumber, tostring(v))
            if ok and type(n) == "number" then v = n end
        end
        if type(v) == "number" then
            table.insert(out, v)
        end
    end
    table.sort(out)
    return out
end

-- Pull the current-chunk hash set. Tries the engine accessor first, then
-- the ExposeMember-tagged backing list. Returns either a table of numbers
-- (possibly empty) or nil if the singleton is unreachable.
-- CONFIDENCE: high — both surfaces are verified in the dump; the accessor
-- is FamANDAssem-scope which means REFramework may decline it on some
-- builds, but the field path is the standard ExposeMember pattern.
local function gather_current_hashes()
    local mgr = get_singleton()
    if mgr == nil then return nil end

    if _state.m_get_current_hashes ~= nil then
        local ok, arr = pcall(function() return _state.m_get_current_hashes:call(mgr) end)
        if ok and arr ~= nil then
            return array_to_sorted_numbers(arr)
        end
    end

    -- Fallback: the manager has a private List<UInt32> backing field marked
    -- ExposeMember. REFramework field reads honor ExposeMember.
    local ok, list = pcall(function() return mgr:get_field("_CurrentSceneID") end)
    if ok and list ~= nil then
        return list_to_sorted_numbers(list)
    end

    return nil
end

local function gather_dest_hashes()
    local mgr = get_singleton()
    if mgr == nil then return nil end

    if _state.m_get_dest_hashes ~= nil then
        local ok, arr = pcall(function() return _state.m_get_dest_hashes:call(mgr) end)
        if ok and arr ~= nil then
            return array_to_sorted_numbers(arr)
        end
    end

    local ok, list = pcall(function() return mgr:get_field("_DestSceneID") end)
    if ok and list ~= nil then
        return list_to_sorted_numbers(list)
    end

    return nil
end

-- Fold an ascending integer array down to a single 32-bit-ish scalar.
-- Choice of fold: 32-bit Fletcher with rotation, in pure Lua so we don't
-- depend on bit-op extensions. Stable for a given input ordering, which
-- the caller guarantees by sorting first.
-- CONFIDENCE: medium — the fold is simple and deterministic; collisions
-- are theoretically possible but acceptable for transition detection.
local function fold_hash_set(nums)
    if type(nums) ~= "table" or #nums == 0 then return nil end

    -- Single-chunk case: just pass the hash through verbatim. This keeps
    -- the dominant "in one chunk" steady state stable and avoids any
    -- fold-induced mismatch with raw engine ids.
    if #nums == 1 then return nums[1] end

    -- Multi-chunk fold. Use two accumulators and modulus 2^31 - 1 to keep
    -- everything in safe-int territory under Lua 5.1 semantics that
    -- REFramework's Lua runtime uses.
    local MOD = 2147483647 -- 2^31 - 1
    local a, b = 1, 0
    for i = 1, #nums do
        local v = nums[i] % MOD
        a = (a + v) % MOD
        b = (b + a) % MOD
    end
    -- Combine accumulators into one scalar. Avoid bit-ops; multiplicative
    -- mix is good enough here.
    local combined = (a + b * 65521) % MOD
    return combined
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns an OPAQUE numeric identifier for the current world chunk set,
-- or nil if no chunk is currently active (menu, loading, unloaded).
--
-- Callers use this strictly for inequality comparison ("did it change?").
-- The return value is either:
--   * a single engine chunk-hash (UInt32, when the player is in one chunk), or
--   * a folded scalar derived from the sorted set of active chunk hashes,
-- in either case a stable opaque integer with NO recoverable name string.
--
-- CONFIDENCE: high — the engine surface stores chunk identity as UInt32
-- hashes, so there is nothing to redact. The fold step is internal and
-- only collapses the multi-chunk case to a single scalar for caller
-- convenience.
function M.get_current_id()
    local nums = gather_current_hashes()
    if nums == nil then return nil end
    if #nums == 0 then
        -- Active singleton but empty current-chunk list: typically means
        -- "between transitions / not in a streamed area." Treat as "no
        -- current id" so callers don't see a bogus stable zero.
        return nil
    end
    return fold_hash_set(nums)
end

-- Returns true if a non-empty pending destination chunk set exists AND
-- it differs from the current set — i.e. an area transition is in flight.
-- Returns false otherwise (steady state, no pending transition, or
-- singleton unreachable).
-- CONFIDENCE: medium — the dump shows _DestSceneID is the streaming
-- destination, but the exact lifecycle (when it gets cleared) isn't
-- documented in the dump itself. Callers should treat this as a hint,
-- not a contract.
function M.is_transitioning()
    local cur = gather_current_hashes()
    local dst = gather_dest_hashes()
    if dst == nil or #dst == 0 then return false end
    if cur == nil then return true end
    -- Quick set-equality check via folded scalar.
    local cur_fold = fold_hash_set(cur)
    local dst_fold = fold_hash_set(dst)
    if cur_fold == nil or dst_fold == nil then return true end
    return cur_fold ~= dst_fold
end

-- Returns a boolean: true when the world is currently loaded and live;
-- false during menus / loading screens / unloaded states.
-- Falls back to the ExposeMember backing field if the interface getter
-- isn't reachable. Returns false (conservative) on any failure.
-- CONFIDENCE: high — both the interface method and the field are present
-- in the dump.
function M.is_loaded()
    local mgr = get_singleton()
    if mgr == nil then return false end

    if _state.m_get_is_loaded ~= nil then
        local ok, v = pcall(function() return _state.m_get_is_loaded:call(mgr) end)
        if ok and v == true then return true end
        if ok and v == false then return false end
    end

    -- Some REFramework builds expose explicit-interface methods only via
    -- the bare getter name; try that next.
    local ok2, v2 = pcall(function() return mgr:call("get_IsLoaded") end)
    if ok2 and v2 == true then return true end
    if ok2 and v2 == false then return false end

    -- Backing field fallback (Private | ExposeMember).
    local okf, vf = pcall(function() return mgr:get_field("_IsLoaded") end)
    if okf and vf == true then return true end
    if okf and vf == false then return false end

    return false
end

return M
