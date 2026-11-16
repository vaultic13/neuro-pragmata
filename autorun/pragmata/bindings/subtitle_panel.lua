-- The subtitle on screen, read from the game's subtitle GUI panel.
--
-- Subtitles render through GUI panel UI/Asset/ui2000/gui/ui2010, which holds
-- 8 via.gui.Text controls (all named "text"). One subtitle occupies 1-2
-- slots (long lines wrap to 2 visible lines); all visible slots together form
-- one logical utterance.
--
-- Slot order: the game fills visible slots bottom-up, so the visual TOP is
-- the higher slot index. They are read in REVERSE so the joined text reads
-- top-to-bottom.
--
-- The panel's live element is captured on its draw events. Its Text controls
-- can keep their last message and Visible flag after the panel itself stops
-- drawing, so a panel that has not drawn for STALE_READS reads counts as
-- gone -- otherwise a frozen panel would hold a line open forever.
--
-- Neutral output only: a string or nil.

local M = {}

local PANEL_PATH = "UI/Asset/ui2000/gui/ui2010"
local STALE_READS = 30   -- read() runs once per frame, so: frames

local _live_gui = nil          -- latest via.gui.GUI element of the panel
local _reads_since_draw = nil  -- nil until the panel has drawn once
local _text_runtime_type = nil -- cached System.Type for via.gui.Text

re.on_pre_gui_draw_element(function(element, _ctx)
    if element == nil then return true end
    local ok, asset_path = pcall(function() return element:call("get_AssetPath") end)
    if ok and asset_path == PANEL_PATH then
        _live_gui = element
        _reads_since_draw = 0
    end
    return true
end)

local function ensure_text_type()
    if _text_runtime_type ~= nil then return true end
    local td = sdk.find_type_definition("via.gui.Text")
    if td == nil then return false end
    local ok, rt = pcall(function() return td:get_runtime_type() end)
    if not ok or rt == nil then return false end
    _text_runtime_type = rt
    return true
end

-- The subtitle on screen as one string, or nil when there is none. Call it
-- once per frame: the staleness count advances per call.
function M.read()
    if _live_gui == nil or _reads_since_draw == nil then return nil end
    _reads_since_draw = _reads_since_draw + 1
    if _reads_since_draw > STALE_READS then return nil end
    if not ensure_text_type() then return nil end

    local ok, objs = pcall(function()
        return _live_gui:call("findObjects", _text_runtime_type)
    end)
    if not ok or objs == nil then return nil end

    local count = 0
    pcall(function() count = objs:get_size() or 0 end)
    if count == 0 then return nil end

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

    if #lines == 0 then return nil end
    -- One space between wrapped halves reads as one utterance.
    return table.concat(lines, " ")
end

return M
