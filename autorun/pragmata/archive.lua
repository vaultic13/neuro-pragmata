-- Collectible-document ("Archive") text capture.
--
-- Pragmata's collectible documents are `app.ArchivePropDriver` props in the
-- world; reading one opens a GUI panel that displays its text. This module
-- captures that text the same proven way `dialogue.lua` captures subtitles:
-- grab the live `via.gui.GUI` element whose asset path matches the document
-- panel, then each frame collect its visible `via.gui.Text` controls, join
-- them, and forward the combined text to the AI as a silent `context` message
-- (so the AI peer can be asked to read / recall the document later).
--
-- The document panel's GUI asset path is NOT known from the static dump and
-- varies by build, so it must be configured: set `archive_gui_path` in
-- mod_config.lua. To FIND it, set `archive_discover_paths = true`, open a
-- document in-game, and watch reframework/log.txt — this module logs every
-- GUI panel that currently shows visible text, with a sample, as
--   [pragmata] archive: candidate GUI path '<path>' text='<sample>'
-- Pick the one whose text is the document body, put it in `archive_gui_path`,
-- and turn discovery back off.

local M = {}
local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local config = require("pragmata.mod_config")

local DEDUP_WINDOW = 32
local FRAME_INTERVAL = 2     -- documents are static while open; no need every frame

local _live_gui = nil        -- GUI element matching archive_gui_path
local _discover = {}         -- path -> GUI element, for discovery mode
local _discover_logged = {}  -- path -> true, so each candidate logs once
local _text_runtime_type = nil
local _frame = 0
local _recent_list = {}
local _recent_set = {}
local _warned_no_path = false

local function record_recent(msg)
    if _recent_set[msg] then return end
    table.insert(_recent_list, msg)
    _recent_set[msg] = true
    if #_recent_list > DEDUP_WINDOW then
        local old = table.remove(_recent_list, 1)
        _recent_set[old] = nil
    end
end

local function ensure_text_type()
    if _text_runtime_type ~= nil then return true end
    local td = sdk.find_type_definition("via.gui.Text")
    if td == nil then return false end
    local ok, rt = pcall(function() return td:get_runtime_type() end)
    if not ok or rt == nil then return false end
    _text_runtime_type = rt
    return true
end

-- Collect every visible, non-empty via.gui.Text message under a GUI element,
-- in slot order. `reverse` flips the order (Pragmata fills some panels
-- bottom-up; flip via archive_reverse_slots if the document reads backwards).
local function collect_lines(gui, reverse)
    local ok, objs = pcall(function()
        return gui:call("findObjects", _text_runtime_type)
    end)
    if not ok or objs == nil then return {} end

    local count = 0
    pcall(function() count = objs:get_size() or 0 end)
    if count == 0 then return {} end

    local lines = {}
    local function read_slot(i)
        local ctrl
        pcall(function() ctrl = objs:get_element(i) end)
        if ctrl == nil then return end
        local visible = false
        pcall(function() visible = ctrl:call("get_Visible") and true or false end)
        if not visible then return end
        local msg
        pcall(function()
            local m = ctrl:call("get_Message")
            if type(m) == "string" then msg = m end
        end)
        if msg ~= nil and msg ~= "" then table.insert(lines, msg) end
    end

    if reverse then
        for i = count - 1, 0, -1 do read_slot(i) end
    else
        for i = 0, count - 1 do read_slot(i) end
    end
    return lines
end

local function forward_document(text)
    log.info("archive: captured document ("
          .. tostring(#text) .. " chars)")
    mailbox.send({
        command = "context",
        game = "Pragmata",
        data = {
            message = 'Collectible document text: "' .. text .. '"',
            -- Silent: absorbed as context so Vedal/Neuro can ask about it,
            -- without auto-triggering a response the moment it's opened.
            silent = true,
        },
    })
end

-- --------------------------------------------------------------------
-- Capture the live GUI element(s) on draw
-- --------------------------------------------------------------------
re.on_pre_gui_draw_element(function(element, _ctx)
    if element == nil then return true end
    if config.archive_enabled == false then return true end

    local ok, asset_path = pcall(function() return element:call("get_AssetPath") end)
    if not ok or asset_path == nil then return true end

    if config.archive_gui_path ~= nil and asset_path == config.archive_gui_path then
        _live_gui = element
    end
    if config.archive_discover_paths then
        _discover[asset_path] = element
    end
    return true
end)

-- --------------------------------------------------------------------
-- Frame poller
-- --------------------------------------------------------------------
re.on_frame(function()
    if config.archive_enabled == false then return end
    _frame = _frame + 1
    if (_frame % FRAME_INTERVAL) ~= 0 then return end
    if not ensure_text_type() then return end

    -- Discovery mode: log any panel that currently shows visible text so the
    -- user can identify the document panel's asset path. Each path logs once.
    if config.archive_discover_paths then
        for path, gui in pairs(_discover) do
            if not _discover_logged[path] then
                local lines = collect_lines(gui, false)
                if #lines > 0 then
                    _discover_logged[path] = true
                    local sample = table.concat(lines, " | ")
                    if #sample > 120 then sample = sample:sub(1, 120) .. "..." end
                    log.info("archive: candidate GUI path '" .. path
                          .. "' text='" .. sample .. "'")
                end
            end
        end
    end

    if config.archive_gui_path == nil then
        if not _warned_no_path and not config.archive_discover_paths then
            _warned_no_path = true
            log.info("archive: archive_gui_path not set; document capture idle. "
                  .. "Set archive_discover_paths=true to find it.")
        end
        return
    end

    if _live_gui == nil then return end

    local lines = collect_lines(_live_gui, config.archive_reverse_slots == true)
    if #lines == 0 then return end

    -- Documents are multi-line prose: join with newlines to preserve structure.
    local combined = table.concat(lines, "\n")
    if not _recent_set[combined] then
        record_recent(combined)
        forward_document(combined)
    end
end)

return M
