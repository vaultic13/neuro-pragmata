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
local config = require("pragmata.mod_config")
local gamepad = require("pragmata.bindings.gamepad")
local puzzle_snake = require("pragmata.bindings.puzzle_snake")

-- Dialogue capture binding. Pulls subtitle text from UI/Asset/ui2000/gui/ui2010
-- and forwards each new line to the AI as a silent context message.
require("pragmata.dialogue")

-- Collectible-document ("Archive") capture. Forwards the text of a document
-- as a silent context message when one is opened/read, so the AI peer can be
-- asked to read or recall it. Idle until mod_config.archive_gui_path is set (see the
-- discovery instructions in archive.lua / mod_config.lua).
require("pragmata.archive")

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

-- Auto-hack on-screen overlay. Draws a banner over the game while the AI peer
-- is planning/executing a hack so it's clear the AI (not the player) is
-- driving the cursor. Peer name shown comes from mod_config.display_name.
-- Toggle via mod_config.hacking_show_overlay.
require("pragmata.hacking_overlay")

-- Abilities debug panel (ImGui). Renders under "Pragmata Abilities Debug";
-- shows live Scan / Overdrive binding state (singleton + driver capture,
-- gauge, trigger outcomes) and manual trigger buttons for in-game verification.
require("pragmata.abilities_debug")

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

-- Schema is built around the `hacking_require_reasoning` config flag.
-- When true, the peer must emit a step-by-step trace alongside the moves
-- (better grid-solving accuracy, more generation latency). When false,
-- the peer can reply with `moves` alone for faster reaction.
local hack_plan_properties = {
    moves = {
        type = "array",
        items = { ["enum"] = { "up", "down", "left", "right" } },
        minItems = 1,
        maxItems = 32,
    },
}
local hack_plan_required = { "moves" }
if config.hacking_require_reasoning then
    hack_plan_properties.reasoning = {
        type = "string",
        -- Hard cap so a model that can't find a route can't spiral into a
        -- multi-paragraph "let me reconsider…" and time the force out. A compact
        -- per-step trace of even a long path fits well under this.
        maxLength = 700,
        description = (
            "BEFORE the moves, trace ONE route step by step from the cursor in "
            .. "the state. For each move write the cell you land on and what's "
            .. "there, read straight from the grid, e.g. '1:up(2,0)O; 2:right(3,0).; "
            .. "3:right(4,0)O; 4:down(4,1)G'. A step onto # or X is ILLEGAL — pick "
            .. "another direction; never write a # or X step. Be DECISIVE: commit "
            .. "to ONE route and keep it short — do NOT second-guess, restart, or "
            .. "write prose like 'let me reconsider'. If you can't quickly find a "
            .. "safe route through a blue, just take the shortest safe path to G. "
            .. "End on G; the moves array must match the trace exactly."
        ),
    }
    hack_plan_required = { "reasoning", "moves" }
end
-- Pin the SERIALIZED property order so `reasoning` (when present) comes out
-- BEFORE `moves`. The order properties appear in the schema maps to the order
-- the model generates the arguments, and chain-of-thought only works if the
-- trace is generated FIRST — otherwise the moves come straight from the model's
-- reflex and the reasoning is a post-hoc rationalization that doesn't even match
-- them (observed: a correct trace next to a wrong move list). Lua's pairs() order
-- is non-deterministic, so json_encode honors this __keyorder hint. Mirrors the
-- required-order. Backend-agnostic — applies to whatever peer reads the schema.
hack_plan_properties.__keyorder = hack_plan_required

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
        .. "NEVER step on a # (a wall — the cursor just stops), a d (an error "
        .. "node — entering RESETS the whole hack and you lose all progress), or "
        .. "an X (it fails the hack), and never re-enter a ~ trail cell against "
        .. "its arrow. Check "
        .. "EVERY move's destination cell against the grid, not just the first "
        .. "one. Plan ends on G.\n"
        .. "BONUS NODES: blue 'O' nodes are where the damage comes from — a hack "
        .. "that grabs none is nearly useless, so ACTIVELY prefer a SAFE route "
        .. "that passes through one or two O's on the way to G, even a few moves "
        .. "longer. Collect them going forward; do NOT detour out to a blue and "
        .. "double back, since retracing your own path undoes the blues. Hard "
        .. "limits: never step on a # (wall) or d (error node) to reach one - a d "
        .. "resets the whole hack - and only fall back to the shortest path if no "
        .. "O is reachable without crossing a # or d. (Yellow '*' = minor "
        .. "secondary bonus.)"
    ),
    schema = {
        type = "object",
        required = hack_plan_required,
        properties = hack_plan_properties,
    },
    handler = function(args, ctx)
        local moves = args.moves or {}
        local count = #moves

        -- Hand the reply to the observer. It owns the force→reply→target
        -- correlation: the moves are parked on the puzzle the in-flight force
        -- was for and dispatched only while the player is aimed at it (now or
        -- on return). Staleness from a structural change (e.g. a sticky bomb
        -- that mutated the grid while the AI was generating) is caught at
        -- dispatch time by the binding's structural-signature check.
        local hacking_observer = package.loaded["pragmata.hacking_observer"]
        if not (hacking_observer and hacking_observer.on_plan_received) then
            return true, "observer unavailable; plan dropped"
        end

        -- DEFER the action result. The plan executes asynchronously over the
        -- next ~second; its REAL outcome (reached the goal, hit an error node and
        -- reset, stopped at a wall, fell short) is reported as the tool result
        -- via ctx.resolve when the plan resolves — so the AI sees what actually
        -- happened, not a blind "plan applied". The observer stores ctx.resolve
        -- on the puzzle and the binding fires it at the terminal point.
        local applied, info = hacking_observer.on_plan_received(moves, ctx.resolve)
        if not applied then
            -- Couldn't park the plan (puzzle gone / no in-flight force). Resolve
            -- synchronously — there's nothing to wait on.
            log.info("pragmata_hack_plan: " .. tostring(count)
                  .. " moves not applied (" .. tostring(info) .. ")")
            return true, ("plan discarded (" .. tostring(info) .. "): "
                       .. tostring(count) .. " moves")
        end

        local parked = info  -- on success, info is the `parked` bool
        log.info(string.format("pragmata_hack_plan: applied %d moves (parked=%s); "
                            .. "result deferred until the plan resolves",
                               count, tostring(parked)))
        return ctx.defer()
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
