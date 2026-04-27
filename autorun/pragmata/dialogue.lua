-- Phase 1 dialogue capture.
--
-- Subtitles in Pragmata render through GUI panel UI/Asset/ui2000/gui/ui2010,
-- which holds 8 via.gui.Text controls (all named "text"). One subtitle can
-- occupy 1-2 slots (long lines wrap to 2 visible lines); all visible slots
-- together form one logical utterance.
--
-- Slot index ordering: empirically, Pragmata fills visible slots bottom-up,
-- so visual TOP corresponds to higher slot index. We iterate in REVERSE so
-- the forwarded text reads top-to-bottom = natural reading order.
--
-- Strategy: capture the panel's live GUI element on its draw events, then on
-- each frame collect all visible non-empty messages in display order, join
-- them into a single string, and forward as one context message when the
-- combined string is new. Dedup on the combined string so the same on-screen
-- state doesn't re-fire frame after frame.
--
-- Speaker name is NOT captured yet — it lives somewhere else (probably
-- ui7000/ui7200) and uses a different mechanism. TODO follow-up.

local M = {}
local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local speaker = require("pragmata.dialogue_speaker")

local SUBTITLE_GUI_PATH = "UI/Asset/ui2000/gui/ui2010"
local DEDUP_WINDOW = 64    -- max retained recent messages
local FRAME_INTERVAL = 1   -- check every N frames; 1 = every frame

local _live_gui = nil      -- latest via.gui.GUI element matching SUBTITLE_GUI_PATH
local _text_runtime_type   -- cached System.Type for via.gui.Text
local _frame = 0
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

-- --------------------------------------------------------------------
-- Capture the live GUI element each time it draws
-- --------------------------------------------------------------------

re.on_pre_gui_draw_element(function(element, _ctx)
    if element == nil then return true end
    local ok, asset_path = pcall(function() return element:call("get_AssetPath") end)
    if ok and asset_path == SUBTITLE_GUI_PATH then
        _live_gui = element
    end
    return true
end)

-- --------------------------------------------------------------------
-- Frame poller: scan the panel's Text controls, forward new lines
-- --------------------------------------------------------------------

local function ensure_text_type()
    if _text_runtime_type ~= nil then return true end
    local td = sdk.find_type_definition("via.gui.Text")
    if td == nil then return false end
    local ok, rt = pcall(function() return td:get_runtime_type() end)
    if not ok or rt == nil then return false end
    _text_runtime_type = rt
    return true
end

-- Format follows the Neuro-cyberpunk integration convention:
--   Dialogue: [<Type>] <Speaker> says "<text>"
-- Type comes from the spoiler-zone resolver reading MessageInfo._Type.
-- Falls back to "Dialogue" if the resolver couldn't determine one (idle
-- frames return nil, but if a real line is on screen with no resolved
-- type, we don't want to drop the bracket entirely).
local DIALOGUE_TYPE_FALLBACK = "Dialogue"

local function forward_line(msg)
    local who = speaker.get_current_speaker()
    local kind = speaker.get_current_dialogue_type() or DIALOGUE_TYPE_FALLBACK
    local tagged
    if who and #who > 0 then
        tagged = string.format('Dialogue: [%s] %s says "%s"', kind, who, msg)
    else
        tagged = string.format('Dialogue: [%s] "%s"', kind, msg)
    end
    log.info("dialogue: " .. (tagged:len() > 100 and (tagged:sub(1, 100) .. "...") or tagged))
    mailbox.send({
        command = "context",
        game = "Pragmata",
        data = {
            message = tagged,
            -- Silent so the AI absorbs lines as context without spamming
            -- responses on every single line. Lift to false later if/when
            -- you want real-time reactions.
            silent = true,
        },
    })
end

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % FRAME_INTERVAL) ~= 0 then return end
    if _live_gui == nil then return end
    if not ensure_text_type() then return end

    local ok, objs = pcall(function()
        return _live_gui:call("findObjects", _text_runtime_type)
    end)
    if not ok or objs == nil then return end

    local count = 0
    pcall(function() count = objs:get_size() or 0 end)
    if count == 0 then return end

    -- Collect visible non-empty lines in display order (visual top first).
    -- Pragmata appears to fill slots bottom-up, so we iterate from highest
    -- slot index down to 0.
    local lines = {}
    for i = count - 1, 0, -1 do
        local ctrl
        pcall(function() ctrl = objs:get_element(i) end)
        if ctrl ~= nil then
            local visible = false
            pcall(function() visible = ctrl:call("get_Visible") and true or false end)

            local msg
            pcall(function()
                local m = ctrl:call("get_Message")
                if type(m) == "string" then msg = m end
            end)

            if visible and msg ~= nil and msg ~= "" then
                table.insert(lines, msg)
            end
        end
    end

    if #lines == 0 then return end

    -- Join with a single space — wrapped subtitle halves read naturally as one
    -- utterance after this. If lines turn out to come from distinct speakers
    -- in some scene, we can revisit (but we'll know it from the speaker
    -- discovery follow-up before that becomes a real problem).
    local combined = table.concat(lines, " ")
    if not _recent_set[combined] then
        record_recent(combined)
        forward_line(combined)
    end
end)

return M
