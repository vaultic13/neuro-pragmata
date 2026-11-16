--
-- What kind of talk is playing right now, read from app.ConversationManager.
--
-- dialogue.lua uses this to decide how much a subtitle line matters to the
-- AI peer (ambient chatter / ordinary dialogue / an important beat). This
-- binding only reports what the engine says; the policy lives in dialogue.lua.
--
-- Engine layout (from the IL2CPP dump; field names, all private):
--   app.ConversationManager (singleton)
--     _PlayingTalkID        : UInt32   talk currently playing, 0 = none
--     _PlayingSeriousTalk   : Boolean  the playing talk is flagged serious
--     _PlayingEvent         : Boolean  a scripted event is playing
--     _TalkIDDict_<Source>  : Dictionary<UInt32, TalkDictData>, one per
--                             source: Battle, Gimmick, Item, Shelter, Stage,
--                             StageChat, StageTips
--   app.ConversationManager.TalkDictData
--     IsSerious : Boolean
--
-- The source is found by asking each table whether it holds the playing talk
-- id (ContainsKey first, through reflect.dict_get -- a missing key on get_Item
-- throws in-game). Lines that come from no table (cutscene subtitles, radio
-- closed captions) report source = nil.
--
-- Confirmed in-game (2026-11-16): _PlayingTalkID is set on the frame the
-- subtitle first shows. Combat barks come from Battle, Diana and Hugh's
-- Shelter talk from Shelter, story talk from Stage (the serious ones with
-- the flag set). Cutscene subtitles and the "[IDUS transmission signal]"
-- caption have no talk id.
--
-- Neutral output only: plain numbers, strings and booleans.

local reflect = require("pragmata.bindings.reflect")

local M = {}

local MANAGER = "app.ConversationManager"

-- engine table suffix -> neutral source name
local SOURCES = {
    { field = "_TalkIDDict_Battle",    name = "battle" },
    { field = "_TalkIDDict_StageChat", name = "stage_chat" },
    { field = "_TalkIDDict_StageTips", name = "stage_tips" },
    { field = "_TalkIDDict_Gimmick",   name = "gimmick" },
    { field = "_TalkIDDict_Item",      name = "item" },
    { field = "_TalkIDDict_Shelter",   name = "shelter" },
    { field = "_TalkIDDict_Stage",     name = "stage" },
}

local function bool(obj, name)
    local v = reflect.field(obj, name)
    if v == nil then return nil end
    return v == true
end

-- The playing talk as a neutral table, or nil when the manager is not there
-- (title screen, loading).
--   talk_id        number|nil   nil when no talk is tracked
--   serious        boolean|nil  the manager's flag, or the talk entry's
--   source         string|nil   one of the SOURCES names
--   in_event       boolean|nil
function M.current()
    local mgr = reflect.singleton(MANAGER)
    if mgr == nil then return nil end

    local out = {
        in_event = bool(mgr, "_PlayingEvent"),
        serious  = bool(mgr, "_PlayingSeriousTalk"),
    }

    local id = reflect.to_int(reflect.field(mgr, "_PlayingTalkID"))
    if id == nil or id == 0 then return out end
    out.talk_id = id

    for _, s in ipairs(SOURCES) do
        local entry = reflect.dict_get(reflect.field(mgr, s.field), id)
        if entry ~= nil then
            out.source = s.name
            if reflect.field(entry, "IsSerious") == true then out.serious = true end
            break
        end
    end
    return out
end

return M
