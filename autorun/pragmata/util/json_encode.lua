-- Minimal UTF-8-safe JSON encoder.
--
-- REFramework's built-in json.dump_string was observed to strip or mishandle
-- non-ASCII bytes (em dashes vanishing from dialogue text). This encoder
-- preserves UTF-8 bytes verbatim by only escaping the chars JSON requires
-- (control 0x00-0x1F, 0x7F, ", \) and leaving everything else as-is.
-- Output is valid JSON since unescaped UTF-8 sequences are legal in strings.
--
-- Decoder remains REFramework's json.load_string -- we don't read non-ASCII
-- on incoming messages (tool-call args are ASCII), so no fix needed there.

local M = {}

local function escape_string(s)
    -- Pattern uses explicit byte ranges, NOT %c.  Lua's %c can match bytes
    -- 0x80-0x9F under some locales (C1 control set), which are also UTF-8
    -- continuation bytes — that mangles multi-byte chars like the em dash
    -- (U+2014 = 0xE2 0x80 0x94, where the 0x80 would get escaped and break
    -- the sequence).  We only escape genuine ASCII control bytes here.
    return (s:gsub('[%z\1-\31\127"\\]', function(c)
        if c == '\\' then return '\\\\' end
        if c == '"'  then return '\\"' end
        if c == '\b' then return '\\b' end
        if c == '\f' then return '\\f' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        return string.format('\\u%04x', c:byte())
    end))
end

local encode_value

local function encode_table(t)
    -- Detect array shape: positive integer keys 1..n with no gaps and #t == count.
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    local is_array = (n > 0) and (n == #t)
    if is_array then
        for k in pairs(t) do
            if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n then
                is_array = false
                break
            end
        end
    end

    if n == 0 then
        -- Empty: caller's intent is ambiguous. For our usage all empty objects
        -- are intended as objects, never arrays.
        return "{}"
    end

    if is_array then
        local parts = {}
        for i = 1, n do parts[i] = encode_value(t[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    -- Object. Lua `pairs()` order is non-deterministic for string keys, but
    -- some consumers care about property order — notably a tool schema's
    -- `properties`, where the order maps to the order the LLM generates the
    -- arguments in (e.g. a `reasoning` field must come BEFORE the answer field
    -- to actually function as chain-of-thought). A table may set a `__keyorder`
    -- array to pin the leading keys; it is consumed here and never emitted.
    local order = rawget(t, "__keyorder")
    local parts = {}
    local emitted = {}
    if type(order) == "table" then
        for _, k in ipairs(order) do
            if t[k] ~= nil and not emitted[k] then
                parts[#parts + 1] = '"' .. escape_string(tostring(k)) .. '":' .. encode_value(t[k])
                emitted[k] = true
            end
        end
    end
    for k, v in pairs(t) do
        if k ~= "__keyorder" and not emitted[k] then
            parts[#parts + 1] = '"' .. escape_string(tostring(k)) .. '":' .. encode_value(v)
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encode_value = function(v)
    local t = type(v)
    if t == "string"  then return '"' .. escape_string(v) .. '"' end
    if t == "number"  then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        return tostring(v)
    end
    if t == "boolean" then return v and "true" or "false" end
    if t == "nil"     then return "null" end
    if t == "table"   then return encode_table(v) end
    return "null"
end

function M.encode(v) return encode_value(v) end

return M
