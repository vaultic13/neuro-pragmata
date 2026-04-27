--
-- Bindings for "are we in active combat right now?" — used by callers to
-- nudge ability narration without leaking enemy identity, encounter type,
-- or any narrative-tagged combat state.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   The engine ships an enemy-roster singleton (registered through
--   app.AppSingleton`1<...>) that maintains two roster lists for the
--   active scene:
--
--     - <IngameMembers>k__BackingField  (List<EnemyHandle>, InitOnly)
--         All enemies the engine considers "in the current scene." Wider
--         than active combat — includes idle / patrolling enemies that
--         haven't engaged the player yet.
--
--     - <EngageMembers>k__BackingField  (List<EnemyHandle>, InitOnly)
--         The subset that has actively engaged the player (the engine's
--         internal "in fight" list — enemies that are aggro'd, locked-on,
--         or otherwise mid-encounter with Hugh).
--
--   Both have property accessors (get_IngameMembers / get_EngageMembers)
--   marked "Private | HideBySig | SpecialName" — engine-internal scope,
--   so reflection-call may decline them. We try the accessors first and
--   fall through to direct backing-field reads.
--
--   Crucially: we ONLY ever read counts off these lists. We never enumerate
--   the EnemyHandle elements, never read names off them, and never expose
--   anything other than a boolean / coarse bucket. There are several other
--   booleans on the singleton (engagement-mode flags) whose names are
--   spoilery; we deliberately do not read them, because their names alone
--   would give callers context about what kind of fight is happening.
--
-- Combat-state derivation:
--
--   * is_in_combat() returns true iff EngageMembers count > 0. This is the
--     engine's own definition of "actively fighting" and matches what the
--     player experiences (lock-on UI active, combat music, etc.).
--
--   * threat_level() buckets the IngameMembers count into none/low/high.
--     Bucket boundaries are conservative because we want a stable signal,
--     not a precise reading:
--       - 0 ingame members        => "none"
--       - 1..3 ingame members     => "low"
--       - 4+ ingame members       => "high"
--     Bucketing IngameMembers (rather than EngageMembers) means we surface
--     a "high threat" hint even before the engage transition fires, which
--     gives callers more lead time to react.
--
-- Note on coverage:
--   The engine has additional combat sub-modes whose distinct flags exist
--   in the dump but whose names are spoilery; we deliberately ignore them
--   and rely on the generic engage-list signal, which is broad enough to
--   cover all of them. This means is_in_combat() may report false during
--   pre-combat ramp-up frames where a scripted encounter is starting but
--   no enemy has yet been entered into the engage list. That's an
--   acceptable lag.

local log = require("pragmata.util.log")

local M = {}

-- ---------------------------------------------------------------------------
-- One-time SDK lookups
-- ---------------------------------------------------------------------------

local _state = {
    inited = false,
    mgr_td = nil,
    m_get_engage_members = nil,
    m_get_ingame_members = nil,
}

-- Engine names live ONLY here.
-- CONFIDENCE: high — verified against the IL2CPP dump.
local _MGR_TYPE = "app.EnemyBattleSystem"
local _M_GET_ENGAGE = "get_EngageMembers()"
local _M_GET_INGAME = "get_IngameMembers()"
local _F_ENGAGE_BACKING = "<EngageMembers>k__BackingField"
local _F_INGAME_BACKING = "<IngameMembers>k__BackingField"

local function ensure_init()
    if _state.inited then return end
    _state.inited = true

    local ok, td = pcall(function() return sdk.find_type_definition(_MGR_TYPE) end)
    if ok and td ~= nil then
        _state.mgr_td = td

        local function m(sig)
            local mok, mv = pcall(function() return td:get_method(sig) end)
            if mok then return mv end
            return nil
        end
        _state.m_get_engage_members = m(_M_GET_ENGAGE)
        _state.m_get_ingame_members = m(_M_GET_INGAME)
    end
end

local function get_singleton()
    ensure_init()
    if _state.mgr_td == nil then return nil end
    local ok, inst = pcall(function() return sdk.get_managed_singleton(_MGR_TYPE) end)
    if ok and inst ~= nil then return inst end
    return nil
end

-- Read a List<>'s Count via either the public accessor or the _size
-- backing field. Returns a Lua number or nil. We deliberately do NOT
-- read .get_Item / iterate elements — only the count is needed and we
-- want zero risk of accidentally surfacing per-enemy data through this
-- file.
local function list_count(list)
    if list == nil then return nil end
    local ok, c = pcall(function() return list:call("get_Count") end)
    if ok and type(c) == "number" then return c end
    local ok2, c2 = pcall(function() return list:get_field("_size") end)
    if ok2 and type(c2) == "number" then return c2 end
    return nil
end

-- Resolve a member-list (engage / ingame) to a count, trying the engine
-- accessor first and the backing field second. Returns a Lua number or
-- nil if neither path is reachable.
local function read_member_count(method, backing_field_name)
    local mgr = get_singleton()
    if mgr == nil then return nil end

    if method ~= nil then
        local ok, list = pcall(function() return method:call(mgr) end)
        if ok and list ~= nil then
            local c = list_count(list)
            if c ~= nil then return c end
        end
    end

    -- Backing-field fallback. Field is private but compiler-generated
    -- ("<...>k__BackingField"); REFramework's get_field reads compiler-
    -- generated fields by name without scope checks.
    local ok2, list2 = pcall(function() return mgr:get_field(backing_field_name) end)
    if ok2 and list2 ~= nil then
        local c = list_count(list2)
        if c ~= nil then return c end
    end

    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns true iff Hugh+Diana are currently in active combat.
-- "Active combat" means at least one enemy is in the engine's engage list
-- (aggro'd / locked-on / mid-encounter). Returns false during exploration,
-- in menus, on loading screens, or when the singleton is unreachable.
-- CONFIDENCE: medium — the field exists and the count read is straight-
-- forward, but the accessor's private scope means we may always end up on
-- the backing-field path. That path is well-supported by REFramework but
-- depends on the compiler-generated backing-field name being stable
-- across patches. The "<X>k__BackingField" convention is C# compiler-
-- enforced, so this should be very stable.
function M.is_in_combat()
    local count = read_member_count(_state.m_get_engage_members, _F_ENGAGE_BACKING)
    if type(count) ~= "number" then return false end
    return count > 0
end

-- Returns a coarse threat-level bucket for narration purposes:
--   "none"  — no enemies in scene
--   "low"   — a small handful of enemies in scene (1..3)
--   "high"  — a larger group (4 or more)
-- Returns nil if the engine signal is unreachable (caller should treat
-- nil as "don't know" — different from "none").
--
-- Bucket boundaries are deliberately conservative. We don't try to
-- distinguish encounter difficulty or enemy type — those would be
-- spoiler-bearing. The count alone gives a useful intensity hint.
-- CONFIDENCE: medium — same reachability caveat as is_in_combat. The
-- bucket boundaries are heuristic; tweaking them is a tuning concern,
-- not a correctness one.
function M.threat_level()
    local count = read_member_count(_state.m_get_ingame_members, _F_INGAME_BACKING)
    if type(count) ~= "number" then return nil end
    if count <= 0 then return "none" end
    if count <= 3 then return "low" end
    return "high"
end

return M
