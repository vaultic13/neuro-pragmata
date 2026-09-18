-- Report the puzzles' mouse-input mode as OFF for the few frames the mod is
-- injecting a press.
--
-- WHY THIS EXISTS
--
-- The environmental puzzles read input through one of two completely different
-- routes, and which one they take depends on how the PLAYER is playing:
--
--   app.PuzzleBase.getMouseMoveMode() == false  (pad)
--       PuzzleCircuit.updatePuzzleInput / PuzzleButtonTiming.updateInput ask
--       app.PlayerInputDriver.isTrigger(PuzzleUp|PuzzleDown|PuzzleLeft|
--       PuzzleRight). This is the route bindings/command_input.lua answers, and
--       the same one Scan uses.
--
--   app.PuzzleBase.getMouseMoveMode() == true   (mouse + keyboard)
--       The puzzle asks NOTHING. Its own _TrgUp/_TrgLeft/_TrgRight/_TrgDown
--       flags are written from the ordinary movement vector -- read as
--       app.PlayerCommandUpdater.getVec2("Move") and thresholded at +-0.5 --
--       and the input branch just reads those flags back.
--
-- On mouse + keyboard the second branch is taken, which is why the Puzzle Debug
-- panel's input probe reported "never asked about by the game" for every
-- direction: it was literally true. Nothing was being asked.
--
-- So rather than fabricate a movement vector, this module makes the puzzle take
-- the branch that DOES ask a question, for exactly as long as we have an answer
-- ready. One hook, one boolean, and every puzzle family ends up on the single
-- input route the mod already knows how to drive.
--
-- SCOPED, NOT GLOBAL. Suppression is requested by bindings/puzzle_input.lua for
-- the duration of one press and lapses on its own. Outside a dispatch the
-- engine's own answer is passed through untouched, so the player's mouse control
-- of the puzzle is unaffected. The enemy grid never comes through here at all --
-- it dispatches by writing _NextMovePosition, not through the command layer.
--
-- Note that getMouseMoveMode() is also called from PuzzleBase.update(), so while
-- suppression is on the base update sees the forced value too. That is the price
-- of the approach; it lasts a handful of frames and reverses itself.

local log = require("pragmata.util.log")

local M = {}

local TD_BASE = "app.PuzzleBase"
local SIGNATURE = "getMouseMoveMode()"

-- A press is queued on one frame and injected on the two after it. Six frames
-- covers that with headroom, which is the right side to err on: suppressing a
-- few frames too long is invisible, suppressing one frame too few means the
-- press lands on the branch that ignores it.
local DEFAULT_SUPPRESS_FRAMES = 6

local _state = {
    initialized = false,
    error = nil,
    method = nil,
    installed = false,
    hook_error = nil,
}

-- `fired` is not decoration. Without it, "the hook was never installed or the
-- call was inlined away" and "mouse mode was already false" look identical from
-- the outside -- which is exactly the trap the Overdrive investigation fell into
-- once already. A climbing `fired` proves we are in the call path.
local _frame = 0
local _until = -1
local _fired = 0
local _forced = 0
local _observed = nil
-- Set while M.query() is asking on the debug panel's behalf. Our own calls must
-- neither be counted nor answered falsely: a `fired` that the panel drives
-- itself would prove nothing about the engine's call path, which is the only
-- thing that counter is for.
local _self_query = false


local function safe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end


-- sdk.hook post callbacks must return the ABI value of the method, not a Lua
-- boolean -- same reasoning (and same idiom) as bindings/command_input.lua.
local function bool_return(value)
    local pointer = safe(function() return sdk.to_ptr(value and 1 or 0) end)
    return pointer ~= nil and pointer or (value and 1 or 0)
end


local function to_bool(value)
    if type(value) == "boolean" then return value end
    if value == nil then return nil end
    local n = safe(function() return sdk.to_int64(value) end)
    if type(n) == "number" then return n ~= 0 end
    return nil
end


local function resolve()
    if _state.initialized then return _state.error == nil end
    _state.initialized = true

    local td = safe(function() return sdk.find_type_definition(TD_BASE) end)
    if td == nil then
        _state.error = TD_BASE .. " type definition unavailable"
        return false
    end
    _state.method = safe(function() return td:get_method(SIGNATURE) end)
    if _state.method == nil then
        _state.error = TD_BASE .. "." .. SIGNATURE .. " unavailable"
        return false
    end
    _state.error = nil
    return true
end


local function install()
    if _state.installed then return true end
    if _state.hook_error ~= nil then return false end
    if not resolve() then
        _state.hook_error = _state.error
        return false
    end

    local ok, err = pcall(function()
        sdk.hook(_state.method,
            function(args) end,
            function(retval)
                if _self_query then
                    local seen = to_bool(retval)
                    if seen ~= nil then _observed = seen end
                    return retval
                end
                _fired = _fired + 1
                -- Only record what the engine really thinks while we are not
                -- lying to it, or observed() would just echo our own answer.
                if _frame > _until then
                    local seen = to_bool(retval)
                    if seen ~= nil then _observed = seen end
                    return retval
                end
                _forced = _forced + 1
                return bool_return(false)
            end)
    end)
    if not ok then
        _state.hook_error = tostring(err)
        log.warn("puzzle_mouse_mode: hook failed: " .. tostring(err))
        return false
    end
    _state.installed = true
    log.info("puzzle_mouse_mode: hook installed on " .. TD_BASE .. "." .. SIGNATURE)
    return true
end


-- Report mouse mode as off for the next `frames` frames. Installing the hook on
-- first use rather than at load keeps the cost at zero for a session that never
-- touches an environmental puzzle.
function M.suppress(frames)
    if not install() then return false, _state.hook_error or _state.error end
    local n = tonumber(frames) or DEFAULT_SUPPRESS_FRAMES
    if n < 1 then n = 1 end
    -- Extend rather than replace: a second press queued while the first is
    -- still in flight must not shorten the window the first one is relying on.
    local target = _frame + n
    if target > _until then _until = target end
    return true
end


function M.release()
    _until = -1
end


-- Ask the engine which branch this puzzle is on, for the debug panel.
--
-- Goes through here rather than through puzzle_registry so the hook can tell our
-- question apart from the engine's own: a self-query is never counted and never
-- answered falsely, so `fired` keeps meaning "the engine reached this hook" even
-- while the panel is reading every frame.
function M.query(inst)
    if inst == nil then return nil end
    -- Installing here as well as in suppress() means the panel shows the hook's
    -- real state before the first press is ever sent.
    install()
    if _state.method == nil then return nil end
    _self_query = true
    local value = safe(function() return _state.method:call(inst) end)
    _self_query = false
    if value == nil then return nil end
    return value == true
end


function M.active()
    return _frame <= _until
end


-- What the engine answers when we are not interfering, or nil if it has not
-- been asked yet this session. TRUE here on mouse + keyboard is the whole
-- reason this module exists.
function M.observed()
    return _observed
end


function M.tick()
    _frame = _frame + 1
end


function M.status()
    resolve()
    return {
        installed     = _state.installed,
        resolve_error = _state.error,
        hook_error    = _state.hook_error,
        active        = M.active(),
        frames_left   = math.max(0, _until - _frame),
        fired         = _fired,
        forced        = _forced,
        observed      = _observed,
    }
end


return M
