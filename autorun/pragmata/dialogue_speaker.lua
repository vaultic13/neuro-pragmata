-- Who is speaking the current subtitle line, what kind of line it is, and
-- how long it stays on screen.
--
-- Polls bindings/speaker_resolver.lua once per frame and keeps its answer
-- for dialogue.lua. Everything here is neutral: a name, a type word
-- ("Conversation", "Cinematic", "Radio", "Dialogue") and seconds.

local M = {}
local log = require("pragmata.util.log")

local _current_speaker = nil
local _current_type = nil
local _current_seconds = nil   -- how long the current line shows, or nil

-- Required at boot (a runtime require would fail) and pcall'd, so a broken
-- binding only costs the speaker names, types and lengths.
local resolver
do
    local ok, mod = pcall(require, "pragmata.bindings.speaker_resolver")
    if ok and type(mod) == "table" and type(mod.read_current) == "function" then
        resolver = mod
    else
        log.warn("dialogue_speaker: bindings.speaker_resolver not loaded ("
              .. tostring(mod) .. "); lines go out without speaker names")
    end
end

re.on_frame(function()
    if resolver == nil then return end
    local ok, cur = pcall(resolver.read_current)
    if not ok or type(cur) ~= "table" then
        _current_speaker, _current_type, _current_seconds = nil, nil, nil
        return
    end
    _current_speaker = cur.speaker
    _current_type = cur.kind
    _current_seconds = cur.seconds
end)

function M.get_current_speaker()
    return _current_speaker
end

function M.get_current_dialogue_type()
    return _current_type
end

-- Seconds the current line stays on screen, or nil when not known.
function M.get_current_line_seconds()
    return _current_seconds
end

return M
