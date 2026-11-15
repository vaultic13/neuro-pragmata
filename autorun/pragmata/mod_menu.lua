-- The mod's entry in the REFramework menu (Insert -> "Pragmata Neuro").
--
-- A short status, a few buttons that recover from something going wrong
-- without restarting the game, and the two values a non-English game needs
-- for mod_config.lua. Nothing here is needed in normal play.
--
-- Drawing it reads only the mod's own state: no game calls run while the menu
-- is open, and the setup values are read from the game once per button press.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local mailbox = require("pragmata.bridge_mailbox")
local dispatcher = require("pragmata.dispatcher")

local M = {}

local CONFIRM_SECONDS = 5
local SIZE_REFRESH_SECONDS = 1

local _feedback = nil          -- { text, at } shown under the buttons
local _clear_armed_at = nil    -- os.clock() of the first "Clear bridge files" click
local _sizes = { at = nil, outbox = nil, inbox = nil }
local _setup = nil             -- lines read by "Read setup values"

local function now() return os.clock() end

local function say(text)
    _feedback = { text = text, at = now() }
    log.info("mod_menu: " .. text)
end

local function ago(t)
    if t == nil then return "never" end
    local s = os.time() - t
    if s < 1 then return "just now" end
    if s < 120 then return string.format("%d s ago", s) end
    return string.format("%d min ago", math.floor(s / 60))
end

local function kb(n)
    if n == nil then return "missing" end
    return string.format("%.1f KB", n / 1024)
end

local function loaded(name) return package.loaded[name] end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

local function bridge_line()
    if not mailbox.is_ready() then
        return "Bridge: waiting for reframework/data/pragmata_mailbox/ (create it and start the sidecar)"
    end
    local t = now()
    if _sizes.at == nil or t - _sizes.at >= SIZE_REFRESH_SECONDS then
        _sizes.at = t
        _sizes.outbox, _sizes.inbox = mailbox.sizes()
    end
    return string.format("Bridge: ready (to sidecar %s, from sidecar %s); last message in: %s",
        kb(_sizes.outbox), kb(_sizes.inbox), ago(dispatcher.last_incoming()))
end

local function actions_line()
    local total, held = dispatcher.counts()
    return string.format("Actions: %d registered, %d offered to %s now; last re-sent: %s",
        total, held, tostring(config.display_name or "the AI"), ago(dispatcher.last_reregister()))
end

local function hack_line()
    local obs = loaded("pragmata.hacking_observer")
    local inflight = obs and obs.inflight and obs.inflight() or nil
    if inflight ~= nil and inflight.id ~= nil then
        local registry = loaded("pragmata.bindings.puzzle_registry")
        local label = registry and registry.kind_label(inflight.kind) or tostring(inflight.kind)
        return string.format("Hacking: waiting for an answer about a %s (%d s)",
            label, math.floor((inflight.frames or 0) / 60))
    end
    return "Hacking: no request waiting"
end

local function scene_line()
    local obs = loaded("pragmata.cutscene_prompt_observer")
    local cur = obs and obs.inflight and obs.inflight() or nil
    if cur == nil then return nil end
    return "Scene prompt: waiting for an answer"
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

local function resend_actions()
    dispatcher.reregister_all()
    say("Sent startup and the action list again, and freed the request slots.")
end

local function reset_hacking()
    local obs = loaded("pragmata.hacking_observer")
    if obs == nil or obs.reset == nil then
        say("Hacking is not loaded; nothing to reset.")
        return
    end
    obs.reset()
    say("Hacking reset: plans stopped and the request slot freed. The hack on screen will be asked about again.")
end

local function clear_bridge()
    local t = now()
    if _clear_armed_at == nil or t - _clear_armed_at > CONFIRM_SECONDS then
        _clear_armed_at = t
        say("Click \"Clear bridge files\" again within " .. CONFIRM_SECONDS .. " s to empty both files.")
        return
    end
    _clear_armed_at = nil
    _sizes.at = nil
    if mailbox.clear() then
        say("Both bridge files emptied. Press \"Re-send actions\" if the AI lost its actions.")
    else
        say("Could not open the bridge files; is the mailbox folder there?")
    end
end

local function rescan()
    local mod = loaded("pragmata.catalog_actions")
    if mod == nil or mod.rescan == nil then
        say("The archive readers are not loaded.")
        return
    end
    local ok, err = pcall(mod.rescan)
    if not ok then
        say("Rescan failed: " .. tostring(err))
        return
    end
    say("Archive and catalogs will be read again; entries already found are not announced as new.")
end

-- ---------------------------------------------------------------------------
-- Setup values (mod_config.lua, "Non-English games")
-- ---------------------------------------------------------------------------

local function read_setup()
    local lines = {}
    local gs = loaded("pragmata.game_state")
    local area = gs and gs.area
    local ok_s, hash, name = pcall(function() return area.current_sector() end)
    if ok_s and hash ~= nil then
        lines[#lines + 1] = string.format("Sector: %s  (hash %s)", tostring(name), tostring(hash))
    else
        lines[#lines + 1] = "Sector: not readable here"
    end
    local ok_i, items = pcall(function() return gs.inventory.read() end)
    if ok_i and type(items) == "table" then
        lines[#lines + 1] = "Held items (internal name = shown name):"
        for _, it in ipairs(items) do
            lines[#lines + 1] = string.format("  %s = %s", tostring(it.internal), tostring(it.name))
        end
    else
        lines[#lines + 1] = "Held items: not readable here"
    end
    _setup = lines
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata Neuro") then return end

    imgui.text(bridge_line())
    imgui.text(actions_line())
    imgui.text(hack_line())
    local scene = scene_line()
    if scene ~= nil then imgui.text(scene) end
    local file = log.session_file()
    if type(file) == "string" then imgui.text("Session log: reframework/data/" .. file) end

    imgui.separator()
    imgui.text("If something went wrong:")
    if imgui.button("Re-send actions") then resend_actions() end
    imgui.same_line()
    if imgui.button("Reset hacking") then reset_hacking() end
    imgui.same_line()
    if imgui.button("Rescan archive and catalogs") then rescan() end
    imgui.same_line()
    if imgui.button("Clear bridge files") then clear_bridge() end
    if _feedback ~= nil then imgui.text(_feedback.text) end

    if imgui.tree_node("Setup values (non-English games)") then
        imgui.text("For mod_config.lua: state_repair_kit_item, and the sector names in part 2.")
        if imgui.button("Read setup values") then
            local ok, err = pcall(read_setup)
            if not ok then _setup = { "Could not read: " .. tostring(err) } end
        end
        for _, line in ipairs(_setup or {}) do imgui.text(line) end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)

return M
