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
local command_input = require("pragmata.bindings.command_input")
local puzzle_snake = require("pragmata.bindings.puzzle_snake")
-- Discovery + input for the hacking puzzles that are NOT the enemy grid.
-- puzzle_registry.preload() below loads every enabled family binding; see the
-- call site for why that cannot wait until a puzzle is sighted.
local puzzle_registry = require("pragmata.bindings.puzzle_registry")
local puzzle_input = require("pragmata.bindings.puzzle_input")
-- pragmata_enviro_hack_sequence's definition, which follows the sequence group.
local sequence_action = require("pragmata.sequence_action")

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

-- Game-state reporting: the formatter behind the read-only state actions
-- below, and the observer that pushes area / low-health / new-weapon context
-- (each switchable in mod_config). Required here, at boot, because that is the
-- only time `require` resolves.
local game_state = require("pragmata.game_state")
require("pragmata.game_state_observer")
-- Which actions are available where (e.g. no abilities in the Shelter). Polls
-- place and open menus and re-announces the action list when it changes.
local gates = require("pragmata.action_gates")

-- Autonomy nudges. No-op unless mod_config.autonomy_nudges is true; emits
-- in-combat ability hints on the transient lane while enabled.
require("pragmata.autonomy")

-- Hacking observer. Watches whichever hacking puzzle the player is aimed at --
-- the enemy grid or any of the environmental ones -- for lifecycle edges; on
-- start it emits the rendered puzzle as context and fires actions/force so the
-- AI peer plans automatically. Also carries the player-level outcome backstop
-- that catches a hack finishing while the player has already looked away.
require("pragmata.hacking_observer")

-- Hacking debug panel (ImGui). Renders under "Pragmata Hacking Debug" in
-- the REFramework menu; shows real-time binding state, trigger field
-- values, instance-cache status, and provides a "send synthetic test grid"
-- button for end-to-end pipeline verification.
require("pragmata.hacking_debug")

-- Puzzle debug panel (ImGui). Renders under "Pragmata Puzzle Debug": switches
-- the sequence hack's group for the session, shows the text the peer is sent
-- for the live non-grid puzzle, and toggles puzzle families.
require("pragmata.puzzle_debug")

-- Auto-hack on-screen overlay. Draws a banner over the game while the AI peer
-- is planning/executing a hack so it's clear the AI (not the player) is
-- driving the cursor. Peer name shown comes from mod_config.display_name.
-- Toggle via mod_config.hacking_show_overlay.
require("pragmata.hacking_overlay")

-- Abilities debug panel (ImGui) and the manual ability triggers. Renders under
-- "Pragmata Abilities Debug"; shows live Scan / Overdrive binding state
-- (singleton + driver capture, gauge, scan inventory) and binds F6 / F7 / F8 to
-- Scan / Auto-Hack / Overdrive for in-game verification. Each key calls exactly
-- the binding function the AI peer's action calls, so a working key proves the
-- peer's route rather than a parallel one.
require("pragmata.abilities_debug")

-- Game-state debug panel (ImGui). Renders under "Pragmata State Debug"; shows
-- the raw binding state and the exact peer text for each state action, with
-- F9 snapshotting all of them into a history.
require("pragmata.state_debug")

log.info("booting")

-- --------------------------------------------------------------------
-- Sanity check
-- --------------------------------------------------------------------

-- Developer-only: it does nothing in the game, so the peer does not see it
-- unless mod_config.debug_actions is on.
if config.debug_actions then
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
end

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
-- Scene prompts that wait for the Overdrive button. Loaded before
-- ability_actions so its pcall'd require is a cache hit (boot is the only
-- time `require` resolves).
load_binding("pragmata.bindings.cutscene_prompt")
local ability_actions = load_binding("pragmata.ability_actions")
-- Offers those prompts to the peer as an actions/force for pragmata_overdrive.
load_binding("pragmata.cutscene_prompt_observer")

-- The other puzzle families, loaded here rather than on first sighting because
-- boot is the only time `require` resolves at all: REFramework's module search
-- path carries this directory only while it is loading scripts. The registry
-- pcalls each one and reports a failure as a log line, so a family that cannot
-- load costs its own action and nothing else.
pcall(puzzle_registry.preload)

-- Scanning and re-reading the last scan are one action. scan_memory decides
-- which: a new scan only once the last is mod_config.scan_cache_seconds old;
-- otherwise the results already held, said to be cached. A new scan resolves
-- with what it found (ability_actions.scan), so no second call is needed.
dispatcher.register("pragmata_scan", {
    description = "Have Diana scan the surroundings and report what she finds: each entry gives a name and the distance in metres to every instance the game can place, so '4x Upgrade Components (51 / 63 / 70 / 88 m)' means four separate pickups at those ranges. Items are named from the game's own catalogs; unnamed markers are described by what they are (objective marker, escape hatch, point of interest). Only live markers the game can place are listed; 'cannot be taken yet' means the game currently refuses interaction. "
        .. string.format("If the last scan is under %d s old, no new scan is made and the reply gives the cached results and how old they are.",
            tonumber(config.scan_cache_seconds) or 7),
    short = "Have Diana scan the surroundings and report what she finds, with distances in metres. A scan made a few seconds ago is answered from cache, and the reply says so.",
    schema = { type = "object" },
    available = gates.abilities_available,
    handler = function(_args, ctx)
        if not scan_bind then return false, "scan binding not loaded" end
        if not ability_actions then return false, "ability actions not loaded" end
        return ability_actions.scan(ctx)
    end,
})

-- --------------------------------------------------------------------
-- Game state (read-only)
-- --------------------------------------------------------------------
-- One question the peer can ask about the player, answered synchronously from
-- live game data. It changes nothing in the game, so asking is always safe and
-- costs nothing but the reply. game_state.lua does the formatting and turns a
-- missing binding or an unreadable value into a stated reason rather than an
-- empty success.
--
-- Health, location, weapons, mods and inventory were five actions, and
-- upgrades a sixth. Asked together they are one look at "how are we doing",
-- so they are one action now. Upgrades went: the equipped levels are in the
-- weapons and mods lines, and the rest is what the Shelter's Unit Printer and
-- Firmware Updater show (pragmata_menu_list).
dispatcher.register("pragmata_status", {
    description = "Report Hugh's current state: health (HP, repair kits carried and roughly how much one restores), location (map area, its completion and what is left to collect there), weapons (equipped ones, level as 'Lv current/max', ammo, what each does), equipped mods, equipped hacking mods (what each does, uses left, the hacking style) and inventory (everything held, by the game's item category). Give `category` for just one of them; leave it out for all. Read-only.",
    short = "Report Hugh's health, location, weapons, mods, hacking mods and inventory; `category` picks just one. Read-only.",
    -- `category` is optional: no `required` list, so a call with no arguments
    -- still answers everything, as it did before the argument existed.
    schema = {
        type = "object",
        properties = {
            category = {
                type = "string",
                ["enum"] = game_state.status_categories(),
                description = "Only this part of the status. Leave out for all of them.",
            },
        },
    },
    handler = function(args)
        return game_state.describe_status(type(args) == "table" and args.category or nil)
    end,
})

-- Shelter menus and catalogs, behind two stable actions: pragmata_menu_list
-- and pragmata_menu_info, with the menu as an enum argument
-- (menu_actions.lua). Each module adds its menus -- formatting, gate and, for
-- the printer, its tab cache stay in the module -- and the two actions are
-- registered once all of them have, since the enum is built from them.
local menu_actions = require("pragmata.menu_actions")

-- Firmware Updater, Unit Printer, train mod menu: readable while open.
local shelter_menus_bind = load_binding("pragmata.bindings.shelter_menus")
local shelter_menu_actions = load_binding("pragmata.shelter_menu_actions")
if shelter_menu_actions ~= nil then
    shelter_menu_actions.register(menu_actions, gates, shelter_menus_bind)
end

-- Stamp Club (the Cabin hub's shop tab): readable while that tab is selected.
local stamp_club_bind = load_binding("pragmata.bindings.stamp_club")
local stamp_actions = load_binding("pragmata.stamp_actions")
if stamp_actions ~= nil then
    stamp_actions.register(menu_actions, gates, stamp_club_bind)
end

-- Catalogs (Data Library, Archive, Bot Database, Training Simulations, Earth
-- Memories): readable anywhere in the Shelter (the Archive everywhere), plus
-- the Shelter-only "new entry" pushes.
local catalogs_bind = load_binding("pragmata.bindings.catalogs")
local catalog_actions = load_binding("pragmata.catalog_actions")
if catalog_actions ~= nil then
    catalog_actions.register(menu_actions, gates, catalogs_bind)
end

-- Train sector selection: readable while that screen is open (State Debug
-- F11 also dumps its data).
local sectors_bind = load_binding("pragmata.bindings.sectors")
local sector_actions = load_binding("pragmata.sector_actions")
if sector_actions ~= nil then
    sector_actions.register(menu_actions, gates, sectors_bind)
end

menu_actions.register(dispatcher)

dispatcher.register("pragmata_enemy_auto_hack", {
    description = "Enemies only: have Diana auto-hack the enemy she is currently locked on to. Consumes part of the hacking gauge to bypass the manual hacking minigame. Requires the Auto-Hack upgrade (unlocked mid-game from the Unit Printer). Takes no arguments: the engine's start call has no target parameter, so the lock-on decides the target. Success means the game entered Auto-Hack, not merely that preconditions passed.",
    short = "Enemies only: have Diana auto-hack the enemy she is locked on to, spending part of the hacking gauge. Needs the Auto-Hack upgrade; takes no arguments.",
    -- No target selector. startAutoHack() takes no parameters; the target_id
    -- this used to advertise was resolved and then discarded, so a peer that
    -- sent one got no choice of target AND skipped the "is anything locked on"
    -- refusal.
    schema = { type = "object" },
    available = gates.abilities_available,
    handler = function(_args, ctx)
        if not hacking_bind then return false, "hacking binding not loaded" end
        if not ability_actions then return false, "ability actions not loaded" end
        return ability_actions.auto_hack(ctx)
    end,
})

dispatcher.register("pragmata_overdrive", {
    description = "Fire Diana's Overdrive. Requires a charged gauge and confirms only after the game actually starts the ability and spends the gauge. When a scene has stopped on the Overdrive button prompt, this presses that prompt for the player instead, and confirms once the scene continues.",
    short = "Fire Diana's Overdrive (needs a charged gauge), or press a scene's Overdrive button prompt when one is up.",
    schema = { type = "object" },
    available = gates.overdrive_available,
    handler = function(_args, ctx)
        if not overdrive_bind then return false, "overdrive binding not loaded" end
        if not ability_actions then return false, "ability actions not loaded" end
        return ability_actions.overdrive(ctx)
    end,
})

-- The filament-cleaning button, as a scripted scene asks for it (the
-- Filament Remover scene). Announced only while that prompt is up; the scene
-- prompt observer forces it then.
dispatcher.register("pragmata_purify", {
    description = "Clean the filament: press the filament-cleaning button a scene is waiting for, so the scene carries on. Only available while such a scene prompt is up; confirms once the scene continues.",
    schema = { type = "object" },
    available = gates.purify_available,
    handler = function(_args, ctx)
        if not ability_actions then return false, "ability actions not loaded" end
        return ability_actions.purify(ctx)
    end,
})

-- --------------------------------------------------------------------
-- Hacking action
-- --------------------------------------------------------------------
-- The hacking observer fires actions/force on grid-start, listing this
-- action as the only allowed name. The handler validates the returned
-- plan and queues it for cursor-movement dispatch via puzzle_snake.tick_plan.

-- How a plan reply is answered once the observer has looked at it. Shared by
-- every hacking action.
--
-- Not applied (no hack is waiting, the puzzle is gone): success = true. Nothing
-- went wrong that a retry of the same answer could fix, and a failing result
-- inside a force would make the server ask again for a hack that is not there.
-- The message says plainly that nothing happened.
--
-- Parked (the player looked away before the reply came): answered at once,
-- because the plan may wait longer than the server's ~20 s result window. Its
-- outcome follows as context when it runs.
local NOT_APPLIED = "Nothing was done: "
local NOT_APPLIED_REASONS = {
    ["no in-flight force"] = "no hack is waiting for a plan right now.",
    ["puzzle gone"] = "that hack is no longer there.",
    ["reply does not match the active puzzle"] =
        "this action is for a different kind of hack than the one that asked.",
    ["puzzle binding unavailable"] = "the mod cannot drive this kind of hack.",
}

local function plan_reply(name, ctx, applied, info, what)
    if not applied then
        log.info(name .. ": " .. what .. " not applied (" .. tostring(info) .. ")")
        if info == "plan rejected by the puzzle" then
            -- The binding already sent the reason as the result.
            return true, "plan rejected"
        end
        return true, NOT_APPLIED .. (NOT_APPLIED_REASONS[info] or (tostring(info) .. "."))
    end
    local parked = info  -- on success, info is the `parked` bool
    log.info(string.format("%s: applied %s (parked=%s); result deferred until it resolves",
                           name, what, tostring(parked)))
    if parked and ctx.answer_now ~= nil then
        ctx.answer_now(true, "Plan saved: Hugh is not aimed at that target now, so it "
            .. "runs when he aims at it again. The outcome will follow as context.")
    end
    return ctx.defer()
end

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

dispatcher.register("pragmata_enemy_hack_plan", {
    description = (
        "Enemy hack: plan a path through the hacking grid on the enemy, from cursor @ to Goal G.\n"
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
    short = "Enemy hack: plan the cursor's path through the hacking grid on the enemy to the goal G, as a list of moves. The rules are in the force's state.",
    rules_in_force = true,
    schema = {
        type = "object",
        required = hack_plan_required,
        properties = hack_plan_properties,
    },
    available = gates.hacking_available,
    handler = function(args, ctx)
        local moves = args.moves
        if type(moves) ~= "table" then
            return false, "Give 'moves' as a list of directions (up, down, left, right)."
        end
        local count = #moves

        -- Hand the reply to the observer. It owns the force→reply→target
        -- correlation: the moves are parked on the puzzle the in-flight force
        -- was for and dispatched only while the player is aimed at it (now or
        -- on return). Staleness from a structural change (e.g. a sticky bomb
        -- that mutated the grid while the AI was generating) is caught at
        -- dispatch time by the binding's structural-signature check.
        local hacking_observer = package.loaded["pragmata.hacking_observer"]
        if not (hacking_observer and hacking_observer.on_plan_received) then
            return true, NOT_APPLIED .. "the hacking observer is not loaded."
        end

        -- DEFER the action result. The plan executes asynchronously over the
        -- next ~second; its REAL outcome (reached the goal, hit an error node and
        -- reset, stopped at a wall, fell short) is reported as the tool result
        -- via ctx.resolve when the plan resolves — so the AI sees what actually
        -- happened, not a blind "plan applied". The observer stores ctx.resolve
        -- on the puzzle and the binding fires it at the terminal point.
        local applied, info = hacking_observer.on_plan_received("snake", moves, ctx.resolve, ctx)
        return plan_reply("pragmata_enemy_hack_plan", ctx, applied, info,
                          tostring(count) .. " moves")
    end,
})

-- --------------------------------------------------------------------
-- The other hacking puzzles
-- --------------------------------------------------------------------
-- The enemy grid above is one of five hacking minigames; the rest are on
-- switches, doors and elevators. They share the entry point, the controls and
-- the outcome, and until now the mod could not see them at all.
--
-- One action per family rather than one polymorphic action: the mechanics have
-- nothing in common (turn a piece / press a sequence / slide a tile), so a
-- shared schema would be a union of unrelated fields with a description that
-- contradicted itself half the time. The observer only ever offers the peer the
-- one action that matches the puzzle actually in front of it.
--
-- Each handler follows pragmata_enemy_hack_plan exactly: hand the reply to the
-- observer, which parks it on the puzzle the in-flight force was for, then
-- defer -- so the tool result the peer sees is what the hack actually did.

local function register_puzzle_action(name, kind, payload_key, description, schema, short)
    -- Don't advertise an action for a family this install has switched off: the
    -- observer would never force it, so a peer calling it could only ever be
    -- told there was nothing to plan. `slide` and `path` ship off, which is why
    -- this matters rather than being theoretical.
    local kinds = config.puzzle_kinds or {}
    if kinds[kind] == false then
        log.info("skipping " .. name .. " (mod_config.puzzle_kinds." .. kind .. " is off)")
        return
    end

    dispatcher.register(name, {
        description = description,
        -- With mod_config.action_descriptions = "short", `short` is what the
        -- peer sees and the full text rides on every force as its rules.
        short = short,
        rules_in_force = true,
        schema = schema,
        available = gates.hacking_available,
        handler = function(args, ctx)
            local observer = package.loaded["pragmata.hacking_observer"]
            if not (observer and observer.on_plan_received) then
                return true, NOT_APPLIED .. "the hacking observer is not loaded."
            end
            -- Each family names its payload differently; the observer passes it
            -- straight through to the binding, which is the only thing that
            -- knows how to read it. A function key is resolved per call, for
            -- the sequence hack, whose key follows the group active right now.
            local key = type(payload_key) == "function" and payload_key() or payload_key
            local payload = args[key]
            if type(payload) ~= "table" then
                return false, "Give the answer in '" .. tostring(key)
                    .. "' as a list, as the action's schema describes."
            end
            local applied, info = observer.on_plan_received(kind, payload, ctx.resolve, ctx)
            return plan_reply(name, ctx, applied, info, "the answer")
        end,
    })
end

local DIRECTION_ENUM = { "up", "down", "left", "right" }

register_puzzle_action("pragmata_enviro_hack_rotate", "circuit", "rotations",
    "Solve the active circuit hack, an environment hack (a door, switch or elevator). One to four connectors sit around a centre, "
    .. "each of them one circuit to close. A circuit is a line running in from the "
    .. "edge of the board; its connector closes it when it JOINS that line to the "
    .. "centre, both ends lined up -- pointing at the centre is not enough.\n"
    .. "`piece` names a connector by the direction button that turns it, which the "
    .. "mod measures on the board before describing it. The state field lists every "
    .. "connector under that name, what it opens onto now, and whether it is "
    .. "already connected; use those names verbatim.\n"
    .. "`steps` is how many presses to give that connector: 1, 2 or 3. Most "
    .. "connector lines end in `PRESS n to close it` -- use that "
    .. "number. It is worked out from the board, so it is not a hint to be improved "
    .. "on. Where a line gives no press count instead, the three options are "
    .. "spelled out and the answer is the count you judge joins its line to the "
    .. "centre.\n"
    .. "Leave a connector out of your answer to leave it alone, and leave alone "
    .. "any the state already reports as connected -- turning one disconnects it "
    .. "again. Work out the whole answer before replying; the timed variants do "
    .. "not wait.",
    {
        type = "object",
        required = { "rotations" },
        properties = {
            rotations = {
                type = "array",
                minItems = 1,
                maxItems = 8,
                items = {
                    type = "object",
                    required = { "piece", "steps" },
                    properties = {
                        piece = { type = "string", ["enum"] = DIRECTION_ENUM,
                                  description = "which piece, by its position relative to the centre" },
                        steps = { type = "integer", minimum = 1, maximum = 3,
                                  description = "how many presses to give it" },
                    },
                    __keyorder = { "piece", "steps" },
                },
            },
        },
    },
    "Solve the active circuit hack, an environment hack (a door, switch or elevator), by giving connectors presses, named as the state field names them.")

-- The description, the schema and even the payload key follow the active
-- group (mod_config.puzzle_sequence_group), which the puzzle debug panel can
-- switch for the session; sequence_action.lua owns both the definition and
-- the re-registration a switch needs.
local sequence_def = sequence_action.definition()
register_puzzle_action(sequence_action.ACTION_NAME, "buttons", sequence_action.answer_field,
    sequence_def.description, sequence_def.schema, sequence_def.short)

register_puzzle_action("pragmata_enviro_hack_slide", "slide", "moves",
    "Solve the active pipe hack, an environment hack (a door, switch or elevator). Tiles slide into a single empty space; the hack "
    .. "completes when an unbroken pipe runs from the source S to the goal O.\n"
    .. "Each move names the direction the EMPTY SPACE travels, so 'up' pulls the "
    .. "tile above the gap down into it. (0,0) is TOP-LEFT: x runs left to "
    .. "right, y runs top to bottom. A move that would push the empty space off "
    .. "the board does nothing, so keep every move inside the grid and track "
    .. "where the gap ends up after each one.",
    {
        type = "object",
        required = { "moves" },
        properties = {
            moves = {
                type = "array",
                minItems = 1,
                maxItems = 24,
                items = { ["enum"] = DIRECTION_ENUM },
                description = "directions the empty space travels, in order",
            },
        },
    },
    "Solve the active pipe hack, an environment hack (a door, switch or elevator): move the empty space until a pipe runs from S to O.")

register_puzzle_action("pragmata_enviro_hack_path", "path", "rotations",
    "Solve the active path hack, an environment hack (a door, switch or elevator). Pieces on a board are turned until an unbroken "
    .. "path runs across it.\n"
    .. "Pieces are addressed by COLUMN, numbered from 0 at the left; the state "
    .. "field says which columns can be turned. `steps` is how many QUARTER "
    .. "TURNS to give that column's piece: 1, 2 or 3. The selection is walked to "
    .. "each column for you, so list them in whatever order makes sense.",
    {
        type = "object",
        required = { "rotations" },
        properties = {
            rotations = {
                type = "array",
                minItems = 1,
                maxItems = 12,
                items = {
                    type = "object",
                    required = { "column", "steps" },
                    properties = {
                        column = { type = "integer", minimum = 0, maximum = 15,
                                   description = "column index, 0 at the left" },
                        steps  = { type = "integer", minimum = 1, maximum = 3,
                                   description = "quarter turns" },
                    },
                    __keyorder = { "column", "steps" },
                },
            },
        },
    },
    "Solve the active path hack, an environment hack (a door, switch or elevator), by giving columns quarter turns until a path runs across the board.")


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
            -- Only the actions available now; action_gates re-announces as
            -- the player moves in and out of places that change the set.
            dispatcher.announce_all()
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

    -- Answer any deferred result that is about to outlive the server's
    -- ~20 s window (dispatcher.lua, "THE 20-SECOND RULE").
    pcall(dispatcher.tick)

    -- Drive Scan's command input. This injects into the game's own
    -- app.PlayerInputDriver queries; it writes no controller, no OS keyboard
    -- state, and no visible device.
    pcall(command_input.tick)

    -- Drive the other puzzles' input. Sits on top of the same command layer and
    -- paces presses to the interval the game itself accepts, holding a press
    -- back until the timing window is open where a puzzle has one. It goes
    -- BEFORE the plan dispatchers so a press queued this frame is spaced from
    -- the last one rather than doubling up.
    --
    -- It also counts down the window in which those puzzles are made to read
    -- the command layer at all: on mouse + keyboard they otherwise take a
    -- branch that asks nothing. Unconditional, not only while a press is
    -- queued, because the debug probe queues presses of its own.
    pcall(puzzle_input.tick)

    -- Drive the puzzle-snake plan dispatcher. Pulls moves off the queue,
    -- writes the next cell with proper cursor-settle timing.
    pcall(puzzle_snake.tick_plan)

    -- Drive every other family. They are all loaded at boot, so this list is
    -- the set of families this install has enabled -- each tick_plan returns
    -- immediately unless a puzzle of that family is live and carrying a plan.
    for _, entry in ipairs(puzzle_registry.loaded_bindings()) do
        if entry.kind ~= "snake" then
            pcall(entry.mod.tick_plan)
        end
    end
end)
