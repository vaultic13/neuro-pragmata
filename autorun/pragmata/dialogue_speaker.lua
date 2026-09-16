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
-- This module polls get_CurrentMessageInfo each frame and sets
-- _current_speaker from it, preferring bindings/speaker_resolver.lua when that
-- file is present and falling back to try_extract_speaker() below.
--
-- The one-shot MessageInfo structure dump that used to write
-- messageinfo_discovery.log has been removed -- it was discovery scaffolding,
-- and the shapes it found are encoded in try_extract_speaker() and the
-- resolver. Recover it from git history if a future build changes the type.

local M = {}
local log = require("pragmata.util.log")

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

-- Fallback speaker extraction, used when bindings/speaker_resolver.lua is
-- absent. Tries the MessageInfo shapes that the discovery pass found, in
-- descending order of directness.
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
