--
-- Shared reflection plumbing for the game-state bindings.
--
-- Every binding in this directory re-derives the same half-dozen helpers
-- (pcall wrapper, type/method lookup, integer coercion, array walking). The
-- older ones keep their own copies; the game-state bindings (player_vitals,
-- loadout, perks, inventory, area_progress) share this one so their SDK
-- surface stays small and uniform.
--
-- Nothing here names a game type. It is only the mechanics of asking the
-- engine things through REFramework's `sdk`.

local log = require("pragmata.util.log")

local M = {}

function M.safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

function M.td(name)
    return M.safe(function() return sdk.find_type_definition(name) end)
end

-- Method by exact signature. Signatures carry no spaces, matching the rest of
-- the codebase; REFramework resolves overloads only by exact signature.
function M.method(type_def, signature)
    if type_def == nil then return nil end
    return M.safe(function() return type_def:get_method(signature) end)
end

function M.singleton(name)
    return M.safe(function() return sdk.get_managed_singleton(name) end)
end

-- REFramework's Lua version varies across builds; 5.1 has a global unpack,
-- 5.2+ has table.unpack.
local unpack_args = table.unpack or unpack

-- Call a resolved MethodDefinition. `this` is nil for static methods.
-- Returns nil on any failure, including an unresolved method.
function M.call(method_def, this, ...)
    if method_def == nil then return nil end
    local args = { ... }
    local n = select("#", ...)
    return M.safe(function()
        return method_def:call(this, unpack_args(args, 1, n))
    end)
end

-- Number out of whatever the engine handed back.
--
-- Elements of a primitive array (UInt32[], UInt64[]) come out of
-- get_element() BOXED: a managed System.UInt32 object whose value sits in its
-- `m_value` field. Enums box the same way with `value__`. Those fields are read
-- first. sdk.to_int64 is only for raw pointer-sized returns -- handed a managed
-- object it returns the object's ADDRESS, which looks like a plausible id,
-- differs on every read, and was the first in-game test's bug: every weapon
-- "new" every poll, every name unresolved, every level 0.
function M.to_int(value)
    if value == nil then return nil end
    if type(value) == "number" then return value end
    if type(value) == "boolean" then return nil end
    for _, name in ipairs({ "m_value", "value__", "mValue" }) do
        local n = M.safe(function() return value:get_field(name) end)
        if type(n) == "number" then return n end
    end
    -- A managed object that is not a boxed number has no numeric value.
    if M.safe(function() return value:get_type_definition() end) ~= nil then
        return nil
    end
    local n = M.safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n end
    local ok, t = pcall(tonumber, tostring(value))
    if ok and type(t) == "number" then return t end
    return nil
end

function M.to_float(value)
    if type(value) == "number" then return value end
    return M.to_int(value)
end

function M.field(obj, name)
    if obj == nil then return nil end
    return M.safe(function() return obj:get_field(name) end)
end

-- Dictionary lookup that never throws inside the game: get_Item on a missing
-- key raises KeyNotFoundException, which REFramework logs every time (the
-- 2026-10-01 log had them on every location read). Nil when absent.
function M.dict_get(dict, key)
    if dict == nil or key == nil then return nil end
    if M.safe(function() return dict:call("ContainsKey", key) end) ~= true then return nil end
    return M.safe(function() return dict:call("get_Item", key) end)
end

-- Every { key, value } of a Dictionary<K,V>, read from its entries array
-- (`_entries`, or `entries` on older runtimes) up to its count. Bounded like
-- elements(); slots freed by Remove (hashCode < 0) are skipped.
function M.dict_pairs(dict)
    local out = {}
    if dict == nil then return out end
    local entries = M.field(dict, "_entries") or M.field(dict, "entries")
    local count = M.to_int(M.field(dict, "_count") or M.field(dict, "count"))
    if entries == nil or count == nil then return out end
    -- (oversize() is declared further down; record the refusal directly.)
    if count < 0 or count > M.MAX_ELEMENTS then M.oversize = count return out end
    for i = 0, count - 1 do
        local e = M.safe(function() return entries:get_element(i) end)
        if e ~= nil then
            local h = M.to_int(M.field(e, "hashCode"))
            if h == nil or h >= 0 then
                local k, v = M.field(e, "key"), M.field(e, "value")
                if k ~= nil then out[#out + 1] = { key = k, value = v } end
            end
        end
    end
    return out
end

-- True while a managed handle still points at a live object.
function M.is_live(obj)
    if obj == nil then return false end
    return pcall(function() return obj:get_type_definition() end)
end

-- Walk a managed array (T[]) or List<T> into a plain Lua array, raw elements.
-- Unreadable elements are skipped, never turned into holes.
--
-- Bounded. 2026-10-01: entering the train elevator froze the game while
-- REFramework logged ~9.7 million System.Array.GetValue
-- ArgumentOutOfRangeExceptions -- a walk was handed a collection whose
-- reported size was far larger than what it held (a container torn down
-- mid-transition). So a size beyond MAX_ELEMENTS is refused outright, and a
-- walk that keeps hitting unreadable indexes stops instead of trying every
-- remaining one.
M.MAX_ELEMENTS = 4096
M.oversize = nil                -- last refused size, for the debug panel

local function oversize(n)
    if M.oversize == nil then
        log.warn("reflect: refused to walk a collection reporting " .. tostring(n) .. " elements")
    end
    M.oversize = n
end

-- REFramework swallows the game's out-of-range exception (it only logs it)
-- and hands back nil, so "past the end" looks like a null element. A run of
-- MAX_MISSES unreadable elements ends the walk; a real null or two in an
-- object array does not.
local MAX_MISSES = 8

function M.elements(collection)
    local out = {}
    if collection == nil then return out end

    local function walk(n, read)
        if n < 0 or n > M.MAX_ELEMENTS then oversize(n) return end
        local misses = 0
        for i = 0, n - 1 do
            local v = read(i)
            if v ~= nil then
                out[#out + 1] = v
                misses = 0
            else
                misses = misses + 1
                if misses >= MAX_MISSES then break end
            end
        end
    end

    -- System.Array
    local size = M.safe(function() return collection:get_size() end)
    if type(size) == "number" then
        walk(size, function(i)
            -- Indexing hands primitives back as plain numbers on the builds
            -- the puzzle bindings run on; get_element boxes them (see to_int).
            local v = M.safe(function() return collection[i] end)
            if type(v) ~= "number" then
                local boxed = M.safe(function() return collection:get_element(i) end)
                if boxed ~= nil then v = boxed end
            end
            return v
        end)
        return out
    end

    -- List<T>
    local count = M.to_int(M.safe(function() return collection:call("get_Count") end))
    if type(count) == "number" then
        walk(count, function(i)
            return M.safe(function() return collection:call("get_Item", i) end)
        end)
        return out
    end

    -- Plain Lua table (some REFramework builds convert arrays eagerly).
    if type(collection) == "table" then
        for _, v in ipairs(collection) do out[#out + 1] = v end
    end
    return out
end

-- Same as elements(), but each element coerced to a number. Non-numbers are
-- dropped; this is for UInt32[] / UInt64[] id arrays.
function M.numbers(collection)
    local out = {}
    for _, v in ipairs(M.elements(collection)) do
        local n = M.to_int(v)
        if type(n) == "number" then out[#out + 1] = n end
    end
    return out
end

-- Resolve the hash of one member of an EnumLikeArrayBase "smart enum" by
-- member NAME, e.g. hash_of("app.PerkType", "Permanent"). Reads the
-- `<Name>Hash` literal the dump shows on every such type. Cached.
local _hash_cache = {}
function M.enum_hash(type_name, member)
    local key = type_name .. "." .. member
    local cached = _hash_cache[key]
    if cached ~= nil then return cached or nil end
    local type_def = M.td(type_name)
    local value = nil
    if type_def ~= nil then
        local f = M.safe(function() return type_def:get_field(member .. "Hash") end)
        if f ~= nil then value = M.to_int(M.safe(function() return f:get_data(nil) end)) end
    end
    _hash_cache[key] = value or false
    return value
end

-- Every member of a smart enum as { name, hash }, from its static `<Name>Hash`
-- fields, in declaration order. Cached once non-empty; empty on failure.
local _members_cache = {}
function M.enum_hash_members(type_name)
    local cached = _members_cache[type_name]
    if cached ~= nil then return cached end
    local out = {}
    local type_def = M.td(type_name)
    for _, f in ipairs((type_def and M.safe(function() return type_def:get_fields() end)) or {}) do
        local name = M.safe(function() return f:get_name() end)
        if type(name) == "string" and #name > 4 and name:sub(-4) == "Hash"
            and M.safe(function() return f:is_static() end) == true then
            local v = M.to_int(M.safe(function() return f:get_data(nil) end))
            if type(v) == "number" then
                out[#out + 1] = { name = name:sub(1, -5), hash = v }
            end
        end
    end
    if #out > 0 then _members_cache[type_name] = out end
    return out
end

-- Name of a smart-enum member from its hash, through the type's own static
-- getName(System.UInt32). Nil when unknown.
local _name_methods = {}
function M.enum_name(type_name, hash)
    if hash == nil then return nil end
    local m = _name_methods[type_name]
    if m == nil then
        m = M.method(M.td(type_name), "getName(System.UInt32)") or false
        _name_methods[type_name] = m
    end
    if m == false then return nil end
    local name = M.call(m, nil, hash)
    if type(name) == "string" and #name > 0 then return name end
    return nil
end

-- value -> member name for a plain CLR enum, by reflecting its static fields
-- (same approach as player_status.build_flag_map). Cached; empty on failure.
local _enum_maps = {}
function M.enum_value_names(type_name)
    local cached = _enum_maps[type_name]
    if cached ~= nil then return cached end
    local map = {}
    local type_def = M.td(type_name)
    for _, f in ipairs((type_def and M.safe(function() return type_def:get_fields() end)) or {}) do
        local name = M.safe(function() return f:get_name() end)
        if type(name) == "string" and name ~= "value__"
            and M.safe(function() return f:is_static() end) == true then
            local v = M.to_int(M.safe(function() return f:get_data(nil) end))
            if type(v) == "number" and map[v] == nil then map[v] = name end
        end
    end
    _enum_maps[type_name] = map
    return map
end

return M
