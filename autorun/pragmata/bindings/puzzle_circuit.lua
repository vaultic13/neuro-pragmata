-- Binding for the rotate-to-connect hacking puzzles.
--
-- Engine types, one family:
--   app.PuzzleCircuit            -- the plain version
--   app.PuzzleCircuitWithTimer   -- same, on a countdown
--   app.AdvancedPuzzleCircuit    -- same, larger layouts
--   plus level-specific reskins that add nothing (PuzzleCircuitCh14310,
--   ch17020MissilePuzzleCircuit, ch18000MissilePuzzleCircuit)
--
-- What the player sees is one to four CONNECTORS placed around a centre, each
-- one circuit that has to be closed. A circuit is a line that starts at a
-- source on the edge of the board and runs through fixed cells and one
-- connector into the centre; the connector closes it when it JOINS its line to
-- the centre, both ends lined up. Pointing at the centre is not enough -- see
-- lit_cells() for the 2026-09-11 trace that settled it, including a turn made
-- by hand that left an arm on the centre and put the whole line out.
--
-- This file believed the one-arm version for a round, on the strength of how
-- the diamonds look on screen; the engine's own flags disagree in 79 of 175
-- recorded board states.
--
-- Connectors are therefore addressed by the side they sit on, which is also the
-- button that turns them (that pairing is what the engine's own button2Index
-- encodes). Unlike an array index it cannot silently mean something else if the
-- engine reorders its array -- but it is only safe while the side we name is
-- the side whose button really turns that connector.
--
-- That pairing is now MEASURED rather than worked out from the board. The
-- 2026-09-07 capture is what working it out cost: across four hacks the
-- connector the peer called "right" never moved once in sixteen presses while a
-- connector nobody had named turned instead, and the only two hacks that were
-- solved were solved because every piece was a straight needing exactly one
-- press -- the one shape where a shuffled set of names still gives the right
-- answer. See the "Which button turns which cell" section below.

local log = require("pragmata.util.log")
local registry = require("pragmata.bindings.puzzle_registry")
local input = require("pragmata.bindings.puzzle_input")
local plan_lib = require("pragmata.bindings.puzzle_plan")
local render = require("pragmata.util.puzzle_render")
local config = require("pragmata.mod_config")

local M = {}

M.kind = "circuit"
M.action_name = "pragmata_hack_rotate"
M.force_query = "A circuit hack is live. Call pragmata_hack_rotate to give each "
             .. "connector the presses its line asks for."

local P = plan_lib.new({ kind = "circuit" })

local store = registry.make_store(function(rec)
    P.resolve(rec, false, "the hack ended before the rotations finished")
end)


-- A user-tunable setting, or the fallback when it is absent or nonsense. Up
-- here because the press section far below and force_blocked far above it both
-- read settings, and a local is only visible after the line that declares it.
local function tunable(name, fallback, floor_at)
    local v = config[name]
    if type(v) ~= "number" or v < (floor_at or 0) then return fallback end
    return v
end


-- --------------------------------------------------------------------
-- Reflection helpers
-- --------------------------------------------------------------------
local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function arr_size(a)
    if a == nil then return 0 end
    local n = safe(function() return a:get_size() end)
    if type(n) == "number" then return n end
    n = safe(function() return a.Length end)
    if type(n) == "number" then return n end
    return 0
end

local function arr_get(a, i)
    if a == nil then return nil end
    local v = safe(function() return a[i] end)
    if v ~= nil then return v end
    return safe(function() return a:get_element(i) end)
end


-- PathType is a set of openings, so it is decoded as a bitmask against the
-- game's own constants. A value that matches no bit is reported as a plain
-- member name instead, which covers the case where it turns out to be a plain
-- enum on some build.
local _path_bits = nil
local function decode_openings(value)
    local v = registry.to_int(value)
    if v == nil then return {} end
    if _path_bits == nil then
        _path_bits = {}
        for name, bit in pairs(registry.enum_values("app.PuzzleCircuit.PathType")) do
            if name ~= "None" then _path_bits[#_path_bits + 1] = { name = name:lower(), bit = bit } end
        end
        table.sort(_path_bits, function(a, b) return a.bit < b.bit end)
    end
    local out = {}
    for _, entry in ipairs(_path_bits) do
        if registry.has_bit(v, entry.bit) or v == entry.bit then
            out[#out + 1] = entry.name
        end
    end
    return out
end

local _source_names = nil
local function source_name(value)
    local v = registry.to_int(value)
    if v == nil then return nil end
    if _source_names == nil then
        _source_names = {}
        for name, sv in pairs(registry.enum_values("app.PuzzleCircuit.SourceType")) do
            _source_names[sv] = name:lower()
        end
    end
    return _source_names[v]
end


-- --------------------------------------------------------------------
-- Which button turns which cell
-- --------------------------------------------------------------------
-- app.PuzzleCircuit.button2Index(ButtonIndex, out int, out int) is the engine's
-- own answer to exactly this question. Whether REFramework will marshal two
-- `out int`s back out of a call is not something a type dump can settle, so it
-- is attempted once, behind a pcall, and the press probe below covers the case
-- where it cannot -- resolving the method proves nothing about calling it.
local BUTTON_TYPE = "app.PuzzleCircuit"
local BUTTON_ENUM = "app.PuzzleCircuit.ButtonIndex"

local _b2i = { tried = false, method = nil, values = nil, note = nil }

local function button_method()
    if _b2i.tried then return _b2i.method end
    _b2i.tried = true

    local td = safe(function() return sdk.find_type_definition(BUTTON_TYPE) end)
    if td == nil then
        _b2i.note = BUTTON_TYPE .. " did not resolve"
        return nil
    end
    local m = safe(function()
        return td:get_method("button2Index(app.PuzzleCircuit.ButtonIndex, System.Int32, System.Int32)")
    end)
    if m == nil then m = safe(function() return td:get_method("button2Index") end) end
    if m == nil then
        _b2i.note = "button2Index did not resolve"
        return nil
    end

    -- Names, not numbers: the enum is Up=0, Left=1, Right=2, Down=3 on this
    -- build, which is not the clockwise cycle and not an order worth assuming.
    local values = {}
    for name, value in pairs(registry.enum_values(BUTTON_ENUM)) do
        local dir = name:lower()
        if dir == "up" or dir == "down" or dir == "left" or dir == "right" then
            values[dir] = value
        end
    end
    if next(values) == nil then
        _b2i.note = BUTTON_ENUM .. " had no members"
        return nil
    end
    _b2i.values = values
    _b2i.method = m
    return m
end

local function key_of(x, y) return y * 1000 + x end
local function cell_key(x, y) return tostring(x) .. "," .. tostring(y) end

-- Ask the engine directly. Returns { up = "x,y", ... } or nil, and never throws:
-- an unmarshalled out-parameter comes back as nil or as something that is not a
-- pair of numbers, and both mean "use the probe instead".
local function engine_button_cells(inst)
    if _b2i.distrusted then return nil end
    local m = button_method()
    if m == nil or inst == nil then return nil end

    local out = {}
    for dir, value in pairs(_b2i.values) do
        local ok, a, b, c = pcall(function() return m:call(inst, value) end)
        if not ok then
            _b2i.note = "button2Index could not be called: " .. tostring(a)
            return nil
        end
        -- Some builds hand the outs back as extra return values, some hand back
        -- nothing at all. Only a genuine pair of coordinates counts.
        local x, y = b, c
        if type(x) ~= "number" or type(y) ~= "number" then x, y = nil, nil end
        if x == nil then
            _b2i.note = "button2Index returned no coordinates"
            return nil
        end
        out[dir] = cell_key(math.floor(x), math.floor(y))
    end
    if next(out) == nil then return nil end
    _b2i.note = "answered by the engine"
    return out
end


-- --------------------------------------------------------------------
-- Direction vocabulary
-- --------------------------------------------------------------------
-- PathType's members are the engine's own screen names (Up=1, Right=2, Down=4,
-- Left=8 -- a bitmask). What is NOT known is which grid delta each name means:
-- _Question is a jagged Grid[][] and nothing promises its rows run the way the
-- screen does.
--
-- So the mapping is scored rather than assumed, from two things the engine
-- already tells us every frame: openings must be MUTUAL between neighbours, and
-- IsConnectingToGoal says which cells really do reach the centre. The candidate
-- that reproduces the engine's own flags wins.
--
-- What this decides, and what it no longer decides. It fixes the FRAME -- which
-- grid delta each opening name means -- and that is all neighbour lookups and
-- the demanded-openings calculation need, because both ask their questions
-- through the same map and so survive any of the eight candidates intact.
--
-- It does NOT name connectors any more. It used to, and the 2026-09-07 capture
-- is what that cost: the scoring reported itself CONFIDENT on all eighteen
-- layouts of the session and was wrong on half of them, because a board can be
-- symmetric enough that the engine's own flags cannot separate two candidates
-- and this is only as good as the evidence on the board. Names come from the
-- measured button mapping above; a name is a promise about which button turns
-- something, and that is worth measuring rather than deducing.

local CW = { "up", "right", "down", "left" }        -- the fixed clockwise cycle
local OPPOSITE = { up = "down", down = "up", left = "right", right = "left" }
-- The same cycle as grid deltas, if the board is laid out the way it is drawn.
local SCREEN = { { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }

-- The eight ways four names can sit on four deltas while keeping them in a
-- cycle: four rotations, each of them optionally mirrored. Transposition -- the
-- likeliest way to read a jagged array wrong -- is the diagonal mirror, so it is
-- in here. "r0" is the identity, and is first so it wins every tie.
local _candidates = nil
local function candidates()
    if _candidates ~= nil then return _candidates end
    _candidates = {}
    for _, mirrored in ipairs({ false, true }) do
        for turn = 0, 3 do
            local map = {}
            for i, name in ipairs(CW) do
                local d = SCREEN[((i - 1 + turn) % 4) + 1]
                map[name] = mirrored and { -d[1], d[2] } or { d[1], d[2] }
            end
            _candidates[#_candidates + 1] = {
                id = (mirrored and "m" or "r") .. tostring(turn),
                map = map,
            }
        end
    end
    return _candidates
end

-- Openings as a set, so "does this cell open onto that side" is one lookup.
local function opening_set(list)
    local s = {}
    for _, name in ipairs(list or {}) do s[name] = true end
    return s
end

-- Which cells the engine will call connected, for a given reading of the grid.
--
-- THE ENGINE'S RULE, measured rather than assumed. Replaying all 175 board
-- states of the 2026-09-11 trace against the game's own IsConnectingToGoal:
--
--   flood outward from the centre (the old model)        wrong in 79 states
--   a line runs from an edge source into the centre      wrong in 13, all of
--                                                        them where the trace
--                                                        itself missed a re-deal
--
-- Each circuit starts at an edge SOURCE (_SourceType Open) and runs through
-- fixed cells and one connector into the centre. A cell is connected only if it
-- lies on a line that gets there. The centre does not pass connection outward:
-- it reads NOT connected until some line reaches it, and a connector touching
-- an already-lit centre with its other arm loose stays dark. That last one is
-- the decisive observation -- f002782, a turn made by hand: connector 2,1 went
-- from up+right to right+down, its right arm still on the centre, and its whole
-- line went out. So a connector closes its circuit only when it joins its own
-- line to the centre, both ends lined up, and "point it at the centre" is only
-- the same thing by accident, on a straight piece.
--
-- A goal is therefore a SINK: reached, never walked out of. `ends.sources` and
-- `ends.goals` are lists of {x, y}; `override` swaps in other openings for the
-- connectors being tried. A board with no source cells at all (a variant this
-- has not seen) falls back to flooding from the goals, the rule it replaces.
local function lit_cells(at, ends, map, override)
    override = override or {}
    local function opens(cell)
        local o = override[key_of(cell.x, cell.y)]
        if o ~= nil then return o end
        return cell.open_set
    end

    local lit = {}
    local sources = ends and ends.sources or {}

    if #sources == 0 then
        local queue = {}
        for _, g in ipairs(ends and ends.goals or {}) do
            local k = key_of(g.x, g.y)
            if at[k] ~= nil and not lit[k] then
                lit[k] = true
                queue[#queue + 1] = at[k]
            end
        end
        while #queue > 0 do
            local cell = table.remove(queue)
            for name in pairs(opens(cell)) do
                local d = map[name]
                local k = key_of(cell.x + d[1], cell.y + d[2])
                local nb = at[k]
                if nb ~= nil and not lit[k] and opens(nb)[OPPOSITE[name]] then
                    lit[k] = true
                    queue[#queue + 1] = nb
                end
            end
        end
        return lit
    end

    for _, src in ipairs(sources) do
        local start = key_of(src.x, src.y)
        if at[start] ~= nil then
            local seen = { [start] = true }
            local walked = { start }
            local queue = { at[start] }
            local reached = false
            while #queue > 0 do
                local cell = table.remove(queue)
                if cell.source == "goal" then
                    reached = true
                else
                    for name in pairs(opens(cell)) do
                        local d = map[name]
                        local k = key_of(cell.x + d[1], cell.y + d[2])
                        local nb = at[k]
                        if nb ~= nil and not seen[k] and opens(nb)[OPPOSITE[name]] then
                            seen[k] = true
                            walked[#walked + 1] = k
                            queue[#queue + 1] = nb
                        end
                    end
                end
            end
            if reached then
                for _, k in ipairs(walked) do lit[k] = true end
            end
        end
    end
    return lit
end


-- How many cells can be walked from the edge sources, following mutual
-- openings, before each walk stops. Nothing needs to be lit for this to mean
-- something, which is the point.
--
-- On an empty board -- nothing connected yet, which is every board at the start
-- of every round -- the engine's flags cannot tell the eight frames apart: under
-- the real rule, no line is complete under ANY of them, so all eight agree with
-- the game perfectly. The old tie-break, fewest contradictions, then picked m0
-- on the first board of the 2026-09-11 trace and the right frame on only 5 of
-- its 12 boards. But the fixed line cells are laid out for one frame: read
-- through it, each source's line can be followed cell by cell up to its
-- connector; read through any other, the walk dies at once. Walk length picks
-- the right frame, alone, on all 12.
local function source_reach(at, ends, map)
    local total = 0
    for _, src in ipairs(ends and ends.sources or {}) do
        local start = key_of(src.x, src.y)
        if at[start] ~= nil then
            local seen = { [start] = true }
            local queue = { at[start] }
            total = total + 1
            while #queue > 0 do
                local cell = table.remove(queue)
                if cell.source ~= "goal" then
                    for name in pairs(cell.open_set) do
                        local d = map[name]
                        local k = key_of(cell.x + d[1], cell.y + d[2])
                        local nb = at[k]
                        if nb ~= nil and not seen[k] and nb.open_set[OPPOSITE[name]] then
                            seen[k] = true
                            total = total + 1
                            queue[#queue + 1] = nb
                        end
                    end
                end
            end
        end
    end
    return total
end


-- How well one candidate explains the board. Fewer contradictions is better;
-- reproducing the engine's connection flags exactly is decisive.
local function score_candidate(cells, at, ends, map)
    local contradictions = 0
    for _, cell in ipairs(cells) do
        for name in pairs(cell.open_set) do
            local d = map[name]
            local nb = at[key_of(cell.x + d[1], cell.y + d[2])]
            -- A dangling opening at the border is normal -- that is how a line
            -- enters the board -- so only a neighbour that fails to open back
            -- counts against the candidate.
            if nb ~= nil and not nb.open_set[OPPOSITE[name]] then
                contradictions = contradictions + 1
            end
        end
    end

    local lit = lit_cells(at, ends, map)

    -- Every cell is scored, the goal included: under the real rule the centre
    -- reads connected exactly when a line reaches it, which is evidence like
    -- any other.
    --
    -- `evidence` is what stops a perfect score meaning nothing. On a board where
    -- the engine has flagged NOTHING connected, a model that predicts nothing
    -- connected agrees with it on every cell without having been tested once.
    -- Count the non-goal cells the engine itself says are connected, and let
    -- the caller decide how much the score is worth.
    local agree, disagree, evidence = 0, 0, 0
    for _, cell in ipairs(cells) do
        local k = key_of(cell.x, cell.y)
        if cell.connected == true and cell.source ~= "goal" then evidence = evidence + 1 end
        if (lit[k] == true) == (cell.connected == true) then
            agree = agree + 1
        else
            disagree = disagree + 1
        end
    end

    return { contradictions = contradictions, agree = agree, disagree = disagree,
             evidence = evidence, reach = source_reach(at, ends, map) }
end

local function better(a, b)
    -- Matching the engine's flags outranks everything. Among candidates that
    -- match equally -- on an empty board, all eight -- the one whose lines can
    -- be walked furthest from their sources wins (see source_reach), and only
    -- then the contradiction count. `a` is only better than `b` if it wins, so
    -- an earlier candidate -- the identity, first in the list -- keeps a draw.
    if (a.disagree == 0) ~= (b.disagree == 0) then return a.disagree == 0 end
    if a.disagree ~= b.disagree then return a.disagree < b.disagree end
    if (a.reach or 0) ~= (b.reach or 0) then return (a.reach or 0) > (b.reach or 0) end
    return a.contradictions < b.contradictions
end

-- The frame the engine has CONFIRMED -- scored against a board with something
-- lit on it, and agreeing. Module-level on purpose: which grid delta each name
-- means is a property of the puzzle's code, not of one board, and the
-- 2026-09-11 trace has it as m1 on every board that had evidence to offer.
--
-- Without this every new round was calibrated from scratch on a board with
-- nothing lit, where four candidates tie on a perfect score and the
-- contradiction count picks between them -- r1, r3 and m2 each won a round that
-- way, and on the last board m2 made every target the mod printed wrong.
local _known_frame = nil

-- Which button turns which connector, remembered per connector arrangement
-- (button_layout_key) once a probe has named EVERY connector on it. Like the
-- frame, it is a fact about where the connectors sit rather than about one
-- board: the 2026-09-12 session measured the same mapping on two different
-- puzzle records. Reusing it skips four presses on every return, and with them
-- the chance of a probe losing presses -- which is how that session's third
-- stage ended up with one named connector out of three for the rest of the
-- session. Dropped when a plan's press turns a connector other than the one it
-- names.
local _known_buttons = {}

-- Pick the mapping for one board. `cells` must already carry `open_set`.
local function calibrate(cells, at, ends)
    local best, best_score, second, matches = nil, nil, nil, 0
    for _, candidate in ipairs(candidates()) do
        local score = score_candidate(cells, at, ends, candidate.map)
        if score.disagree == 0 then matches = matches + 1 end
        if best_score == nil or better(score, best_score) then
            second = best_score
            best, best_score = candidate, score
        elseif second == nil or better(score, second) then
            second = score
        end
    end
    return {
        id         = best.id,
        map        = best.map,
        -- Confident means the winner beat every other candidate outright. A
        -- draw is the interesting case: it means the board is symmetric enough
        -- that neither the engine's connection flags nor the mutual-opening
        -- check can tell two mappings apart, and the side names are then a
        -- coin toss worth saying out loud.
        confident  = second ~= nil and better(best_score, second),
        matches    = matches,
        disagree   = best_score.disagree,
        -- How many connected cells the engine had flagged when this was
        -- decided. Zero means the frame won a race nobody ran.
        evidence   = best_score.evidence,
        contradictions = best_score.contradictions,
        runner_up  = second and second.contradictions or -1,
    }
end

-- Which side of the centre a cell sits on, in the calibrated vocabulary. The
-- dominant axis wins, so a connector two cells out still names a side.
local function side_of(map, dx, dy)
    local ux, uy
    if math.abs(dx) >= math.abs(dy) then
        ux, uy = (dx > 0 and 1 or -1), 0
    else
        ux, uy = 0, (dy > 0 and 1 or -1)
    end
    for _, name in ipairs(CW) do
        local d = map[name]
        if d[1] == ux and d[2] == uy then return name end
    end
    return nil
end

-- Openings after `turns` quarter turns clockwise. Purely a name-space rotation:
-- the names are the screen's, so this holds whatever the grid layout turns out
-- to be.
local _cw_index = nil
local function turn_openings(openings, turns)
    if _cw_index == nil then
        _cw_index = {}
        for i, name in ipairs(CW) do _cw_index[name] = i end
    end
    local out = {}
    for _, name in ipairs(openings or {}) do
        local i = _cw_index[name]
        if i ~= nil then out[#out + 1] = CW[((i - 1 + turns) % 4) + 1] end
    end
    -- Same order the engine's own bitmask decodes in (Up, Right, Down, Left),
    -- so a turned set can be string-compared against one read off the board.
    table.sort(out, function(a, b) return _cw_index[a] < _cw_index[b] end)
    return out
end
M.turn_openings = turn_openings


-- Enough of a state to say what one press did: EVERY cell's openings, keyed by
-- its grid position.
--
-- Keyed by cell, not by side name, on purpose. What a press did has to be
-- observable before the side names are trusted -- measuring the names is the
-- whole point of the probe -- so the observation cannot itself go through them.
--
-- And every cell, not only the ones the board calls rotatable, for the same
-- reason: a cell that turns under a press IS a connector whatever the flag says,
-- and a snapshot that skipped it would report the press as having done nothing.
-- Fixed cells never move, so carrying them costs a few table entries and buys
-- the one connector every layout in the 2026-09-07 session was missing.
local function snapshot_cells(state)
    local out = {}
    for _, cell in ipairs(state and state.cells or {}) do
        out[cell_key(cell.x, cell.y)] = table.concat(cell.openings, "+")
    end
    return out
end

-- The board as the engine handed it over, one line per cell, raw values first.
--
-- Raw because the integer is the evidence and the decoded names are only the
-- reading: the screen shows one arm per connector while _PathType hands over
-- two openings, and it took the engine's own values to settle which was right.
local function board_report(state)
    local out = {}
    local goals = {}
    for _, g in ipairs(state.goals or {}) do
        goals[#goals + 1] = tostring(g.x) .. "," .. tostring(g.y)
    end
    out[#out + 1] = string.format(
        "%dx%d  goals=%s%s  gui lines=%s  rounds=%s  pre-goals=%s",
        state.width, state.height,
        #goals > 0 and table.concat(goals, " ") or "none",
        state.goal_guessed and " (assumed)" or "",
        tostring(state.line_count), tostring(state.rounds_needed),
        tostring(state.pre_goal_count))
    out[#out + 1] = string.format(
        "frame=%s confident=%s disagree=%s evidence=%s confirmed=%s model_bad=%s"
        .. "  solved_whole=%s  spin=%s",
        state.axis and state.axis.id or "?",
        tostring(state.axis and state.axis.confident),
        tostring(state.axis and state.axis.live_disagree),
        tostring(state.axis and state.axis.evidence),
        tostring(state.model_confirmed), tostring(state.model_bad),
        tostring(state.solved_whole), tostring(state.spin))
    out[#out + 1] = "cell    pathtype  openings      bits  rot turn conn source     pathsrc"
    for _, cell in ipairs(state.cells) do
        out[#out + 1] = string.format(
            "%-6s  %-8s  %-12s  %-4d  %-3s %-4s %-4s %-10s %s",
            cell.key, tostring(cell.raw_path),
            #cell.openings > 0 and table.concat(cell.openings, "+") or "-",
            #cell.openings,
            cell.rotatable and "y" or "-",
            cell.turnable and "y" or "-",
            cell.connected and "y" or "-",
            tostring(cell.source) .. "(" .. tostring(cell.raw_source) .. ")",
            tostring(cell.path_source))
    end
    for _, c in ipairs(state.connectors) do
        out[#out + 1] = string.format(
            "connector %-6s at %-6s target=%-12s presses=%-5s closes-as=%-12s complete=%-5s"
            .. "  [%s]",
            tostring(c.side or "UNNAMED"), c.key, tostring(c.target or "-"),
            tostring(c.presses),
            #c.demanded > 0 and table.concat(c.demanded, "+") or "-",
            tostring(c.demand_complete), tostring(c.wanted_detail))
    end
    return out
end

-- Which cells differ between two snapshots, sorted so the answer is stable.
local function changed_cells(before, after)
    local moved = {}
    if before == nil or after == nil then return moved end
    for key, value in pairs(after) do
        if before[key] ~= nil and before[key] ~= value then moved[#moved + 1] = key end
    end
    table.sort(moved)
    return moved
end

-- Which way did that cell turn? +1 for one quarter forward through the name
-- cycle, -1 for one quarter back, nil when the question has no answer.
--
-- It has no answer more often than it looks. A straight piece lands on the same
-- pair of openings whichever way it goes, so only an elbow can say -- and a
-- board of straight pieces can never say, which is fine, because on a board of
-- straight pieces the direction does not change any answer either.
--
-- This used to only warn. The 2026-09-08 capture has that warning in it and
-- nothing acted on it, so on that layout every press count was 1 and 3 the
-- wrong way round: a half turn is a half turn and a straight piece needs one
-- press either way, but an elbow needing 1 or 3 was told the opposite. The
-- direction is a property of THIS board's name frame, not of the engine -- a
-- mirrored calibration turns a physically clockwise press into a
-- counter-clockwise one in these names -- so it is measured per layout.
local function quarter_turn_spin(before, after, key)
    if before == nil or after == nil then return nil end
    local from, to = before[key], after[key]
    if from == nil or to == nil or from == to then return nil end
    local list = {}
    for name in from:gmatch("[^+]+") do list[#list + 1] = name end
    local cw = table.concat(turn_openings(list, 1), "+")
    local ccw = table.concat(turn_openings(list, 3), "+")
    if cw == ccw then return nil end          -- a straight piece cannot say
    if to == cw then return 1 end
    if to == ccw then return -1 end
    log.warn("puzzle_circuit: cell " .. key .. " went " .. from .. " -> " .. to
          .. ", which is not a quarter turn either way")
    return nil
end

-- Turns through the name cycle <-> presses on the button. The same map both
-- ways, so one function does for reading a press count and for previewing one.
local function with_spin(turns, spin)
    if turns == nil then return nil end
    if spin ~= nil and spin < 0 then return (4 - turns) % 4 end
    return turns
end

-- --------------------------------------------------------------------
-- Current puzzle
-- --------------------------------------------------------------------
local function current_record()
    local active = registry.active_raw()
    if active == nil or active.kind ~= M.kind then return nil, active end
    return store.track(active.inst, active.unit), active
end

function M.current_puzzle_id()
    local rec = current_record()
    return rec and rec.id or nil
end

M.matched_puzzle_id = M.current_puzzle_id

function M.live_puzzle_ids()
    return store.live_ids()
end


-- The press count that reaches the end state the peer MEANT, on the board as it
-- is now rather than as it was described to them.
--
-- This puzzle is driven by the same buttons as player movement, so the board
-- moves while the peer is thinking. In the 2026-09-08 capture the mod pressed a
-- connector that had already drifted into the orientation the answer was asking
-- for, forty-six times, turning a correct connector wrong and costing the hack a
-- retry each time.
--
-- The answer is re-expressed rather than second-guessed. A press count plus the
-- openings it was read against name one absolute orientation, and that
-- orientation is what the peer asked for; how many presses reach it from HERE is
-- arithmetic. So the plan still ends exactly where the peer intended, with no
-- input it did not ask for.
--
-- Returns the corrected count (0 means "already there, press nothing"), or nil
-- when the answer cannot be re-expressed at all -- a piece of a different shape,
-- which means a round slipped in and the plan is stale for bigger reasons.
local function reconcile_presses(was, openings, asked, spin)
    if type(was) ~= "string" or was == "" then return nil end
    -- No drift, no correction. Taken before the search on purpose: a straight
    -- piece reaches the same shape two ways, and rewriting an untouched answer
    -- from 3 presses to 1 would be a change the peer never asked for and a log
    -- line about nothing.
    if table.concat(openings, "+") == was then return asked end

    local list = {}
    for name in was:gmatch("[^+]+") do list[#list + 1] = name end
    local intended = table.concat(turn_openings(list, with_spin(asked, spin)), "+")

    -- Smallest first, so a straight piece takes the cheaper of its two answers.
    for turns = 0, 3 do
        if table.concat(turn_openings(openings, with_spin(turns, spin)), "+") == intended then
            return turns
        end
    end
    return nil
end


-- --------------------------------------------------------------------
-- Solving the whole board at once
-- --------------------------------------------------------------------
-- The demand rule above answers one connector at a time, and there is one case
-- it structurally cannot answer: a connector whose neighbour is another
-- connector. What that neighbour will open onto is not settled, so no number
-- can be stood behind and the state text falls back to listing the three
-- options. The 2026-09-08 capture says how often that happened -- 103 of 138
-- forces carried no press count at all -- and a fallback that frequent is not a
-- fallback, it is the behaviour, and the behaviour is the coin flip this was
-- all meant to remove.
--
-- Worse, the fallback is not even neutral. A connector that is invisible to the
-- reader (the GUI drew four circuits and only three cells are flagged
-- rotatable) is treated as a FIXED cell, so whatever it happens to be pointing
-- at right now is read as a demand -- which is how an elbow ended up being told
-- it must open left AND right.
--
-- So the board is solved as a whole instead. calibrate() already models the
-- engine's connectivity -- goal-reachability through cells that open onto each
-- other -- and, better, it already PROVES that model on this board:
-- `disagree == 0` means the model reproduced the engine's own
-- IsConnectingToGoal flag on every cell. With the model confirmed the
-- connectors' orientations are the only unknowns, and there are 4^n of them.
--
-- The result is a target opening set per connector, which is layout-stable:
-- turning a connector does not change what the board needs it to end up as. So
-- this runs once per layout and the per-connector press count is then a
-- comparison, not a search.
local SOLVE_MAX_CONNECTORS = 6

-- The fewest presses that close this one connector, with every other piece
-- held where it is -- or nil when there is none, or when the answer depends on
-- another connector.
--
-- It is the engine's rule asked about one cell: try each press count and see
-- whether lit_cells puts this connector on a finished line. Counted in PRESSES
-- (via spin), so on a board whose presses run backwards through the names the
-- cheaper of two good orientations is still the one chosen. Returned as a turn
-- count in names, like the whole-board solve, so the caller converts both the
-- same way.
--
-- This replaces a one-arm rule -- "cheapest turn that opens onto the centre" --
-- that the 2026-09-11 trace disproves: see lit_cells.
--
-- `complete` is false when a neighbour is itself a connector: what that one
-- will open onto is not settled, so an answer computed through it would be
-- guesswork wearing a number. solve_board answers those.
local function presses_to_close(cell, at, ends, map, spin)
    local self_key = key_of(cell.x, cell.y)

    local complete = true
    for _, name in ipairs(CW) do
        local d = map[name]
        local nb = at[key_of(cell.x + d[1], cell.y + d[2])]
        if nb ~= nil and nb.turnable then complete = false end
    end

    local found, detail = nil, {}
    for presses = 0, 3 do
        local turns = with_spin(presses, spin)
        local shape = turn_openings(cell.openings, turns)
        local lit = lit_cells(at, ends, map, { [self_key] = opening_set(shape) })
        local closes = lit[self_key] == true
        -- Carried out to the Num0 dump: which press counts close this
        -- connector is the whole of this rule, and a wrong answer here is
        -- invisible in the number it produces.
        detail[#detail + 1] = tostring(presses) .. "=" .. table.concat(shape, "+")
                           .. (closes and "(closes)" or "")
        if closes and found == nil then found = turns end
    end
    return found, complete, table.concat(detail, " ")
end


-- The orientation every connector has to end up in, or nil when the board
-- cannot be solved this way.
--
-- "Solved" is EVERY CONNECTOR ON A FINISHED LINE, in the fewest presses --
-- lit_cells, the engine's own rule, asked for every combination. The search is
-- only allowed to run while the model reproduces IsConnectingToGoal, so what
-- it searches is a proven reading of this board.
--
-- On the last board of the 2026-09-11 trace this has exactly one answer and it
-- is the one the player found by hand. The previous objective -- every
-- connector merely TOUCHING the centre -- accepted orientations whose other arm
-- was loose, which the game never lights. Lit cells break a tie between two
-- equally cheap answers, where they decide nothing and keep the choice
-- deterministic.
--
-- Fewest presses also disposes of the harmless ties: a straight piece reaches
-- the same shape two ways and 0 beats 2.
--
-- `spin` is what makes "fewest" mean fewest PRESSES rather than fewest steps
-- around the name cycle. On a mirrored frame those run opposite ways, so
-- counting name steps would pick a three-press target over a one-press one --
-- and, worse, would make the answer depend on which of the eight frames
-- calibrate() happened to choose, which is the class of bug this file exists to
-- close. nil (not measured yet) leaves it counting name steps, as before.
local function solve_board(cells, at, ends, map, spin)
    if ends == nil or #ends.goals == 0 then return nil end

    local turnable = {}
    for _, cell in ipairs(cells) do
        if cell.turnable then turnable[#turnable + 1] = cell end
    end
    local n = #turnable
    if n == 0 or n > SOLVE_MAX_CONNECTORS then return nil end

    -- Every orientation of every connector up front: the search body runs 4^n
    -- times and this is the allocation worth keeping out of it.
    local shapes, keys = {}, {}
    for i, cell in ipairs(turnable) do
        keys[i] = key_of(cell.x, cell.y)
        shapes[i] = {}
        for t = 0, 3 do
            shapes[i][t] = opening_set(turn_openings(cell.openings, t))
        end
    end

    local best, best_lit, best_cost = nil, nil, nil
    local choice, override = {}, {}
    local combinations = 1
    for _ = 1, n do combinations = combinations * 4 end

    for code = 0, combinations - 1 do
        local rest, cost = code, 0
        for i = 1, n do
            local t = rest % 4
            rest = math.floor(rest / 4)
            choice[i] = t
            cost = cost + with_spin(t, spin)
            override[keys[i]] = shapes[i][t]
        end

        local seen = lit_cells(at, ends, map, override)
        local lit, all = 0, true
        for _ in pairs(seen) do lit = lit + 1 end
        for i = 1, n do
            if not seen[keys[i]] then all = false break end
        end

        if all and (best_cost == nil or cost < best_cost
                    or (cost == best_cost and lit > best_lit)) then
            best_lit, best_cost = lit, cost
            best = {}
            for i = 1, n do best[i] = choice[i] end
        end
    end

    if best == nil then return nil end

    local targets = {}
    for i, cell in ipairs(turnable) do
        targets[cell.key] = table.concat(turn_openings(cell.openings, best[i]), "+")
    end
    return targets
end


-- --------------------------------------------------------------------
-- Board reader
-- --------------------------------------------------------------------
-- What makes this board THIS board: its size, its centre, where the
-- connectors and sources sit, and the shape of every FIXED cell. A connector's
-- openings are excluded, so turning one does not read as a new layout --
-- struct_sig depends on that and so does every cache keyed on this.
--
-- The fixed cells used to be left out too, and the 2026-09-11 trace shows what
-- that cost: rounds reuse the same source positions with different lines, and
-- the key o0,0;o0,4;o4,4 turns up with two different boards under it. A round
-- dealt under an old key inherited the previous round's solved targets and no
-- replan happened. A fixed cell never turns, so its shape can be fingerprinted
-- without a turning connector ever looking like a new board.
local function layout_key(cells, goals, width, height)
    local marks = {}
    for _, cell in ipairs(cells) do
        if cell.rotatable then
            marks[#marks + 1] = "r" .. cell.x .. "," .. cell.y
        elseif cell.source and cell.source ~= "none" then
            marks[#marks + 1] = cell.source:sub(1, 1) .. cell.x .. "," .. cell.y
        end
        if not cell.turnable and (cell.raw_path or 0) ~= 0 then
            marks[#marks + 1] = "p" .. cell.x .. "," .. cell.y .. "=" .. tostring(cell.raw_path)
        end
    end
    table.sort(marks)
    local goal_marks = {}
    for _, g in ipairs(goals or {}) do
        goal_marks[#goal_marks + 1] = "g" .. g.x .. "," .. g.y
    end
    table.sort(goal_marks)
    return table.concat({
        tostring(width), tostring(height),
        #goal_marks > 0 and table.concat(goal_marks, ",") or "g?",
        table.concat(marks, ";"),
    }, "|")
end


-- Where the connectors are, and nothing else. The button mapping and the
-- direction a press turns depend on this alone, so they are keyed on it rather
-- than on layout_key: a new round with the connectors in the same places keeps
-- its measured names, and the probe -- four presses that fairly often finish a
-- round by themselves -- runs once per arrangement instead of once per round.
local function button_layout_key(cells, width, height)
    local marks = {}
    for _, cell in ipairs(cells) do
        if cell.rotatable then marks[#marks + 1] = cell.x .. "," .. cell.y end
    end
    table.sort(marks)
    return tostring(width) .. "x" .. tostring(height) .. ":" .. table.concat(marks, ";")
end

-- How many cells the engine's own _Goals set holds, or nil when it cannot be
-- read. Best effort by design: this exists to be compared against the cells
-- whose _SourceType says "goal", and a nil compares as "no opinion".
local function goals_field_count(inst)
    local set = safe(function() return inst:get_field("_Goals") end)
    if set == nil then return nil end
    local n = registry.to_int(safe(function() return set:call("get_Count") end))
    if n ~= nil then return n end
    return registry.to_int(safe(function() return set:get_field("_count") end))
end


local function read_state(rec)
    if rec == nil then return nil end
    local inst = rec.inst
    if not registry.is_alive(inst) then return nil end

    local base = registry.base_state(inst)
    local question = safe(function() return inst:get_field("_Question") end)
    local rows = arr_size(question)
    if rows == 0 then return nil end

    local cells = {}
    local at = {}
    local goals = {}
    local sources = {}
    local width = 0

    for y = 0, rows - 1 do
        local row = arr_get(question, y)
        local cols = arr_size(row)
        if cols > width then width = cols end
        for x = 0, cols - 1 do
            local cell = arr_get(row, x)
            if cell ~= nil then
                local raw_source = registry.to_int(safe(function() return cell:get_field("_SourceType") end))
                local raw_path = registry.to_int(safe(function() return cell:get_field("_PathType") end))
                local source = source_name(raw_source)
                local openings = decode_openings(raw_path)
                local key = cell_key(x, y)
                local rotatable = registry.read_bool(cell, "_IsRotatable", false)
                local entry = {
                    x         = x,
                    y         = y,
                    key       = key,
                    openings  = openings,
                    open_set  = opening_set(openings),
                    rotatable = rotatable,
                    -- A cell a press has actually turned counts as a connector
                    -- whatever _IsRotatable says: the button moved it, which is
                    -- the only evidence that matters. Every layout in the
                    -- 2026-09-07 session reported one more GUI line than
                    -- rotatable cell, so at least one connector was going
                    -- undescribed and unpressed on every board.
                    turnable  = rotatable
                             or (rec.extra_cells ~= nil and rec.extra_cells[key] == true),
                    connected = registry.read_bool(cell, "<IsConnectingToGoal>k__BackingField", false),
                    source    = source,
                    -- The engine's own integers, kept beside the decoded names
                    -- for the Num0 dump, verbatim rather than summarised.
                    raw_path   = raw_path,
                    raw_source = raw_source,
                    -- Which sources have rippled this far (clearGridPathSource /
                    -- rippleSource fill it in). Carried for the debug dump only
                    -- -- nothing here depends on a reading of its meaning.
                    path_source = registry.to_int(safe(function() return cell:get_field("_PathSource") end)),
                }
                cells[#cells + 1] = entry
                at[key_of(x, y)] = entry
                -- EVERY goal. This kept the last one it saw, and every circuit
                -- running to any other goal was then solved toward the wrong
                -- place -- silently, because a board with nothing connected
                -- yet cannot contradict a reachability model.
                if source == "goal" then goals[#goals + 1] = { x = x, y = y } end
                -- Where each circuit starts. Open is what every board of the
                -- 2026-09-11 trace uses; Start is its sibling in the same enum.
                if source == "open" or source == "start" then
                    sources[#sources + 1] = { x = x, y = y }
                end
            end
        end
    end

    -- Without an explicit goal cell, the centre of the board is the target the
    -- connectors have to reach; that is what the puzzle draws. Say so: the goal
    -- anchors both the calibration and every "side facing the centre", so a
    -- guessed one is worth knowing about before its consequences are debugged.
    local goal_guessed = false
    if #goals == 0 and width > 0 and rows > 0 then
        goal_guessed = true
        goals[1] = { x = math.floor((width - 1) / 2), y = math.floor((rows - 1) / 2) }
        if rec.goal_warned ~= true then
            rec.goal_warned = true
            log.warn("puzzle_circuit: no goal cell on the board; assuming the centre ("
                  .. tostring(goals[1].x) .. "," .. tostring(goals[1].y) .. ")")
        end
    end
    -- One anchor for the geometric side name, which is a fallback for a name
    -- the probe normally measures. Every connection question below asks about
    -- all of them instead.
    local goal = goals[1]
    local ends = { sources = sources, goals = goals }

    -- Which grid delta each opening name means. Cached against the layout, not
    -- the rotations: turning a connector must not trigger a recalibration, or
    -- the answer would change under the plan that is being executed.
    local layout = layout_key(cells, goals, width, rows)
    local button_layout = button_layout_key(cells, width, rows)
    -- Recomputed on a new layout, and retried while it is not confident: the
    -- engine's connection flags are the strong evidence and there are more of
    -- them once a connector or two has been closed. A confident answer is then
    -- frozen, because it is what the peer's side names mean and re-deciding it
    -- under a running plan would throw that plan away.
    -- Re-decided on a new layout, while unconfident, and once more per layout
    -- if the board has since DISPROVED the frame with something lit -- the
    -- names no longer come from the frame (the probe measures them), so a
    -- correction costs nothing but a plan written against the wrong model.
    local recheck = rec.axis ~= nil and rec.axis.disproved == true
        and rec.axis_recheck ~= layout
    if recheck then rec.axis_recheck = layout end

    -- The remembered frame first. If it still agrees with this board it is
    -- kept without a vote, because on an empty board a vote is a coin toss.
    if (rec.axis == nil or rec.axis.layout ~= layout) and not recheck
        and _known_frame ~= nil then
        local score = score_candidate(cells, at, ends, _known_frame.map)
        if score.disagree == 0 then
            rec.axis = {
                id = _known_frame.id, map = _known_frame.map, confident = true,
                matches = -1, disagree = 0, evidence = score.evidence,
                contradictions = score.contradictions, runner_up = -1,
                layout = layout, remembered = true,
            }
        end
    end

    if rec.axis == nil or rec.axis.layout ~= layout or not rec.axis.confident or recheck then
        local axis = calibrate(cells, at, ends)
        axis.layout = layout
        rec.axis = axis
        if axis.confident then
            log.info("puzzle_circuit: direction mapping calibrated as " .. axis.id)
        elseif rec.axis_warned ~= layout then
            -- Once per layout, and loud: every side name below is only as good
            -- as this, and a wrong one turns the connector the peer did not name.
            rec.axis_warned = layout
            log.warn(string.format(
                "puzzle_circuit: direction mapping is a guess (%s) -- %d candidate(s) "
                .. "matched the engine's connection flags, %d cell(s) disagree, "
                .. "%d contradiction(s) against %d for the runner-up",
                axis.id, axis.matches, axis.disagree, axis.contradictions,
                axis.runner_up))
        end
    end
    local axis = rec.axis

    -- The frozen frame keeps its id -- the peer's names must not move under a
    -- plan -- but its SCORE goes stale the moment the board changes, and the
    -- score is what the whole-board solve is licensed by. axis.disagree used to
    -- keep the number it had at calibration time, which on a board with nothing
    -- connected is a perfect zero that nothing earned.
    --
    -- So re-score the chosen candidate on every read. One flood over a board of
    -- a few dozen cells, against a solver that is about to try every
    -- combination of connector orientations.
    local live = score_candidate(cells, at, ends, axis.map)
    axis.live_disagree = live.disagree
    axis.evidence = live.evidence
    -- Confirmed means the engine has actually flagged something connected and
    -- this model agreed with it. Anything else is a reading, and the peer is
    -- told which it is getting.
    axis.confirmed = live.disagree == 0 and live.evidence > 0
    -- Disproved is the same test failing: something lit, and the model got it
    -- wrong. The next read re-decides the frame (once per layout).
    axis.disproved = live.disagree > 0 and live.evidence > 0
    if axis.confirmed and (_known_frame == nil or _known_frame.id ~= axis.id) then
        _known_frame = { id = axis.id, map = axis.map }
        log.info("puzzle_circuit: direction frame " .. axis.id .. " confirmed by the"
              .. " engine's own flags; later boards keep it while it agrees")
    elseif axis.disproved and _known_frame ~= nil and _known_frame.id == axis.id then
        _known_frame = nil
    end

    -- Which way a press turns is a fact about THIS board's name frame, so it
    -- goes stale with the layout exactly as the frame does.
    if rec.spin_layout ~= button_layout then
        rec.spin, rec.spin_layout = nil, button_layout
    end

    -- Solve the board whole, once, while it is still this board -- and only
    -- while the model still reproduces the engine's own connection flags. That
    -- agreement is the whole evidence that this reachability model is the
    -- engine's; without it a press count out of this search would be a
    -- confident guess of the kind this file exists to stop making.
    --
    -- The search runs 4^connectors floods, so it is deliberately kept to the
    -- transitions that change the answer: a new board, a newly measured spin,
    -- a model that has just started agreeing (closing one connector gives it
    -- flags to be scored against, so a board that could not be modelled at
    -- first can become modellable a press later), and a model that has just
    -- stopped agreeing, which drops the answer built on it.
    local have = rec.solution ~= nil
        and rec.solution.layout == layout
        -- Which way a press turns decides which of two equally good targets is
        -- the cheap one, so a solution worked out before the spin was known is
        -- worth working out again once it is.
        and rec.solution.spin == rec.spin
    local resolve_board = not have
        or (rec.solution.targets == nil and live.disagree == 0
            and rec.solution.disagree ~= 0)
        or (rec.solution.targets ~= nil and live.disagree ~= 0)
    if resolve_board then
        local targets = nil
        if live.disagree == 0 then
            targets = solve_board(cells, at, ends, axis.map, rec.spin)
        end
        rec.solution = { layout = layout, targets = targets, disagree = live.disagree,
                         spin = rec.spin }
        if targets ~= nil then
            local parts = {}
            for key, shape in pairs(targets) do parts[#parts + 1] = key .. "=" .. shape end
            table.sort(parts)
            log.info("puzzle_circuit: board solved -- " .. table.concat(parts, " ")
                  .. (axis.confirmed and ""
                      or " (unconfirmed: the engine has flagged nothing connected on this"
                      .. " board, so the model has not been tested against anything)"))
        elseif live.disagree ~= 0 then
            log.warn("puzzle_circuit: the connection model does not reproduce the engine's"
                  .. " flags on this board (" .. tostring(live.disagree) .. " cell(s) differ)"
                  .. " -- press counts fall back to the per-connector rule")
        else
            log.warn("puzzle_circuit: no orientation of the connectors connects them all"
                  .. " -- press counts fall back to the per-connector rule")
        end
    end
    -- A plan that ran to the model's own targets and did not finish the hack
    -- disproves the model on this layout, whatever its score says. finish_plan
    -- marks it; here is where the answer built on it stops being offered.
    local solved = rec.solution and rec.solution.targets or nil
    if rec.model_bad == layout then solved = nil end

    -- One entry per connector: the button that turns it, what the board demands
    -- it open onto, how many presses get it there, and what each press would
    -- leave it opening onto.
    --
    -- `side` is the MEASURED button wherever there is a measurement. Where there
    -- is not -- the probe is off, or has not run yet -- it falls back to the
    -- geometric side and says so, because a name nobody has tested is a name the
    -- peer should not be asked to bet a hack on.
    local by_cell = {}
    if rec.buttons ~= nil then
        for dir, key in pairs(rec.buttons) do
            if key ~= nil then by_cell[key] = dir end
        end
    end

    local connectors = {}
    local by_side = {}
    local unaddressed = 0
    for _, cell in ipairs(cells) do
        if cell.turnable then
            -- Nearest goal: this names the geometric fallback side only, and a
            -- board with several goals has no single centre to measure from.
            local anchor = goal
            for _, g in ipairs(goals) do
                if math.abs(cell.x - g.x) + math.abs(cell.y - g.y)
                    < math.abs(cell.x - anchor.x) + math.abs(cell.y - anchor.y) then
                    anchor = g
                end
            end
            local geometric = side_of(axis.map, cell.x - anchor.x, cell.y - anchor.y)
            local measured = by_cell[cell.key]
            local side = measured or (rec.buttons == nil and geometric or nil)
            local closing, complete, wanted_detail =
                presses_to_close(cell, at, ends, axis.map, rec.spin)

            -- The whole-board answer first: it is the only one that can speak
            -- for a connector sitting next to another connector, and it is
            -- checked against the engine's flags before it is believed at all.
            local turns = nil
            local target = solved and solved[cell.key] or nil
            if target ~= nil then
                for t = 0, 3 do
                    if table.concat(turn_openings(cell.openings, t), "+") == target then
                        turns = t
                        break
                    end
                end
            end
            local from_solver = turns ~= nil
            local closes_as = closing ~= nil and turn_openings(cell.openings, closing) or {}
            if turns == nil and complete then turns = closing end
            local presses = with_spin(turns, rec.spin)

            -- The engine's own flag is the arbiter, in ONE direction. A
            -- connector the demand calls misoriented cannot be one the engine
            -- calls connected, so that combination means the reading is wrong
            -- and every press count derived from it is suspect. The opposite --
            -- oriented but not connected -- is ordinary: a circuit with a second
            -- connector still open is not closed however right this one is.
            if not from_solver and presses ~= nil and presses ~= 0 and cell.connected == true then
                if rec.demand_warned ~= layout then
                    rec.demand_warned = layout
                    log.warn(string.format(
                        "puzzle_circuit: cell %s closes as %s and opens %s, so it"
                        .. " reads %s, but the engine says %s -- press counts withheld for"
                        .. " this layout",
                        cell.key, #closes_as > 0 and table.concat(closes_as, "+") or "nothing",
                        table.concat(cell.openings, "+"),
                        presses == 0 and "closed" or "open",
                        cell.connected and "connected" or "not connected"))
                end
                rec.demand_bad = layout
            end
            -- Only the per-connector rule is withheld: the whole-board answer
            -- is checked against the engine's flags before it is used at all,
            -- and it may quite legitimately turn a connector that is already
            -- lit in order to pass its line further along.
            if not from_solver and rec.demand_bad == layout then presses = nil end
            -- And nothing at all once a finished plan has disproved the model:
            -- the per-connector rule reads the same wiring the solve did, so it
            -- is disproved with it. The render lists the options instead, which
            -- is a question the peer can actually answer differently.
            if rec.model_bad == layout then presses = nil end

            local connector = {
                side      = side,
                direction = side,          -- the name the action still uses
                measured  = measured ~= nil,
                geometric = geometric,
                x = cell.x, y = cell.y,
                key       = cell.key,
                openings  = cell.openings,
                -- The orientation that closes this one with the others held
                -- where they are, from the engine's rule rather than from
                -- geometry. Empty when no orientation does, which means the
                -- board wants another connector moved first.
                needs     = #closes_as > 0 and table.concat(closes_as, "+") or nil,
                demanded  = closes_as,
                demand_complete = complete,
                wanted_detail = wanted_detail,
                -- Where the whole-board solve says this one has to end up, as
                -- an openings list. nil when the count came from the
                -- per-connector rule instead.
                target    = from_solver and target or nil,
                presses   = presses,
                connected = cell.connected,
                -- What each PRESS COUNT leaves it opening onto -- press counts,
                -- not name-cycle steps, so a board whose presses run the other
                -- way previews what will actually happen.
                previews  = {
                    turn_openings(cell.openings, with_spin(1, rec.spin)),
                    turn_openings(cell.openings, with_spin(2, rec.spin)),
                    turn_openings(cell.openings, with_spin(3, rec.spin)),
                },
            }
            connectors[#connectors + 1] = connector
            if side ~= nil and by_side[side] == nil then
                by_side[side] = connector
            else
                -- No button, or a button already spoken for. Either way this
                -- connector cannot be answered for, and offering a name that
                -- resolves to a different connector would be worse than saying
                -- so: that is the failure this whole change is about.
                connector.side, connector.direction = nil, nil
                unaddressed = unaddressed + 1
            end
        end
    end

    -- The GUI parameter is the game's own view of the same puzzle: one Line per
    -- circuit, which is what the player sees as a row. The countdown lives here
    -- on the timer variants, and the line count is a free sanity check on the
    -- connector model above.
    local param = safe(function() return inst:get_field("_GuiParam") end)
    local remaining, timer_rate, line_count = nil, nil, nil
    if param ~= nil then
        remaining = safe(function() return param:get_field("RemainingTime") end)
        timer_rate = safe(function() return param:get_field("TimerRate") end)
        if type(remaining) ~= "number" then
            remaining = safe(function() return remaining:get_field("value") end)
        end
        if type(timer_rate) ~= "number" then
            timer_rate = safe(function() return timer_rate:get_field("value") end)
        end
        local lines = safe(function() return param:get_field("Lines") end)
        local n = arr_size(lines)
        if n > 0 then line_count = n end
    end

    local connected_count = 0
    for _, c in ipairs(connectors) do if c.connected then connected_count = connected_count + 1 end end

    -- Worth a line, and nothing more than that. It used to read "the connector
    -- model does not fit this layout", and the state block told the peer a
    -- circuit was going undescribed -- on a board whose screenshot has exactly
    -- three pieces and three key pads against a Lines array of four. Lines is
    -- not a count of circuits, whatever else it is, so nothing may be concluded
    -- from the difference until something has read _GuiParam properly.
    if line_count ~= nil and line_count ~= #connectors and rec.line_warned ~= layout then
        rec.line_warned = layout
        log.info(string.format(
            "puzzle_circuit: the GUI holds %d line(s) and the board has %d turnable "
            .. "cell(s); the two do not have to agree",
            line_count, #connectors))
    end

    return {
        kind            = M.kind,
        width           = width,
        height          = rows,
        goal            = goal,
        goals           = goals,
        sources         = sources,
        layout          = layout,
        button_layout   = button_layout,
        goal_guessed    = goal_guessed,
        -- Whether the connection model has been checked against a board the
        -- engine had flagged something on, and whether a finished plan has
        -- since disproved it. The render says which it is offering.
        model_confirmed = axis.confirmed == true,
        known_frame     = _known_frame and _known_frame.id or nil,
        model_bad       = rec.model_bad == layout,
        cells           = cells,
        connectors      = connectors,
        by_side         = by_side,
        unaddressed     = unaddressed,
        buttons         = rec.buttons,
        button_route    = rec.button_route,
        axis            = axis,
        -- +1 / -1 once a press has said which way this board turns, nil until
        -- one has. The render needs it for one sentence; the debug panel needs
        -- it to explain a press count that looks backwards.
        spin            = rec.spin,
        solved_whole    = solved ~= nil,
        -- Set by force_blocked when a board that reads as needing nothing has
        -- gone on not completing. The render says so rather than printing a
        -- page of "leave it alone" under a question.
        stuck           = rec.force_stuck == true,
        line_count      = line_count,
        connected_count = connected_count,
        rounds_needed   = registry.to_int(safe(function() return inst:get_field("_RoundCountForSuccess") end)),
        pre_goal_count  = registry.to_int(safe(function() return inst:get_field("_PreGoalCount") end)),
        -- The engine's own goal set, shown on the debug panel and in the Num0
        -- dump and depended on by nothing: a HashSet needs reflection that may
        -- not work on every build, while _SourceType marks the same cells and
        -- always reads.
        goals_field     = goals_field_count(inst),
        remaining_time  = type(remaining) == "number" and remaining or nil,
        timer_rate      = type(timer_rate) == "number" and timer_rate or nil,
        timed           = type(remaining) == "number",
        success         = registry.read_bool(inst, "_SuccessTrigger", false),
        failed          = registry.read_bool(inst, "_FaildTrg", false),
        playing         = base and base.playing or nil,
    }
end


function M.get_state(id)
    local rec = id and store.by_id(id) or current_record()
    return read_state(rec)
end


-- Layout fingerprint. Piece ROTATIONS are excluded on purpose: they are exactly
-- what the plan changes, so including them would make every plan invalidate
-- itself on its own first press.
local function struct_sig(state)
    if state == nil then return nil end
    -- The calibration id rides along: if the mapping is re-measured, the side
    -- names in flight no longer mean what the plan meant by them, and that is a
    -- structural change like any other.
    local buttons = { "b" }
    for _, dir in ipairs(CW) do
        buttons[#buttons + 1] = dir .. "=" .. tostring(state.buttons and state.buttons[dir] or "?")
    end
    return table.concat({
        "circuit",
        layout_key(state.cells, state.goals, state.width, state.height),
        state.axis and state.axis.id or "?",
        -- The measured mapping rides along for the same reason the calibration
        -- does: it is what the side names in a plan MEAN, so re-measuring it is
        -- a structural change and a plan written before it is stale.
        table.concat(buttons, ","),
    }, "|")
end
M.struct_sig = struct_sig


function M.render_state(id)
    local state = M.get_state(id)
    if state == nil then return nil end
    return render.circuit(state)
end


-- --------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------
function M.lifecycle()
    local rec = current_record()
    local blank = { started = false, changed = false, reset = false, success = false, failed = false }
    if rec == nil then return blank end
    local state = read_state(rec)
    if state == nil then return blank end
    return {
        started = registry.read_bool(rec.inst, "_InitTrg", false),
        changed = false,
        reset   = false,
        success = state.success,
        failed  = state.failed,
    }
end


function M.is_interactive()
    local rec = current_record()
    if rec == nil then return false end
    local state = read_state(rec)
    return state ~= nil and state.playing == true
end


-- --------------------------------------------------------------------
-- Force / plan plumbing
-- --------------------------------------------------------------------
-- Called immediately before the force goes out, on the board the peer is
-- about to be shown.
--
-- struct_sig, which is what P.snapshot stores, deliberately leaves ROTATIONS out
-- -- they are what a plan changes, so including them would make every plan
-- invalidate itself on its own first press. That is right for "is this still the
-- same board", and it means nothing survives the force that says what the
-- connectors were OPENING ONTO when the peer was asked.
--
-- It has to. This puzzle is driven by the same buttons as player movement, so
-- the board moves while the peer is thinking: in the 2026-09-08 capture the mod
-- logged "the peer asked for 1 press(es) on <side> and the board says 0" forty-
-- six times -- the connector had already reached the orientation the answer was
-- about to ask for, and the press turned it back off again. So the openings are
-- parked here too, and set_plan reconciles the answer against them.
function M.snapshot_force_target(id)
    local rec = store.by_id(id)
    if rec == nil then return end
    local state = read_state(rec)
    P.snapshot(rec, struct_sig(state))

    rec.forced_view = nil
    if state == nil then return end
    local view = {
        layout   = state.axis and state.axis.layout or nil,
        sides    = {},
        openings = {},
    }
    for _, c in ipairs(state.connectors) do
        view.openings[c.key] = table.concat(c.openings, "+")
        if c.side ~= nil then view.sides[c.side] = c.key end
    end
    rec.forced_view = view
end

function M.clear_force_snapshot(id)
    local rec = store.by_id(id)
    P.clear_snapshot(rec)
    -- The view describes the board that was described. Dropping the signature
    -- without it would leave a stale answer reconciled against a board nobody
    -- was ever shown.
    if rec ~= nil then rec.forced_view = nil end
end

function M.struct_changed(id)
    local rec = store.by_id(id)
    return P.changed(rec, struct_sig(read_state(rec)))
end

function M.needs_force(id)
    local rec = store.by_id(id)
    return P.needs_force(rec, struct_sig(read_state(rec)))
end

function M.has_plan(id)
    return P.has_plan(store.by_id(id))
end

local function stuck_force_frames()
    return math.floor(tunable("puzzle_circuit_stuck_force_frames", 180, 1))
end

-- Consulted by hacking_observer before it forces. The peer names connectors by
-- the button that turns them, so describing a board before that pairing has
-- been measured would be asking it to bet a hack on an untested name.
function M.force_blocked(id)
    local rec = id and store.by_id(id) or current_record()
    if rec == nil then return false end
    if rec.press ~= nil then return true end
    local state = read_state(rec)
    if state == nil then return true end
    local layout = state.axis and state.axis.layout or nil
    if rec.probe_layout ~= state.button_layout then return true end

    -- Everything below is about THIS board. A new one starts the question over,
    -- including the right to say once that there is nothing to ask about.
    if rec.unanswerable_layout ~= layout then
        rec.unanswerable_layout = layout
        rec.unanswerable_frames, rec.unanswerable_said = nil, nil
        rec.stuck_warned, rec.force_stuck = nil, false
    end

    -- A force is a question, and there has to be something to ask. 28 of the 79
    -- circuit forces in the 2026-09-08 capture asked one while telling the peer
    -- to leave every single connector alone, and an answer to that is either
    -- nothing (the hack stalls) or a guess that turns a connector which was
    -- already right.
    local answerable = false
    for _, c in ipairs(state.connectors) do
        -- No count means the mod could not work one out and the render lists
        -- the options instead: that is a real question. A count of zero, or a
        -- connector the engine already calls connected, is not.
        if c.side ~= nil and not c.connected and (c.presses == nil or c.presses > 0) then
            answerable = true
            break
        end
    end
    if answerable then
        rec.unanswerable_frames, rec.unanswerable_said = nil, nil
        rec.stuck_warned, rec.force_stuck = nil, false
        return false
    end

    local waited = (rec.unanswerable_frames or 0) + 1
    rec.unanswerable_frames = waited
    if rec.unanswerable_said ~= true then
        rec.unanswerable_said = true
        return true, "The circuit board reads as already correct, so there is nothing to"
                  .. " ask for yet."
    end

    -- Deadlock guard, and it is meant to be conspicuous. If the board still has
    -- not completed after all this, the mod's reading of it is wrong somewhere
    -- and the peer is better placed to say where than a mod that has run out of
    -- model. Without this a board misread as finished would wedge with no
    -- action ever taken -- which is precisely the state 21:45:49 ended in.
    if waited < stuck_force_frames() then return true end
    if rec.stuck_warned ~= true then
        rec.stuck_warned = true
        log.warn("puzzle_circuit: every connector reads as already correct and the hack"
              .. " has not completed after " .. tostring(waited) .. " frames -- forcing"
              .. " anyway and telling the peer the reading is unreliable")
    end
    rec.force_stuck = true
    return false
end

function M.discard_plan(id)
    local rec = store.by_id(id)
    if rec ~= nil then
        input.cancel(rec.id)
        -- A probe is not the plan's to cancel: it is measuring the names the
        -- next plan will be written in.
        if rec.press ~= nil and rec.press.kind ~= "probe" then rec.press = nil end
        rec.dispatching = false
    end
    P.discard(rec)
end

function M.resolve_plan(id, ok, message)
    return P.resolve(store.by_id(id), ok, message)
end

function M.current_plan_status()
    return P.status(current_record())
end

function M.consume_plan_events()
    return P.consume_events()
end


-- The peer's answer: a list of { piece = "<direction from the centre>",
-- steps = <quarter turns> }. Expanded here into one press per quarter turn,
-- because the engine has no "rotate N times" input -- only the button.
function M.set_plan(id, rotations, resolve)
    local rec = store.by_id(id)
    if rec == nil then return 0, false end

    -- A plan already being pressed is abandoned here rather than left to finish
    -- and report on a plan that is no longer the current one. A probe in flight
    -- is left alone: it is measuring the names this plan will be judged in.
    if rec.press ~= nil and rec.press.kind == "plan" then
        input.cancel(rec.id)
        rec.press = nil
        rec.dispatching = false
    end

    local state = read_state(rec)
    local orders = {}
    local rejected = nil
    local answered, adjusted, dropped = 0, 0, 0

    -- The board the peer was actually shown, parked by snapshot_force_target
    -- just before the force went out. Only usable while it still describes this
    -- board: a new layout, or a re-measured button mapping, means the names in
    -- the answer no longer point at the connectors they were written about.
    local view = rec.forced_view
    if view ~= nil and state ~= nil
        and view.layout ~= (state.axis and state.axis.layout or nil) then
        view = nil
    end

    for _, entry in ipairs(rotations or {}) do
        local piece = type(entry) == "table" and entry.piece or nil
        local turns = type(entry) == "table" and tonumber(entry.steps) or nil
        if not input.is_direction(piece) then
            rejected = "unknown connector '" .. tostring(piece) .. "'"
            break
        end
        if state ~= nil and state.by_side[piece] == nil then
            rejected = "no connector is turned by the " .. tostring(piece) .. " button"
            break
        end
        turns = math.floor(turns or 1)
        -- Four quarter turns is a no-op, so anything outside 1..3 is a mistake
        -- worth reporting rather than silently normalising.
        if turns < 1 or turns > 3 then
            rejected = "steps must be 1, 2 or 3 (got " .. tostring(turns) .. ")"
            break
        end
        local connector = state ~= nil and state.by_side[piece] or nil
        answered = answered + 1

        -- Re-express the answer on the board it will land on. Anything that
        -- makes the two boards incomparable falls through to pressing what was
        -- asked, which is what this did before there was a view at all.
        if connector ~= nil and view ~= nil and view.sides[piece] == connector.key then
            local was = view.openings[connector.key]
            local corrected = reconcile_presses(was, connector.openings, turns, rec.spin)
            if corrected == nil then
                log.warn("puzzle_circuit: the " .. tostring(piece) .. " connector was "
                      .. tostring(was) .. " when the peer was asked and is "
                      .. table.concat(connector.openings, "+") .. " now, which is not the"
                      .. " same piece; pressing what was asked")
            elseif corrected == 0 then
                dropped = dropped + 1
                log.info("puzzle_circuit: the board moved under the answer -- "
                      .. tostring(piece) .. " already reads "
                      .. table.concat(connector.openings, "+")
                      .. ", the end state its " .. tostring(turns)
                      .. " press(es) were aiming for; not pressing it")
                turns = 0
            elseif corrected ~= turns then
                adjusted = adjusted + 1
                log.info("puzzle_circuit: the board moved under the answer -- "
                      .. tostring(piece) .. " was " .. tostring(was)
                      .. " when the peer was asked and reads "
                      .. table.concat(connector.openings, "+") .. " now; "
                      .. tostring(turns) .. " press(es) becomes " .. tostring(corrected)
                      .. " to reach the same end state")
                turns = corrected
            end
        end

        -- The state block names the press count this connector needs, worked
        -- out from the board. The peer's answer is still what gets pressed --
        -- it may know something about a circuit the mod cannot read -- but a
        -- disagreement is worth a line: it is the difference between "the peer
        -- misread the state" and "the mod computed the wrong number", and
        -- without it the next session cannot tell those apart. Compared AFTER
        -- reconciling, so drift does not masquerade as disagreement.
        if turns > 0 and connector ~= nil and connector.presses ~= nil
            and connector.presses ~= turns then
            log.warn("puzzle_circuit: the peer asked for " .. tostring(turns)
                  .. " press(es) on " .. tostring(piece) .. " and the board says "
                  .. tostring(connector.presses) .. "; pressing what was asked")
        end

        if turns > 0 then
            orders[#orders + 1] = { piece = piece, left = turns }
        end
    end

    if rejected ~= nil then
        P.resolve(rec, false, "Nothing was rotated: " .. rejected .. ".")
        return 0, false
    end

    if #orders == 0 then
        -- Every connector the peer named had already drifted into the
        -- orientation it was aiming for, so there is nothing to press. Pressing
        -- anyway is precisely the bug this exists to stop. Drop the force
        -- snapshot so the board is described again next frame, and tell the peer
        -- what happened rather than reporting a failure it did not cause.
        P.discard(rec)
        P.clear_snapshot(rec)
        if answered > 0 and dropped == answered then
            P.resolve(rec, false, "The board moved between the state you were shown and"
                  .. " your answer: every connector you named had already reached the"
                  .. " orientation you asked for, so nothing was pressed. Here is the"
                  .. " board as it stands now.")
            P.push_event("retrying")
        else
            P.resolve(rec, false, "Nothing was rotated: the answer named no connector to"
                  .. " turn.")
        end
        return 0, false
    end

    -- One press per connector per round, rather than all of one connector's
    -- presses in a row.
    --
    -- The puzzle edge-detects each direction against its own _PrevUp /
    -- _PrevDown / _PrevLeft / _PrevRight, so two presses of the SAME button
    -- back to back are the pair most likely to arrive as one edge and turn the
    -- connector once. That is what the 2026-09-08 session reported on itself --
    -- "the peer asked for 3 press(es) on down and the board says 1", and three
    -- consecutive re-presses of left that all turned nothing -- and it is why a
    -- board needing one press per connector solved while a board needing two or
    -- three on one connector did not.
    --
    -- Spreading them out puts a different button, and therefore a guaranteed
    -- release, between every repeat. The order costs nothing: each connector's
    -- quarter turns are independent of the others'.
    local steps = {}
    local remaining = true
    while remaining do
        remaining = false
        for _, order in ipairs(orders) do
            if order.left > 0 then
                steps[#steps + 1] = order.piece
                order.left = order.left - 1
                if order.left > 0 then remaining = true end
            end
        end
    end

    local cur = current_record()
    local queued, parked = P.set_plan(rec, steps, resolve, cur ~= nil and cur.id == rec.id)
    -- The drift is worth carrying on this line as well as per connector: it is
    -- how a session tells "the peer answered badly" from "the board moved under
    -- a good answer", and those want completely different fixes.
    local drift = ""
    if adjusted > 0 or dropped > 0 then
        drift = string.format(" (%d adjusted, %d dropped -- the board moved under the answer)",
                              adjusted, dropped)
    end
    log.info("puzzle_circuit: plan for puzzle " .. tostring(id) .. " -- "
          .. tostring(queued) .. " turns, parked=" .. tostring(parked) .. drift)
    return queued, parked
end


-- --------------------------------------------------------------------
-- Pressing, one press at a time
-- --------------------------------------------------------------------
-- The engine's own _InputEnableInterval is 0.03 s -- three frames -- and the
-- dispatcher used to fire a whole plan at that cadence and watch it go. The
-- 2026-09-07 capture says what that bought: 114 quarter turns asked for, 70
-- delivered. Three frames is the fastest the engine will ACCEPT an input, not
-- how long a connector takes to turn, so the rest of the burst landed on a
-- board that was still animating and was dropped.
--
-- So each press now waits for its own result. The gate on press N is "press
-- N-1 has been seen to turn something", which is the machinery the timing
-- puzzle already needed, and a press whose result never arrives is sent again
-- rather than counted. That also fixes the observation: the old report_turn
-- read the board in the same frame as the press and so blamed every turn on the
-- press AFTER the one that caused it, which is why its warnings read as chaos
-- instead of as the one clear signal they were.
local function press_timeout_frames()
    return math.floor(tunable("puzzle_circuit_press_timeout_frames", 30, 1))
end
local function press_retry_budget()
    return math.floor(tunable("puzzle_circuit_press_retries", 2, 0))
end
local function settle_frames()
    return math.floor(tunable("puzzle_circuit_settle_frames", 30, 1))
end
local function press_gap_frames()
    return math.floor(tunable("puzzle_circuit_press_gap_frames", 10, 2))
end
local function probe_quiet_frames()
    return math.floor(tunable("puzzle_circuit_probe_quiet_frames", 6, 0))
end

local function probe_min_time()
    return tunable("puzzle_circuit_probe_min_time", 5.0, 0)
end

local function describe_buttons(map)
    local parts = {}
    for _, dir in ipairs(CW) do
        local key = map and map[dir] or nil
        parts[#parts + 1] = dir .. "->" .. (key and tostring(key) or "nothing")
    end
    return table.concat(parts, " ")
end

-- Take in what the press we were waiting on actually did. Called once per frame
-- from tick_plan and never from the gate, so the gate stays a question and this
-- stays the only place an observation is recorded.
local function absorb(rec, track)
    if track.pending == nil then return end
    local live = read_state(rec)
    if live == nil then return end

    local now = snapshot_cells(live)
    local moved = changed_cells(track.before, now)
    if #moved == 0 then return end

    local prev = track.before
    local index = track.pending
    local dir = track.dirs[index]
    track.before = now
    track.pending = nil

    if #moved > 1 then
        -- Two cells cannot turn on one press. Either the board was read
        -- mid-update or -- far more often -- a round ended and the next one was
        -- dealt while a press was in flight. Whatever it was, this press did not
        -- cause it, so nothing is recorded: no mapping entry, no spin reading,
        -- no cell promoted to connector.
        --
        -- The old version warned and then took moved[1] anyway. That is where
        -- "the down button turns cell 0,0, which the board does not flag as
        -- rotatable -- counting it as a connector anyway" came from, and where
        -- two buttons ended up pointing at one cell, which quietly leaves a real
        -- connector with no name to answer for it.
        log.warn("puzzle_circuit: pressed " .. tostring(dir) .. " and " .. tostring(#moved)
              .. " cells moved (" .. table.concat(moved, " ") .. "); the board was being"
              .. " rebuilt, so this press is not evidence of anything")
        track.moved[index] = false
        track.unattributed = (track.unattributed or 0) + 1
        if track.kind == "probe" then
            -- A mapping is only worth as much as its worst measurement. Throw
            -- the whole thing away and take it again once the board is still;
            -- rec.probe_attempts still bounds how often that may happen.
            track.spoiled = true
        end
        return
    end

    local key = moved[1]
    track.moved[index] = key

    -- Which way the board turns, from the board itself. Measured here because
    -- this is the one place a press and its result are already lined up, and
    -- the probe -- four presses before anything is described to the peer --
    -- gets the answer in before the first press count is printed.
    local spin = quarter_turn_spin(prev, now, key)
    if spin ~= nil and rec.spin ~= spin then
        rec.spin = spin
        -- The solved targets are in the name cycle and do not move with this;
        -- only the count of presses that reaches them does.
        log.info("puzzle_circuit: a press turns "
              .. (spin > 0 and "clockwise" or "COUNTER-clockwise")
              .. " in this board's frame; press counts follow it")
    end

    -- Did it land where it was aimed? Only worth asking once there is a
    -- measurement to be wrong about; during the probe this IS the measurement.
    if track.kind == "plan" and rec.buttons ~= nil then
        local expected = rec.buttons[dir]
        if expected ~= nil and expected ~= key then
            track.misaimed = { dir = dir, expected = expected, actual = key }
            log.warn("puzzle_circuit: pressed " .. tostring(dir) .. ", which should turn cell "
                  .. tostring(expected) .. ", but cell " .. tostring(key) .. " turned")
            -- Every remaining press in this plan names a connector by the same
            -- mapping that has just been shown to be wrong, so none of them are
            -- sent. Carrying on would be turning connectors at random, which is
            -- what the 2026-09-07 session did for two and a half minutes.
            input.cancel(rec.id)
        end
    end
end

-- A gate that never opened. For the probe that is an answer -- there is no
-- connector on that side. For a plan it is a lost press, and the fix is to send
-- it again rather than carry on as though it had landed.
local function press_timed_out(rec, track, index)
    local previous = index - 1
    local dir = track.dirs[previous]

    if track.kind ~= "probe" then
        if track.retries < track.budget then
            track.retries = track.retries + 1
            log.warn("puzzle_circuit: the " .. tostring(dir)
                  .. " press turned nothing; sending it again")
            return dir
        end
        log.warn("puzzle_circuit: the " .. tostring(dir)
              .. " press turned nothing and the retries are used up")
    end

    track.lost = track.lost + 1
    track.moved[previous] = false
    track.pending = nil
    local live = read_state(rec)
    if live ~= nil then track.before = snapshot_cells(live) end
    return true          -- carry on with the next press
end

-- Queue a run of presses. `kind` is "probe" (measuring which button turns what)
-- or "plan" (carrying out the peer's answer); they differ only in what a press
-- that turns nothing means.
local function start_presses(rec, dirs, kind)
    local state = read_state(rec)
    if state == nil then return false, "the board could not be read" end

    local track = {
        kind    = kind,
        dirs    = dirs,
        before  = snapshot_cells(state),
        pending = nil,
        moved   = {},
        retries = 0,
        budget  = press_retry_budget(),
        lost    = 0,
        settle  = 0,
    }

    local items = {}
    for i, dir in ipairs(dirs) do
        items[i] = {
            command = dir,
            label   = dir,
            -- The first press has nothing to wait for. Every one after it waits
            -- until the press before it has been observed.
            gate = (i > 1) and function() return track.pending == nil end or nil,
            gate_timeout = press_timeout_frames(),
            on_timeout = function(index) return press_timed_out(rec, track, index) end,
        }
    end

    rec.press = track
    local ok, err = input.queue_sequence(items, {
        owner    = rec.id,
        -- The engine's own interval is a floor on how fast it will ACCEPT
        -- input, not on how long a button takes to read as released, and this
        -- puzzle turns a connector on a rising edge only. Take the longer of
        -- the two.
        interval = math.max(input.interval_frames(rec.inst), press_gap_frames()),
        on_step  = function(index, _ok, _label, retry)
            -- A re-press is the same press again, not the next one.
            if retry then return end
            track.pending = index
            -- Drained as presses land, not up front: see puzzle_buttons.lua.
            if kind == "plan" and rec.plan ~= nil then
                rec.plan.executed = index
                table.remove(rec.plan.queue, 1)
            end
        end,
        on_done  = function(done_ok, reason)
            track.done   = true
            track.ok     = done_ok
            track.reason = reason
            track.settle = 0
        end,
    })
    if not ok then rec.press = nil end
    return ok, err
end

-- Observe the run in flight. Returns true once it has finished AND the board
-- has stopped moving, which is the first moment anything may be concluded from
-- it; the finished run is left on rec.finished_press for the caller.
local function press_tick(rec, state)
    local track = rec.press
    if track == nil then return true end

    absorb(rec, track)
    if not track.done then return false end

    -- The engine ripples its connection state in its own update, a frame or
    -- more after the last press lands. Reading it in the same frame is what
    -- reported all seven of the 2026-09-07 session's SUCCESSFUL hacks to the
    -- peer as failures. Its own success trigger ends the wait early.
    local succeeded = state ~= nil and state.success == true
    if succeeded then track.settle = settle_frames() end
    track.settle = track.settle + 1
    if track.settle < settle_frames() then return false end

    -- The LAST press has no press after it to notice that it went missing, so
    -- the settle window doubles as its timeout. Without this the one press most
    -- likely to decide the hack is the one press never re-sent.
    -- For a PROBE, a press that turned nothing is the answer -- there is no
    -- connector on that side -- so re-sending it buys nothing. press_timed_out
    -- already makes that distinction for every press but the last one; the last
    -- one is handled here and used to re-send regardless, which cost two presses
    -- and about a second on every layout whose fourth button turns nothing (all
    -- fifteen of them in the 2026-09-08 capture).
    if track.pending ~= nil and not succeeded and track.kind ~= "probe" then
        local dir = track.dirs[track.pending]
        if track.retries < track.budget then
            track.retries = track.retries + 1
            log.warn("puzzle_circuit: the last press (" .. tostring(dir)
                  .. ") turned nothing; sending it again")
            local ok = input.press_once(dir, { owner = rec.id })
            if ok then
                track.settle = 0
                return false
            end
        end
        log.warn("puzzle_circuit: the last press (" .. tostring(dir)
              .. ") turned nothing and was not recovered")
        track.lost = track.lost + 1
        track.moved[track.pending] = false
    end
    track.pending = nil

    rec.press = nil
    rec.finished_press = track
    return true
end


-- --------------------------------------------------------------------
-- Measuring the buttons
-- --------------------------------------------------------------------
-- Four presses, one per direction, before the peer is told anything. Whichever
-- cell each one turns IS the connector that button addresses -- no deduction,
-- no confidence score, and no way for the answer to be confidently wrong. A
-- button that turns nothing has no connector on that side, which is an answer
-- too.
--
-- It costs four quarter turns and about a third of a second, and it is taken
-- BEFORE the force goes out so the peer plans against the board it is shown. A
-- cell that turns under a press but was never flagged _IsRotatable is added to
-- the connector list: every layout in the 2026-09-07 session showed one more
-- GUI line than rotatable cell, so at least one connector was invisible.
local function finish_probe(rec, track, state)
    if track.spoiled then
        -- The board moved under the measurement. Record nothing and leave
        -- rec.probe_layout alone so probe_ready takes it again on a still board.
        log.warn("puzzle_circuit: the board was rebuilt during the button probe;"
              .. " measuring again once it is still")
        return
    end

    -- Fresh every measurement: the keys are grid positions, and a stale one
    -- from the last layout would make a cell turnable that nothing turns.
    local buttons, extra = {}, {}
    for index, dir in ipairs(track.dirs) do
        local key = track.moved[index]
        if type(key) == "string" then
            buttons[dir] = key
            local cell = nil
            for _, c in ipairs(state and state.cells or {}) do
                if c.key == key then cell = c break end
            end
            if cell ~= nil and cell.rotatable ~= true then
                extra[key] = true
                log.warn("puzzle_circuit: the " .. dir .. " button turns cell " .. key
                      .. ", which the board does not flag as rotatable -- counting it"
                      .. " as a connector anyway")
            end
        end
    end

    -- A probe that named some connectors and not others lost presses: a press
    -- that turns nothing is only an answer ("no connector on that side") when
    -- there is no connector left for it to have turned. On 2026-09-12 a probe
    -- taken straight after a round ended turned one connector out of three,
    -- was accepted, and the other two could not be answered for on every later
    -- visit. Measured again instead, within the same three attempts that bound
    -- every probe; only the last attempt's partial mapping is kept.
    local named, missing = {}, {}
    for _, key in pairs(buttons) do named[key] = true end
    for _, c in ipairs(state and state.cells or {}) do
        if (c.rotatable == true or extra[c.key]) and not named[c.key] then
            missing[#missing + 1] = c.key
        end
    end
    if #missing > 0 and next(buttons) ~= nil then
        if (rec.probe_attempts or 0) < 3 then
            log.warn("puzzle_circuit: the button probe named " .. describe_buttons(buttons)
                  .. " but no button turned " .. table.concat(missing, " ")
                  .. " -- presses were lost; measuring again")
            return
        end
        log.warn("puzzle_circuit: the button probe still leaves " .. table.concat(missing, " ")
              .. " unnamed after three attempts; keeping the partial mapping")
    end

    rec.extra_cells  = extra
    rec.probe_layout = track.layout
    -- A cell promoted to connector here changes what there is to solve, and the
    -- layout fingerprint cannot notice: it is built from _IsRotatable, the very
    -- flag that missed the cell. Throw the cached answer away by hand.
    rec.solution     = nil

    if next(buttons) == nil then
        -- Four presses and nothing moved. That is not a mapping, it is a
        -- failure to press at all, and pretending otherwise would leave every
        -- connector unnameable and the hack unanswerable.
        rec.buttons      = nil
        rec.button_route = "geometry"
        log.warn("puzzle_circuit: no button turned anything -- falling back to the"
              .. " board's geometry for connector names")
        return
    end

    rec.buttons      = buttons
    rec.button_route = "probe"
    log.info("puzzle_circuit: button mapping measured by probe: " .. describe_buttons(buttons))
    if #missing == 0 and track.layout ~= nil then
        local b, e = {}, {}
        for dir, key in pairs(buttons) do b[dir] = key end
        for key in pairs(extra) do e[key] = true end
        _known_buttons[track.layout] = { buttons = b, extra = e }
    end

    -- The names have only now acquired a meaning, so anything described before
    -- this was described wrongly. Ask again.
    P.clear_snapshot(rec)
end

-- False while the mapping is still being measured: nothing may be forced,
-- planned or pressed until it has settled.
local function probe_ready(rec, state)
    if state == nil then return false end
    -- Keyed on where the connectors sit, not on the whole board: which button
    -- turns which connector does not change when a round deals new lines.
    local layout = state.button_layout
    if rec.probe_layout == layout then return true end

    -- The attempt counter is there to stop ONE board blocking a hack forever,
    -- not to run out for the puzzle. It used to carry over, and a multi-round
    -- hack draws a fresh board every round: after the third round the probe
    -- stopped for good and every connector name fell back to the board's
    -- geometry -- the exact defect this file was rewritten to remove. That is
    -- why the 2026-09-08 session solved the early rounds and never the later
    -- ones.
    if rec.probe_attempt_layout ~= layout then
        rec.probe_attempt_layout = layout
        rec.probe_attempts = 0
    end

    if config.puzzle_circuit_probe == false then
        rec.button_route = "geometry"
        rec.probe_layout = layout
        if rec.probe_warned ~= layout then
            rec.probe_warned = layout
            log.warn("puzzle_circuit: mod_config.puzzle_circuit_probe is off -- connector"
                  .. " names come from the board's geometry and are unverified")
        end
        return true
    end

    -- A complete mapping already measured on this arrangement of connectors,
    -- by this record or another one. Copied, so a record that later finds it
    -- wrong cannot edit another record's names in place.
    local known = _known_buttons[layout]
    if known ~= nil then
        local b, e = {}, {}
        for dir, key in pairs(known.buttons) do b[dir] = key end
        for key in pairs(known.extra) do e[key] = true end
        rec.buttons      = b
        rec.extra_cells  = e
        rec.button_route = "remembered"
        rec.probe_layout = layout
        rec.solution     = nil
        log.info("puzzle_circuit: button mapping remembered for these connector positions: "
              .. describe_buttons(b))
        P.clear_snapshot(rec)
        return true
    end

    -- The engine's own answer, when it can be had, costs nothing at all --
    -- but only after it has been checked against the board. An out-parameter
    -- REFramework never wrote back does not come back as an error, it comes
    -- back as whatever was in the register, and two small integers is exactly
    -- what that would look like. Every coordinate has to name a cell that
    -- actually turns, and no two buttons may name the same one.
    local engine = engine_button_cells(rec.inst)
    if engine ~= nil then
        local turnable, seen, bad = {}, {}, nil
        for _, cell in ipairs(state.cells) do
            if cell.turnable then turnable[cell.key] = true end
        end
        for dir, key in pairs(engine) do
            if not turnable[key] then
                bad = dir .. " -> " .. tostring(key) .. ", which is not a connector"
            elseif seen[key] then
                bad = dir .. " -> " .. tostring(key) .. ", which another button already turns"
            end
            seen[key] = true
        end
        if bad ~= nil then
            _b2i.distrusted = true
            _b2i.note = "answered implausibly (" .. bad .. ")"
            log.warn("puzzle_circuit: button2Index " .. _b2i.note
                  .. " -- measuring the buttons by pressing them instead")
            engine = nil
        end
    end
    if engine ~= nil then
        rec.buttons      = engine
        rec.button_route = "engine"
        rec.probe_layout = layout
        log.info("puzzle_circuit: button mapping from the engine: " .. describe_buttons(engine))
        P.clear_snapshot(rec)
        return true
    end

    if state.playing ~= true then return false end

    -- On a timer with barely any left, four presses is the wrong trade.
    if state.timed and type(state.remaining_time) == "number"
        and state.remaining_time < probe_min_time() then
        rec.button_route = "geometry"
        rec.probe_layout = layout
        log.warn(string.format("puzzle_circuit: %.1fs left, too little to measure the"
              .. " buttons -- falling back to the board's geometry", state.remaining_time))
        return true
    end

    -- Every corrupted measurement in the 2026-09-08 capture sits within a few
    -- frames of a lifecycle edge, so wait for the board to hold still before
    -- pressing anything at it. Checked before the attempt is counted: waiting is
    -- not a failed attempt.
    if (rec.quiet_frames or 0) < probe_quiet_frames() then return false end

    -- Never block a hack forever on a probe that will not start.
    rec.probe_attempts = (rec.probe_attempts or 0) + 1
    if rec.probe_attempts > 3 then
        rec.button_route = "geometry"
        rec.probe_layout = layout
        log.warn("puzzle_circuit: the button probe could not be started; falling back to"
              .. " the board's geometry")
        return true
    end

    local ok, err = start_presses(rec, { "up", "right", "down", "left" }, "probe")
    if ok then
        rec.press.layout = layout
        log.info("puzzle_circuit: measuring which button turns which connector")
    else
        log.warn("puzzle_circuit: could not start the button probe: " .. tostring(err))
    end
    return false
end


-- --------------------------------------------------------------------
-- Dispatch
-- --------------------------------------------------------------------
-- What the peer is told at the end of a plan, decided only once the board has
-- stopped moving. The old version read it in the same frame as the final press
-- and reported every one of the 2026-09-07 session's seven SUCCESSFUL hacks as
-- "the rotations were applied but the circuit is not solved" -- the worst
-- possible thing to teach a peer that learns from its own tool results.
local function finish_plan(rec, track, state)
    -- A press turned a connector other than the one it names. Every name in
    -- this plan is therefore suspect, so absorb() stopped the run: the mapping
    -- is thrown away, measured again, and the peer asked again against names
    -- that have been tested. Read before track.ok, because the cancellation
    -- that ended the run is a consequence of this rather than a fault of its
    -- own.
    if track.misaimed ~= nil then
        if rec.button_route == "engine" then
            _b2i.distrusted = true
            log.warn("puzzle_circuit: the engine's button2Index mapping does not match what"
                  .. " the presses do; measuring by pressing from here on")
        end
        -- A remembered mapping that has just been shown wrong must not be
        -- handed to the next record either.
        if rec.probe_layout ~= nil then _known_buttons[rec.probe_layout] = nil end
        rec.buttons, rec.probe_layout, rec.button_route = nil, nil, nil
        rec.probe_attempts = 0
        P.discard(rec)
        P.clear_snapshot(rec)
        P.resolve(rec, false, "The " .. tostring(track.misaimed.dir)
              .. " button turned a different connector, so the rest of the plan was not"
              .. " entered. The connectors are being identified again; ask for a new plan.")
        P.push_event("retrying")
        return
    end

    if track.ok ~= true then
        P.discard(rec)
        if track.reason ~= "superseded" then
            P.resolve(rec, false, "The rotations could not be entered: " .. tostring(track.reason))
            P.push_event("move_failed", { reason = track.reason })
        end
        return
    end

    if state == nil then return end

    -- The engine has it. The lifecycle edge carries the real result to the
    -- peer, so nothing is said here.
    if state.success == true then
        P.discard(rec)
        return
    end
    if state.playing ~= true then return end

    local total = #state.connectors
    if state.connected_count >= total then
        -- Everything the mod can see is closed and the hack still has not
        -- completed. Say that, rather than claiming a success the game has not
        -- given or a failure it has not either.
        P.discard(rec)
        P.clear_snapshot(rec)
        P.resolve(rec, false, "Every connector reads connected but the hack has not"
              .. " completed; there may be a circuit the mod cannot see.")
        return
    end

    -- The sharp case: every connector the whole-board solve named is sitting on
    -- the orientation it asked for, the presses all landed, and the hack did not
    -- complete. The model has been disproved on this layout by the only judge
    -- that counts, so stop offering answers built on it -- read_state drops the
    -- solution while model_bad names this layout -- and write the board down.
    --
    -- Without this the mod simply says the same thing again, which is the loop
    -- the 2026-09-08 sessions spent themselves in.
    if track.lost == 0 and state.solved_whole then
        local on_target, targets = true, 0
        for _, c in ipairs(state.connectors) do
            if c.target ~= nil then
                targets = targets + 1
                if table.concat(c.openings, "+") ~= c.target then on_target = false end
            end
        end
        if targets > 0 and on_target then
            rec.model_bad = state.axis and state.axis.layout or nil
            log.warn("puzzle_circuit: every connector is on the orientation the solve asked"
                  .. " for and the hack did not complete -- the connection model is wrong"
                  .. " on this board; press counts fall back and the peer is told so")
        end
    end

    local lost = ""
    if track.lost > 0 then
        lost = string.format(" (%d press%s never registered)",
                             track.lost, track.lost == 1 and "" or "es")
    end
    P.discard(rec)
    P.clear_snapshot(rec)
    P.resolve(rec, false, string.format(
        "The rotations were applied but the circuit is not solved: %d of %d connectors"
        .. " are connected.%s", state.connected_count, total, lost))
end


function M.tick_plan()
    local rec = current_record()
    if rec == nil then return end
    if registry.is_game_paused() then return end

    local state = read_state(rec)
    if state == nil then return end

    -- How long the board has held still. Counted here because tick_plan runs
    -- exactly once per frame, where read_state does not: it is called several
    -- times a frame by the render, the force gate and the debug panel.
    local cells_now = snapshot_cells(state)
    local still = true
    if rec.last_cells == nil then
        still = false
    else
        for key, value in pairs(cells_now) do
            if rec.last_cells[key] ~= value then still = false break end
        end
        if still then
            for key in pairs(rec.last_cells) do
                if cells_now[key] == nil then still = false break end
            end
        end
    end
    rec.last_cells = cells_now
    rec.quiet_frames = still and ((rec.quiet_frames or 0) + 1) or 0

    -- A run of presses in flight owns the frame: nothing is concluded, forced
    -- or dispatched until it has finished and the board has stopped moving.
    if rec.press ~= nil then
        if not press_tick(rec, state) then return end
        local track = rec.finished_press
        rec.finished_press = nil
        local settled = read_state(rec) or state
        if track.kind == "probe" then
            finish_probe(rec, track, settled)
        else
            rec.dispatching = false
            finish_plan(rec, track, settled)
        end
        return
    end

    -- Which button turns which connector, measured, before anything is
    -- described to the peer or pressed on its behalf.
    if not probe_ready(rec, state) then return end

    if rec.plan == nil then return end

    if rec.plan.parked then
        rec.plan.parked = false
        P.push_event("resumed")
    end

    if P.changed(rec, struct_sig(state)) then
        log.info("puzzle_circuit: board changed under the plan; discarding")
        input.cancel(rec.id)
        rec.dispatching = false
        P.discard(rec)
        P.clear_snapshot(rec)
        P.resolve(rec, false, "The circuit changed before the plan could run; replanning.")
        P.push_event("grid_changed")
        return
    end

    if rec.dispatching then return end
    if state.playing ~= true then return end

    local steps = rec.plan.queue
    if #steps == 0 then return end

    -- `steps` is the live queue and is drained as presses land, so the press
    -- order is copied out for the run to observe against.
    local dirs = {}
    for i, direction in ipairs(steps) do dirs[i] = direction end

    rec.dispatching = true
    local ok, err = start_presses(rec, dirs, "plan")
    if not ok then
        rec.dispatching = false
        P.discard(rec)
        P.resolve(rec, false, "Could not drive the circuit: " .. tostring(err))
    end
end


-- --------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------
-- Every cell of the board, verbatim. Written for the one question the logs
-- could not answer: the GUI reported four circuits on every layout of the
-- 2026-09-07 session while the reader found three rotatable cells, and which of
-- the two is wrong is not decidable from a mailbox capture.
-- The whole board as text, for the Num0 dump: every raw value the engine
-- handed over, formatted by board_report, plus what is specific to a dump --
-- the button mapping and where the names came from.
function M.board_dump()
    local rec = current_record()
    local state = read_state(rec)
    if state == nil then return nil end

    local lines = board_report(state)
    table.insert(lines, 2, string.format(
        "buttons via %s: %s   (connectors=%d connected=%d unaddressed=%d)",
        tostring(state.button_route), describe_buttons(state.buttons),
        #state.connectors, state.connected_count, state.unaddressed or 0))
    table.insert(lines, 3, string.format(
        "goal cells marked in the grid: %d;  the engine's _Goals set holds: %s",
        #(state.goals or {}), tostring(state.goals_field)))
    return table.concat(lines, "\n")
end


function M.debug_status()
    local rec, active = current_record()
    local track = rec and rec.press or nil
    return {
        kind      = M.kind,
        puzzle_id = rec and rec.id or nil,
        type_name = active and active.type_name or nil,
        state     = read_state(rec),
        plan      = P.status(rec),
        input     = input.status(),
        buttons   = rec and rec.buttons or nil,
        button_route = rec and rec.button_route or nil,
        button_note  = _b2i.note,
        pressing  = track ~= nil and {
            kind    = track.kind,
            pending = track.pending,
            done    = track.done,
            lost    = track.lost,
            retries = track.retries,
        } or nil,
    }
end


return M
