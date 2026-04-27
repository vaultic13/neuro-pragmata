-- Speaker capture via app.MessageManager.
--
-- Object Explorer shows app.MessageManager exposes:
--   app.MessageInfo get_CurrentMessageInfo()
--   String getName(System.Guid)
--   String getMessage(System.Guid)
--   System.Guid getSpeakerNameGUID(System.UInt32)
--   System.Guid getMessageGUID(System.UInt32)
--   System.UInt32 getTalkID(System.Guid)
--
-- We don't yet know app.MessageInfo's shape. This module:
--   1. Polls get_CurrentMessageInfo each frame.
--   2. On first non-null result, dumps the MessageInfo type's methods + fields
--      AND tries a battery of speculative get_* / property reads, logging
--      what each returns. The output goes to messageinfo_discovery.log
--      (one-shot — written once, never re-written).
--   3. Sets _current_speaker each frame if we can extract it via known
--      method names (best-effort until the discovery log is reviewed).
--
-- Once we know the right method to call, the discovery dump can be removed.

local M = {}
local log = require("pragmata.util.log")

local DISCOVERY_LOG = "pragmata_mailbox/messageinfo_discovery.log"

local _structure_dumped = false
local _current_speaker = nil
local _current_type = nil
local _mgr = nil

-- Optional spoiler-zone binding produced by the IL2CPP-dump subagent. If
-- present, we delegate to it instead of the speculative path. Loaded with
-- pcall so the mod still works if the file is missing.
local _spoiler_resolver = nil
do
    local ok, mod = pcall(require, "pragmata.bindings.speaker_resolver")
    if ok and type(mod) == "table" and type(mod.extract_speaker_name) == "function" then
        _spoiler_resolver = mod
        log.info("speaker_resolver loaded from bindings/")
    else
        log.info("speaker_resolver not found; using speculative path only")
    end
end

local SPECULATIVE_INFO_METHODS = {
    "get_SpeakerName",
    "get_Speaker",
    "get_SpeakerNameGUID",
    "get_SpeakerGUID",
    "get_MessageGUID",
    "get_Message",
    "get_TalkID",
    "get_Caption",
    "get_CharacterID",
    "get_CharaID",
    "get_Name",
}

local function append_log(s)
    local f = io.open(DISCOVERY_LOG, "a")
    if not f then return end
    f:write(s)
    f:close()
end

local function safe_tostring(v)
    if v == nil then return "nil" end
    local ok, s = pcall(tostring, v)
    if ok then return s end
    return "?"
end

local function dump_messageinfo_structure(info)
    if _structure_dumped then return end
    _structure_dumped = true

    append_log("\n############# MessageInfo discovery " .. (os.date("%Y-%m-%d %H:%M:%S") or "?") .. " #############\n")

    local td_ok, td = pcall(function() return info:get_type_definition() end)
    if not td_ok or td == nil then
        append_log("ERROR: could not get type definition\n")
        return
    end
    local tname = "?"
    pcall(function() tname = td:get_full_name() or "?" end)
    append_log("type=" .. tname .. "\n")

    append_log("METHODS:\n")
    pcall(function()
        for _, m in ipairs(td:get_methods() or {}) do
            local n = "?"
            pcall(function() n = m:get_name() or "?" end)
            append_log("  " .. n .. "\n")
        end
    end)

    append_log("FIELDS:\n")
    pcall(function()
        for _, f in ipairs(td:get_fields() or {}) do
            local n = "?"
            pcall(function() n = f:get_name() or "?" end)
            append_log("  " .. n .. "\n")
        end
    end)

    append_log("\n--- speculative reads on MessageInfo ---\n")
    for _, c in ipairs(SPECULATIVE_INFO_METHODS) do
        local ok, r = pcall(function() return info:call(c) end)
        if ok then
            append_log(string.format("  %s -> %s\n", c, safe_tostring(r)))
        else
            append_log(string.format("  %s -> ERROR: %s\n", c, safe_tostring(r)))
        end
    end

    -- Try resolving via the manager's getName / getMessage with whatever
    -- GUID-shaped value MessageInfo gave us back from the speculative round.
    append_log("\n--- speculative resolution via MessageManager ---\n")
    for _, src in ipairs({ "get_SpeakerNameGUID", "get_SpeakerGUID", "get_MessageGUID" }) do
        local ok, guid = pcall(function() return info:call(src) end)
        if ok and guid ~= nil then
            local nok, name = pcall(function() return _mgr:call("getName", guid) end)
            if nok then
                append_log(string.format("  manager:getName(%s) -> %s\n", src, safe_tostring(name)))
            end
            local mok, msg = pcall(function() return _mgr:call("getMessage", guid) end)
            if mok then
                append_log(string.format("  manager:getMessage(%s) -> %s\n", src, safe_tostring(msg)))
            end
        end
    end

    -- Also try with TalkID, which Object Explorer showed feeds into
    -- getMessageGUID / getSpeakerNameGUID
    do
        local ok, talk_id = pcall(function() return info:call("get_TalkID") end)
        if ok and talk_id ~= nil then
            local sok, sguid = pcall(function() return _mgr:call("getSpeakerNameGUID", talk_id) end)
            if sok and sguid ~= nil then
                local nok, name = pcall(function() return _mgr:call("getName", sguid) end)
                if nok then
                    append_log(string.format("  via TalkID -> getSpeakerNameGUID -> getName -> %s\n", safe_tostring(name)))
                end
            end
            local mguid_ok, mguid = pcall(function() return _mgr:call("getMessageGUID", talk_id) end)
            if mguid_ok and mguid ~= nil then
                local mok, msg = pcall(function() return _mgr:call("getMessage", mguid) end)
                if mok then
                    append_log(string.format("  via TalkID -> getMessageGUID -> getMessage -> %s\n", safe_tostring(msg)))
                end
            end
        end
    end

    append_log("############# end discovery #############\n\n")
    log.info("MessageInfo discovery written to " .. DISCOVERY_LOG)
end

-- Build a resolver function once we have a working method. Until the
-- discovery log is reviewed, try a few common shapes opportunistically
-- so speakers may "just work" without needing a second iteration.
local function try_extract_speaker(info)
    -- Direct string: most ergonomic if it exists
    local ok, r = pcall(function() return info:call("get_SpeakerName") end)
    if ok and type(r) == "string" and r ~= "" then return r end

    -- TalkID -> getSpeakerNameGUID -> getName
    local ok2, talk_id = pcall(function() return info:call("get_TalkID") end)
    if ok2 and talk_id ~= nil then
        local gok, guid = pcall(function() return _mgr:call("getSpeakerNameGUID", talk_id) end)
        if gok and guid ~= nil then
            local nok, name = pcall(function() return _mgr:call("getName", guid) end)
            if nok and type(name) == "string" and name ~= "" then return name end
        end
    end

    -- Direct speaker GUID -> getName
    for _, src in ipairs({ "get_SpeakerNameGUID", "get_SpeakerGUID" }) do
        local sok, sguid = pcall(function() return info:call(src) end)
        if sok and sguid ~= nil then
            local nok, name = pcall(function() return _mgr:call("getName", sguid) end)
            if nok and type(name) == "string" and name ~= "" then return name end
        end
    end

    return nil
end

re.on_frame(function()
    if _mgr == nil then
        local ok, mgr = pcall(function() return sdk.get_managed_singleton("app.MessageManager") end)
        if ok and mgr ~= nil then _mgr = mgr end
    end
    if _mgr == nil then return end

    local ok, info = pcall(function() return _mgr:call("get_CurrentMessageInfo") end)
    if not ok or info == nil then
        _current_speaker = nil
        return
    end

    if not _structure_dumped then
        dump_messageinfo_structure(info)
    end

    if _spoiler_resolver ~= nil then
        local ok, name = pcall(_spoiler_resolver.extract_speaker_name, info, _mgr)
        if ok and type(name) == "string" and name ~= "" then
            _current_speaker = name
        else
            _current_speaker = nil
        end
        if type(_spoiler_resolver.extract_dialogue_type) == "function" then
            local tok, tval = pcall(_spoiler_resolver.extract_dialogue_type, info)
            if tok and type(tval) == "string" and tval ~= "" then
                _current_type = tval
            else
                _current_type = nil
            end
        end
    else
        _current_speaker = try_extract_speaker(info)
        _current_type = nil
    end
end)

function M.get_current_speaker()
    return _current_speaker
end

function M.get_current_dialogue_type()
    return _current_type
end

return M
