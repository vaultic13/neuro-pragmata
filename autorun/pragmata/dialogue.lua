-- Dialogue (subtitle) capture.
--
-- Each frame, the subtitle on screen (bindings/subtitle_panel.lua) becomes a
-- line with a speaker, type and length (dialogue_speaker.lua) and a reply
-- level (bindings/dialogue_talk.lua + classify() below).
--
-- Two ways out (mod_config.dialogue_transport):
--
--   "speech"   The line is OPEN while its text is on screen. It opens with
--              speech/started (id, speaker, text, reply, expected length) and
--              closes with speech/ended when the text changes or has been gone
--              for dialogue_end_grace_frames -- a skipped line closes the same
--              way. While a line is open Neuro does not talk over it; when the
--              dialogue goes quiet she answers per the last line's reply. The
--              text is NOT also sent as context (the API says not to).
--   "context"  Each new line once as silent context, tagged with its type and
--              level. Deduplicated on the text.
--
-- Every opened line gets a fresh id, and an end is always sent for it: on a
-- change, on the grace running out, and on a script reset.

local M = {}
local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local speaker = require("pragmata.dialogue_speaker")
local config = require("pragmata.mod_config")

local GAME = "Pragmata"

-- Both bindings are required here, at boot -- a runtime require would fail
-- (CLAUDE.md) -- and pcall'd so a broken one cannot take the mod down.
local function load_binding(name, fn, consequence)
    local ok, mod = pcall(require, "pragmata.bindings." .. name)
    if ok and type(mod) == "table" and type(mod[fn]) == "function" then return mod end
    log.warn("dialogue: bindings." .. name .. " not loaded (" .. tostring(mod) .. "); "
          .. consequence)
    return nil
end

local panel = load_binding("subtitle_panel", "read", "no dialogue is reported")
local talk_bind = load_binding("dialogue_talk", "current",
    'every line gets the reply level "maybe"')

local DEDUP_WINDOW = 64    -- context mode: max retained recent messages

-- The API's limits (characters); longer values are cut.
local MAX_SPEAKER = 200
local MAX_TEXT = 4000
local MAX_DURATION_MS = 600000

local _recent_list = {}    -- ordered list of recent messages
local _recent_set = {}     -- O(1) lookup; in-set <=> in-list

local function record_recent(msg)
    if _recent_set[msg] then return end
    table.insert(_recent_list, msg)
    _recent_set[msg] = true
    if #_recent_list > DEDUP_WINDOW then
        local old = table.remove(_recent_list, 1)
        _recent_set[old] = nil
    end
end

local function read_subtitle()
    if panel == nil then return nil end
    local ok, text = pcall(panel.read)
    if ok and type(text) == "string" then return text end
    return nil
end

-- --------------------------------------------------------------------
-- How much a line matters: its reply level
-- --------------------------------------------------------------------
-- The reply of speech/started: what Neuro does once the dialogue has gone
-- quiet ("never" / "maybe" / "always"). In context mode it is the tag's
-- second word, from mod_config.dialogue_reply_labels.
--
-- First match wins:
--   always  the talk is flagged serious, the line is a cutscene's, or a
--           scripted event is playing
--   never   the talk comes from one of mod_config.dialogue_ambient_sources
--   maybe   everything else (Shelter and stage talks, unknown source)

-- Format of a context line, following the Neuro-cyberpunk convention plus
-- the level:  Dialogue: [<Type>, <level>] <Speaker> says "<text>"
-- Type falls back to "Dialogue" when the resolver couldn't name one.
local DIALOGUE_TYPE_FALLBACK = "Dialogue"

local REPLY_LABEL_FALLBACK = { never = "ambient", maybe = "dialogue", always = "important" }

local function classify(kind, talk)
    talk = talk or {}
    if talk.serious == true or kind == "Cinematic" or talk.in_event == true then
        return "always"
    end
    local ambient = config.dialogue_ambient_sources
    if talk.source ~= nil and type(ambient) == "table" and ambient[talk.source] == true then
        return "never"
    end
    return "maybe"
end

local function reply_label(reply)
    local labels = config.dialogue_reply_labels
    local v = type(labels) == "table" and labels[reply] or nil
    if type(v) == "string" and v ~= "" then return v end
    return REPLY_LABEL_FALLBACK[reply]
end

local function read_talk()
    if talk_bind == nil then return nil end
    local ok, t = pcall(talk_bind.current)
    if ok and type(t) == "table" then return t end
    return nil
end

-- Everything known about the line now on screen.
local function describe(text)
    local kind = speaker.get_current_dialogue_type() or DIALOGUE_TYPE_FALLBACK
    local talk = read_talk()
    local line = {
        text    = text,
        speaker = speaker.get_current_speaker(),
        kind    = kind,
        reply   = classify(kind, talk),
        source  = talk and talk.source or nil,
        seconds = speaker.get_current_line_seconds(),
    }
    return line
end

local function short(s)
    return (s:len() > 100) and (s:sub(1, 100) .. "...") or s
end

local function cut(s, n)
    if #s <= n then return s end
    return s:sub(1, n)
end

-- --------------------------------------------------------------------
-- Context mode
-- --------------------------------------------------------------------

local function send_context(line)
    local tag = line.kind .. ", " .. reply_label(line.reply)
    local tagged
    if line.speaker and #line.speaker > 0 then
        tagged = string.format('Dialogue: [%s] %s says "%s"', tag, line.speaker, line.text)
    else
        tagged = string.format('Dialogue: [%s] "%s"', tag, line.text)
    end
    log.info("dialogue: " .. short(tagged))
    mailbox.send({
        command = "context",
        game = GAME,
        -- Silent: lines are absorbed as context, not answered one by one.
        data = { message = tagged, silent = true },
    })
end

-- --------------------------------------------------------------------
-- Speech mode
-- --------------------------------------------------------------------
-- Ids are "pragmata-<boot time>-<n>": new for every line spoken, and unique
-- across sessions because the boot time differs. The server ignores a
-- speech/started reusing an id that has already ended.

local _id_prefix = "pragmata-" .. tostring(os.time()) .. "-"
local _id_counter = 0

-- The open line: describe()'s table plus its id, or nil.
local _open = nil
local _missing_frames = 0   -- frames the open line's text has been off screen

local function new_id()
    _id_counter = _id_counter + 1
    return _id_prefix .. tostring(_id_counter)
end

local function speaker_name(line)
    local who = line.speaker
    if type(who) ~= "string" or who == "" then
        who = config.dialogue_unnamed_speaker
        if type(who) ~= "string" or who == "" then who = "Unknown voice" end
    end
    return cut(who, MAX_SPEAKER)
end

local function send_started(line)
    local data = {
        id      = line.id,
        speaker = speaker_name(line),
        text    = cut(line.text, MAX_TEXT),
        reply   = line.reply,
    }
    if config.dialogue_send_duration ~= false and type(line.seconds) == "number" then
        local ms = math.floor(line.seconds * 1000 + 0.5)
        if ms > 0 then data.expected_duration_ms = math.min(ms, MAX_DURATION_MS) end
    end
    local responder = config.dialogue_responder
    if line.reply == "always" and type(responder) == "string" and responder ~= "" then
        data.responder = responder
    end
    mailbox.send({ command = "speech/started", game = GAME, data = data })
    log.info("dialogue: started " .. line.id .. " (" .. line.reply .. ") "
          .. data.speaker .. ": " .. short(line.text))
end

local function close_open(why)
    if _open == nil then return end
    mailbox.send({ command = "speech/ended", game = GAME, data = { id = _open.id } })
    log.info("dialogue: ended " .. _open.id .. " (" .. why .. ")")
    _open = nil
    _missing_frames = 0
end

local function open_line(text)
    local line = describe(text)
    line.id = new_id()
    _open = line
    _missing_frames = 0
    M.last_line = line
    send_started(line)
end

local function grace_frames()
    local n = tonumber(config.dialogue_end_grace_frames)
    if n == nil or n < 0 then return 12 end
    return n
end

local function track_speech(text)
    if text == nil then
        if _open ~= nil then
            _missing_frames = _missing_frames + 1
            if _missing_frames > grace_frames() then close_open("gone") end
        end
        return
    end
    if _open ~= nil and _open.text == text then
        _missing_frames = 0
        return
    end
    -- A different line (or the first): the previous one has ended. Sent
    -- back to back, the server treats both as one stretch of dialogue.
    close_open("replaced")
    open_line(text)
end

-- --------------------------------------------------------------------
-- Status (mod menu) and lifecycle
-- --------------------------------------------------------------------

-- The last line reported, for the mod menu: describe()'s table (text,
-- speaker, kind, reply, source, seconds, and the id in speech mode).
M.last_line = nil

function M.transport()
    return config.dialogue_transport == "context" and "context" or "speech"
end

-- True while a speech line is open (its speech/ended not yet sent).
function M.line_open() return _open ~= nil end

-- A reloaded or unloaded script would otherwise leave the server holding an
-- open line until its safety timeout, keeping Neuro quiet that long.
re.on_script_reset(function()
    pcall(close_open, "script reset")
end)

re.on_frame(function()
    local text = read_subtitle()

    if M.transport() == "context" then
        -- A switch from speech to context leaves no line open.
        if _open ~= nil then close_open("transport changed") end
        if text ~= nil and not _recent_set[text] then
            record_recent(text)
            local line = describe(text)
            M.last_line = line
            send_context(line)
        end
        return
    end

    track_speech(text)
end)

return M
