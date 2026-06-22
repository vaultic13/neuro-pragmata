-- ImGui debug panel for the hacking (PuzzleSnake) integration.
--
-- Renders under "Pragmata Hacking Debug" in the REFramework menu (press
-- Insert in-game). Shows real-time:
--   - Whether type defs and methods resolved
--   - Whether the active PuzzleSnake instance was found
--   - Current values of the lifecycle trigger fields
--   - Observer edge hit counts (cumulative since boot)
--   - Grid dimensions and cursor position when readable
--
-- Diagnostic buttons:
--   - "Force discover":          re-runs instance lookup paths
--   - "Send synthetic test grid": fakes a grid render + force, useful to
--                                 verify the bridge → AI peer pipeline
--                                 independent of in-game state
--   - "Dump cells to log":       writes the full cell list to a dump file
--   - "Render current grid":     runs the renderer against current state
--
-- Manual move dispatch:
--   - Per-direction move() and can_move() buttons
--   - Plan-queue test buttons that drive a multi-move sequence
--   - Manual `_RequestForceSuccess` write button (production completion path)
--
-- This is purely diagnostic. Safe to leave enabled in shipping builds; the
-- panel only renders when expanded.

local M = {}

local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local snake = require("pragmata.bindings.puzzle_snake")
local observer = require("pragmata.hacking_observer")
local render = require("pragmata.util.snake_render")

local DUMP_PATH = "pragmata_mailbox/hacking_dump.log"

-- Write a multi-line block to the dump file. The mailbox directory is known
-- to exist (the bridge requires it); this gives us a reliable sink that
-- doesn't depend on REFramework's log.txt being writable on this install.
local function append_dump(s)
    local f = io.open(DUMP_PATH, "a")
    if f then f:write(s); f:close() end
end

local GAME = "Pragmata"


local function bool_text(v)
    if v == true then return "TRUE" end
    if v == false then return "false" end
    if v == nil then return "<nil>" end
    return tostring(v)
end


-- Track outcomes of action buttons so the panel can show success/error
-- without requiring the user to dig through log.txt.
local _last_test_outcome = "(not yet pressed)"

-- Live ASCII-grid preview state. Lets us eyeball exactly what the renderer
-- produces for the current puzzle ON SCREEN (in the panel), so glyph/legend
-- changes can be verified without running the AI peer and reading the force
-- context. `live` re-renders every frame the node is expanded; legend/adjacency
-- mirror render.render's opts so we can check those blocks too.
local _preview = {
    live           = true,
    with_legend    = true,
    with_adjacency = true,
    text           = nil,
    err            = nil,
}

local function send_test_force()
    log.info("hacking_debug: send_test_force() ENTER")

    local fake_state = {
        width  = 4,
        height = 4,
        cursor = { x = 1, y = 2 },
        goal   = { x = 3, y = 0 },
        cells  = {
            { { type = "Open" }, { type = "Open" }, { type = "Open" }, { type = "Goal" } },
            { { type = "Open" }, { type = "Obstacle" }, { type = "Open" }, { type = "Open" } },
            { { type = "Open" }, { type = "Start" }, { type = "Open" }, { type = "Open" } },
            { { type = "Obstacle" }, { type = "Open" }, { type = "Open" }, { type = "Open" } },
        },
        trail = { { x = 1, y = 2 } },
    }

    local ok_render, rendered = pcall(render.render, fake_state)
    if not ok_render then
        _last_test_outcome = "RENDER FAILED: " .. tostring(rendered)
        log.error("hacking_debug: render failed: " .. tostring(rendered))
        return
    end
    log.info("hacking_debug: render OK, " .. tostring(#rendered) .. " chars")

    local ok_ctx = mailbox.send({
        command = "context",
        game = GAME,
        data = {
            message = "DEBUG TEST GRID (synthetic):\n" .. rendered,
            silent = true,
            lane = "transient",
        },
    })
    log.info("hacking_debug: context send returned " .. tostring(ok_ctx))

    local ok_force = mailbox.send({
        command = "actions/force",
        game = GAME,
        data = {
            state = "DEBUG TEST GRID (synthetic):\n" .. rendered,
            query = "DEBUG TEST: plan a path through the synthetic grid above. "
                 .. "This is a manual test from the hacking debug panel.",
            ephemeral_context = true,
            action_names = { "pragmata_hack_plan" },
        },
    })
    log.info("hacking_debug: force send returned " .. tostring(ok_force))

    if ok_ctx and ok_force then
        _last_test_outcome = "SENT (context + force, " .. tostring(#rendered) .. " chars)"
    else
        _last_test_outcome = "PARTIAL/FAILED (ctx=" .. tostring(ok_ctx)
                          .. " force=" .. tostring(ok_force) .. ")"
    end
end


re.on_draw_ui(function()
    if not imgui.tree_node("Pragmata Hacking Debug") then return end

    local s = snake.debug_status()
    local r = s.init_report

    if imgui.tree_node("SDK init report") then
        imgui.text("PuzzleSnake type def:        " .. bool_text(r.snake_td))
        imgui.text("GridAccessor type def:       " .. bool_text(r.accessor_td))
        imgui.text("Grid (cell) type def:        " .. bool_text(r.cell_td))
        imgui.text("Unit type def:               " .. bool_text(r.unit_td))
        imgui.text("PuzzleSnakeGridType type def:" .. bool_text(r.grid_type_td))
        imgui.separator()
        imgui.text("get_GRID_ACTUAL_SIZE_X:      " .. bool_text(r.m_get_size_x))
        imgui.text("get_GRID_ACTUAL_SIZE_Y:      " .. bool_text(r.m_get_size_y))
        imgui.text("getStartPos:                 " .. bool_text(r.m_get_start))
        imgui.text("PuzzleSnakeGridType.getName: " .. bool_text(r.m_get_name))
        imgui.text("Unit.move(via.Int2):         " .. bool_text(r.m_unit_move))
        imgui.text("Unit.canReachStraight:       " .. bool_text(r.m_unit_can_reach))
        imgui.text("Unit.get_isMove:             " .. bool_text(r.m_unit_get_is_move))
        imgui.separator()
        imgui.text(".ctor hook:  " .. tostring(r.ctor_hook))
        imgui.text("update hook: " .. tostring(r.update_hook))
        imgui.tree_pop()
    end

    imgui.separator()

    imgui.text("HackingManager singleton: " .. bool_text(s.hacking_mgr_present))
    imgui.text("IsTargetedEnemy: " .. bool_text(s.is_targeted_enemy))
    imgui.text("LastHackingTarget set: " .. bool_text(s.has_target_unit))
    imgui.text("Known PuzzleSnake instances: " .. tostring(s.known_instance_count or 0))
    if s.instance_cached then
        imgui.text("Active instance (matched to target): YES")
    else
        imgui.text("Active instance (matched to target): no")
    end
    -- Instances bound to the aimed enemy, by lifecycle. >1 total with an
    -- "ended" present = the "invisible enemy" bug: a leftover completed
    -- PuzzleSnake shares the target. The matcher now skips ended ones in
    -- favor of a playable instance; picked = what it actually chose.
    imgui.text(string.format(
        "Instances matching target: %d (playable=%d idle=%d ended=%d), picked=%s",
        s.match_total or 0, s.match_playable or 0, s.match_idle or 0,
        s.match_ended or 0, tostring(s.picked_lifecycle)))
    imgui.text("GUI handle present: " .. bool_text(s.gui_handle_present))
    imgui.text("is_active(): " .. bool_text(s.active))

    -- _State reading. Per the il2cpp dump, PuzzleState is Play|Stop; the
    -- format strongly suggests Play=1, Stop=0. Confirm visually by watching
    -- this value flip as a puzzle starts/ends.
    local state_val = snake.read_state_value()
    imgui.text("_State (PuzzleBase): " .. tostring(state_val)
            .. "  (best inference: Play=1, Stop=0)")
    imgui.text("is_interactive(): " .. bool_text(snake.is_interactive()))

    if s.grid_dims then
        imgui.text(string.format("Grid: %dx%d", s.grid_dims.width, s.grid_dims.height))
    else
        imgui.text("Grid: <unreadable>")
    end
    if s.cursor then
        imgui.text(string.format("Cursor: (%d, %d)", s.cursor.x, s.cursor.y))
    else
        imgui.text("Cursor: <unreadable>")
    end

    imgui.separator()
    -- Equipped hacking mode (PuzzleSnakeMode). Read-only probe: equip each mode
    -- at the Tram Terminal and confirm 'mapped' matches it. This feeds the
    -- force-context mode line. engine='<name>' with mapped=Unknown = a hash we
    -- haven't mapped (report it).
    local mode = snake.read_hacking_mode()
    if mode == nil then
        imgui.text("Hacking mode: <binding not ready>")
    elseif not mode.ok then
        imgui.text("Hacking mode: read FAILED (" .. tostring(mode.err) .. ")")
    else
        imgui.text(string.format("Hacking mode: mapped=%s  mode=%s  engine='%s'  hash=%s",
            tostring(mode.key), tostring(mode.style),
            tostring(mode.engine_name), tostring(mode.hash)))
        if mode.desc then imgui.text("  -> " .. mode.desc) end
    end

    -- Equipped active SKILL (the '*' node). Read-only probe: equip each skill at
    -- the Tram Terminal and confirm 'skill' matches it (this also confirms the
    -- inferred relabels Stun=Freeze / DefenseDown=Expose / Shock=Decode). The
    -- equipped_id is the raw ObjectID fallback if auto-matching fails.
    local skill = snake.read_active_skill()
    if skill == nil then
        imgui.text("Active skill: <binding not ready>")
    elseif not skill.ok then
        imgui.text("Active skill: read FAILED (" .. tostring(skill.err) .. ")")
    elseif skill.none then
        imgui.text(string.format("Active skill: none matched (slots=%s)", tostring(skill.count)))
    else
        imgui.text(string.format("Active skill: skill=%s  enum=%s  engine='%s'  id=%s  distinct=%s slots=%s%s",
            tostring(skill.display), tostring(skill.key),
            tostring(skill.engine_name), tostring(skill.equipped_id),
            tostring(skill.distinct), tostring(skill.count),
            skill.multiple and "  (MULTIPLE - Code Generator)" or ""))
        if skill.desc then imgui.text("  -> " .. skill.desc) end
    end

    imgui.separator()
    imgui.text("Lifecycle triggers (one-frame edges):")
    if s.triggers then
        for _, name in ipairs({
            "_StartTrg", "_SuccessTrigger", "_FailedTrigger",
            "_ResetTrg", "_GridResetRequest",
            "_GridChangeStartTrg", "_GridChangeEndTrg", "_AttackTrg",
        }) do
            imgui.text("  " .. name .. ": " .. bool_text(s.triggers[name]))
        end
    end

    imgui.separator()
    imgui.text("Observer edge hit counts (cumulative since boot):")
    local hits = observer.debug_hit_counts()
    imgui.text(string.format("  _StartTrg:           %d", hits.start_trg))
    imgui.text(string.format("  _GridChangeEndTrg:   %d", hits.grid_change_end))
    imgui.text(string.format("  _ResetTrg:           %d", hits.reset))
    imgui.text(string.format("  _SuccessTrigger:     %d", hits.success))
    imgui.text(string.format("  _FailedTrigger:      %d", hits.failed))
    imgui.text(string.format("  cancelled (GUI dropped mid-flight): %d", hits.cancelled or 0))

    imgui.separator()

    if imgui.button("Force discover") then
        local result = snake.debug_discover()
        log.info("hacking_debug: discover returned instance_cached="
              .. tostring(result.instance_cached))
    end
    imgui.same_line()
    if imgui.button("Send synthetic test grid") then
        send_test_force()
    end
    imgui.text("Last test outcome: " .. _last_test_outcome)

    if imgui.button("Dump cells to log") then
        local result = snake.debug_dump_cells()
        local cells = result.cells or {}
        local lines = {}
        local function emit(s) table.insert(lines, s) end

        emit("=== hacking_dump @ " .. tostring(os.time()) .. " ===")
        emit("shape: " .. tostring(result.shape))
        emit("cell count: " .. tostring(#cells))

        -- Frequency-by-position map so we can quickly see how many cells
        -- claim each position.
        local pos_counts = {}
        for _, c in ipairs(cells) do
            local k = string.format("(%d,%d)", c.x, c.y)
            pos_counts[k] = (pos_counts[k] or 0) + 1
        end
        emit("position frequency (count, position):")
        local freq_keys = {}
        for k, _ in pairs(pos_counts) do table.insert(freq_keys, k) end
        table.sort(freq_keys, function(a, b)
            return (pos_counts[a] or 0) > (pos_counts[b] or 0)
        end)
        for _, k in ipairs(freq_keys) do
            emit(string.format("  %4d  %s", pos_counts[k], k))
        end

        emit("")
        emit("full cell list (excluding undecorated type=None padding):")
        emit("  (gold=_IsGoldenPath [auto-hack route marker; NOT the blue nodes - those are type=Open],")
        emit("   parry=IsParryHacking, skill=ActiveSkill type, skillN=ActiveSkillCount,")
        emit("   deadfil=_DeadFilamentType [boss-content variant; None on standard grids],")
        emit("   hide=_IsHide [node not yet revealed], obs=_ObstacleReasons bitmask [nonzero = blocked;")
        emit("   1=ObstacleGrid aka the red error nodes, 2=DeadFilament, 4=Ch16092, 8=Ch14100, 16=AllPassed],")
        emit("   stun=_StunReasons bitmask, skipR/skipC=IsSkipRow/IsSkipCol [row/col removed by sticky bomb])")
        for i, c in ipairs(cells) do
            -- A cell can be type=None yet still carry a decoration the AI
            -- must know about (error nodes live exactly there). Filtering on
            -- type alone is what hid dead filaments from earlier dumps.
            local decorated = c.dead_filament or c.is_erase or c.is_parry_hacking
                or c.is_golden_path or c.active_skill_type ~= nil
                or c.is_hide or c.is_skip_row or c.is_skip_col
                or (c.obstacle_reasons or 0) ~= 0 or (c.stun_reasons or 0) ~= 0
            if c.type ~= "None" or decorated then
                emit(string.format(
                    "  [%3d] pos=(%d,%d) type=%-11s gold=%-5s parry=%-5s skill=%-12s skillN=%-3s deadfil=%-8s in=%-12s out=%-12s erase=%-5s hide=%-5s obs=%-3s stun=%-3s skipR=%-5s skipC=%-5s trail=%s",
                    i, c.x, c.y,
                    tostring(c.type),
                    tostring(c.is_golden_path),
                    tostring(c.is_parry_hacking),
                    tostring(c.active_skill_type),
                    tostring(c.active_skill_count),
                    tostring(c.dead_filament_type),
                    tostring(c.in_way_type),
                    tostring(c.out_way_type),
                    tostring(c.is_erase),
                    tostring(c.is_hide),
                    tostring(c.obstacle_reasons),
                    tostring(c.stun_reasons),
                    tostring(c.is_skip_row),
                    tostring(c.is_skip_col),
                    tostring(c.in_trail)
                ))
            end
        end
        emit("")
        emit("")

        local body = table.concat(lines, "\n")
        append_dump(body)
        log.info("hacking_debug: dumped " .. tostring(#cells)
              .. " cells to " .. DUMP_PATH)
        _last_test_outcome = string.format(
            "Dumped %d cells to %s, shape=%s",
            #cells, DUMP_PATH, tostring(result.shape)
        )
    end
    imgui.same_line()
    if imgui.button("Render current grid (to log)") then
        local state = snake.get_state()
        if state == nil then
            _last_test_outcome = "get_state returned nil"
        else
            local ok, rendered = pcall(render.render, state, { with_legend = false })
            if ok then
                log.info("hacking_debug: rendered grid preview:\n" .. rendered)
                _last_test_outcome = "Rendered " .. tostring(#rendered) .. " chars (see log)"
            else
                _last_test_outcome = "RENDER FAILED: " .. tostring(rendered)
            end
        end
    end

    imgui.separator()
    -- On-screen ASCII grid preview. Exactly what render.render() produces for
    -- the live puzzle, drawn here in the panel (not the log) so glyph/legend/
    -- mode changes can be verified at a glance. Open this node next to the game.
    if imgui.tree_node("Live ASCII grid preview") then
        local _
        _, _preview.live = imgui.checkbox("Live (re-render every frame)", _preview.live)
        imgui.same_line()
        _, _preview.with_legend = imgui.checkbox("legend", _preview.with_legend)
        imgui.same_line()
        _, _preview.with_adjacency = imgui.checkbox("adjacency", _preview.with_adjacency)

        local do_render = _preview.live
        if imgui.button("Render once") then do_render = true end

        if do_render then
            local state = snake.get_state()
            if state == nil then
                _preview.text = nil
                _preview.err = "get_state() returned nil "
                    .. "(no active/interactive puzzle right now)"
            else
                local ok, rendered = pcall(render.render, state, {
                    with_legend    = _preview.with_legend,
                    with_adjacency = _preview.with_adjacency,
                })
                if ok then
                    _preview.text = rendered
                    _preview.err  = nil
                else
                    _preview.err  = "render failed: " .. tostring(rendered)
                end
            end
        end

        if _preview.err then
            imgui.text(_preview.err)
        end
        if _preview.text then
            imgui.separator()
            -- Draw line-by-line so every newline breaks regardless of build
            -- (imgui.text on the whole block is unreliable). The panel font is
            -- proportional, so columns won't perfectly align — fine for
            -- verifying glyphs; cross-check exact spacing in the log dump if
            -- needed.
            for line in (_preview.text .. "\n"):gmatch("([^\n]*)\n") do
                imgui.text(line)
            end
        end
        imgui.tree_pop()
    end

    imgui.separator()
    imgui.text("Move dispatch:")
    local strategy = snake.int2_strategy_in_use()
    if strategy then
        imgui.text("Int2 strategy in use: " .. strategy)
    else
        imgui.text("Int2 strategy in use: <not yet probed>")
    end
    imgui.text("Unit is mid-transition: " .. tostring(snake.is_unit_moving()))

    local function try_move(dir)
        local ok, msg = snake.move(dir)
        log.info("hacking_debug: move(" .. dir .. ") ok=" .. tostring(ok)
              .. " msg=" .. tostring(msg))
        if ok then
            _last_test_outcome = "move " .. dir .. ": " .. tostring(msg)
        else
            _last_test_outcome = "move " .. dir .. " FAILED: " .. tostring(msg)
        end
    end
    local function try_can_reach(dir)
        local ok, msg = snake.can_move(dir)
        log.info("hacking_debug: can_move(" .. dir .. ") -> " .. tostring(ok)
              .. " (" .. tostring(msg) .. ")")
        _last_test_outcome = "can_move " .. dir .. ": " .. tostring(ok)
                          .. " (" .. tostring(msg) .. ")"
    end

    imgui.text("Can-reach (read-only, safe):")
    if imgui.button("Can-reach up") then try_can_reach("up") end
    imgui.same_line()
    if imgui.button("Can-reach down") then try_can_reach("down") end
    imgui.same_line()
    if imgui.button("Can-reach left") then try_can_reach("left") end
    imgui.same_line()
    if imgui.button("Can-reach right") then try_can_reach("right") end

    imgui.text("Move (Unit.move direct — bypasses cell side-effects):")
    if imgui.button("Move up") then try_move("up") end
    imgui.same_line()
    if imgui.button("Move down") then try_move("down") end
    imgui.same_line()
    if imgui.button("Move left") then try_move("left") end
    imgui.same_line()
    if imgui.button("Move right") then try_move("right") end

    -- Experimental: write _NextMovePosition and let the engine's input
    -- pipeline (updateInput → updatePuzzleMovement → onEnterGrid) process
    -- the move. If this works, cell side-effects (walls, skill cells,
    -- goal auto-complete) should engage naturally and the tick_plan path
    -- can be migrated to use it.
    local nmp = snake.read_next_move_position()
    if nmp then
        imgui.text(string.format("_NextMovePosition (current): (%d, %d)", nmp.x, nmp.y))
    else
        imgui.text("_NextMovePosition (current): <unreadable>")
    end

    local function try_nmp_move(dir)
        local ok, msg = snake.move_via_next_position(dir)
        log.info("hacking_debug: move_via_next_position(" .. dir .. ") ok="
              .. tostring(ok) .. " msg=" .. tostring(msg))
        _last_test_outcome = (ok and "nmp " or "nmp " .. dir .. " FAILED: ")
                          .. dir .. ": " .. tostring(msg)
    end

    imgui.text("Move (_NextMovePosition write — experimental, engine handles cell logic):")
    if imgui.button("NMP up") then try_nmp_move("up") end
    imgui.same_line()
    if imgui.button("NMP down") then try_nmp_move("down") end
    imgui.same_line()
    if imgui.button("NMP left") then try_nmp_move("left") end
    imgui.same_line()
    if imgui.button("NMP right") then try_nmp_move("right") end

    imgui.separator()
    if imgui.tree_node("Plan dispatch (Unit.move sequence)") then
        local ps = snake.plan_status()
        imgui.text(string.format("queue=%d  cooldown=%d  active=%s  unit_moving=%s",
            ps.queue_size, ps.cooldown,
            tostring(ps.active), tostring(ps.unit_moving)))
        if ps.last_msg then
            imgui.text("last: " .. tostring(ps.last_msg))
        end
        imgui.text("Test: queue a path. Hack must be open.")
        if imgui.button("Queue: D, R, R, D") then
            snake.queue_plan({ "down", "right", "right", "down" })
        end
        imgui.same_line()
        if imgui.button("Queue: D, D, R, R, D") then
            snake.queue_plan({ "down", "down", "right", "right", "down" })
        end
        if imgui.button("Clear plan queue") then snake.clear_plan() end

        imgui.separator()
        imgui.text("Manual completion (cursor must be on Goal):")
        if imgui.button("set _RequestForceSuccess=true") then
            local ok, msg = snake.try_set_request_force_success()
            log.info("set_request_force_success: " .. tostring(ok) .. " " .. tostring(msg))
            _last_test_outcome = "set_request_force_success: " .. tostring(ok) .. " (" .. tostring(msg) .. ")"
        end
        imgui.tree_pop()
    end

    imgui.separator()
    if imgui.tree_node("Discovery event log") then
        local result = snake.debug_discover()  -- returns the running log
        if result.log and #result.log > 0 then
            for _, line in ipairs(result.log) do
                imgui.text(line)
            end
        else
            imgui.text("(no events yet)")
        end
        imgui.tree_pop()
    end

    imgui.tree_pop()
end)


return M
