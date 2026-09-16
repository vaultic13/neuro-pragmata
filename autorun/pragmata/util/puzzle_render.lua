-- Renderers for the non-grid hacking puzzles.
--
-- One function per family. Each turns the plain state table its binding produced
-- into the text the AI peer reads in an actions/force. util/snake_render.lua
-- stays as it is -- its vocabulary is specific to the cursor-routing grid and
-- generalising it would only make both jobs harder.
--
-- House rules, same as the grid renderer:
--   * describe what is ON SCREEN, never anything the player cannot see
--   * state the coordinate convention explicitly rather than assuming it
--   * put the routing rules next to the thing they apply to
--   * keep it short; every line is tokens the peer pays for on every hack

local config = require("pragmata.mod_config")

local M = {}

-- --------------------------------------------------------------------
-- Shared bits
-- --------------------------------------------------------------------
local function set_of(list)
    local s = {}
    for _, v in ipairs(list or {}) do s[v] = true end
    return s
end

local function join(list, sep)
    return table.concat(list or {}, sep or ", ")
end

-- A pipe piece drawn from which sides it opens onto. Two openings is the normal
-- case (the engine builds straight and elbow pieces); anything else falls back
-- to a neutral marker rather than a misleading glyph.
local function pipe_glyph(openings)
    local o = set_of(openings)
    local n = 0
    for _ in pairs(o) do n = n + 1 end
    if n == 0 then return "." end
    if n >= 3 then return "+" end
    if n == 1 then
        if o.up then return "^" elseif o.down then return "v"
        elseif o.left then return "<" else return ">" end
    end
    if o.up and o.down then return "|" end
    if o.left and o.right then return "-" end
    if o.up and o.right then return "L" end
    if o.up and o.left then return "J" end
    if o.down and o.right then return "r" end
    if o.down and o.left then return "7" end
    return "?"
end


-- --------------------------------------------------------------------
-- Circuit: turn each connector until it joins its line to the centre
-- --------------------------------------------------------------------
-- Deliberately NOT drawn as a board. The player sees one row per circuit, not a
-- grid of pipe glyphs, and the glyph picture cost tokens on every force while
-- leaving the one fact that decides the answer -- how many presses each
-- connector needs -- for the peer to infer. It is stated outright here instead.
--
-- BOTH ENDS. A connector closes its circuit when it joins its own line --
-- which runs in from a source on the edge of the board -- to the centre. For a
-- round this said "point it at the centre", which is true of a straight piece
-- by accident and false of an elbow: bindings/puzzle_circuit.lua's lit_cells()
-- carries the trace that settled it.
--
-- Opening names are LABELS here, not screen directions. The calibration fixes
-- what "up" means as a grid delta and never as a direction on screen -- the
-- boards are transposed, grid +x runs down the screen -- so they appear only to
-- tell the press counts apart. The peer is asked for a count, which it can act
-- on without knowing which way the grid runs.
function M.circuit(state)
    if state == nil then return "A circuit hack is active." end

    local lines = {}
    local total = #state.connectors
    lines[#lines + 1] = string.format(
        "Circuit hack: %d circuit%s to close, %d of %d already connected. Each one "
        .. "is a line running in from the edge of the board through one connector "
        .. "to the centre, and the connector closes it when it JOINS its line to the "
        .. "centre -- both ends lined up. Pointing at the centre is not enough.",
        total, total == 1 and "" or "s", state.connected_count, total)

    -- What the counts below are worth. The mod works them out from a model of
    -- the wiring, and that model is only as good as the last time the game
    -- contradicted it -- so say which of the three it is rather than printing a
    -- number that looks equally certain in all three cases.
    if state.model_bad then
        lines[#lines + 1] =
            "Note: the last answer left every connector where this reading said it "
            .. "should be and the hack did not complete, so the reading is WRONG on "
            .. "this board. The counts below are withheld; pick from the options on "
            .. "each line and vary what you try."
    elseif state.model_confirmed == false then
        lines[#lines + 1] =
            "Note: the game has not yet flagged any connector on this board as "
            .. "connected, so the mod's reading of the wiring has nothing to check "
            .. "itself against. Treat a press count below as its best reading rather "
            .. "than a certainty, and the alternatives beside it as live options."
    end

    -- The mod only asks when it has something to ask. If it is asking anyway,
    -- its own reading has failed and the peer should be told that outright
    -- rather than handed a page of "leave it alone" under a question.
    if state.stuck then
        lines[#lines + 1] =
            "Careful with this one: every connector below reads as already correct "
            .. "and the hack has still not completed, so one of those readings is "
            .. "wrong. Pick the connector you judge is off and turn it."
    end

    if state.timed and state.remaining_time then
        lines[#lines + 1] = string.format(
            "This one is on a timer: %.1f seconds left. Answer with your best "
            .. "rotation now rather than deliberating.", state.remaining_time)
    end

    lines[#lines + 1] = ""
    for _, c in ipairs(state.connectors) do
        if c.side == nil then
            -- Measured and found unreachable: no button turns it. Saying so is
            -- better than offering a name the answer would be discarded for.
            lines[#lines + 1] = string.format(
                "  (a connector at %s that no button turns -- it cannot be answered for)",
                tostring(c.key))
        else
            local side = c.side
            -- The name IS the button, because that is what was measured. It was
            -- "the connector on the <side> side" before, which sounded like a
            -- fact about the board and was really a fact about the button.
            lines[#lines + 1] = string.format(
                "  %-6s the connector the %s button turns -- call it \"%s\"", side, side, side)

            lines[#lines + 1] = string.format("         opens %s now -- %s",
                #c.openings > 0 and join(c.openings, "+") or "nothing",
                c.connected and "ALREADY CONNECTED, leave it alone" or "not connected")

            if not c.connected then
                if c.presses == 0 then
                    -- Pointing the right way and still not connected: the circuit
                    -- is waiting on something else. Saying "after 1 press: ..."
                    -- here would invite the peer to turn the one connector that
                    -- is already right.
                    lines[#lines + 1] =
                        "         already lined up -- leave it alone; its "
                        .. "circuit is waiting on another connector"
                elseif c.presses ~= nil and c.presses > 0 then
                    local others = {}
                    for turns = 1, 3 do
                        if turns ~= c.presses then
                            others[#others + 1] = string.format("%d -> %s", turns,
                                join(c.previews[turns], "+"))
                        end
                    end
                    lines[#lines + 1] = string.format(
                        "         PRESS %d to close it   (%s)",
                        c.presses, join(others, ", "))
                else
                    lines[#lines + 1] = string.format(
                        "         the mod could not work this one out -- after 1 press: "
                        .. "%s   after 2: %s   after 3: %s",
                        join(c.previews[1], "+"), join(c.previews[2], "+"),
                        join(c.previews[3], "+"))
                end
            end
        end
    end
    lines[#lines + 1] = ""

    -- Deliberately not "clockwise" any more. Which way a press turns is a fact
    -- about this board's frame, and the 2026-09-08 capture has the mod noticing
    -- a board that turned the other way and telling the peer clockwise anyway.
    -- The previews above are computed from the measured direction, so they are
    -- true either way and the peer never has to know which it is.
    lines[#lines + 1] =
        "Answer with `rotations`: name a connector by its side and give the PRESS "
        .. "count from its line above. Each press is a quarter turn and four presses "
        .. "are back where they started, so a count is always 1, 2 or 3, and the "
        .. "openings listed beside each count are what that many presses actually "
        .. "leave it opening onto. Leave out any connector that is already connected "
        .. "-- turning one disconnects it again. Where a line gives no press count, "
        .. "pick the count you judge joins that connector's line to the centre."

    return table.concat(lines, "\n")
end


-- --------------------------------------------------------------------
-- Buttons: press the directions in order
-- --------------------------------------------------------------------
-- Five ways to show the puzzle, chosen as a GROUP by
-- mod_config.puzzle_sequence_group. Each one passed seqbench
-- (reframework/seqbench/, 2026-09-16) with a peer answering without a thinking
-- pass, and the texts below are line-for-line ports of its
-- sequence_texts.py -- change one side and the other stops describing what was
-- tested. The numbers and ids match the bench's:
--
--   1 cross+arms+hints+letters-both  one line per arm with a distance ruler,
--                                    numbered reading steps and a worked
--                                    example; buttons drawn as letters, each
--                                    answered with its direction AND distance
--   2 cross+hints+letters-side       the same on the 2-D cross; each letter
--                                    answered with its direction only
--   3 list+compass+shuffle           the directions written out as compass
--                                    points, numbered entries shown out of order
--   4 list+compass                   compass points, in order
--   5 list                           the original "On screen, in order:" list
--
-- THE DRAWING. 0 is the centre, each arm is a row of button slots, "-" is an
-- empty slot and "*" filler off the cross. Press i of n sits n-i+1 slots out,
-- so the last press is always next to 0 and every distance holds exactly one
-- button. Arms are as long as the sequence: 3 presses draw 7 x 7, 4 draw 9 x 9.
-- Characters are separated by a space (`0 - b -`, not `0-b-`), so each slot is
-- its own token instead of being merged into runs the peer then miscounts.
--
-- LETTERS. A button is drawn as a letter rather than "+", and the letters are a
-- per-puzzle shuffle (state.perm, rolled by the binding), so "a" is never
-- simply the first press. The peer names what each letter is and the binding
-- sorts the presses farthest first; which half of the reading it supplies is
-- the group's letter form. A letter says nothing about press order, which is
-- the point: the peer reads each button on its own instead of carrying an
-- order in its head while it reads.
--
-- COMPASS AND SHUFFLE change only what is shown. The answer is still
-- up/down/left/right, in press order.
local ARM_STEP = { up = { -1, 0 }, down = { 1, 0 }, left = { 0, -1 }, right = { 0, 1 } }
local ARM_ORDER = { "up", "down", "left", "right" }
local DIRECTION_ENUM = { "up", "down", "left", "right" }
local LETTERS = "abcdefghijklmnop"
local COMPASS = { up = "north", down = "south", left = "west", right = "east" }
-- Where an arm line's slots start: #"right 0 ".
local ARM_PREFIX = 8
local GAP = " "

-- Drawn by the same code as the real puzzle, so it can never disagree with the
-- rules it illustrates. One arm holds two buttons with a gap between them, the
-- case a reader most often gets wrong. Its letters are b, c, a.
local EXAMPLE_SEQUENCE = { "right", "up", "right" }
local EXAMPLE_PERM = { 1, 2, 0 }

M.SEQUENCE_GROUPS = {
    { number = 1, id = "cross+arms+hints+letters-both",
      render = "cross", arms = true, hints = true, letters = "both" },
    { number = 2, id = "cross+hints+letters-side",
      render = "cross", arms = false, hints = true, letters = "side" },
    { number = 3, id = "list+compass+shuffle",
      render = "list", compass = true, shuffle = true },
    { number = 4, id = "list+compass",
      render = "list", compass = true },
    { number = 5, id = "list",
      render = "list" },
}
M.SEQUENCE_DEFAULT_GROUP = 1

-- The group for a setting value -- its number or its id -- or nil.
function M.find_sequence_group(value)
    for _, g in ipairs(M.SEQUENCE_GROUPS) do
        if g.number == tonumber(value) or g.id == value then return g end
    end
    return nil
end

-- The active group. Read on every call, not once at load, so a switch from the
-- debug panel takes effect on the next render. An unknown setting falls back to
-- the default and says so once.
local _bad_group_said = nil
function M.sequence_group()
    local g = M.find_sequence_group(config.puzzle_sequence_group)
    if g ~= nil then return g end
    if _bad_group_said ~= tostring(config.puzzle_sequence_group) then
        _bad_group_said = tostring(config.puzzle_sequence_group)
        local ok, log = pcall(require, "pragmata.util.log")
        if ok then
            log.warn("puzzle_sequence_group " .. _bad_group_said .. " is not a group; using "
                .. tostring(M.SEQUENCE_DEFAULT_GROUP))
        end
    end
    return M.SEQUENCE_GROUPS[M.SEQUENCE_DEFAULT_GROUP]
end

-- True when the sequence hack is drawn rather than listed.
function M.buttons_as_cross()
    return M.sequence_group().render ~= "list"
end

-- True when the drawing is one line per arm instead of the 2-D cross.
function M.buttons_arms()
    return M.buttons_as_cross() and M.sequence_group().arms == true
end

-- True when the drawing carries the ruler, numbered steps and worked example.
function M.buttons_hints()
    return M.buttons_as_cross() and M.sequence_group().hints == true
end

-- nil for "+" buttons, else what each letter is answered with: "both"
-- (direction and distance) or "side" (direction only).
function M.buttons_letter_form()
    if not M.buttons_as_cross() then return nil end
    return M.sequence_group().letters
end

function M.buttons_compass()
    return not M.buttons_as_cross() and M.sequence_group().compass == true
end

function M.buttons_shuffle()
    return not M.buttons_as_cross() and M.sequence_group().shuffle == true
end

-- The action's payload key: `buttons` for the letter groups, `order` otherwise.
function M.buttons_answer_field()
    return M.buttons_letter_form() and "buttons" or "order"
end

-- The word shown for a direction: its compass point in the compass groups.
function M.buttons_shown_word(direction)
    if M.buttons_compass() then return COMPASS[direction] or direction end
    return direction
end

local function plural(n, suffix)
    if n == 1 then return "" end
    return suffix or "s"
end

-- A usable permutation of 0..n-1, or the identity.
local function perm_or_identity(perm, n)
    if type(perm) == "table" and #perm == n then return perm end
    local id = {}
    for i = 1, n do id[i] = i - 1 end
    return id
end

-- The letter drawn for each press, in press order.
local function marks_for(sequence, perm)
    local p = perm_or_identity(perm, #sequence)
    local marks = {}
    for i = 1, #sequence do
        local k = p[i] + 1
        marks[i] = LETTERS:sub(k, k)
    end
    return marks
end

-- letter -> { distance = from 0, direction = its arm }. Press i of n sits
-- n-i+1 out.
function M.letter_truth(sequence, perm)
    local n = #sequence
    local truth = {}
    for i, m in ipairs(marks_for(sequence, perm)) do
        truth[m] = { distance = n - i + 1, direction = sequence[i] }
    end
    return truth
end

local function sorted_letters(truth)
    local keys = {}
    for m in pairs(truth) do keys[#keys + 1] = m end
    table.sort(keys)
    return keys
end

-- `ruler` labels the top edge with each column's distance from 0 and the left
-- edge with each row's. One digit per cell keeps the columns aligned; a
-- sequence of ten or more presses wraps the digit, which no round comes near.
local function button_cross(sequence, ruler, marks)
    local n = #sequence
    local arm = math.max(1, n)
    local grid = {}
    for r = -arm, arm do
        local row = {}
        for c = -arm, arm do
            if r == 0 and c == 0 then row[#row + 1] = "0"
            elseif r == 0 or c == 0 then row[#row + 1] = "-"
            else row[#row + 1] = "*" end
        end
        grid[r + arm + 1] = row
    end
    for i, d in ipairs(sequence) do
        local step = ARM_STEP[d]
        -- An unreadable direction has no arm to go on. The binding does not
        -- force such a sequence, so this only guards a render asked for anyway.
        if step == nil then return nil end
        local dist = n - i + 1
        grid[arm + step[1] * dist + 1][arm + step[2] * dist + 1] = marks and marks[i] or "+"
    end
    local lines = {}
    if ruler then
        local head = {}
        for c = -arm, arm do head[#head + 1] = tostring(math.abs(c) % 10) end
        lines[#lines + 1] = "  " .. table.concat(head, GAP)
    end
    for i, row in ipairs(grid) do
        local text = table.concat(row, GAP)
        if ruler then text = tostring(math.abs(i - arm - 1) % 10) .. " " .. text end
        lines[#lines + 1] = text
    end
    return lines
end

-- The same slots as the cross, one line per arm, each read from 0 outward --
-- so every distance is a position along a line and nothing has to be read down
-- a column. The lines share a width, so equal distances line up between arms,
-- and `ruler` puts each slot's distance above it.
local function button_arms(sequence, ruler, marks)
    local n = #sequence
    local arm = math.max(1, n)
    local slots = {}
    for _, d in ipairs(ARM_ORDER) do
        slots[d] = {}
        for k = 1, arm do slots[d][k] = "-" end
    end
    for i, d in ipairs(sequence) do
        if slots[d] == nil then return nil end
        slots[d][n - i + 1] = marks and marks[i] or "+"
    end
    local lines = {}
    if ruler then
        local head = {}
        for k = 1, arm do head[#head + 1] = tostring(k % 10) end
        lines[#lines + 1] = string.rep(" ", ARM_PREFIX) .. table.concat(head, GAP)
    end
    for _, d in ipairs(ARM_ORDER) do
        lines[#lines + 1] = string.format("%-5s 0%s%s", d, GAP, table.concat(slots[d], GAP))
    end
    return lines
end

local function draw(sequence, perm, ruler)
    local marks = M.buttons_letter_form() and marks_for(sequence, perm) or nil
    if M.buttons_arms() then return button_arms(sequence, ruler, marks) end
    return button_cross(sequence, ruler, marks)
end

local LETTER_TASK = {
    both = "For every letter, give its direction and its distance; the mod presses "
        .. "them farthest first.",
    side = "For every letter, give only its direction; the mod knows each distance "
        .. "and presses them farthest first.",
}

-- The reading rules as numbered steps. Only the letter groups draw, so these
-- are the letter wording.
local function hint_steps(form)
    local steps
    if M.buttons_arms() then
        steps = {
            "1. Each line is one arm, named at its start. 0 is the centre. Each letter "
                .. "(a, b, c, ...) is a button, \"-\" is an empty slot.",
            "2. The numbers above the slots are each slot's distance from 0.",
            "3. A letter stands for the direction its line is named for.",
            "4. Its distance is the number above it.",
        }
    else
        steps = {
            "1. 0 is the centre. Each letter (a, b, c, ...) is a button, \"-\" is an empty "
                .. "button slot, \"*\" is filler.",
            "2. The numbers along the top and the left edge are each "
                .. "column's and each row's distance from 0.",
            "3. A letter above 0 is up, below 0 is down, left of 0 is "
                .. "left, right of 0 is right.",
            "4. Its distance is its row number if it is up or down, "
                .. "and its column number if it is left or right.",
        }
    end
    steps[#steps + 1] = "5. Each distance holds exactly one button, and "
        .. (M.buttons_arms() and "a line" or "an arm")
        .. " can hold more than one. " .. LETTER_TASK[form]
    return steps
end

-- The worked example: its drawing, then the reading of it spelled out.
local function example_lines(form)
    local lines = { "Worked example -- NOT this puzzle:" }
    for _, l in ipairs(draw(EXAMPLE_SEQUENCE, EXAMPLE_PERM, true)) do lines[#lines + 1] = l end
    local truth = M.letter_truth(EXAMPLE_SEQUENCE, EXAMPLE_PERM)
    local found, answer = {}, {}
    for _, m in ipairs(sorted_letters(truth)) do
        local t = truth[m]
        found[#found + 1] = string.format("%s is %s at distance %d", m, t.direction, t.distance)
        if form == "both" then
            answer[#answer + 1] = string.format("%s %s %d", m, t.direction, t.distance)
        else
            answer[#answer + 1] = string.format("%s %s", m, t.direction)
        end
    end
    lines[#lines + 1] = "The buttons: " .. join(found, "; ")
        .. ". So the example's answer is " .. join(answer, ", ") .. "."
    return lines
end

local UNREADABLE = "A sequence hack is active, but its directions could not be read."

function M.buttons(state)
    if state == nil then return "A sequence hack is active." end

    local lines = {}
    local n = #state.sequence
    local form = M.buttons_letter_form()

    if M.buttons_as_cross() then
        local drawn = draw(state.sequence, state.perm, true)
        if drawn == nil then return UNREADABLE end
        lines[#lines + 1] = string.format("Sequence hack: %d direction%s must be entered in order, %s.",
            n, plural(n), M.buttons_arms() and "one line per arm" or "drawn as a cross")
        lines[#lines + 1] = ""
        lines[#lines + 1] = "How to read the drawing:"
        for _, l in ipairs(hint_steps(form)) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
        for _, l in ipairs(example_lines(form)) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("This puzzle (%d press%s):", n, plural(n, "es"))
        for _, l in ipairs(drawn) do lines[#lines + 1] = l end
        lines[#lines + 1] = ""
    else
        for _, d in ipairs(state.sequence) do
            if ARM_STEP[d] == nil then return UNREADABLE end
        end
        lines[#lines + 1] = string.format("Sequence hack: %d direction%s must be entered in order.",
            n, plural(n))
        local entries = {}
        for i, d in ipairs(state.sequence) do
            entries[i] = string.format("%d.%s%s", i, M.buttons_shown_word(d),
                i <= (state.step or 0) and "(done)" or "")
        end
        if M.buttons_shuffle() then
            -- Entry i is shown in slot perm[i], so the numbers come out of order.
            local slots = perm_or_identity(state.perm, n)
            local shown = {}
            for i = 1, n do shown[slots[i] + 1] = entries[i] end
            lines[#lines + 1] = "On screen, numbered by press but shown out of order: "
                .. join(shown, "  ")
        else
            lines[#lines + 1] = "On screen, in order: " .. join(entries, "  ")
        end
        if M.buttons_compass() then
            lines[#lines + 1] = "Directions are compass points: north = up, south = down, "
                .. "west = left, east = right. Answer with up/down/left/right."
        end
    end

    if (state.step or 0) > 0 then
        lines[#lines + 1] = string.format(
            "%d of %d already entered. Give the WHOLE sequence from the start "
            .. "anyway -- the plan is checked against the full list.",
            state.step, state.total)
    end

    if state.timed then
        lines[#lines + 1] =
            "This one has a timing dial. You do NOT have to time anything: give "
            .. "the order and each press is fired on a frame the game accepts."
    end

    if form ~= nil then
        lines[#lines + 1] = "Answer with `buttons`: one entry per letter, with its `button` letter and "
            .. (form == "both" and "its `distance` from 0 and its `direction`" or "its `direction`")
            .. ", in any order. It must have exactly " .. tostring(state.total)
            .. " entries, one per letter -- a missing, repeated or unknown letter is refused "
            .. "without pressing anything, because a wrong-length sequence fails the hack outright."
        return table.concat(lines, "\n")
    end

    local how = M.buttons_as_cross() and "farthest button first"
        or M.buttons_shuffle() and "sorted by their numbers, press 1 first"
        or "in sequence"
    lines[#lines + 1] = "Answer with `order` listing every direction, " .. how
        .. ". It must have exactly " .. tostring(state.total) .. " entries -- a short or long "
        .. "answer is refused without pressing anything, because a wrong-length "
        .. "sequence fails the hack outright."

    return table.concat(lines, "\n")
end

-- The force's one-line query.
function M.buttons_force_query()
    local form = M.buttons_letter_form()
    if form ~= nil then
        return "A sequence hack is live. Read each lettered button off the drawing in the "
            .. "state and call pragmata_hack_sequence with "
            .. (form == "both" and "its direction and distance" or "its direction")
            .. " for every letter."
    end
    if M.buttons_as_cross() then
        return "A sequence hack is live. Read the directions off the drawing in the "
            .. "state and call pragmata_hack_sequence with them in order."
    end
    if not (M.buttons_shuffle() or M.buttons_compass()) then
        return "A sequence hack is live. Call pragmata_hack_sequence with the "
            .. "directions in the order shown."
    end
    return "A sequence hack is live. Call pragmata_hack_sequence with the directions "
        .. (M.buttons_shuffle() and "sorted by their numbers" or "in the order shown")
        .. (M.buttons_compass() and ", translated from compass points to up/down/left/right" or "")
        .. "."
end

-- pragmata_hack_sequence's action description, for the active group.
function M.buttons_description()
    local form = M.buttons_letter_form()
    local middle
    if form ~= nil then
        local per = form == "both"
            and ("its `distance` from 0, counted along its arm (1 is next to 0), and its "
                 .. "`direction`. List them in any order -- the mod sorts them and presses "
                 .. "the farthest first")
            or ("its `direction`, the arm it is on. List them in any order -- the mod "
                .. "knows each distance and presses the farthest first")
        middle = "The state field draws the puzzle in characters around a 0 and says how "
            .. "to read it: each letter is a button, pointing the way its arm runs from 0. "
            .. "Give one `buttons` entry per letter: its `button` letter and " .. per
            .. ". Give every letter"
    elseif M.buttons_as_cross() then
        middle = "The state field draws the puzzle in characters around a 0 and "
            .. "says how to read it: each \"+\" is a button pointing the way its arm runs "
            .. "from 0, pressed farthest from 0 first. Decode it and give the order in "
            .. "`order`, from the FIRST press to the last"
    elseif M.buttons_shuffle() then
        middle = "Read the directions out of the state field; they are numbered by press but "
            .. "shown out of order, so sort them by number and give them in `order`, from "
            .. "press 1 to the last"
    else
        middle = "Read the order out of the state field and repeat it in `order`, from the "
            .. "FIRST prompt to the last"
    end
    if M.buttons_compass() then
        middle = middle .. ", translating compass points to directions (north = up, south = down, "
            .. "west = left, east = right)"
    end
    return "Solve the active sequence hack. A ring of direction prompts is on screen "
        .. "and they have to be entered in order.\n"
        .. middle
        .. " -- including any steps the state says are "
        .. "already done, because the plan is checked against the full sequence. It "
        .. "must have exactly as many entries as the state says; a short or long "
        .. "answer is refused without pressing anything, since a wrong-length "
        .. "sequence fails the hack outright.\n"
        .. "Some of these have a timing dial. You do NOT have to time anything and "
        .. "there is no rush on your reply: give the order, and each press is fired "
        .. "on a frame the game will accept."
end

-- pragmata_hack_sequence's schema, for the active group.
function M.buttons_schema()
    local form = M.buttons_letter_form()
    local field = M.buttons_answer_field()
    local items, desc
    if form ~= nil then
        -- Key order is what the peer generates in: the letter first, so every
        -- entry is anchored to a button before anything is read off it.
        local props = { button = { type = "string", description = "the button's letter",
                                   __keyorder = { "type", "description" } } }
        local order = { "button" }
        if form == "both" then
            props.distance = { type = "integer", minimum = 1, maximum = 16,
                               description = "how far the button is from 0, counted along "
                                   .. "its arm; 1 is next to 0",
                               __keyorder = { "type", "minimum", "maximum", "description" } }
            order[#order + 1] = "distance"
        end
        props.direction = { type = "string", ["enum"] = DIRECTION_ENUM,
                            description = "the arm the button is on",
                            __keyorder = { "type", "enum", "description" } }
        order[#order + 1] = "direction"
        props.__keyorder = order
        items = { type = "object", required = order, properties = props,
                  __keyorder = { "type", "required", "properties" } }
        desc = "one entry per letter in the drawing, in any order"
    else
        items = { ["enum"] = DIRECTION_ENUM }
        desc = M.buttons_as_cross() and "every direction decoded from the drawing, farthest button first"
            or M.buttons_shuffle() and "every direction, sorted by its number, press 1 first"
            or "every direction, in the order shown on screen"
    end
    return {
        type = "object",
        required = { field },
        properties = {
            [field] = {
                type = "array",
                minItems = 1,
                maxItems = 16,
                items = items,
                description = desc,
                __keyorder = { "type", "minItems", "maxItems", "items", "description" },
            },
        },
        __keyorder = { "type", "required", "properties" },
    }
end


-- --------------------------------------------------------------------
-- SlidePipe: slide tiles to complete a pipe run
-- --------------------------------------------------------------------
function M.slide(state)
    if state == nil then return "A pipe hack is active." end

    local lines = {}
    lines[#lines + 1] = string.format(
        "Pipe hack (%d x %d sliding tiles). Slide tiles into the empty space "
        .. "until an unbroken pipe runs from S to the goal O.",
        state.width, state.height)

    local by_pos = {}
    for _, cell in ipairs(state.cells or {}) do
        by_pos[cell.y * 1000 + cell.x] = cell
    end
    lines[#lines + 1] = ""
    for y = 0, state.height - 1 do
        local row = {}
        for x = 0, state.width - 1 do
            local cell = by_pos[y * 1000 + x]
            local glyph
            if state.empty and state.empty.x == x and state.empty.y == y then
                glyph = " "
            elseif cell == nil then
                glyph = "."
            elseif cell.is_goal then
                glyph = "O"
            elseif cell.is_start then
                glyph = "S"
            else
                glyph = pipe_glyph(cell.openings)
            end
            row[#row + 1] = glyph
        end
        lines[#lines + 1] = " " .. table.concat(row, " ")
    end
    lines[#lines + 1] = ""

    if state.empty then
        lines[#lines + 1] = string.format(
            "The empty space is at (%d, %d). (0,0) is TOP-LEFT; x runs left to "
            .. "right, y runs top to bottom.", state.empty.x, state.empty.y)
    end
    lines[#lines + 1] =
        "Each move names the direction the EMPTY SPACE travels -- 'up' pulls the "
        .. "tile above it down into the gap. A move that would push the empty "
        .. "space off the board does nothing, so keep it inside the grid."
    lines[#lines + 1] =
        "Glyphs: | - L J r 7 are pipe tiles drawn by which sides they open onto, "
        .. "S the source, O the goal, a blank the empty space."

    return table.concat(lines, "\n")
end


-- --------------------------------------------------------------------
-- ThroughThePath: rotate rows to open a route
-- --------------------------------------------------------------------
function M.path(state)
    if state == nil then return "A path hack is active." end

    local lines = {}
    lines[#lines + 1] = string.format(
        "Path hack (%d x %d). Rotate whole rows until an unbroken path runs "
        .. "across the board.", state.width, state.height)

    local by_pos = {}
    for _, cell in ipairs(state.cells or {}) do
        by_pos[cell.y * 1000 + cell.x] = cell
    end
    lines[#lines + 1] = ""
    for y = 0, state.height - 1 do
        local row = {}
        for x = 0, state.width - 1 do
            local cell = by_pos[y * 1000 + x]
            row[#row + 1] = cell and pipe_glyph(cell.openings) or "."
        end
        local mark = ""
        for _, r in ipairs(state.rotatable_rows or {}) do
            if r == y then mark = "  <- rotatable" end
        end
        lines[#lines + 1] = string.format(" row %d  %s%s", y, table.concat(row, " "), mark)
    end
    lines[#lines + 1] = ""

    if #(state.rotatable_rows or {}) > 0 then
        local names = {}
        for _, r in ipairs(state.rotatable_rows) do names[#names + 1] = tostring(r) end
        lines[#lines + 1] = "Rotatable rows: " .. join(names, ", ") .. "."
    end
    lines[#lines + 1] =
        "Answer with `rotations`, each naming a row and how many quarter turns to "
        .. "give it (1, 2 or 3). Rows are numbered from 0 at the top."
    lines[#lines + 1] =
        "Glyphs: | - L J r 7 are path pieces drawn by which sides they open onto, "
        .. ". an empty cell."

    return table.concat(lines, "\n")
end


-- Fallback for a family that resolved but has no renderer, and for the case
-- where a read failed mid-hack. Never leaves the peer with an empty state field.
function M.unknown(kind_label)
    return "A " .. tostring(kind_label or "hack") .. " is active, but its board "
        .. "could not be read this frame."
end


return M
