-- Binding for the directional-sequence hacking puzzles.
--
-- Two engine types, one family:
--   app.PuzzleButtonTimingNoRotate -- press the directions in order, untimed
--   app.PuzzleButtonTiming         -- same, but a needle sweeps a dial and each
--                                     press only counts while the needle is
--                                     inside that step's angle window
--
-- They are laid out as a ring of direction prompts around a dial, all visible to
-- the player at once, with a current-step marker. The peer gets the same
-- information as a picture to decode -- util/puzzle_render.lua draws it as a
-- cross of button slots around a centre -- and answers with the order.
--
-- The TIMING is not the peer's job and cannot be. A window a few frames wide is
-- unreachable across a websocket round trip, so the peer supplies the order and
-- bindings/puzzle_input.lua fires each press on a frame the engine will accept,
-- gated on the engine's own "would this press count right now" flag. The peer
-- still has to get the order right, and a wrong order still fails the hack.
--
-- READING THE ORDER. Every force of the 2026-09-11 session told the peer
-- "On screen, in order: 1.?  2.?  3.?", so it guessed, and every guess failed
-- on its first press. The order was read from the GUI parameter's
-- InputCommands, an array of enum values: a value-type element comes back from
-- reflection boxed, and the generic enum reader asked the box for sdk.to_int64
-- first -- which is the box's ADDRESS, a number no direction has. The list the
-- GUI array is built from (updateStatus maps _Buttons to their Command, in
-- order) holds class objects whose Command is an ordinary field and reads as a
-- plain number, so that is now the source, the array the fallback, and a
-- sequence that still does not decode is not put to the peer at all.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local registry = require("pragmata.bindings.puzzle_registry")
local input = require("pragmata.bindings.puzzle_input")
local plan_lib = require("pragmata.bindings.puzzle_plan")
local render = require("pragmata.util.puzzle_render")

local M = {}

M.kind = "buttons"
M.action_name = "pragmata_hack_sequence"
-- A function rather than a string: the wording follows the active group, and
-- the group can be switched for the session from the debug panel.
M.force_query = render.buttons_force_query

local P = plan_lib.new({ kind = "buttons" })

-- Resolving a dangling deferred result on destruction: without this the peer
-- waits forever on a tool call whose puzzle no longer exists.
local store = registry.make_store(function(rec)
    P.resolve(rec, false, "the hack ended before the sequence finished")
end)

-- How long a puzzle may go on reading as unreadable before the peer is told it
-- will not be asked, in reads (about half a second). The first frames after a
-- puzzle opens are routinely empty; saying "could not be read" about those would
-- be a false alarm followed by a force.
local UNREADABLE_GRACE_READS = 30

-- How long a force waits for the GUI parameter to be filled in, in reads. It
-- normally takes one frame; if it never happens on some build, the force goes
-- out after this with the variant taken from the concrete type instead.
local GUI_WAIT_READS = 30


local function tunable(name, default)
    local v = config[name]
    if type(v) == "number" and v >= 0 then return v end
    return default
end


-- --------------------------------------------------------------------
-- Reflection helpers
-- --------------------------------------------------------------------
local function safe(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

-- Managed arrays expose their length differently across REFramework builds.
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

local function list_items(list)
    if list == nil then return nil, 0 end
    local size = registry.to_int(safe(function() return list:get_field("_size") end)) or 0
    local items = safe(function() return list:get_field("_items") end)
    return items, size
end


-- Way enum -> neutral direction string, resolved from the game's own constants.
-- Rebuilt while it is empty, so a lookup made before the type resolved is not
-- latched as "every direction unknown" for the session.
local _way_names = nil
local function way_names()
    if _way_names == nil or next(_way_names) == nil then
        _way_names = {}
        for name, v in pairs(registry.enum_values("app.PuzzleButtonTiming.Way")) do
            _way_names[v] = name:lower()
        end
    end
    return _way_names
end

-- The integer inside whatever reflection handed back for an enum. A field read
-- gives a plain number; an array element may give a box, and for a box value__
-- is the enum while sdk.to_int64 is its address -- so value__ goes first.
local function way_value(v)
    if v == nil then return nil end
    if type(v) == "number" then return v end
    local n = safe(function() return v:get_field("value__") end)
    if type(n) == "number" then return n end
    return registry.to_int(v)
end

local function way_to_direction(value)
    local n = way_value(value)
    if n == nil then return nil end
    local name = way_names()[n]
    if name ~= nil and input.is_direction(name) then return name end
    return nil
end

local function all_known(seq)
    if #seq == 0 then return false end
    for _, d in ipairs(seq) do
        if d == "?" then return false end
    end
    return true
end


-- A shuffle of 0..n-1 that is never the identity for n >= 2, so letter "a" is
-- never simply the first press.
local function shuffled_perm(n)
    local perm = {}
    for i = 1, n do perm[i] = i - 1 end
    if n < 2 then return perm end
    repeat
        for i = n, 2, -1 do
            local j = math.random(i)
            perm[i], perm[j] = perm[j], perm[i]
        end
        local identity = true
        for i = 1, n do
            if perm[i] ~= i - 1 then identity = false; break end
        end
    until not identity
    return perm
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

-- Same thing here: this family has one puzzle live at a time (it belongs to the
-- prop being hacked), so "matched" and "current" coincide.
M.matched_puzzle_id = M.current_puzzle_id

function M.live_puzzle_ids()
    return store.live_ids()
end


-- --------------------------------------------------------------------
-- State
-- --------------------------------------------------------------------
-- Layout fingerprint. The step index and the needle angle are PROGRESS, not
-- structure, so they are deliberately excluded: advancing through the sequence
-- must not read as "the puzzle changed under the plan".
local function struct_sig(state)
    if state == nil then return nil end
    return table.concat({
        "buttons",
        state.timed and "t" or "u",
        tostring(state.total),
        table.concat(state.sequence, ","),
    }, "|")
end
M.struct_sig = struct_sig


-- Reads the puzzle instance first and the GUI parameter object second. The
-- instance fields are authoritative; the GUI param carries the couple of things
-- the instance does not spell out (whether this is the untimed variant, and the
-- per-step angle windows).
local function read_state(rec)
    if rec == nil then return nil end
    local inst = rec.inst
    if not registry.is_alive(inst) then return nil end

    local base = registry.base_state(inst)
    local param = safe(function() return inst:get_field("_ParamBuff") end)

    local function pget(name)
        if param == nil then return nil end
        return safe(function() return param:get_field("<" .. name .. ">k__BackingField") end)
    end

    -- The required order. It is on screen for the player -- the whole ring of
    -- prompts is drawn at once -- so transcribing it is showing the peer the
    -- screen, not handing it a hidden answer.
    --
    -- Two lists hold it. _Buttons is the one the puzzle checks presses against
    -- and the one the GUI array is built from; its Command is a class field and
    -- reads as a number. InputCommands is the GUI's copy, whose elements may
    -- come back boxed. The first list that decodes in full wins.
    local from_buttons = {}
    local items, size = list_items(safe(function() return inst:get_field("_Buttons") end))
    for i = 0, size - 1 do
        local btn = arr_get(items, i)
        local cmd = btn and safe(function()
            return btn:get_field("<Command>k__BackingField")
        end)
        if cmd == nil and btn ~= nil then
            cmd = safe(function() return btn:call("get_Command") end)
        end
        from_buttons[#from_buttons + 1] = way_to_direction(cmd) or "?"
    end

    local from_commands = {}
    local commands = pget("InputCommands")
    if commands == nil and param ~= nil then
        commands = safe(function() return param:call("get_InputCommands") end)
    end
    local command_count = arr_size(commands)
    for i = 0, command_count - 1 do
        from_commands[#from_commands + 1] = way_to_direction(arr_get(commands, i)) or "?"
    end

    -- Neutral names for where the order came from, for the debug panel.
    local sequence, source
    if all_known(from_buttons) then
        sequence, source = from_buttons, "button list"
    elseif all_known(from_commands) then
        sequence, source = from_commands, "on-screen list"
    elseif #from_buttons > 0 then
        sequence, source = from_buttons, "button list (unreadable)"
    elseif #from_commands > 0 then
        sequence, source = from_commands, "on-screen list (unreadable)"
    else
        sequence, source = {}, "nothing to read yet"
    end

    local circle_num = registry.to_int(pget("CircleNum"))
    -- The GUI parameter exists from the first frame but is filled in a frame
    -- later, and until then it holds defaults: CircleNum 0, no commands, and
    -- NoRotateMode false. The 2026-09-11 session forced on exactly that frame,
    -- so the peer was told the untimed puzzle had a timing dial, and the
    -- fingerprint flipped from timed to untimed 10 ms later -- which discards
    -- whatever plan was made against it.
    local gui_ready = (circle_num or 0) > 0 and command_count > 0
    local no_rotate = nil
    if gui_ready then no_rotate = pget("NoRotateMode") end
    if no_rotate == nil then
        -- Without the GUI param, fall back to the concrete type: the untimed
        -- variant is its own subclass.
        no_rotate = (registry.type_name(inst) or ""):find("NoRotate") ~= nil
    end

    local current = registry.to_int(safe(function() return inst:get_field("_Current") end))
    if current == nil then current = registry.to_int(pget("CurrentCircle")) end
    local total = registry.to_int(safe(function() return inst:get_field("_Max") end))
    if total == nil or total == 0 then total = circle_num end
    if total == nil or total == 0 then total = #sequence end

    -- The letters drawn on the buttons. Rolled once per sequence and kept on
    -- the record, so a re-render or a replan of the same puzzle shows the same
    -- letters, and the answer is judged against the letters the peer was shown.
    local sig = table.concat(sequence, ",")
    if rec.perm == nil or rec.perm_sig ~= sig then
        rec.perm, rec.perm_sig = shuffled_perm(#sequence), sig
    end

    local state = {
        kind            = M.kind,
        perm            = rec.perm,
        timed           = no_rotate ~= true,
        sequence        = sequence,
        sequence_source = source,
        readable        = all_known(sequence),
        gui_ready       = gui_ready,
        step            = current or 0,
        step_readable   = current ~= nil,
        total           = total or #sequence,
        inside          = registry.read_bool(inst, "_Inside", false),
        angle           = safe(function() return inst:get_field("_CurrentAngle") end),
        success         = registry.read_bool(inst, "_SuccessTrigger", false),
        failed          = registry.read_bool(inst, "_FailedTrigger", false),
        -- The base class's failed status bit. Watched for a RISING edge only
        -- while a sequence is in flight: whether it stays up after a failure
        -- is not known, and a bit left over from the last attempt must not
        -- fail this one.
        status_failed   = base and base.status_failed or false,
        started         = registry.read_bool(inst, "_StartTrg", false),
        playing         = base and base.playing or nil,
    }
    return state
end


function M.get_state(id)
    local rec = id and store.by_id(id) or current_record()
    return read_state(rec)
end


function M.render_state()
    local state = M.get_state(nil)
    if state == nil then return nil end
    return render.buttons(state)
end


-- --------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------
-- Reported as neutral booleans; the observer edge-tracks them. `changed` and
-- `reset` have no analogue here -- the sequence puzzle has no mutating layout
-- and no partial reset -- so they stay false rather than being faked.
function M.lifecycle()
    local rec = current_record()
    if rec == nil then
        return { started = false, changed = false, reset = false, success = false, failed = false }
    end
    local state = read_state(rec)
    if state == nil then
        return { started = false, changed = false, reset = false, success = false, failed = false }
    end
    return {
        -- Either the family's own start trigger, or the puzzle entering play.
        -- The observer edge-tracks this, so "is playing" rising IS the start.
        started = state.started or state.playing == true,
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
function M.snapshot_force_target(id)
    local rec = store.by_id(id)
    P.snapshot(rec, struct_sig(read_state(rec)))
end

function M.clear_force_snapshot(id)
    P.clear_snapshot(store.by_id(id))
end

function M.struct_changed(id)
    local rec = store.by_id(id)
    return P.changed(rec, struct_sig(read_state(rec)))
end

function M.needs_force(id)
    local rec = store.by_id(id)
    return P.needs_force(rec, struct_sig(read_state(rec)))
end

-- Never an answerless force. A sequence with a "?" in it asks the peer to guess,
-- and a guess fails the hack on its first wrong press -- which is all the
-- 2026-09-11 session's sequence forces ever did. Held back instead, and said
-- once, quietly, so the silence reads as a decision; the player can still enter
-- the sequence by hand, and a read that starts working forces as normal.
function M.force_blocked(id)
    local rec = store.by_id(id)
    if rec == nil then return false end
    local state = read_state(rec)
    if state == nil then return false end
    if state.readable then
        rec.unreadable_reads = nil
        -- Readable, but the GUI parameter may not be filled in yet, and the
        -- timed/untimed reading -- part of the fingerprint the plan is checked
        -- against -- comes from it. Wait for it, briefly and silently.
        if state.gui_ready then
            rec.gui_wait_reads = nil
            return false
        end
        rec.gui_wait_reads = (rec.gui_wait_reads or 0) + 1
        return rec.gui_wait_reads < GUI_WAIT_READS
    end
    rec.unreadable_reads = (rec.unreadable_reads or 0) + 1
    if rec.unreadable_reads >= UNREADABLE_GRACE_READS and rec.unreadable_said ~= true then
        rec.unreadable_said = true
        log.warn("puzzle_buttons: the sequence on puzzle " .. tostring(rec.id)
              .. " could not be read (" .. tostring(state.sequence_source)
              .. "); not forcing")
        return true, "A sequence hack is live, but its directions could not be read "
            .. "from the game, so you are not being asked to guess them. The player "
            .. "can enter it."
    end
    return true
end

function M.has_plan(id)
    return P.has_plan(store.by_id(id))
end

function M.discard_plan(id)
    local rec = store.by_id(id)
    if rec ~= nil then input.cancel(rec.id) end
    P.discard(rec)
end

function M.resolve_plan(id, ok, message)
    return P.resolve(store.by_id(id), ok, message)
end

function M.current_plan_status()
    local rec = current_record()
    return P.status(rec)
end

function M.consume_plan_events()
    return P.consume_events()
end


-- The peer's answer: an ordered list of directions. Validated against what the
-- puzzle actually wants BEFORE anything is pressed -- a wrong-length or
-- unknown-direction reply is refused outright rather than half-pressed, because
-- a partial sequence fails the hack for real.
-- The press order from { distance, direction } entries, one per button, in any
-- order, sorted farthest first. Returns nil and a reason unless
-- the distances run 1..N with none repeated -- a gap or a repeat means the
-- drawing was misread, and pressing a guessed order would fail the hack.
local function order_from_distances(order)
    local by_distance, n = {}, 0
    for _, entry in ipairs(order or {}) do
        if type(entry) ~= "table" then
            return nil, "each entry needs a distance and a direction (got "
                .. tostring(entry) .. ")"
        end
        local dist, dir = tonumber(entry.distance), entry.direction
        if not input.is_direction(dir) then
            return nil, "unknown direction '" .. tostring(dir) .. "'"
        end
        if dist == nil or dist ~= math.floor(dist) or dist < 1 then
            return nil, "distance must be a whole number from 1 up (got "
                .. tostring(entry.distance) .. ")"
        end
        if by_distance[dist] ~= nil then
            return nil, string.format("two buttons were given distance %d; every "
                .. "button is a different distance from 0", dist)
        end
        by_distance[dist] = dir
        n = n + 1
    end
    for d = 1, n do
        if by_distance[d] == nil then
            return nil, string.format("no button was given distance %d; %d buttons "
                .. "sit at distances 1 to %d", d, n, n)
        end
    end
    local steps = {}
    for d = n, 1, -1 do steps[#steps + 1] = by_distance[d] end
    return steps
end

-- The press order from a letter answer: one entry per letter drawn, in any
-- order. Every letter exactly once; then the half the peer did not give comes
-- from the drawing itself -- for "side", each letter's real distance -- and the
-- presses are sorted farthest first. For "both" the given distances go through
-- order_from_distances, so a misread distance is refused, not guessed at.
local LETTER_NEEDS = { both = ", a distance and a direction", side = " and a direction" }

local function order_from_letters(form, entries, sequence, perm)
    local truth = render.letter_truth(sequence, perm)
    local given = {}
    for _, entry in ipairs(entries or {}) do
        if type(entry) ~= "table" then
            return nil, "each entry needs a button" .. (LETTER_NEEDS[form] or "")
                .. " (got " .. tostring(entry) .. ")"
        end
        local raw = entry.button
        local letter = raw
        if type(raw) == "string" then letter = raw:match("^%s*(.-)%s*$"):lower() end
        if letter == nil or truth[letter] == nil then
            return nil, "unknown button '" .. tostring(raw) .. "'"
        end
        if given[letter] ~= nil then
            return nil, "button " .. letter .. " was given twice"
        end
        given[letter] = entry
    end
    local letters = {}
    for m in pairs(truth) do letters[#letters + 1] = m end
    table.sort(letters)
    for _, m in ipairs(letters) do
        if given[m] == nil then
            return nil, "button " .. m .. " is missing; give every letter in the drawing once"
        end
    end
    if form == "side" then
        local by_distance = {}
        for _, m in ipairs(letters) do
            local dir = given[m].direction
            if not input.is_direction(dir) then
                return nil, "unknown direction '" .. tostring(dir) .. "'"
            end
            by_distance[truth[m].distance] = dir
        end
        local steps = {}
        for d = #letters, 1, -1 do steps[#steps + 1] = by_distance[d] end
        return steps
    end
    local given_pairs = {}
    for _, m in ipairs(letters) do
        given_pairs[#given_pairs + 1] = { distance = given[m].distance, direction = given[m].direction }
    end
    return order_from_distances(given_pairs)
end

function M.set_plan(id, order, resolve)
    local rec = store.by_id(id)
    if rec == nil then return 0, false end

    local steps = {}
    local form = render.buttons_letter_form()
    if form ~= nil and type(order) == "table" and #order > 0 then
        local state = read_state(rec)
        local sorted, why
        if state == nil then
            sorted, why = nil, "the puzzle could not be read"
        else
            sorted, why = order_from_letters(form, order, state.sequence, rec.perm)
        end
        if sorted == nil then
            -- Refused before anything is parked, so a plan already waiting is
            -- left alone. The dispatcher sends one result per call, so this is
            -- the one the peer sees; the handler's own "discarded" is dropped.
            log.info("puzzle_buttons: letter answer for puzzle " .. tostring(id)
                  .. " refused -- " .. why)
            if resolve ~= nil then
                pcall(resolve, false, "Nothing was pressed: " .. why .. ".")
            end
            return 0, false
        end
        steps = sorted
        log.info("puzzle_buttons: letter answer sorted into " .. table.concat(steps, ","))
    elseif form ~= nil then
        -- No entries at all: nothing to press, which the plan layer reports.
        steps = {}
    else
        for _, d in ipairs(order or {}) do
            if input.is_direction(d) then steps[#steps + 1] = d end
        end
    end

    local cur = current_record()
    local queued, parked = P.set_plan(rec, steps, resolve, cur ~= nil and cur.id == rec.id)
    log.info("puzzle_buttons: plan for puzzle " .. tostring(id) .. " -- "
          .. tostring(queued) .. " presses, parked=" .. tostring(parked))
    return queued, parked
end


-- --------------------------------------------------------------------
-- Dispatch
-- --------------------------------------------------------------------
-- What was pressed, for the peer's tool result when the game rejects a
-- sequence. With a drawing only the presses: the directions asked for would
-- hand back the answer the picture leaves the peer to decode. A list states
-- them anyway, so there each press is shown against its step -- in the word
-- shown on screen, so a compass list says "asked north".
local function run_summary(run)
    local parts = {}
    local with_asked = not render.buttons_as_cross()
    for k = 1, run.sent do
        parts[#parts + 1] = tostring(run.dirs[k])
            .. (with_asked and "(asked " .. tostring(render.buttons_shown_word(run.asked[k])) .. ")" or "")
    end
    return #parts > 0 and table.concat(parts, " ") or "nothing yet"
end

-- Watches a sequence in flight. On a failure it stops pressing -- presses sent
-- into a puzzle that has already failed land on whatever it resets to -- and
-- tells the peer what actually happened instead of leaving its call parked
-- until the next plan supersedes it.
local function watch_run(rec, state)
    local run = rec.run
    if run == nil then return end

    local step = state.step
    local went_back = false
    if state.step_readable and run.seen_step ~= nil and step < run.seen_step then
        went_back = not state.success
    end
    if state.step_readable then run.seen_step = step end

    local failed_edge = state.status_failed == true and run.status_failed_at_start ~= true
    if not (state.failed or failed_edge or went_back) then return end

    rec.run = nil
    P.resolve(rec, false, string.format(
        "The game rejected the sequence after press %d of %d. Pressed so far: %s.",
        run.sent, run.total, run_summary(run)))
    input.cancel(rec.id)
end


-- Handing the whole sequence to puzzle_input at once (rather than one press per
-- frame from here) is what makes the timing variant work: the gate is polled
-- every frame inside the input tick, so a press lands on the exact frame the
-- engine says it would count.
function M.tick_plan()
    local rec = current_record()
    if rec == nil then return end
    if rec.plan == nil then return end
    if registry.is_game_paused() then return end

    local state = read_state(rec)
    if state == nil then return end

    -- Resume a plan that was parked while the player was looking elsewhere.
    if rec.plan.parked then
        rec.plan.parked = false
        P.push_event("resumed")
    end

    -- Structural change under a queued plan: the puzzle we described to the peer
    -- is not the puzzle in front of us any more.
    if P.changed(rec, struct_sig(state)) then
        log.info("puzzle_buttons: sequence changed under the plan; discarding")
        input.cancel(rec.id)
        P.discard(rec)
        P.clear_snapshot(rec)
        P.resolve(rec, false, "The sequence changed before the plan could run; replanning.")
        P.push_event("grid_changed")
        return
    end

    if rec.dispatching then
        watch_run(rec, state)
        return
    end
    if state.playing ~= true then return end

    local steps = rec.plan.queue
    if #steps == 0 then return end

    -- Refuse a plan that does not match the puzzle's own step count. Pressing a
    -- short or long sequence is a guaranteed failure, and the peer learns more
    -- from being told why than from watching the hack fail.
    if state.total > 0 and #steps ~= state.total then
        input.cancel(rec.id)
        P.discard(rec)
        P.resolve(rec, false, string.format(
            "The sequence needs exactly %d presses but the plan had %d; nothing was pressed.",
            state.total, #steps))
        return
    end

    -- The peer gives the whole sequence even when part of it is already in (the
    -- render asks it to). Pressing it all again would put the first direction
    -- on a later step, so the steps already entered are skipped.
    local skip = 0
    if state.step > 0 and state.step < #steps then
        skip = state.step
        for _ = 1, skip do table.remove(steps, 1) end
        rec.plan.executed = skip
    end

    local run = {
        dirs   = {},
        asked  = {},
        total  = #steps,
        sent   = 0,
        base   = state.step,
        seen_step = state.step_readable and state.step or nil,
        status_failed_at_start = state.status_failed == true,
        waited = {},
    }
    local landed_wait = tunable("puzzle_sequence_landed_wait_frames", 20)

    local items = {}
    for k, direction in ipairs(steps) do
        run.dirs[k] = direction
        run.asked[k] = state.sequence[skip + k] or "?"

        -- The press before this one has registered: the step counter has moved
        -- past it. A counter that cannot be read, or has not moved after
        -- landed_wait frames, lets the press go anyway -- at worst the old
        -- fixed cadence with a longer gap, never a sequence that stalls.
        local function landed()
            if k == 1 then return true end
            local cur = registry.to_int(safe(function() return rec.inst:get_field("_Current") end))
            if cur == nil or cur >= run.base + (k - 1) then return true end
            run.waited[k] = (run.waited[k] or 0) + 1
            if run.waited[k] <= landed_wait then return false end
            if run.waited[k] == landed_wait + 1 then
                log.warn(string.format(
                    "puzzle_buttons: press %d of %d never showed on the step counter "
                    .. "(still %d after %d frames); sending press %d anyway",
                    k - 1, run.total, cur, landed_wait, k))
            end
            return true
        end

        items[k] = {
            command = direction,
            label   = direction,
            -- Untimed variant: only "the last press landed". Timed variant: that,
            -- and the engine's own _Inside flag saying a press would land inside
            -- the current step's window.
            gate = state.timed and function()
                return landed() and registry.read_bool(rec.inst, "_Inside", false)
            end or landed,
        }
    end

    rec.run = run
    rec.dispatching = true
    local ok, err = input.queue_sequence(items, {
        owner    = rec.id,
        interval = input.interval_frames(rec.inst),
        -- Drain the queue as presses land rather than up front. While the
        -- sequence is in flight has_plan() must stay true, or reconciliation
        -- would decide the puzzle needs planning again and the overlay would
        -- read "idle" through the whole dispatch.
        on_step  = function(index)
            if rec.plan ~= nil then
                rec.plan.executed = skip + index
                table.remove(rec.plan.queue, 1)
            end
            run.sent = index
        end,
        on_done  = function(done_ok, reason)
            rec.dispatching = false
            rec.run = nil
            if done_ok then
                -- The presses are in. Whether the hack SUCCEEDED is the engine's
                -- call, and it arrives as a lifecycle edge -- so leave the
                -- deferred result parked and let the outcome resolve it.
                log.info("puzzle_buttons: sequence dispatched for puzzle " .. tostring(rec.id))
            else
                P.discard(rec)
                if reason ~= "superseded" then
                    P.resolve(rec, false, "The sequence could not be entered: " .. tostring(reason))
                    P.push_event("move_failed", { reason = reason })
                end
            end
        end,
    })
    if not ok then
        rec.dispatching = false
        rec.run = nil
        P.discard(rec)
        P.resolve(rec, false, "Could not drive the sequence: " .. tostring(err))
    end
end


function M.debug_status()
    local rec, active = current_record()
    return {
        kind      = M.kind,
        puzzle_id = rec and rec.id or nil,
        type_name = active and active.type_name or nil,
        state     = read_state(rec),
        plan      = P.status(rec),
        input     = input.status(),
    }
end


return M
