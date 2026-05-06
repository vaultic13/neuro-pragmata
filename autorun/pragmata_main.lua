-- Pragmata mod entrypoint.
--
-- Boots the file-mailbox transport, sends startup + actions/register to the
-- bridge via the Python sidecar, and pumps the inbox each frame to dispatch
-- incoming actions.
--
-- Deploy: copy the contents of mods/pragmata_lua/autorun/ into
-- <Pragmata>/reframework/autorun/.

-- Make pragmata/ submodules requireable. REFramework's autorun dir is on the
-- working path; we add it explicitly to be safe.
package.path = package.path .. ";reframework/autorun/?.lua;./reframework/autorun/?.lua"

local log = require("pragmata.util.log")
local mailbox = require("pragmata.bridge_mailbox")
local dispatcher = require("pragmata.dispatcher")
local gamepad = require("pragmata.bindings.gamepad")
local puzzle_snake = require("pragmata.bindings.puzzle_snake")

-- Dialogue capture binding. Pulls subtitle text from UI/Asset/ui2000/gui/ui2010
-- and forwards each new line to the AI as a silent context message.
require("pragmata.dialogue")

-- Ability state emitters. Polls binding state each frame; emits gauge/scan/
-- overdrive/auto-hack-unlock edges as context updates with appropriate lanes.
require("pragmata.ability_state")

-- World state emitters. Scene transitions, checkpoint reaches, combat start/end.
require("pragmata.world_state")

-- Autonomy nudges. No-op unless mod_config.autonomy_nudges is true; emits
-- in-combat ability hints on the transient lane while enabled.
require("pragmata.autonomy")

-- Hacking observer. Watches the active PuzzleSnake instance for lifecycle
-- triggers; on grid-start emits the rendered grid as a transient context
-- and fires actions/force so the AI peer plans a route automatically.
require("pragmata.hacking_observer")

-- Hacking debug panel (ImGui). Renders under "Pragmata Hacking Debug" in
-- the REFramework menu; shows real-time binding state, trigger field
-- values, instance-cache status, and provides a "send synthetic test grid"
-- button for end-to-end pipeline verification.
require("pragmata.hacking_debug")

-- ====================================================================
-- GUI probe is loaded but DISABLED by default. Re-enable from the
-- in-game ImGui panel (Pragmata Probe -> Enable) when you want to do
-- more discovery, e.g. finding the speaker-name source. The dialogue
-- binding above doesn't depend on this.
-- ====================================================================
require("pragmata.probe_gui")  -- registers UI panel; remains disabled until clicked
-- ====================================================================

log.info("booting")

-- --------------------------------------------------------------------
-- Sanity check
-- --------------------------------------------------------------------

dispatcher.register("pragmata_ping", {
    description = "Sanity check. Confirms the mod, sidecar, and bridge are wired up. Returns 'pong' as the result message.",
    -- Empty Lua tables encode ambiguously in some JSON encoders ([] vs {}).
    -- Plain {type = "object"} avoids that without losing meaning here.
    schema = { type = "object" },
    handler = function(_args)
        log.info("pragmata_ping called")
        return true, "pong"
    end,
})

-- --------------------------------------------------------------------
-- Diana abilities
-- --------------------------------------------------------------------
-- Bindings live in spoiler-isolation under bindings/. Failures at load time
-- shouldn't take down the rest of the mod, so each is loaded via pcall and
-- the corresponding action returns a neutral failure if its binding is nil.

local function load_binding(name)
    local ok, mod = pcall(require, name)
    if not ok then
        log.error("failed to load " .. name .. ": " .. tostring(mod))
        return nil
    end
    return mod
end

local hacking_bind = load_binding("pragmata.bindings.hacking")
local scan_bind = load_binding("pragmata.bindings.scan")
local overdrive_bind = load_binding("pragmata.bindings.overdrive")

dispatcher.register("pragmata_scan", {
    description = "Have Diana scan the environment. Highlights nearby objectives, paths, and (with the Object Scan upgrade) pickups like REM disks, Upgrade Modules, Mods, and Pure Lunum. Fire-and-forget: scan results arrive as separate context updates.",
    schema = { type = "object" },
    handler = function(_args)
        if not scan_bind then return false, "scan binding not loaded" end
        return scan_bind.scan()
    end,
})

dispatcher.register("pragmata_auto_hack", {
    description = "Have Diana auto-hack a target. Consumes part of the hacking gauge to bypass the manual hacking minigame. Requires the Auto-Hack upgrade (unlocked mid-game from the Unit Printer). target_id is optional; if omitted, the currently locked-on target is used. Returns success on precondition pass; actual hack completion will be confirmed via subsequent context updates.",
    schema = {
        type = "object",
        properties = {
            target_id = {
                type = "string",
                description = "Optional. Identifier of the target to hack. Omit to use the currently locked-on target.",
            },
        },
    },
    handler = function(args)
        if not hacking_bind then return false, "hacking binding not loaded" end
        return hacking_bind.auto_hack(args.target_id)
    end,
})

dispatcher.register("pragmata_overdrive", {
    description = "Fire Diana's Overdrive Protocol. An AoE pulse that stuns and exposes the weak points of nearby enemies and grants Hugh a brief energy/Suit Integrity buffer. Requires the hacking gauge to be full. Unlocks during the Sector 1 boss fight.",
    schema = { type = "object" },
    handler = function(_args)
        if not overdrive_bind then return false, "overdrive binding not loaded" end
        return overdrive_bind.trigger()
    end,
})

-- --------------------------------------------------------------------
-- Hacking action
-- --------------------------------------------------------------------
-- The hacking observer fires actions/force on grid-start, listing this
-- action as the only allowed name. The handler validates the returned
-- plan and queues it for cursor-movement dispatch via puzzle_snake.tick_plan.

dispatcher.register("pragmata_hack_plan", {
    description = (
        "Plan a path through the active hacking grid from cursor @ to Goal G.\n"
        .. "Coordinates: (0,0) is TOP-LEFT. x=column (left->right). y=row "
        .. "(top->bottom). 'up' decreases y by 1; 'down' increases y by 1; "
        .. "'left' decreases x by 1; 'right' increases x by 1. The first row "
        .. "is y=0; the last row is y=height-1. You cannot move 'up' from "
        .. "y=0 or 'down' from y=height-1.\n"
        .. "Read the state field carefully — the cursor and goal positions "
        .. "are given there, and the Adjacency block lists which first-moves "
        .. "are legal. Use those positions verbatim; do not infer or guess.\n"
        .. "Avoid # walls, X EraseCode traps, and ~ trail cells. Plan ends on G."
    ),
    schema = {
        type = "object",
        required = { "reasoning", "moves" },
        properties = {
            reasoning = {
                type = "string",
                description = (
                    "Trace your plan one step at a time, copying the cursor "
                    .. "and goal coordinates from the state field exactly. "
                    .. "Format: '1:down(1,2)open; 2:right(2,2)open; 3:down(2,3)G'. "
                    .. "Aim for ~150 chars; one line per move."
                ),
            },
            moves = {
                type = "array",
                items = { ["enum"] = { "up", "down", "left", "right" } },
                minItems = 1,
                maxItems = 32,
            },
        },
    },
    handler = function(args)
        -- Check the observer's stale-plan flag: if the puzzle ended (player
        -- dropped aim, target died) while the AI was generating, this reply
        -- is stale and should be discarded rather than attempted.
        local hacking_observer = package.loaded["pragmata.hacking_observer"]
        local was_stale = false
        if hacking_observer and hacking_observer.on_plan_received then
            was_stale = hacking_observer.on_plan_received()
        end

        local moves = args.moves or {}
        local count = #moves

        if was_stale then
            log.info("pragmata_hack_plan: received plan with " .. tostring(count)
                  .. " moves, but the puzzle ended before the AI responded; discarding")
            return true, ("plan discarded as stale (puzzle ended before reply): "
                       .. tostring(count) .. " moves")
        end

        if count == 0 then
            return true, "empty plan; nothing to dispatch"
        end

        -- Drop any previous in-flight plan before queuing the new one.
        puzzle_snake.clear_plan()

        local queued = puzzle_snake.queue_plan(moves)
        local skipped = count - queued
        log.info(string.format("pragmata_hack_plan: queued %d/%d moves (%d skipped as invalid)",
                               queued, count, skipped))
        return true, string.format("plan dispatched: %d moves queued (%d skipped)",
                                   queued, skipped)
    end,
})

-- --------------------------------------------------------------------
-- Boot + frame loop
-- --------------------------------------------------------------------

local started = false
local last_warn_frame = 0
local frame_counter = 0

re.on_frame(function()
    frame_counter = frame_counter + 1

    if not started then
        if mailbox.ensure_ready() then
            mailbox.send({ command = "startup", game = "Pragmata" })
            mailbox.send({
                command = "actions/register",
                game = "Pragmata",
                data = { actions = dispatcher.action_list() },
            })
            log.info("sent startup + actions/register")
            started = true
        else
            -- Throttle warning so we don't spam the log every frame
            if frame_counter - last_warn_frame > 600 then  -- ~10 sec at 60fps
                log.warn("mailbox dir not ready (create reframework/data/pragmata_mailbox/ and start sidecar)")
                last_warn_frame = frame_counter
            end
        end
        return
    end

    -- Drain inbox: process at most a few messages per frame to avoid hitches.
    for _ = 1, 8 do
        local msg = mailbox.recv()
        if msg == nil then break end
        dispatcher.handle_incoming(msg, mailbox.send)
    end

    -- Drive the gamepad-injection state machine. Cheap when idle (early-out
    -- if queue is empty); does the per-frame button writes when a press is
    -- in flight. (Now mostly unused — left in for general gamepad-mod
    -- use since puzzle dispatch went elsewhere.)
    pcall(gamepad.tick)

    -- Drive the puzzle-snake plan dispatcher. Pulls moves off the queue,
    -- calls Unit.move() with proper cursor-settle timing.
    pcall(puzzle_snake.tick_plan)
end)
