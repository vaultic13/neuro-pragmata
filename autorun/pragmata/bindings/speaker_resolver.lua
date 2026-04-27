--
-- Resolves the current speaker's display name from an app.MessageInfo +
-- app.MessageManager pair.
--
-- Engine layout (verified against the IL2CPP dump):
--   app.MessageInfo._Params         : app.MessageParam[]   (polymorphic)
--   app.MessageInfo._CurrentIndex   : System.Int32         (-1 when idle)
--   app.MessageInfo:get_CurrentParam() -> app.MessageParam (engine accessor;
--       presumably returns _Params[_CurrentIndex] but is private/family-scope
--       and may not be reachable through reflection — we still try it first).
--
--   app.MessageParam.<speakerID>k__BackingField : System.UInt32   (talkID)
--   app.MessageParam:get_speakerID() -> System.UInt32              (property)
--   app.MessageParam:get_isNoSpeak() -> System.Boolean             (property)
--       — true means the line is intentionally unattributed; we honor it
--         and return nil rather than the default speaker for that talkID.
--
--   app.MessageManager:getSpeakerNameGUID(UInt32 talkID) -> System.Guid
--   app.MessageManager.getName(System.Guid) -> System.String       (STATIC)
--
-- The dump shows exactly one direct subclass of app.MessageParam, and that
-- subclass overrides only openGui — it inherits the speakerID field and
-- accessor unchanged. So the same resolution path covers every concrete
-- param type currently present in the binary.
--
-- Dialogue type/status layout (used by extract_dialogue_type):
--   app.MessageInfo._Type     : app.MessageInfo.MessageType (Int32 enum)
--   app.MessageInfo._Status   : app.ConversationPlayStateType (Int32 enum)
--   app.MessageInfo._IsValid  : System.Boolean
--   app.MessageInfo._IsFinished : System.Boolean
--
-- The dumped MessageType enum has five members. Per their setter origins
-- and naming, they bucket into three category surfaces:
--   * a "live conversation line" tag (the most common case),
--   * a "cinematic / cutscene" tag,
--   * a family of "closed-caption" tags (radio-style, off-screen, or
--     conversation-linked closed captioning).
-- _Status is the standard play-state enum (idle / running / paused / ended).
--
-- We resolve the runtime int values for those enum members by reflection
-- on the enum type definition rather than hardcoding literals — the dumper
-- emits packed metadata defaults, not raw int32 ordinals, so trusting the
-- "default" field would be wrong. The reflection lookup is cached per-load.

local M = {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

-- Return true iff `talk_id` looks like a usable UInt32 (non-zero numeric).
-- speakerID == 0 is the "unset" sentinel in this engine — paths that hand
-- it to getSpeakerNameGUID return an empty/zero GUID and getName then
-- returns nil or "".
local function valid_talk_id(talk_id)
    if talk_id == nil then return false end
    if type(talk_id) == "number" then return talk_id ~= 0 end
    -- REFramework sometimes hands UInt32 back as a userdata-like value;
    -- coerce defensively.
    local ok, n = pcall(tonumber, tostring(talk_id))
    if ok and n and n ~= 0 then return true end
    return false
end

local function nonempty_string(v)
    return type(v) == "string" and v ~= ""
end

-- Read app.MessageParam.speakerID. Tries the property accessor first
-- (cheaper and survives any future field-layout shifts), then falls back
-- to the backing field directly.
-- CONFIDENCE: high — both the getter and the backing field are confirmed
-- present in the dump; whichever REFramework can resolve will work.
local function read_speaker_id(param)
    if param == nil then return nil end

    local ok, v = pcall(function() return param:call("get_speakerID") end)
    if ok and v ~= nil then return v end

    local fok, fv = pcall(function() return param:get_field("<speakerID>k__BackingField") end)
    if fok and fv ~= nil then return fv end

    -- Some REFramework builds expose backing fields under the property name.
    local pok, pv = pcall(function() return param:get_field("speakerID") end)
    if pok and pv ~= nil then return pv end

    return nil
end

-- Honour the isNoSpeak flag if present. Returns true ONLY when the engine
-- has explicitly marked the line as unattributed; absence of the property
-- means "don't know, proceed".
-- CONFIDENCE: high — `<isNoSpeak>k__BackingField` and get_isNoSpeak are
-- both in the dump on app.MessageParam (the base type).
local function is_no_speak(param)
    if param == nil then return false end
    local ok, v = pcall(function() return param:call("get_isNoSpeak") end)
    if ok and v == true then return true end
    local fok, fv = pcall(function() return param:get_field("<isNoSpeak>k__BackingField") end)
    if fok and fv == true then return true end
    return false
end

-- Pull the active app.MessageParam out of an app.MessageInfo. Tries the
-- engine's own accessor first; on any failure walks _Params[_CurrentIndex]
-- by hand.
-- CONFIDENCE: medium for the accessor path — get_CurrentParam exists in the
-- dump but is FamANDAssem | Family scope, so reflection-call may refuse it
-- in some REFramework versions; the manual fallback covers that case at
-- HIGH confidence (both fields are public-via-reflection and in the dump).
local function current_param(info)
    if info == nil then return nil end

    local ok, p = pcall(function() return info:call("get_CurrentParam") end)
    if ok and p ~= nil then return p end

    local params_ok, params = pcall(function() return info:get_field("_Params") end)
    if not params_ok or params == nil then return nil end

    local idx_ok, idx = pcall(function() return info:get_field("_CurrentIndex") end)
    if not idx_ok or idx == nil then return nil end
    if type(idx) ~= "number" then
        local n = tonumber(tostring(idx))
        if not n then return nil end
        idx = n
    end
    if idx < 0 then return nil end

    -- Managed array access. REFramework exposes a few shapes; try them all.
    local size = nil
    pcall(function() size = params:get_size() end)
    if size == nil then pcall(function() size = params:call("get_Length") end) end
    if size == nil then pcall(function() size = #params end) end
    if type(size) == "number" and idx >= size then return nil end

    local elem = nil
    pcall(function() elem = params:get_element(idx) end)
    if elem == nil then pcall(function() elem = params:call("Get", idx) end) end
    if elem == nil then pcall(function() elem = params[idx + 1] end) end  -- Lua 1-based fallback
    return elem
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Returns the current speaker's display name as a string, or nil.
-- `info` is an app.MessageInfo (REManagedObject from get_CurrentMessageInfo).
-- `manager` is the app.MessageManager singleton.
function M.extract_speaker_name(info, manager)
    if info == nil or manager == nil then return nil end

    -- Cheap early-out: an info with _CurrentIndex < 0 has no active line.
    -- (current_param() would also return nil here, but checking up-front
    -- avoids the get_CurrentParam reflection call on every idle frame.)
    local idx_ok, idx = pcall(function() return info:get_field("_CurrentIndex") end)
    if idx_ok and type(idx) == "number" and idx < 0 then
        return nil
    end

    local param = current_param(info)
    if param == nil then return nil end

    if is_no_speak(param) then return nil end

    local talk_id = read_speaker_id(param)
    if not valid_talk_id(talk_id) then return nil end

    -- talkID -> speaker-name GUID (instance method on the manager).
    -- CONFIDENCE: high — signature matches the dump exactly
    -- (System.Guid getSpeakerNameGUID(System.UInt32)).
    local gok, name_guid = pcall(function() return manager:call("getSpeakerNameGUID", talk_id) end)
    if not gok or name_guid == nil then return nil end

    -- name GUID -> display string. getName is STATIC in the dump
    -- (FamANDAssem | Family | Static). REFramework's :call on the
    -- singleton instance still dispatches to the static thunk because
    -- the underlying function pointer ignores `this`; this matches how
    -- the existing discovery log probes succeeded.
    -- CONFIDENCE: high — matches the dump signature and the existing
    -- working call pattern in dialogue_speaker.lua.
    local nok, name = pcall(function() return manager:call("getName", name_guid) end)
    if not nok then return nil end
    if not nonempty_string(name) then return nil end

    return name
end

-- ---------------------------------------------------------------------------
-- Dialogue-type extraction
-- ---------------------------------------------------------------------------
--
-- Returns a short, neutrally-named category string for the active dialogue
-- in `info`, or nil if there is no active dialogue (idle / finished /
-- _CurrentIndex < 0). Suitable for embedding in a context tag like
-- `Dialogue: [Cinematic] Hugh says "..."`.
--
-- Categories returned (kept short and player-facing-readable):
--   "Conversation"  — a regular spoken dialogue line.
--   "Cinematic"     — dialogue that plays as part of a cinematic.
--   "Radio"         — closed-captioned audio (off-screen / radio-style),
--                     including the conversation-linked closed-caption
--                     variant. All closed-caption flavors share this tag.
--   "Dialogue"      — generic fallback when info is non-idle but _Type
--                     is unreadable or an unrecognised value (e.g. a
--                     post-patch member not present in the captured dump).
-- nil               — idle / no active line.

-- One-time-resolved int -> category map for app.MessageInfo.MessageType.
-- Built lazily via reflection on the enum's type definition: we ask
-- REFramework for each known member by name and read its actual runtime
-- int32 value. This dodges the dumper-emitted "default" literals (which
-- are packed metadata, not the runtime ordinals) and survives any future
-- enum reshuffles short of renames.
-- CONFIDENCE: high — reading enum constant values via the type-definition
-- field accessor is the standard REFramework pattern and matches how
-- engine code itself dispatches on these values.
local _msg_type_map = nil      -- table: int -> category string
local _msg_type_map_tried = false

-- Member name -> public-facing category. Closed-caption variants collapse
-- into a single "Radio" bucket because they all share the same functional
-- character (off-screen / overlaid captioned audio) for the listener;
-- distinguishing them at the context-tag level adds noise without value.
-- CONFIDENCE: medium — bucketing is a presentation choice; semantics
-- match the setter names that produce each enum value, but a future patch
-- could add a member that doesn't fit any of these buckets and would fall
-- through to the generic "Dialogue" fallback.
local MSG_TYPE_NAME_TO_CATEGORY = {
    Conversation          = "Conversation",
    CutScene              = "Cinematic",
    ClosedCaption         = "Radio",
    ConvClosedCaption     = "Radio",
    CutSceneClosedCaption = "Radio",
}

local function read_enum_int(td, member_name)
    -- Read the static literal int value of an enum member by name.
    -- REFramework exposes both shapes; try both.
    local ok, fld = pcall(function() return td:get_field(member_name) end)
    if not ok or fld == nil then return nil end
    -- :get_data(nil) is the canonical accessor for static fields.
    local dok, dval = pcall(function() return fld:get_data(nil) end)
    if dok and type(dval) == "number" then return dval end
    -- Some REFramework builds expose the literal default through a different
    -- path; try get_default_value if present.
    local def_ok, def_val = pcall(function() return fld:get_default_value() end)
    if def_ok and type(def_val) == "number" then return def_val end
    return nil
end

local function ensure_msg_type_map()
    if _msg_type_map ~= nil then return _msg_type_map end
    if _msg_type_map_tried then return nil end
    _msg_type_map_tried = true

    local ok, td = pcall(function()
        return sdk.find_type_definition("app.MessageInfo.MessageType")
    end)
    if not ok or td == nil then return nil end

    local map = {}
    local count = 0
    for member_name, category in pairs(MSG_TYPE_NAME_TO_CATEGORY) do
        local v = read_enum_int(td, member_name)
        if type(v) == "number" then
            map[v] = category
            count = count + 1
        end
    end
    if count == 0 then return nil end

    _msg_type_map = map
    return _msg_type_map
end

-- Reads the raw int value of app.MessageInfo._Type. Returns nil on failure.
-- CONFIDENCE: high — _Type is a public-via-reflection Int32-backed enum
-- field and the dump shows it at a stable offset.
local function read_message_type(info)
    if info == nil then return nil end
    local ok, v = pcall(function() return info:get_field("_Type") end)
    if not ok or v == nil then return nil end
    if type(v) == "number" then return v end
    -- Boxed enum: try to coerce.
    local nok, n = pcall(tonumber, tostring(v))
    if nok and type(n) == "number" then return n end
    return nil
end

-- Idle detection: return true if the info has no live, in-progress line.
-- We treat both an explicitly-not-valid and an explicitly-finished info as
-- idle, plus _CurrentIndex < 0 as a backup signal (matches the early-out
-- already used in extract_speaker_name).
-- CONFIDENCE: medium — _IsValid and _IsFinished are present in the dump
-- and their names suggest the obvious semantics, but we haven't observed
-- their exact transition timing relative to _Status. The combined set of
-- checks is conservative: if any of them say "not active", we say idle.
-- _Status is read but only used as a tertiary hint because we don't have
-- a verified mapping of which ConversationPlayStateType value corresponds
-- to "no active line" vs. "between lines"; we deliberately don't gate on
-- _Status to avoid false-idle on slow transitions.
local function is_idle(info)
    if info == nil then return true end

    local ok_idx, idx = pcall(function() return info:get_field("_CurrentIndex") end)
    if ok_idx and type(idx) == "number" and idx < 0 then return true end

    local ok_v, valid = pcall(function() return info:get_field("_IsValid") end)
    if ok_v and valid == false then return true end

    local ok_f, finished = pcall(function() return info:get_field("_IsFinished") end)
    if ok_f and finished == true then return true end

    return false
end

-- Public: short category string, or nil for idle / no-active-dialogue.
-- The `info` argument is an app.MessageInfo (REManagedObject from
-- app.MessageManager:get_CurrentMessageInfo()).
function M.extract_dialogue_type(info)
    if info == nil then return nil end
    if is_idle(info) then return nil end

    local raw = read_message_type(info)
    if type(raw) ~= "number" then
        -- _Type unreadable but info is non-idle — still return *something*
        -- so the formatter can show a tag. Generic fallback.
        return "Dialogue"
    end

    local map = ensure_msg_type_map()
    if map ~= nil then
        local cat = map[raw]
        if cat ~= nil then return cat end
    end

    -- _Type read OK but not in our known map (e.g. a patch-added value).
    -- Degrade to a generic, non-revealing tag so the line still gets
    -- forwarded with context.
    -- CONFIDENCE: medium — degradation behaviour is the right default but
    -- assumes any unknown member is still "some kind of dialogue".
    return "Dialogue"
end

return M
