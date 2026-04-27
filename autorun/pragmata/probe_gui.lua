-- Phase 1 GUI element probe (v2).
--
-- Hooks re.on_pre_gui_draw_element. For every drawn GUI panel it logs the
-- panel's *asset path* (e.g. GUI/HUD/Reticle), counted per unique path. The
-- type name alone wasn't informative — Pragmata's hook only fires for
-- via.gui.GUI roots, so every entry shared one type. Asset paths are the
-- screen-level differentiator we actually need.
--
-- Also dumps the structure of via.gui.View and via.gui.Control on first run,
-- since walking the View tree is the next step if asset paths alone don't
-- pin down subtitles.
--
-- DELIBERATELY NOT logged: text content, string field values from controls,
-- anything that could leak narrative content. Asset paths are file-system-style
-- identifiers — usually plot-neutral but flag any that look story-revealing
-- before sharing the log.
--
-- Workflow:
--   1. Quiet scene -> "Reset Counts" -> wait -> label baseline_menu -> "Snapshot".
--   2. Dialogue scene -> "Reset Counts" -> let dialogue play -> label dialogue_active -> "Snapshot".
--   3. Diff: paths in #2 not in #1 (or with much higher counts) are subtitle candidates.
--
-- Output file: <Pragmata>/reframework/data/pragmata_mailbox/probe_gui.log

local M = {}
local log = require("pragmata.util.log")

local PROBE_LOG_PATH = "pragmata_mailbox/probe_gui.log"

local _enabled = false
local _type_counts = {}        -- full_name -> count since last reset
local _path_counts = {}        -- asset_path -> count since last reset
local _dumped_structure = {}   -- full_name -> true (first-occurrence dump done)
local _seen_paths = {}         -- asset_path -> true (first-occurrence dump done)
local _snapshot_counter = 0
local _label_buffer = ""       -- label for next snapshot
local _bootstrap_dumped = false  -- one-shot dump of via.gui.View/Control structure

-- Candidate GUI panels identified from snapshot diff: paths that appeared
-- only when dialogue was active and grew in lockstep. We capture each one's
-- most recent live via.gui.GUI element pointer when we see it draw, so the
-- user's "Inspect Candidates" button can walk into its tree.
local CANDIDATE_PATHS = {
    "UI/Asset/ui7000/gui/ui7000",
    "UI/Asset/ui7000/gui/ui7200",
    "UI/Asset/ui0400/gui/ui0420",
    "UI/Asset/ui2000/gui/ui2010",
    "UI/Asset/ui2100/gui/ui2160",
}
local _candidate_guis = {}     -- asset_path -> latest via.gui.GUI element seen
local _log_text_content = false  -- when true, inspect logs the actual Message text
                                  -- (default off; user toggles via ImGui only when
                                  -- the current scene is known spoiler-safe)
local CONTENT_TRUNCATE_LEN = 200

-- --------------------------------------------------------------------
-- Logging helpers
-- --------------------------------------------------------------------

local function append_log(s)
    local f = io.open(PROBE_LOG_PATH, "a")
    if not f then return end
    f:write(s)
    f:close()
end

local function timestamp()
    -- REFramework Lua exposes os.date
    local ok, ts = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    if ok then return ts end
    return "?"
end

-- --------------------------------------------------------------------
-- First-time type structure dump (methods + fields, no values)
-- --------------------------------------------------------------------

local function dump_type_structure(type_def, full_name)
    if _dumped_structure[full_name] then return end
    _dumped_structure[full_name] = true

    local lines = { "\n=== TYPE FIRST SEEN: " .. tostring(full_name) .. " (" .. timestamp() .. ") ===\n" }

    local ok_m, methods = pcall(function() return type_def:get_methods() end)
    if ok_m and methods then
        table.insert(lines, "METHODS:\n")
        local count = 0
        for _, m in ipairs(methods) do
            local mname_ok, mname = pcall(function() return m:get_name() end)
            if mname_ok and mname then
                table.insert(lines, "  " .. tostring(mname) .. "\n")
                count = count + 1
                if count >= 200 then
                    table.insert(lines, "  ...(method list truncated at 200)\n")
                    break
                end
            end
        end
    end

    local ok_f, fields = pcall(function() return type_def:get_fields() end)
    if ok_f and fields then
        table.insert(lines, "FIELDS:\n")
        local count = 0
        for _, fld in ipairs(fields) do
            local fname_ok, fname = pcall(function() return fld:get_name() end)
            if fname_ok and fname then
                table.insert(lines, "  " .. tostring(fname) .. "\n")
                count = count + 1
                if count >= 200 then
                    table.insert(lines, "  ...(field list truncated at 200)\n")
                    break
                end
            end
        end
    end

    append_log(table.concat(lines))
end

-- --------------------------------------------------------------------
-- One-shot bootstrap dump for types we'll likely need but don't see
-- through the GUI-draw hook directly.
-- --------------------------------------------------------------------

local function bootstrap_dump_extra_types()
    if _bootstrap_dumped then return end
    _bootstrap_dumped = true

    local extras = { "via.gui.View", "via.gui.Control", "via.gui.Text", "via.gui.Message" }
    for _, name in ipairs(extras) do
        local td = sdk.find_type_definition(name)
        if td ~= nil then
            dump_type_structure(td, name)
        else
            append_log("\n=== TYPE NOT FOUND: " .. name .. " ===\n")
        end
    end
end

-- --------------------------------------------------------------------
-- The hook
-- --------------------------------------------------------------------

re.on_pre_gui_draw_element(function(element, _context)
    if not _enabled then return true end
    if element == nil then return true end

    bootstrap_dump_extra_types()

    local ok, type_def = pcall(function() return element:get_type_definition() end)
    if not ok or type_def == nil then return true end

    local nok, full_name = pcall(function() return type_def:get_full_name() end)
    if not nok or full_name == nil then return true end

    _type_counts[full_name] = (_type_counts[full_name] or 0) + 1
    if not _dumped_structure[full_name] then
        dump_type_structure(type_def, full_name)
    end

    -- Asset path: screen-level identifier. This is the actual differentiator
    -- between a HUD panel, a menu panel, and (we hope) a subtitle panel.
    local pok, asset_path = pcall(function() return element:call("get_AssetPath") end)
    if pok and type(asset_path) == "string" and asset_path ~= "" then
        _path_counts[asset_path] = (_path_counts[asset_path] or 0) + 1
        if not _seen_paths[asset_path] then
            _seen_paths[asset_path] = true
            append_log("\n=== ASSET PATH FIRST SEEN: " .. asset_path .. " (" .. timestamp() .. ") ===\n")
        end
        -- Track the live GUI element for each candidate path so the user can
        -- inspect-on-demand into its internal Text controls.
        for _, candidate in ipairs(CANDIDATE_PATHS) do
            if asset_path == candidate then
                _candidate_guis[asset_path] = element
                break
            end
        end
    end

    return true
end)

-- --------------------------------------------------------------------
-- Candidate inspection: walk into a GUI panel's tree and enumerate
-- via.gui.Text controls. Logs control name, font size, visibility, and
-- the LENGTH of the current message text. Never logs the message content.
-- --------------------------------------------------------------------

local function inspect_text_controls_in(gui_element, asset_path)
    append_log(string.format("\n  [%s]\n", asset_path))
    if gui_element == nil then
        append_log("    (no live element captured for this path)\n")
        return
    end

    local text_td = sdk.find_type_definition("via.gui.Text")
    if text_td == nil then
        append_log("    via.gui.Text type not found\n")
        return
    end
    local text_runtime
    local rok, rt = pcall(function() return text_td:get_runtime_type() end)
    if rok then text_runtime = rt end
    if text_runtime == nil then
        append_log("    via.gui.Text runtime type unavailable\n")
        return
    end

    -- via.gui.GUI:findObjects has two overloads. Try several call shapes;
    -- log which one worked so we can lock it in for v4.
    local objs = nil
    local how = "?"
    do
        local ok, r = pcall(function() return gui_element:call("findObjects", text_runtime) end)
        if ok and r ~= nil then objs = r; how = "findObjects(Type)" end
    end
    if objs == nil then
        local ok, r = pcall(function() return gui_element:call("findObjects(System.Type)", text_runtime) end)
        if ok and r ~= nil then objs = r; how = "findObjects(System.Type)" end
    end
    if objs == nil then
        append_log("    findObjects: no overload accepted Type arg\n")
        return
    end
    append_log("    findObjects via " .. how .. "\n")

    -- The result might be a System.Array, a List, or a sequence-like wrapper.
    -- Try common shapes for size + indexing.
    local count = 0
    local cok, c = pcall(function() return objs:get_size() end)
    if cok and type(c) == "number" then count = c end
    if count == 0 then
        cok, c = pcall(function() return objs:get_Count() end)
        if cok and type(c) == "number" then count = c end
    end
    if count == 0 then
        cok, c = pcall(function() return #objs end)
        if cok and type(c) == "number" then count = c end
    end
    append_log(string.format("    %d Text control(s)\n", count))

    if count == 0 then return end

    for i = 0, count - 1 do
        local ctrl
        local iok, c1 = pcall(function() return objs:get_element(i) end)
        if iok and c1 ~= nil then ctrl = c1 end
        if ctrl == nil then
            iok, c1 = pcall(function() return objs[i + 1] end)
            if iok and c1 ~= nil then ctrl = c1 end
        end
        if ctrl == nil then
            iok, c1 = pcall(function() return objs[i] end)
            if iok and c1 ~= nil then ctrl = c1 end
        end
        if ctrl ~= nil then
            local name = "?"
            pcall(function()
                local n = ctrl:call("get_Name")
                if type(n) == "string" then name = n end
            end)
            local font = 0
            pcall(function()
                local f = ctrl:call("get_FontSize")
                if type(f) == "number" then font = f end
            end)
            local visible = "?"
            pcall(function()
                local v = ctrl:call("get_Visible")
                visible = tostring(v)
            end)
            local mlen = -1
            local content
            pcall(function()
                local m = ctrl:call("get_Message")
                if type(m) == "string" then
                    mlen = #m
                    if _log_text_content then content = m end
                end
            end)
            -- Some Text controls use MessageId-based localization rather than
            -- direct Message strings. Logging both lets us tell which mechanism
            -- a given control uses.
            local msg_id_str = "?"
            pcall(function()
                local mid = ctrl:call("get_MessageId")
                if mid ~= nil then
                    -- MessageId may be a number, GUID, or struct — coerce to a
                    -- printable form and trim if huge.
                    local s = tostring(mid)
                    if #s > 64 then s = s:sub(1, 64) .. "..." end
                    msg_id_str = s
                end
            end)
            if content ~= nil then
                local truncated = content
                if #truncated > CONTENT_TRUNCATE_LEN then
                    truncated = truncated:sub(1, CONTENT_TRUNCATE_LEN) .. "..."
                end
                truncated = truncated:gsub("[\r\n]+", " | ")
                append_log(string.format(
                    "      name=%-32s font=%-4d visible=%-5s msg_len=%d msg_id=%s\n        msg=%q\n",
                    tostring(name), font, visible, mlen, msg_id_str, truncated))
            else
                append_log(string.format(
                    "      name=%-32s font=%-4d visible=%-5s msg_len=%d msg_id=%s\n",
                    tostring(name), font, visible, mlen, msg_id_str))
            end
        end
    end
end

function M.inspect_candidates(label)
    append_log(string.format("\n>>> INSPECT CANDIDATES #%d  label=%q  ts=%s  content=%s\n",
        _snapshot_counter + 1, tostring(label or ""), timestamp(),
        _log_text_content and "ON" or "off"))
    for _, path in ipairs(CANDIDATE_PATHS) do
        inspect_text_controls_in(_candidate_guis[path], path)
    end
    log.info("inspected " .. tostring(#CANDIDATE_PATHS) .. " candidate paths"
        .. (_log_text_content and " (with message content)" or ""))
end

function M.set_log_content(value)
    _log_text_content = value and true or false
end

-- --------------------------------------------------------------------
-- Public API
-- --------------------------------------------------------------------

function M.enable()
    _enabled = true
    log.info("GUI probe ENABLED — logging to " .. PROBE_LOG_PATH)
    append_log("\n############# PROBE ENABLED " .. timestamp() .. " #############\n")
end

function M.disable()
    _enabled = false
    log.info("GUI probe disabled")
end

function M.reset_counts()
    _type_counts = {}
    _path_counts = {}
    log.info("probe counts reset")
    append_log("\n--- counts reset @ " .. timestamp() .. " ---\n")
end

local function emit_sorted(lines, header, counts)
    table.insert(lines, header)
    local entries = {}
    for k, v in pairs(counts) do
        table.insert(entries, { k = k, v = v })
    end
    table.sort(entries, function(a, b) return a.v > b.v end)
    if #entries == 0 then
        table.insert(lines, "    (none)\n")
        return
    end
    for _, e in ipairs(entries) do
        table.insert(lines, string.format("    %8d  %s\n", e.v, e.k))
    end
end

function M.snapshot(label)
    _snapshot_counter = _snapshot_counter + 1
    local lines = {
        string.format("\n>>> SNAPSHOT #%d  label=%q  ts=%s\n",
            _snapshot_counter, tostring(label or ""), timestamp()),
    }
    emit_sorted(lines, "  TYPES:\n", _type_counts)
    emit_sorted(lines, "  ASSET PATHS:\n", _path_counts)
    append_log(table.concat(lines))

    local n_paths = 0
    for _ in pairs(_path_counts) do n_paths = n_paths + 1 end
    log.info(string.format("snapshot #%d written (%d unique paths)", _snapshot_counter, n_paths))
end

-- --------------------------------------------------------------------
-- ImGui control panel
-- --------------------------------------------------------------------

re.on_draw_ui(function()
    if imgui.tree_node("Pragmata Probe") then
        if _enabled then
            imgui.text("Probe: ENABLED")
        else
            imgui.text("Probe: disabled")
        end

        if imgui.button("Enable") then M.enable() end
        imgui.same_line()
        if imgui.button("Disable") then M.disable() end

        imgui.separator()

        imgui.text("Snapshot label (optional):")
        local changed, new_label = imgui.input_text("##probe_label", _label_buffer)
        if changed then _label_buffer = new_label end

        if imgui.button("Reset Counts") then M.reset_counts() end
        imgui.same_line()
        if imgui.button("Snapshot") then M.snapshot(_label_buffer) end

        if imgui.button("Inspect Candidates") then M.inspect_candidates(_label_buffer) end
        imgui.text("(Press during a dialogue line to dump Text control metadata)")

        local changed_c, new_c = imgui.checkbox("Log message content (early-game only)", _log_text_content)
        if changed_c then _log_text_content = new_c end
        if _log_text_content then
            imgui.text("WARNING: dialogue text WILL be written to probe_gui.log")
        end

        imgui.separator()

        local total_t, distinct_t = 0, 0
        for _, c in pairs(_type_counts) do
            total_t = total_t + c
            distinct_t = distinct_t + 1
        end
        local total_p, distinct_p = 0, 0
        for _, c in pairs(_path_counts) do
            total_p = total_p + c
            distinct_p = distinct_p + 1
        end
        imgui.text(string.format("Distinct types: %d  total: %d", distinct_t, total_t))
        imgui.text(string.format("Distinct paths: %d  total: %d", distinct_p, total_p))
        imgui.text("Log: " .. PROBE_LOG_PATH)

        imgui.tree_pop()
    end
end)

return M
