-- ImGui panel for the hacking puzzles that are NOT the enemy grid.
--
-- Renders under "Pragmata Puzzle Debug" in the REFramework menu (press Insert
-- in-game). The grid has its own panel.
--
-- Deliberately small. It used to carry the input probe (Numpad 8/2/4/6), the
-- circuit board dump, per-family state readouts, a last-seen snapshot and the
-- type-resolution table -- the rigs that mapped these puzzles. They did their
-- job and were cut on 2026-09-16; recover them from git history if a patch
-- breaks a puzzle's input route or its board reading.
--
-- What is left:
--   SEQUENCE HACK GROUP  switch how the sequence hack is shown to the peer, for
--                        this session (mod_config.puzzle_sequence_group)
--   PEER VIEW            the state text the peer is sent for the live puzzle,
--                        kept after aim is released so it can be read
--   ENABLED FAMILIES     turn a puzzle family on or off, for this session
--
-- Purely diagnostic. Safe to leave enabled; the panel only draws when expanded.

local M = {}

local config = require("pragmata.mod_config")
local registry = require("pragmata.bindings.puzzle_registry")
local observer = require("pragmata.hacking_observer")
local puzzle_render = require("pragmata.util.puzzle_render")
local sequence_action = require("pragmata.sequence_action")


local function kv(label, value)
    imgui.text(string.format("%-16s %s", label .. ":", tostring(value)))
end

-- The outcome of the last group switch, kept so a refusal reason stays up.
local _last_switch = nil


-- ---------------------------------------------------------------------------
-- Peer view capture
-- ---------------------------------------------------------------------------
-- These puzzles are only live while aim is held, and a hand on the mouse cannot
-- also read this panel. So the render is captured while a puzzle IS live and
-- kept afterwards, with its age. Throttled: rendering every frame is real work
-- for a readout that changes this rarely.
local CAPTURE_INTERVAL_FRAMES = 15
local _frame = 0
local _seen = nil   -- { frame, kind, text }

re.on_frame(function()
    _frame = _frame + 1
    if (_frame % CAPTURE_INTERVAL_FRAMES) ~= 0 then return end
    pcall(function()
        local binding, active = registry.active_binding()
        if binding == nil or active == nil or active.kind == "snake" then return end
        local ok, text = pcall(binding.render_state)
        _seen = { frame = _frame, kind = active.kind,
                  text = ok and text or ("render threw: " .. tostring(text)) }
    end)
end)


re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata Puzzle Debug") then return end

    -- ----------------------------------------------------------------
    -- Sequence hack group
    -- ----------------------------------------------------------------
    imgui.text("Sequence hack group (session only)")
    imgui.separator()
    local active = puzzle_render.sequence_group()
    for _, g in ipairs(puzzle_render.SEQUENCE_GROUPS) do
        -- Buttons rather than a radio widget this REFramework build has not
        -- been seen to provide.
        local label = string.format("%d  %s%s", g.number, g.id,
            g.number == puzzle_render.SEQUENCE_DEFAULT_GROUP and "  (default)" or "")
        if imgui.button(label) and active.number ~= g.number then
            local _, message = sequence_action.set_group(g.number)
            _last_switch = message
            active = puzzle_render.sequence_group()
        end
        if active.number == g.number then
            imgui.same_line()
            imgui.text("<- active")
        end
    end
    kv("active", string.format("%d (%s)", active.number,
        active.number == sequence_action.configured_group and "from mod_config"
            or "switched here; mod_config says " .. tostring(sequence_action.configured_group)))
    if _last_switch ~= nil then kv("last switch", _last_switch) end
    imgui.text("Not saved -- set mod_config.puzzle_sequence_group to keep one.")
    imgui.text("Switch between hacks: a switch is refused while a sequence")
    imgui.text("force is waiting for its answer.")

    -- ----------------------------------------------------------------
    -- What is live
    -- ----------------------------------------------------------------
    imgui.separator()
    local status = registry.debug_status()
    local inflight = observer.inflight()
    kv("live puzzle", status.active_kind or "(none)")
    kv("waiting on peer", inflight.id ~= nil
        and string.format("%s (%d frames)", tostring(inflight.kind), inflight.frames or 0)
        or "no")

    if imgui.tree_node("Peer view (the force's state field)") then
        if _seen == nil then
            imgui.text("(no non-grid puzzle seen yet -- aim at one)")
        else
            local age = (_frame - _seen.frame) / 60
            imgui.text(string.format("%s, %s", tostring(_seen.kind),
                age < 0.5 and "live" or string.format("last seen %.1fs ago", age)))
            imgui.separator()
            for line in tostring(_seen.text):gmatch("[^\n]*") do
                imgui.text(line)
            end
        end
        imgui.tree_pop()
    end

    -- ----------------------------------------------------------------
    -- Families
    -- ----------------------------------------------------------------
    if imgui.tree_node("Enabled families (session only)") then
        imgui.text("Lasts until the game is restarted; mod_config.puzzle_kinds")
        imgui.text("makes it stick.")
        config.puzzle_kinds = config.puzzle_kinds or {}
        for _, kind in ipairs({ "circuit", "buttons", "slide", "path" }) do
            local changed, value = imgui.checkbox(kind, config.puzzle_kinds[kind] ~= false)
            if changed then config.puzzle_kinds[kind] = value end
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)


return M
