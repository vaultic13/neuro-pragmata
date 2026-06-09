-- ImGui debug panel for the Scan and Overdrive abilities.
--
-- Renders under "Pragmata Abilities Debug" in the REFramework menu (press
-- Insert in-game). Both abilities are static-dump-derived and have to be
-- verified live; this panel shows, in real time:
--   - Scan:      singleton present? trigger methods resolved? isScanning?
--                recent ping count, last trigger outcome.
--   - Overdrive: are the player drivers captured? is requestWideFinishBlow
--                resolved? gauge fill, readiness, last trigger outcome, and
--                the per-driver capture-hook state.
--
-- Manual trigger buttons let you test each ability without the AI peer in
-- the loop. The Overdrive button carries the save-corruption warning from
-- ACTIONS.md — it hooks a cinematic pipeline, so test on a disposable save.
--
-- Purely diagnostic. Safe to leave enabled; only renders when expanded.

local M = {}

local log = require("pragmata.util.log")

local function safe_require(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.warn("abilities_debug: failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local scan      = safe_require("pragmata.bindings.scan")
local overdrive = safe_require("pragmata.bindings.overdrive")

-- Amber, packed as ImGui's 0xAABBGGRR.
local COL_WARN = 255 * 0x1000000 + 60 * 0x10000 + 180 * 0x100 + 255

local function bool_text(v)
    if v == true then return "TRUE" end
    if v == false then return "false" end
    if v == nil then return "<nil>" end
    return tostring(v)
end

local function frac_text(v)
    if type(v) ~= "number" then return "<nil>" end
    return string.format("%.0f%% (%.3f)", v * 100, v)
end

local _last_outcome = "(no manual trigger yet)"


re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata Abilities Debug") then return end

    -- ---- Scan ----------------------------------------------------------
    imgui.text("== Scan ==")
    if scan == nil then
        imgui.text("(scan binding not loaded)")
    else
        local ok_s, s = pcall(scan.debug_status)
        if ok_s and s then
            imgui.text("ScanManager singleton:   " .. bool_text(s.singleton_present))
            imgui.text("requestScan resolved:    " .. bool_text(s.request_scan_ok))
            imgui.text("requestScanObjective:    " .. bool_text(s.request_objective_ok))
            imgui.text("isScanning:              " .. bool_text(s.is_scanning))
            imgui.text("recent ping count:       " .. tostring(s.ping_count))
            imgui.text("last trigger outcome:    " .. tostring(s.last_scan_msg))
        else
            imgui.text("debug_status() failed: " .. tostring(s))
        end
        if imgui.button("Trigger scan") then
            local ok, msg = scan.scan()
            _last_outcome = "scan(): " .. tostring(ok) .. " (" .. tostring(msg) .. ")"
            log.info("abilities_debug: " .. _last_outcome)
        end
    end

    imgui.separator()

    -- ---- Overdrive -----------------------------------------------------
    imgui.text("== Overdrive (wide FinishBlow) ==")
    if overdrive == nil then
        imgui.text("(overdrive binding not loaded)")
    else
        local ok_o, o = pcall(overdrive.debug_status)
        if ok_o and o then
            imgui.text("FinishBlow driver captured:    " .. bool_text(o.finishblow_driver_ok))
            imgui.text("PuzzleControl driver captured: " .. bool_text(o.puzzle_driver_ok))
            imgui.text("requestWideFinishBlow resolved:" .. bool_text(o.request_method_ok))
            imgui.text("hacking gauge fill:            " .. frac_text(o.gauge_fraction))
            imgui.text("is_ready (gauge full):         " .. bool_text(o.is_ready))
            imgui.text("last trigger outcome:          " .. tostring(o.last_trigger_msg))
            if type(o.drivers) == "table" then
                imgui.text("driver capture hooks:")
                for name, st in pairs(o.drivers) do
                    imgui.text(string.format("  %s: hook=%s captured=%s",
                        name, tostring(st.hook), bool_text(st.captured)))
                end
            end
        else
            imgui.text("debug_status() failed: " .. tostring(o))
        end

        imgui.text_colored("WARNING: Overdrive hooks a cinematic pipeline.", COL_WARN)
        imgui.text_colored("Test on a DISPOSABLE save (save-corruption risk).", COL_WARN)
        if imgui.button("Trigger overdrive (gauge must be full)") then
            local ok, msg = overdrive.trigger()
            _last_outcome = "overdrive.trigger(): " .. tostring(ok) .. " (" .. tostring(msg) .. ")"
            log.info("abilities_debug: " .. _last_outcome)
        end
    end

    imgui.separator()
    imgui.text("Last manual trigger: " .. _last_outcome)

    imgui.tree_pop()
end)


return M
