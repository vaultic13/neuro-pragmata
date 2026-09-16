-- ImGui debug panel and manual triggers for Diana's three abilities.
--
-- Renders under "Pragmata Abilities Debug" in the REFramework menu (press
-- Insert in-game), and shows in real time:
--   - Scan:      singleton present? methods resolved? isScanning? marker
--                counts, the readable report, the live inventory.
--   - Auto-Hack: manager, driver, work unit, target, gauge.
--   - Overdrive: drivers captured? canDeathblow? gauge fill and readiness,
--                the live status flags, and the confirmation state machine.
--
-- MANUAL TRIGGERS. F6 / F7 / F8 fire Scan / Auto-Hack / Overdrive, and the
-- three buttons at the top of the panel do the same thing. Each one calls
-- exactly the binding function the AI peer's action calls -- not a parallel
-- test path -- so a working key proves the peer's route, and a broken one is
-- a real failure rather than a broken harness.
--
-- The Overdrive trigger carries the save-corruption warning from ACTIONS.md:
-- it drives a cinematic pipeline, so test on a disposable save.
--
-- Apart from those triggers this panel is read-only, and it writes no files.

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
local hacking   = safe_require("pragmata.bindings.hacking")
local object_names = safe_require("pragmata.bindings.object_names")
local config    = safe_require("pragmata.mod_config")

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

local function hash_text(v)
    if type(v) ~= "number" then return tostring(v or "?") end
    return string.format("0x%08X", v)
end

local _last_outcome = "(no manual trigger yet)"

-- ---------------------------------------------------------------------------
-- Manual triggers
-- ---------------------------------------------------------------------------

-- Virtual-key codes for F6/F7/F8.
local VK_F6, VK_F7, VK_F8 = 0x75, 0x76, 0x77

-- One definition per ability, shared by the hotkeys and the button row so the
-- two can never drift apart. `call` returns (ok, message) exactly like the
-- binding it wraps.
--
-- Each `call` is the SAME function pragmata_main's action handler reaches
-- through ability_actions. The only thing skipped is the deferred confirmation
-- window, which reports the outcome to the peer; here the outcome is the
-- message plus what you can see on screen.
local TRIGGERS = {
    {
        key = VK_F6, label = "Scan", hotkey = "F6",
        call = function()
            if scan == nil then return false, "scan binding not loaded" end
            return scan.scan_input()
        end,
    },
    {
        key = VK_F7, label = "Auto-Hack", hotkey = "F7",
        call = function()
            if hacking == nil then return false, "hacking binding not loaded" end
            return hacking.auto_hack()
        end,
    },
    {
        key = VK_F8, label = "Overdrive", hotkey = "F8",
        call = function()
            if overdrive == nil then return false, "overdrive binding not loaded" end
            return overdrive.trigger()
        end,
    },
}

-- Exactly ONE call to trigger.call per invocation. pcall forwards the
-- binding's (ok, message) pair as its 2nd and 3rd results, so a single call
-- covers both the success path and a raised SDK error.
local function fire(trigger, source)
    local called, ok, message = pcall(trigger.call)
    if not called then
        _last_outcome = string.format("%s [%s]: RAISED (%s)",
            trigger.label, source, tostring(ok))
    else
        _last_outcome = string.format("%s [%s]: %s (%s)",
            trigger.label, source, tostring(ok), tostring(message))
    end
    log.info("abilities_debug: " .. _last_outcome)
end

-- Rising-edge detection: is_key_down is a level, so without this a held key
-- would fire an ability every frame.
local _last_keys = {}

local function pressed(vk)
    local ok, now = pcall(function() return reframework:is_key_down(vk) end)
    now = ok and now == true
    local was = _last_keys[vk] == true
    _last_keys[vk] = now
    return now and not was
end

re.on_frame(function()
    for _, trigger in ipairs(TRIGGERS) do
        if pressed(trigger.key) then fire(trigger, trigger.hotkey) end
    end
end)


re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata Abilities Debug") then return end

    -- ---- Manual triggers -----------------------------------------------
    imgui.text("== Manual triggers ==")
    for i, trigger in ipairs(TRIGGERS) do
        if i > 1 then imgui.same_line() end
        if imgui.button(trigger.label .. " (" .. trigger.hotkey .. ")") then
            fire(trigger, "button")
        end
    end
    imgui.text("Last: " .. _last_outcome)
    imgui.text_colored("Each trigger calls the same binding the AI peer's action calls. "
        .. "Overdrive drives a cinematic pipeline -- test on a disposable save.", COL_WARN)

    imgui.separator()

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
            imgui.text(string.format("markers: %s reported / %s raw%s",
                tostring(s.ping_count_reported), tostring(s.ping_count),
                s.filter_bypassed and "  [FILTER BYPASSED]"
                    or (s.filter_enabled and "" or "  (filter off)")))
            if s.join then
                imgui.text(string.format("join: ctx=%d pair=%d none=%d   candidates=%s (%s keyed, %s collisions)",
                    s.join.context or 0, s.join.pair or 0, s.join.none or 0,
                    tostring(s.candidates_total), tostring(s.candidates_context_keyed),
                    tostring(s.context_collisions)))
            end
            imgui.text(string.format(
                "duplicates collapsed: %s   scene verdicts: %s",
                tostring(s.duplicates_removed or 0), tostring(s.scene_evidence or 0)))
            if (s.scene_evidence or 0) == 0 and (s.ping_count or 0) > 0 then
                imgui.text_colored("no scene verdicts: EnvironmentSceneManager did not answer for "
                    .. "any candidate, so the unloaded-scene filter is inert this scan.", COL_WARN)
            end
            imgui.text("activeContexts=" .. tostring(s.active_context_count)
                .. "  stale=" .. bool_text(s.stale)
                .. "  rebuilds=" .. tostring(s.inventory_recomputes))
            if s.filter_note then
                imgui.text_colored("filter: " .. tostring(s.filter_note), COL_WARN)
            end
            if s.join and (s.join.context or 0) == 0 and (s.join.pair or 0) > 0 then
                imgui.text_colored("ctx=0: ScanCandidateUnit.ContextHash is not ContextID.GetHashCode(); "
                    .. "the pair fallback is carrying every join.", COL_WARN)
            end
            -- The one unverifiable assumption behind the acquired_items filter:
            -- that ScanUnit.objectIDHash is an item id. A true here on any
            -- non-Item icon disproves it outright.
            if s.acquired_probe then
                local ap = s.acquired_probe
                local by = {}
                for icon, n in pairs(ap.true_by_icon or {}) do
                    by[#by + 1] = tostring(icon) .. "=" .. tostring(n)
                end
                table.sort(by)
                imgui.text(string.format("acquired probe: %d asked, %d true  [%s]",
                    ap.asked or 0, ap.true_count or 0, table.concat(by, " ")))
                for icon, n in pairs(ap.true_by_icon or {}) do
                    if icon ~= "Item" and (tonumber(n) or 0) > 0 then
                        imgui.text_colored("  '" .. tostring(icon) .. "' reported acquired: "
                            .. "objectIDHash is NOT the item id space -- keep acquired_items off.",
                            COL_WARN)
                    end
                end
            end
            -- Item / interaction state, read from each marker's own container
            -- record. Unlike the acquired probe above this involves no guess
            -- about ID spaces: the item ID comes out of the object itself.
            if s.pickup_stats then
                local ps = s.pickup_stats
                local why = {}
                for reason, n in pairs(ps.blocked_by or {}) do
                    why[#why + 1] = tostring(reason) .. "=" .. tostring(n)
                end
                table.sort(why)
                imgui.text(string.format(
                    "pickup: %d containers of %d probed, %d takeable, %d blocked%s",
                    ps.containers or 0, ps.asked or 0, ps.pickable or 0,
                    ps.blocked or 0,
                    #why > 0 and ("  [" .. table.concat(why, " ") .. "]") or ""))
                if (ps.named_from_container or 0) > 0 then
                    imgui.text(string.format(
                        "  %d marker(s) named from their contents rather than objectIDHash",
                        ps.named_from_container))
                end
            elseif s.pickup_enabled == false then
                imgui.text("pickup: checks disabled (mod_config.scan_pickup_checks)")
            end
            imgui.text("last request mode:       " .. tostring(s.last_request_mode or "-"))
            imgui.text("last trigger outcome:    " .. tostring(s.last_scan_msg))
            if s.command_input then
                local ci = s.command_input
                imgui.text("Scan command hook:        " .. bool_text(ci.hooks_installed))
                if ci.last_injected then
                    local p = ci.last_injected
                    imgui.text(string.format("last injected step:        %s (T%d D%d R%d)",
                        tostring(p.step), tonumber(p.trigger) or 0,
                        tonumber(p.down) or 0, tonumber(p.release) or 0))
                end
                if ci.last_consumed then
                    local c = ci.last_consumed
                    imgui.text("last injected query:      " .. tostring(c.command) .. "/" .. tostring(c.phase))
                end
            end
        else
            imgui.text("debug_status() failed: " .. tostring(s))
        end
        imgui.text("Trigger: presses the game's own Scan command (default keyboard "
            .. "binding: C). No OS key event is generated.")
        if imgui.button("Log scan inventory") then
            local ok, msg = scan.log_inventory()
            _last_outcome = "scan.log_inventory(): " .. tostring(ok) .. " (" .. tostring(msg) .. ")"
        end
        local ok_i, inventory = pcall(scan.get_inventory)
        if ok_i and inventory ~= nil then
            local ok_r, readable = pcall(scan.describe_results)
            if ok_r and readable and readable.text then
                imgui.text("Readable scan result: " .. tostring(readable.text))
                imgui.text(string.format(
                    "  rows: %d reported / %d built%s",
                    readable.row_count or 0, readable.row_count_all or 0,
                    (readable.unlocated_rows or 0) > 0
                        and string.format("   (%d row(s) / %d markers at unknown range)",
                            readable.unlocated_rows, readable.unlocated_markers or 0)
                        or ""))
                if readable.distance_bypassed then
                    imgui.text_colored("located-only report ABANDONED: nothing had a distance this "
                        .. "scan, so every row is being reported. Check the join counters above.",
                        COL_WARN)
                end
            end
            if imgui.tree_node("Local scan inventory (" .. tostring(inventory.total_count) .. " entries / " .. tostring(#inventory.groups) .. " groups)") then
                if object_names ~= nil then
                    local ok_n, names = pcall(object_names.debug_status)
                    if ok_n and names then
                        imgui.text(string.format(
                            "resolvers: icon=%s objectIDs=%s (%d/%d) variety=%d gui=%s",
                            bool_text(names.icon_resolver_ok), tostring(names.object_ids_state),
                            names.object_ids_scanned or 0, names.object_ids_total or 0,
                            names.variety_count or 0, bool_text(names.display_singleton)))
                    end
                end
                if object_names ~= nil then
                    local ok_ph, names2 = pcall(object_names.debug_status)
                    if ok_ph and names2 and (names2.placeholder_rejected or 0) > 0 then
                        imgui.text(string.format("rejected %d placeholder name(s), e.g. %s",
                            names2.placeholder_rejected, tostring(names2.last_placeholder)))
                    end
                end
                imgui.text_colored("This tree is the RAW data: internal codes and hashes live here. "
                    .. "The AI sees the phrased line above, which never contains either.", COL_WARN)
                for _, group in ipairs(inventory.groups) do
                    imgui.text(string.format("%dx %s  kind=%s icon=%s dist=%s contexts=%d",
                        group.count, tostring(group.label), tostring(group.kind),
                        tostring(group.icon),
                        group.nearest_distance and string.format("%.1f", group.nearest_distance) or "?",
                        #group.contexts))
                    imgui.text(string.format("      object=%s iconhash=%s buckets=%s internal=%s named=%s%s",
                        hash_text(group.object_id), hash_text(group.icon_type),
                        tostring(group.buckets), tostring(group.internal),
                        bool_text(group.named),
                        group.named_from_container and " (from contents)" or ""))
                    if (group.pickable or 0) > 0 or (group.blocked or 0) > 0
                        or group.item_id ~= nil then
                        local why = {}
                        for reason, n in pairs(group.blocked_by or {}) do
                            why[#why + 1] = tostring(reason) .. "=" .. tostring(n)
                        end
                        table.sort(why)
                        imgui.text(string.format(
                            "      pickup: takeable=%d blocked=%d%s itemID=%s qty=%d located=%d",
                            group.pickable or 0, group.blocked or 0,
                            #why > 0 and ("  [" .. table.concat(why, " ") .. "]") or "",
                            hash_text(group.item_id), group.quantity or 0,
                            #(group.distances or {})))
                    end
                end
                imgui.tree_pop()
            end

            -- The artefact that makes the filter verifiable in ONE scan: what
            -- was removed, and on whose say-so.
            local dropped = inventory.dropped or {}
            if #dropped > 0 and imgui.tree_node("Filtered out (" .. tostring(#dropped) .. " shown)") then
                for _, d in ipairs(dropped) do
                    imgui.text(string.format("  %s (%s) icon=%s reason=%s dist=%s scene=%s",
                        tostring(d.label), tostring(d.internal), tostring(d.icon),
                        tostring(d.reason),
                        d.distance and string.format("%.1f", d.distance) or "?",
                        hash_text(d.scene_id)))
                end
                imgui.tree_pop()
            end

            -- Session-only toggles. `config` is a plain table, so writing it
            -- here changes behaviour immediately -- which turns A/B testing a
            -- layer into one click instead of an edit and a restart.
            if config ~= nil and imgui.tree_node("Scan filter layers (session only)") then
                imgui.text_colored("Edit pragmata/mod_config.lua to persist these.", COL_WARN)
                local changed, value = imgui.checkbox("filtering enabled",
                    config.scan_live_candidates_only ~= false)
                if changed then config.scan_live_candidates_only = value end
                config.scan_filters = config.scan_filters or {}
                for _, layer in ipairs({ "active_context", "context_valid", "prop_vanished",
                                         "prop_inactive", "prop_looted", "acquired_items",
                                         "hide_icon", "candidate_match",
                                         "interact_restricted", "earth_item_acquired",
                                         "scene_loaded" }) do
                    local disabled = (s.layers_disabled or {})[layer]
                        or (layer:find("^prop_") and (s.layers_disabled or {}).prop_state)
                    local label = layer .. (disabled and "  (no evidence this scan)" or "")
                        .. "  dropped=" .. tostring((s.filtered_by or {})[layer] or 0)
                    local ch, v = imgui.checkbox(label, config.scan_filters[layer] == true)
                    if ch then config.scan_filters[layer] = v end
                end

                imgui.separator()
                imgui.text("Report shape (affects only the AI-facing line):")
                local chd, vd = imgui.checkbox("report only markers with a distance",
                    config.scan_report_require_distance ~= false)
                if chd then config.scan_report_require_distance = vd end
                local chl, vl = imgui.checkbox("list every distance (off = nearest only)",
                    config.scan_report_detail ~= "grouped")
                if chl then
                    config.scan_report_detail = vl and "located" or "grouped"
                end
                local chp, vp = imgui.checkbox("read item / pickup state per marker",
                    config.scan_pickup_checks ~= false)
                if chp then config.scan_pickup_checks = vp end
                local chdd, vdd = imgui.checkbox("collapse repeated pings for one object",
                    config.scan_dedupe_markers ~= false)
                if chdd then config.scan_dedupe_markers = vdd end
                imgui.tree_pop()
            end
        else
            imgui.text("scan inventory: unavailable")
        end
    end

    imgui.separator()

    -- ---- Auto-Hack ------------------------------------------------------
    imgui.text("== Auto-Hack (diagnostic state) ==")
    if hacking == nil then
        imgui.text("(auto-hack binding not loaded)")
    else
        local ok_h, h = pcall(hacking.debug_status)
        if ok_h and h then
            imgui.text("HackingManager present: " .. bool_text(h.manager_present))
            imgui.text("Puzzle driver captured: " .. bool_text(h.driver_present))
            imgui.text("AutoHack work unit:     " .. bool_text(h.workunit_present))
            imgui.text("Target present:          " .. bool_text(h.target_present))
            imgui.text("Jamming:                 " .. bool_text(h.jamming))
            imgui.text("Auto-Hack running:       " .. bool_text(h.auto_hacking))
            imgui.text("Can Auto-Hack:           " .. bool_text(h.can_auto_hack))
            imgui.text("Start method resolved:    " .. bool_text(h.start_method_ok))
            imgui.text("Gauge empty:             " .. bool_text(h.gauge_empty))
            imgui.text("Gauge remaining rate:    " .. frac_text(h.gauge_remaining_rate))
        else
            imgui.text("debug_status() failed: " .. tostring(h))
        end
    end

    imgui.separator()

    -- ---- Overdrive -----------------------------------------------------
    imgui.text("== Overdrive (PlayerDeathblowDriver route) ==")
    if overdrive == nil then
        imgui.text("(overdrive binding not loaded)")
    else
        local ok_o, o = pcall(overdrive.debug_status)
        if ok_o and o then
            imgui.text("PuzzleControl driver captured: " .. bool_text(o.puzzle_driver_ok))
            imgui.text("Deathblow driver captured:     " .. bool_text(o.deathblow_driver_ok))
            imgui.text("canDeathblow():                " .. bool_text(o.can_deathblow))
            imgui.text("hacking gauge fill:            " .. frac_text(o.gauge_fraction))
            imgui.text(string.format("hacking gauge points:          %s / %s (full=%s)",
                tostring(o.gauge_remain), tostring(o.gauge_total), bool_text(o.gauge_full)))
            imgui.text("READY:                         " .. bool_text(o.is_ready))
            imgui.text("  because:                     " .. tostring(o.readiness_reason))
            imgui.text("dispatch:                      PlayerDeathblowDriver."
                .. tostring(o.dispatch_label)
                .. "  resolved=" .. bool_text(o.try_deathblow_ok))

            -- Status layer: the live engine flags readiness/confirmation now
            -- come from.
            local sl = o.status_layer
            if type(sl) == "table" then
                imgui.text("-- status layer --")
                imgui.text("  status container live:       " .. bool_text(sl.container_ok))
                if type(sl.enums) == "table" then
                    for _, name in ipairs({ "app.player.PuzzleStatus",
                                            "app.player.FinishBlowStatus",
                                            "app.player.DeathblowStatus" }) do
                        local e = sl.enums[name]
                        if type(e) == "table" then
                            local set = type(e.set) == "table" and #e.set > 0
                                and table.concat(e.set, ", ") or "(none set)"
                            imgui.text(string.format("  %s: %s",
                                name:gsub("^app%.player%.", ""), set))
                        end
                    end
                end
            end

            if o.pending then
                imgui.text(string.format("awaiting confirmation: %s, %d frames, gauge delta %s",
                    tostring(o.pending.command), tonumber(o.pending.frames_waited) or 0,
                    tostring(o.pending.gauge_delta)))
            end
            if o.last_confirmation then
                local c = o.last_confirmation
                imgui.text(string.format("last confirmation: %s %s (gauge delta %s)",
                    tostring(c.reason), tostring(c.flag or ""), tostring(c.gauge_delta)))
            end
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

    end

    imgui.separator()

    imgui.separator()
    imgui.text("Last manual trigger: " .. _last_outcome)

    imgui.tree_pop()
end)


return M
