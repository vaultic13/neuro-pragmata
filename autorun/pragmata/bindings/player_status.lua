--
-- Live read of the player's engine status masks.
--
-- The player's per-frame state is not a pile of booleans: it is a set of
-- 64-bit flag masks, one per status enum, hanging off the player driver.
-- overdrive.lua used to say these were "informational only" because it had
-- no reflection path to the live mask. It does — this module is it.
--
-- Engine layout (verified against the IL2CPP dump):
--
--   app.PlayerDriver
--     - get_Status() -> app.EnumBitDatas
--       Every player driver inherits this (PlayerPuzzleControlDriver,
--       PlayerFinishBlowDriver, PlayerDeathblowDriver, ...), so any driver
--       captured by bindings/player_drivers.lua is a valid handle.
--
--   app.EnumBitDatas
--     - get_Datas() -> Dictionary<System.Type, app.EnumBitData>
--     - getData(System.Type) -> app.EnumBitData
--     - hasFlag(System.Type, System.String) -> System.Boolean
--       ^ the engine's own by-name flag test. Preferred for single checks:
--         no 64-bit arithmetic on our side, and it cannot drift from the
--         game's own definition of the flag.
--
--   app.EnumBitData : app.BitData
--     - get__EnumType() -> System.Type
--     - get__FlagNames() -> System.String[]
--   app.BitData
--     - get_Current()  -> System.UInt64   <- the live mask, this frame
--     - get_Previous() -> System.UInt64   <- the mask last frame
--
-- `Current` and `Previous` together are what make edge detection possible
-- without hooking anything: a flag that is set in Current and clear in
-- Previous was raised this frame. That is the same information the old
-- trgFlag hook produced, minus the ~4500-records-per-two-seconds firehose.
--
-- Flag VALUES are resolved by reflecting the enum type's own static fields,
-- so a status enum this module has never heard of still resolves. The four
-- player enums that matter are additionally pinned as literals below, so a
-- readiness check still works if reflection over a given enum ever fails.

local log = require("pragmata.util.log")
local player_drivers = require("pragmata.bindings.player_drivers")

local M = {}

-- Any player driver works as a status handle; these are the ones the mod
-- already captures. Tried in order until one is live.
local STATUS_HANDLE_DRIVERS = {
    "app.PlayerPuzzleControlDriver",
    "app.PlayerFinishBlowDriver",
    "app.PlayerDeathblowDriver",
}

-- The status enums relevant to hacking / Overdrive / Deathblow. The probe
-- watches exactly these; watching every enum the player owns is what made the
-- earlier traces unreadable.
M.WATCHED = {
    "app.player.PuzzleStatus",
    "app.player.FinishBlowStatus",
    "app.player.DeathblowStatus",
    "app.player.ActionStatus",
}

-- Literal fallbacks from the IL2CPP dump. Only consulted when reflection over
-- the enum type returns nothing. Values are exact.
local FLAG_FALLBACK = {
    ["app.player.FinishBlowStatus"] = {
        CheckBurstFinishBlow   = 1,
        CanBurstFinishBlow     = 2,
        RequestBurstFinishBlow = 4,
        StartBurstFinishBlow   = 8,
        CanFinishBlow          = 16,
    },
    ["app.player.DeathblowStatus"] = {
        Play            = 1,
        Kill            = 2,
        CanDeathblow    = 4,
        Start           = 8,
        AutoHackingMode = 16,
        FindTarget      = 32,
        EventKill       = 64,
        CanAutoHack     = 1024,
        Request         = 1048576,
    },
    ["app.player.PuzzleStatus"] = {
        HackingGaugeFullTrigger     = 8,
        Holding                     = 16,
        HackingGaugeBuffMode        = 32,
        HackingGaugeFull            = 64,
        JustDodgeSlowMode           = 128,
        PuzzleSuccess               = 256,
        PuzzleFailed                = 512,
        EndJustDodgeSlowMode        = 1024,
        StartJustDodgeSlowMode      = 4096,
        ShotTargetHackingApplyFirst = 1048576,
        ShotTargetHackingApply      = 2097152,
        ContactDeadFilament         = 4194304,
        OpenFinishBlow              = 1073741824,
        RequestAutoHacking          = 1099511627776,
        HackingSlow                 = 2199023255552,
        AutoHackingNoAim            = 1125899906842624,
    },
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

-- True when every bit of `value` is set in `mask`.
--
-- Done with arithmetic rather than Lua 5.3+ `&` on purpose: REFramework's Lua
-- version varies across builds, so `&` can be a SYNTAX error that stops this
-- whole file from loading -- a project-wide rule, not a local preference.
-- Exact for values below 2^53; the largest flag in these enums is
-- 2^50 (PuzzleStatus.AutoHackingNoAim), so there is no precision loss.
local function bits_set(mask, value)
    if type(mask) ~= "number" or type(value) ~= "number" then return false end
    if value <= 0 then return false end
    -- A negative mask would mean bit 63 is set and the value came back as a
    -- signed 64-bit integer. No flag here lives up there, and reasoning about
    -- the low bits of such a value is not reliable across Lua number types.
    if mask < 0 then return false end
    local m, v = math.floor(mask), math.floor(value)
    while v > 0 do
        if (v % 2) == 1 and (m % 2) ~= 1 then return false end
        v = math.floor(v / 2)
        m = math.floor(m / 2)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Flag name <-> value maps, per enum type
-- ---------------------------------------------------------------------------

local _flag_maps = {}   -- type_name -> { by_name = {...}, by_value = {...}, count = n }

-- Reflect an enum type's static constants into name/value maps. Enum members
-- are static fields whose data is the enum value; `value__` is the backing
-- instance field and is deliberately skipped.
local function build_flag_map(type_name)
    local cached = _flag_maps[type_name]
    if cached ~= nil then return cached end

    local by_name, by_value, count = {}, {}, 0
    local type_def = safe(function() return sdk.find_type_definition(type_name) end)
    if type_def ~= nil then
        for _, field in ipairs(safe(function() return type_def:get_fields() end) or {}) do
            local name = safe(function() return field:get_name() end)
            local is_static = safe(function() return field:is_static() end)
            if is_static == true and type(name) == "string" and name ~= "value__" then
                local value = to_int(safe(function() return field:get_data(nil) end))
                if type(value) == "number" and value > 0 then
                    by_name[name] = value
                    if by_value[value] == nil then by_value[value] = name end
                    count = count + 1
                end
            end
        end
    end

    if count == 0 then
        local fallback = FLAG_FALLBACK[type_name]
        if fallback ~= nil then
            for name, value in pairs(fallback) do
                by_name[name] = value
                by_value[value] = name
                count = count + 1
            end
            log.warn("player_status: reflection over " .. type_name
                  .. " returned nothing; using dumped literals")
        end
    end

    cached = { by_name = by_name, by_value = by_value, count = count }
    _flag_maps[type_name] = cached
    return cached
end

-- Public: { FlagName = value } for one status enum.
function M.flag_values(type_name)
    return build_flag_map(type_name).by_name
end

-- ---------------------------------------------------------------------------
-- Reaching the live status container
-- ---------------------------------------------------------------------------

local _handle_type = nil   -- which driver last produced a status container

-- app.EnumBitDatas.getData and hasFlag are both heavily overloaded (one
-- variant per status enum in the game), so they MUST be resolved by exact
-- signature -- sdk.call_object_func would have to guess which overload is
-- meant. Signatures carry no spaces, matching the rest of this codebase.
-- get_Current/get_Previous live on app.BitData, the base of app.EnumBitData;
-- a base MethodDefinition calls fine on a derived instance.
local _methods = {
    inited = false,
    get_data = nil,
    has_flag = nil,
    get_current = nil,
    get_previous = nil,
}

local function ensure_methods()
    if _methods.inited then return end
    _methods.inited = true
    local datas_td = safe(function() return sdk.find_type_definition("app.EnumBitDatas") end)
    if datas_td ~= nil then
        _methods.get_data = safe(function()
            return datas_td:get_method("getData(System.Type)") end)
        _methods.has_flag = safe(function()
            return datas_td:get_method("hasFlag(System.Type,System.String)") end)
    end
    local bit_td = safe(function() return sdk.find_type_definition("app.BitData") end)
    if bit_td ~= nil then
        _methods.get_current  = safe(function() return bit_td:get_method("get_Current()") end)
        _methods.get_previous = safe(function() return bit_td:get_method("get_Previous()") end)
    end
    if _methods.get_data == nil then
        log.warn("player_status: app.EnumBitDatas.getData(System.Type) unavailable")
    end
end

-- app.EnumBitDatas for the local player, or nil outside gameplay.
function M.container()
    for _, type_name in ipairs(STATUS_HANDLE_DRIVERS) do
        local driver = player_drivers.get(type_name)
        if driver ~= nil then
            local status = safe(function()
                return sdk.call_object_func(driver, "get_Status")
            end)
            if status ~= nil then
                _handle_type = type_name
                return status
            end
        end
    end
    return nil
end

-- Register the capture hooks for every driver we might read status through.
-- Idempotent; player_drivers only installs once per type.
function M.want_handles()
    for _, type_name in ipairs(STATUS_HANDLE_DRIVERS) do
        player_drivers.want(type_name)
    end
end

local function get_data(container, type_name)
    if container == nil then return nil end
    ensure_methods()
    if _methods.get_data == nil then return nil end
    local enum_type = safe(function() return sdk.typeof(type_name) end)
    if enum_type == nil then return nil end
    return safe(function() return _methods.get_data:call(container, enum_type) end)
end

-- ---------------------------------------------------------------------------
-- Public reads
-- ---------------------------------------------------------------------------

-- Raw masks for one status enum: (current, previous). Either may be nil when
-- the player isn't in a level.
function M.mask(type_name, container)
    local data = get_data(container or M.container(), type_name)
    if data == nil then return nil, nil end
    local current, previous
    if _methods.get_current ~= nil then
        current = to_int(safe(function() return _methods.get_current:call(data) end))
    end
    if _methods.get_previous ~= nil then
        previous = to_int(safe(function() return _methods.get_previous:call(data) end))
    end
    return current, previous
end

-- Test one flag by name. Uses the engine's own hasFlag(Type, String) so the
-- answer cannot drift from the game's definition; falls back to a mask test
-- if that overload isn't reachable on a future build.
-- CONFIDENCE: high -- hasFlag(System.Type, System.String) is in the dump.
function M.has(type_name, flag_name, container)
    container = container or M.container()
    if container == nil then return nil end
    ensure_methods()

    if _methods.has_flag ~= nil then
        local enum_type = safe(function() return sdk.typeof(type_name) end)
        if enum_type ~= nil then
            local result = safe(function()
                return _methods.has_flag:call(container, enum_type, flag_name)
            end)
            if type(result) == "boolean" then return result end
            local n = to_int(result)
            if n ~= nil then return n ~= 0 end
        end
    end

    local value = build_flag_map(type_name).by_name[flag_name]
    local current = M.mask(type_name, container)
    if value == nil or current == nil then return nil end
    return bits_set(current, value)
end

-- Every flag currently set on one status enum, as a name list. Used by the
-- probe and the debug panel; not on any hot path.
function M.set_flags(type_name, container)
    local current = M.mask(type_name, container)
    if current == nil then return nil end
    local map = build_flag_map(type_name).by_name
    local names = {}
    for name, value in pairs(map) do
        if bits_set(current, value) then names[#names + 1] = name end
    end
    table.sort(names)
    return names, current
end

-- Last mask this module OBSERVED per enum, and the frame it saw it on.
--
-- Edge detection deliberately does NOT use app.BitData.get_Previous().
--
-- It used to, and it silently reported nothing: a probe capture of an ability
-- that demonstrably changed DeathblowStatus recorded zero edges, while the same
-- masks read correctly when sampled directly. The engine advances Previous to
-- match Current during its own update, so by the time an re.on_frame callback
-- runs the two are equal again and every edge has already been erased.
--
-- Diffing against a value WE stored last time we looked has no such race: it
-- compares two observations made from the same place in the frame, so a change
-- between them is real regardless of when the engine shuffles its own copy.
-- get_Previous() is still reported by M.mask, as data rather than as truth.
local _seen = {}

-- Flags that changed on one status enum since this module last looked at it.
-- Returns (raised, cleared, current) name lists.
--
-- Call this at a steady cadence: it is edge detection against the caller's own
-- sampling rate, so anything that rises and falls between two calls is missed.
-- The first call after a mask becomes readable establishes a baseline and
-- reports no edges -- otherwise every flag already set would look like it had
-- just been raised.
function M.edges(type_name, container)
    local current = M.mask(type_name, container)
    if current == nil then
        -- Out of gameplay. Forget the baseline so re-entering a level does not
        -- report the whole status mask as a single burst of edges.
        _seen[type_name] = nil
        return nil, nil, nil
    end

    local previous = _seen[type_name]
    _seen[type_name] = current
    if previous == nil then return {}, {}, current end
    if current == previous then return {}, {}, current end

    local map = build_flag_map(type_name).by_name
    local raised, cleared = {}, {}
    for name, value in pairs(map) do
        local now, before = bits_set(current, value), bits_set(previous, value)
        if now and not before then raised[#raised + 1] = name
        elseif before and not now then cleared[#cleared + 1] = name end
    end
    table.sort(raised)
    table.sort(cleared)
    return raised, cleared, current
end

-- Drop the observation baseline for every watched enum. Call when starting a
-- recording session so the first sample establishes a fresh baseline instead of
-- diffing against a mask observed minutes ago.
function M.reset_edges()
    _seen = {}
end

-- Edges across every watched enum, in one container fetch.
-- Returns a list of { status = <enum>, raised = {...}, cleared = {...} }, only
-- for enums that actually changed.
function M.watched_edges()
    local container = M.container()
    if container == nil then return {} end
    local out = {}
    for _, type_name in ipairs(M.WATCHED) do
        local raised, cleared = M.edges(type_name, container)
        if raised ~= nil and (#raised > 0 or #cleared > 0) then
            out[#out + 1] = { status = type_name, raised = raised, cleared = cleared }
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

function M.debug_status()
    M.want_handles()
    local container = M.container()
    local per_enum = {}
    for _, type_name in ipairs(M.WATCHED) do
        local flags, current = M.set_flags(type_name, container)
        per_enum[type_name] = {
            known_flags = build_flag_map(type_name).count,
            mask = current,
            set = flags,
        }
    end
    return {
        container_ok = container ~= nil,
        handle_driver = _handle_type,
        enums = per_enum,
    }
end

return M
