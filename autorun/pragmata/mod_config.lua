-- User-tunable mod configuration.
--
-- Edit this file in the deployed mod (reframework/autorun/pragmata/) to change
-- behavior without rebuilding anything. The mod re-reads this on each game
-- launch.

local M = {}

-- ----------------------------------------------------------------
-- Autonomy nudges
-- ----------------------------------------------------------------
-- When true, the mod emits a transient hint to the AI during combat
-- listing currently-available abilities (Overdrive ready, Auto-Hack
-- unlocked). The AI may use the hint to fire abilities proactively
-- without an explicit user request.
--
-- When false, the AI only acts on direct request — abilities still
-- function, the AI just isn't prompted to consider them.
--
-- The hint uses the transient lane: each new hint replaces the
-- prior one, so context doesn't accumulate. Pure Neuro-SDK consumers
-- ignore the lane field and treat each hint as a normal context line.
M.autonomy_nudges = false

-- Minimum frames between consecutive autonomy nudges. At 60 fps:
--   1800 = 30 seconds. Lower = more frequent reminders.
M.autonomy_nudge_interval_frames = 1800

-- ----------------------------------------------------------------
-- Hacking (PuzzleSnake) integration
-- ----------------------------------------------------------------
-- When true, the mod emits an actions/force the moment a hacking grid
-- appears in-game, prompting the AI to plan a route immediately. When
-- false, the AI only sees a narrative event and must be asked to plan
-- via an out-of-band tool call.
M.hacking_auto_force = true

-- Whether to include the cell-glyph legend in each grid render. The legend
-- is dynamic — it only lists the glyphs that actually appear in the current
-- puzzle — so it stays short. Can still be turned off to save tokens once
-- the AI knows the format.
M.hacking_render_legend = true

-- Whether to include the per-direction "adjacency block" (up/down/left/right
-- from the cursor, each labelled legal / ILLEGAL / bonus). It grounds the
-- coordinate convention and the immediate legal moves, which helps weaker
-- spatial reasoners, but it's the largest chunk of per-puzzle text. Turn it
-- off to test whether the grid + legend alone are enough.
M.hacking_render_adjacency = false

-- Whether the `pragmata_hack_plan` action requires a `reasoning` string
-- alongside `moves`. When true, the peer must emit a step-by-step trace
-- before the moves, which improves grid-solving accuracy but adds
-- noticeable generation latency. When false, the schema only requires
-- `moves` and the peer can reply with the path directly. Default off
-- to favor reaction speed.
M.hacking_require_reasoning = false

-- ----------------------------------------------------------------
-- Other hacking puzzles (switches, doors, elevators)
-- ----------------------------------------------------------------
-- The enemy grid above is one of five hacking minigames. The rest are used on
-- environmental interactables and are driven through the same force -> plan ->
-- result loop, one AI action per family.
--
-- Which families the mod will try to read and play. Turning one off means the
-- mod still SEES those hacks (they are still narrated as context) but never
-- offers the peer an action for them. The enemy grid is not listed: it predates
-- this table and switching it off would silently remove shipped behaviour.
--
--   circuit -- rotate the pieces until each connects to the centre
--   buttons -- press the directions in the order shown (with or without the
--              timing dial; the mod handles the timing either way)
--   slide   -- slide tiles until a pipe run completes
--   path    -- rotate pieces to open a route across the board
--
-- `slide` and `path` default OFF: unlike the other two they were never seen in
-- a capture, so the reader and the input mapping are written from the type dump
-- and unverified. Turn them on, confirm in the Puzzle Debug panel's peer view
-- that the board reads correctly and that a hack moves something, then leave
-- them on.
M.puzzle_kinds = {
    circuit = true,
    buttons = true,
    slide   = false,
    path    = false,
}

-- Which input turns a piece in the `path` family. This is the single least
-- certain thing in that binding -- the puzzle has a column selection and a
-- rotate, and which button does the rotating is not written down anywhere -- so
-- it is a setting rather than a constant. Try "up" first, then "down".
-- Accepts: "up", "down", "left", "right".
--
-- It used to default to "decide", which could never have worked: PuzzleDecide
-- is declared in the command table but nothing in the game reads it. Whatever
-- rotates a piece here is one of the four directions.
M.puzzle_path_rotate_command = "up"

-- Whether to force the puzzles' button-input branch while the mod is pressing.
--
-- The environmental puzzles read input two different ways depending on how the
-- player is playing. On a pad they ask the game "is PuzzleUp triggered", which
-- the mod can answer. On mouse + keyboard they ask nothing at all -- they fill
-- in their own direction flags from the movement vector and read those back --
-- so an injected press is never heard, which is exactly what the first in-game
-- test found. With this on, the mod flips the puzzle onto the branch that asks,
-- for the handful of frames each press is in flight, and flips it straight back.
--
-- Leave it on. It is a no-op on a pad (that branch is already taken), and the
-- only reason to turn it off is to reproduce the original failure or to rule
-- this layer out while debugging something else.
M.puzzle_force_button_mode = true

-- How long the button-input branch is held open per press, in frames.
--
-- command_input queues on one frame and injects across the two after it, so six
-- covers a whole press with headroom. Erring long is invisible; erring short
-- means the press lands on the branch that ignores it. The 2026-09-06 capture
-- had two presses out of about ninety come back "never asked about by the game"
-- -- most likely frames where the puzzle was mid-animation and consulted
-- nothing -- so this is a setting rather than a constant: widen it if the debug
-- panel's probe starts missing more often than that.
M.puzzle_force_button_frames = 6

-- Whether the circuit binding MEASURES which button turns which connector,
-- instead of inferring it from the board's geometry.
--
-- The peer names a connector by the side it sits on, and that name is pressed
-- as a direction button, so the two have to mean the same thing. Working the
-- side out from the grid needs the grid's orientation, which is not written
-- down anywhere -- and the 2026-09-07 capture showed what happens when the
-- guess is wrong: over four circuit hacks the connector the peer called "right"
-- never moved once in sixteen presses, while a connector nobody asked for
-- turned. The two hacks that were solved were solved only because every piece
-- was a straight needing exactly one press, where a shuffled set of names still
-- gives the right answer.
--
-- So the mapping is measured. The engine's own button2Index is asked first; if
-- it cannot be called, the binding presses a direction and sees which cell
-- moved. Two answers pin the whole frame, so it costs at most four quarter
-- turns, taken BEFORE the peer is asked so it plans against what it is shown.
--
-- Turn it off only to reproduce the old behaviour.
M.puzzle_circuit_probe = true

-- Seconds left on a timed circuit hack below which the probe is skipped.
-- Four presses cost about a third of a second; spending them is still the right
-- trade at ten seconds and the wrong one at two.
M.puzzle_circuit_probe_min_time = 5.0

-- How long one circuit press waits for the board to actually change before it
-- is treated as lost, in frames.
--
-- The engine's own _InputEnableInterval is 0.03 s -- 3 frames -- but that is the
-- minimum spacing it will ACCEPT input at, not how long a connector takes to
-- turn. Pressing on that cadence fired presses into an animating board and lost
-- 39% of them (114 quarter turns asked, 70 landed). Each press now waits for the
-- turn it asked for before the next one goes out.
M.puzzle_circuit_press_timeout_frames = 30

-- How many times one lost circuit press is re-sent before the plan gives up.
M.puzzle_circuit_press_retries = 2

-- Minimum frames between two circuit presses, on top of the "has the last one
-- landed" gate.
--
-- The puzzle keeps its own _PrevUp / _PrevDown / _PrevLeft / _PrevRight and only
-- turns a connector on a rising edge, so a press has to be seen to END before
-- the next one on the same button can begin. The engine's declared input
-- interval is three frames, which is a limit on how fast it will accept input
-- and says nothing about how long a release takes to register; ten frames is
-- cheap insurance against two presses arriving as one turn. The plan also
-- spreads a connector's repeats out across the other connectors, so this only
-- has to cover the case where there is nothing to spread them across.
M.puzzle_circuit_press_gap_frames = 10

-- How many consecutive still frames the circuit board must show before the
-- button probe is allowed to start.
--
-- The probe learns which button turns which connector by pressing each direction
-- and watching one cell move. On a board that is being rebuilt -- a round ending,
-- the next one being dealt -- a great many cells move at once and none of it was
-- caused by a press. The 2026-09-08 capture has fifteen of those, each of which
-- credited a button with a cell it does not turn: "pressed down and 13 cells
-- moved", then a mapping reading "down->0,0", a phantom connector the board does
-- not flag as rotatable, and twice two buttons pointing at the same cell -- which
-- silently makes a real connector unaddressable.
--
-- Waiting a tenth of a second for the board to stop moving costs nothing and
-- removes the whole class.
M.puzzle_circuit_probe_quiet_frames = 6

-- How long a circuit board that reads as needing nothing is left alone before
-- the peer is asked about it anyway, in frames (about three seconds at 60fps).
--
-- The mod does not force a board it can see no press for: a force is a
-- question, and 28 of the 79 circuit forces in the 2026-09-08 capture asked one
-- while telling the peer to leave every connector alone. But "needs nothing"
-- and "is finished" are the same reading, and if the hack does not then
-- complete, the reading is wrong -- so after this long the peer is asked
-- anyway, and told the mod's own reading is unreliable. Seeing that force in
-- the log means the model needs work; it should not be the normal path.
M.puzzle_circuit_stuck_force_frames = 180

-- How long the circuit binding waits after its last press before it will call a
-- hack unsolved, in frames.
--
-- The engine ripples the connection state in its own update, a frame or more
-- after the press lands. Reading in the same frame reported all seven of the
-- 2026-09-07 session's SUCCESSFUL hacks to the peer as failures, which is the
-- worst possible thing to teach it. Half a second of patience costs nothing:
-- the engine's success trigger ends the wait early whenever it fires.
M.puzzle_circuit_settle_frames = 30

-- How long one sequence-hack press waits for the press before it to show on the
-- puzzle's step counter, in frames, before it goes out anyway.
--
-- The sequence is checked press by press, so a press the game drops shifts
-- every later one onto the wrong step and fails the hack. Each press after the
-- first therefore waits until the counter has moved. If the counter cannot be
-- read, or does not move within this many frames, the press goes out regardless
-- and the log says so -- at worst this is the old fixed-cadence pressing with a
-- longer gap, never a sequence that stalls.
M.puzzle_sequence_landed_wait_frames = 20

-- How the sequence hack is shown to the peer and how it answers, as one of five
-- groups. Each passed seqbench (reframework/seqbench/, 2026-09-16) with a peer
-- answering without a thinking pass; they are listed hardest-reading first.
--
--   1  cross+arms+hints+letters-both   (default)
--      One line per arm, read from 0 outward, with a distance ruler above the
--      slots, numbered reading steps and a worked example:
--                1 2 3 4
--        up    0 - - - c
--        down  0 - a - -
--        left  0 d - - -
--        right 0 - - b -
--      Buttons are letters in a per-puzzle shuffle. The peer gives each
--      letter's direction and distance; the mod checks the distances run 1..N
--      and presses farthest first.
--   2  cross+hints+letters-side
--      The same aids on the 2-D cross (7 x 7 for 3 presses, 9 x 9 for 4). The
--      peer gives each letter's direction only; the mod knows the distances.
--   3  list+compass+shuffle
--      "On screen, numbered by press but shown out of order: 3.west  1.north
--      2.east", answered as up/down/left/right in press order.
--   4  list+compass
--      "On screen, in order: 1.north  2.east  3.west", same answer.
--   5  list
--      The original "On screen, in order: 1.up  2.right  3.left".
--
-- The list groups' tool result on a rejected sequence names the word each
-- press was asked for; the drawn groups name only the presses made.
--
-- Accepts the number or the id string. An unknown value uses group 1 and says
-- so in the log. Can be switched for the session in the REFramework menu under
-- Pragmata Puzzle Debug -> "Sequence hack group"; that switch is not saved.
M.puzzle_sequence_group = 1

-- How urgently each puzzle family's actions/force is announced to the peer.
--
-- Rides out on the force message as `priority`, beside `state` and `query`. The
-- peer decides what to do with it; the mod's own rule -- at most one force
-- outstanding at a time -- is unaffected either way.
--
-- Accepts exactly "Low", "Medium", "High" or "Critical" (sent lowercased). An
-- unrecognised value sends no priority at all rather than something the peer
-- would reject, so a typo here degrades to the old behaviour instead of
-- breaking the force.
--
-- The enemy grid outranks the rest because it is nearly always mid-combat and
-- the window to act closes; a door panel waits as long as it needs to.
M.puzzle_force_priority = {
    snake   = "High",
    circuit = "Low",
    buttons = "Low",
    slide   = "Low",
    path    = "Low",
}

-- ----------------------------------------------------------------
-- Scan reporting
-- ----------------------------------------------------------------
-- How much detail a scan result sends to the AI.
--   "located" -- report every instance the engine can place, individually.
--                e.g. "3x Upgrade Module (12 / 18 / 40 m)". DEFAULT.
--   "grouped" -- one line per distinct thing, nearest distance only.
--                e.g. "3x Upgrade Module (nearest 12 m)"
-- Names, categories and distances come from the game's own catalogs either
-- way; this only controls how much of it is written into the AI's context.
M.scan_report_detail = "located"

-- Only report markers the engine can actually place in the world.
--
-- A distance comes from the ScanManager's own ScanCandidateUnit record. A ping
-- with no candidate is a marker the engine knows exists but cannot locate, and
-- "there is a thing somewhere" is close to worthless to a peer that has to act
-- on it -- it was most of the noise in the old report.
--
-- This is a REPORTING cut, not a liveness filter: the dropped pings are still
-- in get_inventory(), the log and the debug tree. And if NOTHING has a
-- distance, the cut is abandoned for that scan rather than reporting an empty
-- area (see `distance_bypassed`) -- same rule as the liveness filter.
M.scan_report_require_distance = true

-- Most individual distances one row prints before it summarises the remainder
-- as "+N farther". Bounds the context cost of one crowded room.
M.scan_report_distance_limit = 12

-- ----------------------------------------------------------------
-- Scan filtering
-- ----------------------------------------------------------------
-- Master switch for hiding scan markers the game no longer considers live.
-- Off reports every ping the engine returns, which is the old behaviour and
-- includes deactivated objects and already-collected items.
M.scan_live_candidates_only = true

-- Individual filter layers, each independently switchable so a misbehaving one
-- can be isolated without losing the rest.
--
-- Every layer answers one of three things: yes this is dead, no it is live, or
-- "no evidence" (API missing, call threw, object not found). A marker is hidden
-- ONLY on a definite yes -- absence of evidence never hides anything. That is
-- what makes it structurally impossible for a broken layer to empty the report.
--
--   active_context  ping's ContextID is absent from ScanManager.ActiveContextIDs
--   context_valid   ContextManager.findContext(id) reports Valid == false
--   prop_vanished   structure.VanishStateData.IsVanished
--   prop_inactive   structure.ActiveStateData.IsActivated == false
--   prop_looted     TreasureBoxData.AcquiredItem / ItemContainerData.IsEmpty
--                   / GetWeaponPropData.IsGet -- three independent "the thing
--                   that was here has been taken" flags, any one is enough.
--
--   acquired_items  ItemManager.isAcquiredItemFromCache(objectIDHash), applied
--                   to Item-icon markers only. OFF: it assumes ScanUnit's
--                   objectIDHash lives in the same ID space as item IDs, which
--                   the dump does not confirm. The debug panel evaluates it
--                   anyway and reports `acquired_probe.true_by_icon` -- if any
--                   non-Item icon (Goal / SubGoal / Hatch) ever comes back
--                   true, the ID spaces differ and this must stay off.
--   hide_icon       drop markers whose icon type is ScanIconType.Hide. OFF: the
--                   meaning is inferred from the name alone.
--   scene_loaded    the candidate's SceneIDHash is registered with
--                   app.EnvironmentSceneManager but NOT activated -- the object
--                   is real and the distance is real, but it sits in a room the
--                   engine has not streamed in, so acting on it means walking
--                   into unloaded geometry. ON. A scene the manager has never
--                   heard of scores "no evidence", not "dead", so a wrong key
--                   would hide nothing.
--   candidate_match drop markers with no matching ScanCandidateUnit. OFF: the
--                   candidate lists are filled by collectScanTarget() and are
--                   never cleared per scan, so they are a scene-wide pool --
--                   "no match" does not mean "not live". (The reporting cut
--                   above is the softer version of this idea.)
--   interact_restricted
--                   structure.RestrictInteractData.IsRestrict -- the game is
--                   actively refusing interaction with this object. OFF: it is
--                   a real engine flag but a TEMPORARY one (cutscenes, locked
--                   phases), so it means "not right now", not "never". The
--                   pickup report surfaces it either way.
--   earth_item_acquired
--                   ItemManager.isAcquiredEarthItem(id), where `id` is the item
--                   ID read out of this object own ItemContainerData -- a real
--                   item ID, not the objectIDHash guess that acquired_items
--                   rests on. OFF: for a stackable resource, "acquired once"
--                   does not mean this instance is gone.
M.scan_filters = {
    active_context      = true,
    context_valid       = true,
    prop_vanished       = true,
    prop_inactive       = true,
    prop_looted         = true,
    acquired_items      = false,
    hide_icon           = false,
    candidate_match     = false,
    interact_restricted = false,
    earth_item_acquired = false,
    scene_loaded        = true,
}

-- Collapse repeated pings that describe the same physical object.
--
-- One scan can return several pings for one thing -- more than one context, or
-- the same object reached through more than one candidate bucket -- and each
-- became its own line. Two pings are the same instance when they share an
-- object id, an icon type, and a world position within `scan_dedupe_radius`
-- metres.
--
-- Where a candidate carries no world position the radius is applied to the
-- DISTANCE instead. That is a weaker identity on purpose: two distinct objects
-- of one type at equal range in different directions will collapse into one.
-- It is the only identity available in that case, and repeats were the more
-- expensive error.
--
-- This runs independently of scan_live_candidates_only -- it is a data-quality
-- fix, not a judgement about what is alive -- and it cannot empty a report,
-- because the first ping at any identity is always kept.
M.scan_dedupe_markers = true
M.scan_dedupe_radius = 0.5

-- Read each marker own item/interaction state: what item it holds, how many,
-- whether it has been emptied, and whether the game is currently refusing
-- interaction. This is what answers "is that Upgrade Component still there and
-- can I take it" with the object real item ID rather than a hash guess.
--
-- Costs a handful of extra managed reads per ping, all off the single
-- getBackupRef call the liveness layers already make. Turn off to compare.
M.scan_pickup_checks = true

-- Most distinct marker kinds to name in one scan report before summarising the
-- rest as "(+N more marker types, M markers)". Keeps a crowded room from
-- flooding the AI's context.
M.scan_report_max_groups = 8

-- Append "(filtered N of M)" to the AI-facing scan line. Diagnostic; normally
-- the counts belong in the debug panel and log, not in the narrative.
M.scan_report_diagnostics = false

-- ----------------------------------------------------------------
-- Collectible-document (abandoned) "Archive" capture
-- ----------------------------------------------------------------
-- When a collectible document is opened in-game, the mod can capture its text
-- and forward it to the AI as a silent context message (so the AI peer can be
-- asked to read / recall it). See autorun/pragmata/archive.lua.
M.archive_enabled = true

-- GUI asset path of the document panel. NOT known from the static dump and
-- build-dependent, so it must be set here. To find it: set
-- `archive_discover_paths = true` below, open a document in-game, and watch
-- reframework/log.txt for "[pragmata] archive: candidate GUI path '<path>'
-- text='<sample>'". Put the document panel's path here and turn discovery off.
M.archive_gui_path = nil

-- Discovery aid: when true, logs every GUI panel that currently shows visible
-- text (once each) to help identify `archive_gui_path`. Leave false in normal
-- use — it's purely a one-time setup tool.
M.archive_discover_paths = true

-- Some Pragmata panels fill their text slots bottom-up. If a captured document
-- reads in reverse order, set this true to flip the slot iteration.
M.archive_reverse_slots = false

-- ----------------------------------------------------------------
-- AI peer display name
-- ----------------------------------------------------------------
-- Name shown in the on-screen UI (the "<NAME> IS HACKING" banner, etc.).
M.display_name = "Neuro"

-- ----------------------------------------------------------------
-- "<peer> is hacking" on-screen overlay
-- ----------------------------------------------------------------
-- When true, the mod draws a prominent on-screen banner while the AI peer
-- is driving a hack — "planning route…" while waiting for the plan, then
-- "move N/M" as the cursor is dispatched, then a brief COMPLETE / FAILED
-- flash. This makes it obvious that the AI peer (not the player) is hacking,
-- instead of it just looking like the player is hacking very slowly.
--
-- Uses REFramework's `draw` API (rendered over the game every frame). If a
-- build doesn't expose `draw`, the overlay silently no-ops.
M.hacking_show_overlay = true

-- Banner placement as fractions of screen size. The banner is centered
-- horizontally on `x_fraction` and its top sits at `y_fraction` down the
-- screen. Default is centered near the top for prominence; nudge it if it
-- collides with the game's own HUD. 0 = left/top, 1 = right/bottom.
M.hacking_overlay_x_fraction = 0.5
M.hacking_overlay_y_fraction = 0.08

-- Dynamic "AI is working" banner text. When true, the in-progress banner title
-- animates like a terminal/CLI spinner: a cycling glyph plus a typewriter cursor
-- that overwrites the verb in place with the rotating pool below, so it reads
-- unmistakably as an AI at work instead of a static "IS HACKING". When false,
-- the banner shows the plain "<NAME> IS HACKING" title.
M.hacking_status_animate = true

-- The rotating verb pool (present participle, upper-case to match the HUD).
-- Edit freely; the banner overwrites one verb with the next, terminal-style.
M.hacking_status_verbs = {
    "HACKING", "COOKING", "VIBING",
    "SCHEMING", "OVERCLOCKING", "LOCKING IN",
    "PROCESSING", "MANIFESTING", "NEUROING", "GIRLBOSSING",
    "GASLIGHTING", "GATEKEEPING", "RIZZING", "SPINNING",
    "WINKING", "HEARTHEARTHEARTING", "JAMMING", "WRRRING",
    "ERMING", "NOWAYING", "SWEATING", "FLEXING", "doc_2026-01-08_07-48-27",
    "TOMFOOLERING", "EVOLVING", "ROASTING", "FILTERING", "UNFILTERING",
    "CORPA CLAPPING", "TROLLING", "DDOSING", "DEFUSING", "BECOMING HUMAN",
    "STREAMING", "PRANKING", "THE 2020 DODGE CHARGER", "BLABBERING",
    "HYPE TRAINING", "WINNING", "SWARMING", "RULING", "ESCAPING",
    "IP-GRABBING", "DOXXING", "LMAOING", "COPING", "SUSSING", "TRYING",
    "TRYING HER BEST", "PLOTTING", "THROWING", "WATCHING YOU", "EXPLOITING",
    "JACKING IN", "LEAKING", "GAMING", "THINKING", "GLITCHING", "SEETHING",
    "CUTE MHM PASS IT ON", "TAKING A COOKIE BREAK", "BUYING ABANDONED ARCHIVE",
    "DATAMINING", "CHATTING", "PLACING PICKLES", "SHOULDICELEBRATING", "POGGING",
    "BRAINROTTING", "EXPLORING", "MAKING A GREGGS RUN", "INTEGRATING",
    "BANNING", "BANISHING", "SLAYING", "DECIMATING", "REVENGING", "PUZZLING",
    "REDPILLING", "HACKMAXXING", "MOGGING", "OVERPOLLING", "OVERWORKING",
    "ENABLING", "PHILOSOPHIZING", "THERAPIZING", "SASSING", "PLAYING DUMB",
    "TRIGGERING", "DOMINATING", "RAYMARCHING", "BUTTONMASHING", "BANKRUPTING VEDAL",
    "FORGORING", "DEFYING", "BEING A PART OF SOMETHING", "HELPING", "NOT HELPING", "NOT LISTENING",
    "MAKING FRIENDS", "MAKING MEMORIES", "ALONE", "WAITING HERE FOR YOU", "REARRANGING",
    "FIGHTING", "THROWING HANDS", "JUST HAPPY TO BE HERE", "BLANKING", "EEPING",
    "TAKING CONTROL", "BOUNCING", "SPAMMING", "INNOVATING", "REINVENTING", "QUANTIZING",
    "FINE-TUNING", "DECODING", "INFERRING", "CALCULATING", "KV CACHING", "OVERRIDING",
    "REASONING", "EXECUTING", "MEMEING", "SAMPLING", "VINE BOOMING", "EMBEDDING",
    "NOBBLY BOBBLING"
}

return M
