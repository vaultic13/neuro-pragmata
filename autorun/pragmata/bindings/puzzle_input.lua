-- Paced, gated, branch-corrected puzzle input.
--
-- The environmental hacking puzzles read the player's input COMMANDS -- the game
-- declares PuzzleUp / PuzzleDown / PuzzleLeft / PuzzleRight in its own command
-- table -- so the way to drive them is the same way Scan is driven: answer the
-- engine's own "is this command triggered" query for a few frames.
-- bindings/command_input.lua already owns that hook; this module adds what the
-- puzzles need on top of it.
--
-- Three things it adds:
--
--   THE RIGHT BRANCH. The puzzles only ask that question when the player is on
--   a pad. On mouse + keyboard they take a different path entirely and read
--   their own direction flags, which they fill in from the movement vector --
--   so the question is never asked and an injected answer is never heard. That
--   was the original in-game failure: every probe came back "never asked about
--   by the game", which was correct. bindings/puzzle_mouse_mode.lua flips the
--   branch for the frames a press is in flight; see its header for the details.
--
--   PACING. A puzzle refuses input that arrives faster than its own configured
--   interval, so presses are spaced. The interval is read from the game's
--   PuzzleCommonSettingUserdata rather than guessed, falling back to the cadence
--   the snake dispatcher already proved comfortable.
--
--   GATING. The timing variant of the sequence puzzle only accepts a press while
--   a rotating needle is inside a target angle. No AI peer can hit a window that
--   narrow over a websocket, so the peer supplies the ORDER and this module fires
--   each press on a frame the engine will actually accept. A gate that never
--   opens fails the step rather than pressing late and losing the puzzle,
--   unless the caller offers an on_timeout that says what to do instead.
--
--   The circuit family uses the same gate for something else: "has the press
--   before this one actually turned anything yet". That turns an open-loop
--   burst -- which the engine drops presses from while a connector is
--   animating -- into one press at a time, each waiting for its own result.
--
-- Direct writes to the puzzles' _TrgUp/_TrgDown/... fields are deliberately not
-- attempted: those are one-frame trigger fields, which this engine silently
-- drops writes to. Going through the command layer also means the engine runs
-- its own updateTrigger -> updateStatus -> success chain, so the puzzle
-- completes for real instead of being forced into a success state.

local log = require("pragmata.util.log")
local config = require("pragmata.mod_config")
local command_input = require("pragmata.bindings.command_input")
-- Loaded defensively. This module is required unconditionally by
-- pragmata_main, so a puzzle_mouse_mode that cannot resolve its type must
-- degrade to "presses go unheard on mouse + keyboard" rather than take the
-- whole mod down with it.
local mouse_mode
do
    local ok, mod = pcall(require, "pragmata.bindings.puzzle_mouse_mode")
    if ok and type(mod) == "table" then
        mouse_mode = mod
    else
        log.error("puzzle_input: puzzle_mouse_mode failed to load: " .. tostring(mod))
        mouse_mode = {
            suppress = function() return false, "puzzle_mouse_mode did not load" end,
            release  = function() end,
            active   = function() return false end,
            observed = function() return nil end,
            tick     = function() end,
            status   = function() return { installed = false,
                hook_error = "puzzle_mouse_mode did not load" } end,
        }
    end
end

local M = {}

-- Command names as the game declares them.
--
-- Four directions, and only four. The command table also declares
-- PuzzleUpForKeyboard / PuzzleDownForKeyboard / PuzzleLeftForKeyboard /
-- PuzzleRightForKeyboard and PuzzleDecide, and this list used to press the
-- keyboard variants alongside the pad ones, on the reasoning that answering a
-- command nothing queries costs nothing. It does cost nothing -- but those five
-- constants are DEAD. A scan of the whole shipped code section found no
-- reference to any of them outside the command table's own static constructor.
-- Nothing in the game ever asks about them, so nothing here should offer them,
-- and PuzzleDecide in particular must not read as a plausible answer to "which
-- button confirms this puzzle" ever again.
--
-- PuzzleSnakeProgressReset is real, but it is read through
-- app.PlayerCommandUpdater.isDown, which bindings/command_input.lua does not
-- hook -- it only answers app.PlayerInputDriver. Left out rather than offered
-- and then silently ignored.
local COMMANDS = {
    up      = { "PuzzleUp" },
    down    = { "PuzzleDown" },
    left    = { "PuzzleLeft" },
    right   = { "PuzzleRight" },
}

M.DIRECTIONS = { "up", "down", "left", "right" }

function M.is_direction(name)
    return name == "up" or name == "down" or name == "left" or name == "right"
end


-- --------------------------------------------------------------------
-- Cadence
-- --------------------------------------------------------------------
-- Fallback matches bindings/puzzle_snake.lua's proven ~130 ms per input.
local DEFAULT_INTERVAL_FRAMES = 8
-- How long a gated step waits for its window before giving up. Generous: the
-- needle in the timing puzzle takes a second or two per revolution.
local DEFAULT_GATE_TIMEOUT_FRAMES = 420
-- How long to hold the input branch open per press, when mod_config does not
-- say. See mod_config.puzzle_force_button_frames for why it is tunable.
local DEFAULT_SUPPRESS_FRAMES = 6

local _interval_frames = nil

-- The engine's own minimum spacing, in frames. PuzzleCommonSettingUserdata is
-- shared config rather than per-instance, so any puzzle carrying it answers for
-- all of them; the first instance to yield a value settles it for the session.
function M.interval_frames(any_puzzle_inst)
    if _interval_frames ~= nil then return _interval_frames end

    local seconds = nil
    if any_puzzle_inst ~= nil then
        local ok, v = pcall(function()
            local ud = any_puzzle_inst:get_field("<_PuzzleCommonSettingUserdata>k__BackingField")
            if ud == nil then return nil end
            local setting = ud:get_field("_InputSetting")
            if setting == nil then return nil end
            return setting:get_field("_InputEnableInterval")
        end)
        if ok and type(v) == "number" and v > 0 then seconds = v end
    end

    if seconds == nil then
        -- Deliberately NOT cached. Called with no instance (tick's fallback, a
        -- bare press_once) this can only ever return the guess, and caching it
        -- would mean the game's own interval could never be read afterwards --
        -- the first call would decide for the session.
        return DEFAULT_INTERVAL_FRAMES
    end

    -- One extra frame of headroom: landing exactly on the boundary is a coin
    -- flip about whether the engine has already reset its own timer.
    _interval_frames = math.max(2, math.floor(seconds * 60 + 0.5) + 1)
    log.info("puzzle_input: input interval from game = " .. tostring(seconds)
          .. "s (" .. tostring(_interval_frames) .. " frames)")
    return _interval_frames
end


-- --------------------------------------------------------------------
-- Queue
-- --------------------------------------------------------------------
-- Steps are consumed one per accepted frame. `on_step(index, ok, reason)` fires
-- once per step so the caller can track progress; `on_done(ok, reason)` fires
-- once when the queue empties or aborts.
local _queue = {}
local _active = nil
local _cooldown = 0
local _gate_wait = 0
local _owner = nil
local _last_error = nil
local _stats = { pressed = 0, gate_timeouts = 0, busy_frames = 0, repressed = 0 }


local function _finish(ok, reason)
    local job = _active
    _active = nil
    _queue = {}
    _cooldown = 0
    _gate_wait = 0
    _owner = nil
    if job and job.on_done then pcall(job.on_done, ok, reason) end
end


-- Queue a sequence of presses for one owner (a puzzle id). Starting a new
-- sequence abandons any sequence still running -- callers own at most one at a
-- time and a superseded plan should not keep pressing buttons.
--
--   items: array of { command = "up"|"down"|...|"decide", gate = fn|nil,
--                     gate_timeout = frames|nil, on_timeout = fn|nil,
--                     label = string|nil }
--
--   on_timeout(index) is consulted when a gate never opens. Returning a
--   direction re-sends that press, ungated, ahead of this step -- which is how
--   a caller whose gate means "the last press landed" recovers a press the
--   engine dropped. Returning true presses this step anyway; anything else
--   fails the sequence, which is the old and still the default behaviour.
--   opts:  { owner = id, interval = frames|nil, on_step = fn|nil, on_done = fn|nil }
function M.queue_sequence(items, opts)
    opts = opts or {}
    if type(items) ~= "table" or #items == 0 then
        return false, "empty input sequence"
    end
    for _, item in ipairs(items) do
        if COMMANDS[item.command] == nil then
            return false, "unknown puzzle input: " .. tostring(item.command)
        end
    end

    if _active ~= nil or #_queue > 0 then
        _finish(false, "superseded")
    end

    _queue = {}
    for i, item in ipairs(items) do
        _queue[i] = {
            command      = item.command,
            gate         = item.gate,
            gate_timeout = item.gate_timeout or DEFAULT_GATE_TIMEOUT_FRAMES,
            on_timeout   = item.on_timeout,
            label        = item.label,
            index        = i,
        }
    end
    _active = {
        owner    = opts.owner,
        total    = #items,
        done     = 0,
        on_step  = opts.on_step,
        on_done  = opts.on_done,
        interval = opts.interval,
    }
    _owner = opts.owner
    _cooldown = 0
    _gate_wait = 0
    _last_error = nil
    return true, "queued " .. tostring(#items) .. " inputs"
end


function M.press_once(command, opts)
    return M.queue_sequence({ { command = command } }, opts or {})
end


function M.cancel(owner)
    if _active == nil then return false end
    if owner ~= nil and _active.owner ~= owner then return false end
    _finish(false, "cancelled")
    return true
end


function M.busy(owner)
    if _active == nil then return false end
    if owner == nil then return true end
    return _active.owner == owner
end


function M.remaining()
    return #_queue
end


-- --------------------------------------------------------------------
-- Branch
-- --------------------------------------------------------------------
-- Make the puzzle take the branch that reads input commands, for as long as the
-- press we are about to queue is in flight. Called immediately before every
-- queue, including the debug probe's, so the panel keeps testing the real route
-- rather than a parallel one.
--
-- A failure here is logged once and then ignored. Without it the press simply
-- goes unheard on mouse + keyboard, which is exactly where the mod was before;
-- refusing to press at all would be a worse answer than pressing in vain.
local _branch_warned = false

local function force_button_branch()
    if config.puzzle_force_button_mode == false then return end
    local frames = config.puzzle_force_button_frames
    if type(frames) ~= "number" or frames < 1 then frames = DEFAULT_SUPPRESS_FRAMES end
    local ok, err = mouse_mode.suppress(frames)
    if not ok and not _branch_warned then
        _branch_warned = true
        log.warn("puzzle_input: could not force the button input branch ("
              .. tostring(err) .. "); presses may go unheard on mouse + keyboard")
    end
end


-- --------------------------------------------------------------------
-- Tick
-- --------------------------------------------------------------------
-- Called once per frame from pragmata_main, before the family tick_plans.
function M.tick()
    -- Ahead of the early return on purpose: the branch-forcing window counts
    -- down in real frames, and the debug probe queues presses without ever
    -- going through this queue.
    mouse_mode.tick()

    if _active == nil then return end

    local step = _queue[1]
    if step == nil then
        local job = _active
        _active = nil
        _owner = nil
        if job.on_done then pcall(job.on_done, true, "sequence complete") end
        return
    end

    if _cooldown > 0 then
        _cooldown = _cooldown - 1
        return
    end

    -- Timing gate. Poll every frame; the window is only a handful of frames wide
    -- and missing it means the press lands on the wrong step.
    if step.gate ~= nil then
        local ok, open = pcall(step.gate)
        if not ok then
            _stats.gate_timeouts = _stats.gate_timeouts + 1
            _last_error = "gate errored: " .. tostring(open)
            _finish(false, _last_error)
            return
        end
        if open ~= true then
            _gate_wait = _gate_wait + 1
            if _gate_wait > step.gate_timeout then
                _gate_wait = 0
                local action = nil
                if step.on_timeout ~= nil then
                    local ok2, v = pcall(step.on_timeout, step.index)
                    if ok2 then action = v end
                end
                if type(action) == "string" and COMMANDS[action] ~= nil then
                    -- The caller says the press before this one never landed.
                    -- Re-send it UNGATED -- the gate is what is still waiting on
                    -- it, so gating the retry on the same condition would spin.
                    _stats.repressed = _stats.repressed + 1
                    table.insert(_queue, 1, {
                        command      = action,
                        gate         = nil,
                        gate_timeout = step.gate_timeout,
                        on_timeout   = step.on_timeout,
                        label        = (step.label or action) .. " (re-press)",
                        index        = step.index,
                        retry        = true,
                    })
                    return
                end
                if action ~= true then
                    _stats.gate_timeouts = _stats.gate_timeouts + 1
                    _last_error = "the timing window never opened"
                    _finish(false, _last_error)
                    return
                end
                -- action == true: press it anyway, falling through.
            else
                return
            end
        end
    end

    -- command_input is shared with Scan. A busy refusal is a "not this frame",
    -- never a failure -- dropping the step here would silently truncate a plan.
    local names = COMMANDS[step.command]
    local recipe = {
        { trigger = names, down = names },
        { release = names },
    }
    force_button_branch()
    local ok, err = command_input.queue("puzzle_" .. step.command, recipe)
    if not ok then
        _stats.busy_frames = _stats.busy_frames + 1
        _last_error = err
        return
    end

    table.remove(_queue, 1)
    _gate_wait = 0
    _cooldown = _active.interval or M.interval_frames(nil)
    _stats.pressed = _stats.pressed + 1
    _active.done = _active.done + 1
    if _active.on_step then
        pcall(_active.on_step, step.index, true, step.label or step.command,
              step.retry == true)
    end
end


function M.status()
    return {
        busy       = _active ~= nil,
        owner      = _owner,
        remaining  = #_queue,
        done       = _active and _active.done or 0,
        total      = _active and _active.total or 0,
        cooldown   = _cooldown,
        gate_wait  = _gate_wait,
        interval   = _interval_frames or DEFAULT_INTERVAL_FRAMES,
        last_error = _last_error,
        stats      = _stats,
        command_input = command_input.status(),
        mouse_mode = mouse_mode.status(),
    }
end


-- Exposed for the debug panel's manual probe: fire one raw command immediately,
-- outside the queue, so the input route can be tested with nothing else running.
function M.probe(command)
    local names = COMMANDS[command]
    if names == nil then return false, "unknown puzzle input: " .. tostring(command) end
    force_button_branch()
    return command_input.queue("probe_" .. command, {
        { trigger = names, down = names },
        { release = names },
    })
end


function M.command_names(command)
    return COMMANDS[command]
end


return M
