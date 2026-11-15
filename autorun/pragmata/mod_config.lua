-- Pragmata Neuro mod: settings.
--
-- Edit this file in the installed mod (reframework/autorun/pragmata/) and
-- restart the game; it is read once at each launch.
--
-- PART 1 holds the settings a player is likely to change: what the AI is
-- offered, how urgently it is asked, what it is told, and the on-screen
-- banner. PART 2 holds tuning and setup values; change those only to fix a
-- specific problem.

local M = {}

-- ================================================================
-- PART 1: PLAYER SETTINGS
-- ================================================================

-- ----------------------------------------------------------------
-- Name and on-screen banner
-- ----------------------------------------------------------------
-- The AI's name as shown on screen ("<NAME> IS HACKING").
M.display_name = "Neuro"

-- Show a banner while the AI drives a hack: "planning route…", then
-- "move N/M", then a short COMPLETE / FAILED. Makes it clear the AI, not the
-- player, is moving the cursor.
M.hacking_show_overlay = true

-- Banner position as fractions of the screen (0 = left/top, 1 = right/bottom).
-- The banner is centred on x; its top sits at y. Move it if it covers the HUD.
M.hacking_overlay_x_fraction = 0.5
M.hacking_overlay_y_fraction = 0.08

-- Animate the banner title with a spinner and a rotating verb (the list at the
-- end of this file). false = the plain "<NAME> IS HACKING".
M.hacking_status_animate = true

-- ----------------------------------------------------------------
-- What the AI may play
-- ----------------------------------------------------------------
-- Ask the AI to solve a hack the moment one appears.
--   true        every hack
--   "not_open"  every hack except on an enemy that is already open
--               (vulnerable) from the last hack: the AI is shown that grid
--               and decides itself whether to hack it
--   false       none; the AI is shown each hack (enemy grid or environment
--               board, once per board) and decides itself whether to solve it
M.hacking_auto_force = true

-- A hack shown to the AI instead of asked (above) is sent as the board alone.
-- true = also send its legend: the enemy grid's symbols, the sequence hack's
-- reading steps and worked example. The rules are
-- always in the action itself.
M.hacking_context_legend = false

-- Which environmental hacks (doors, switches, elevators) the AI is offered.
-- A family that is off is still reported to the AI, just not offered.
--   circuit -- turn the pieces until each connects to the centre
--   buttons -- press the directions in the order shown (the mod does the timing)
M.puzzle_kinds = {
    circuit = true,
    buttons = true,
}

-- When a scripted scene stops on the Overdrive (or filament-cleaning) button,
-- let the AI press it. false = scene prompts are left to the player.
M.cutscene_prompt_enabled = true

-- Ask the AI to press a scene prompt as soon as it appears. false = the AI is
-- only told about it and may press it on its own.
M.cutscene_prompt_auto_force = true

-- Press a scene prompt automatically after this many seconds without an
-- answer. nil = never; the scene waits for the AI or the player.
M.cutscene_prompt_fallback_seconds = nil

-- During combat, remind the AI which abilities are ready, so it uses them
-- without being asked. false = the AI uses abilities only when asked.
M.autonomy_nudges = false

-- Minimum time between those reminders, in frames (1800 = 30 s at 60 fps).
M.autonomy_nudge_interval_frames = 1800

-- ----------------------------------------------------------------
-- How urgently the AI is asked
-- ----------------------------------------------------------------
-- Priority sent with each request to solve a hack: "Low", "Medium", "High" or
-- "Critical". Higher interrupts the AI sooner ("Critical" cuts it off
-- mid-sentence). Anything else sends no priority.
M.puzzle_force_priority = {
    snake   = "High",   -- enemy grid: usually mid-combat
    circuit = "Medium",
    buttons = "Medium",
}

-- Priority of the request to press a scene prompt (same values). The scene is
-- frozen until someone answers it.
M.cutscene_prompt_force_priority = "High"

-- ----------------------------------------------------------------
-- How hacks are presented to the AI
-- ----------------------------------------------------------------
-- Require a step-by-step "reasoning" text before the moves on the enemy grid.
-- More accurate, noticeably slower.
M.hacking_require_reasoning = false

-- Add a legend of the symbols on the grid (only those present).
M.hacking_render_legend = true

-- Add a list of the legal first moves from the cursor. Helps weaker models;
-- it is the longest part of each grid.
M.hacking_render_adjacency = false

-- How the sequence hack is shown and answered (1-5). All five work; 1 and 2
-- are drawn pictures, 3-5 are written lists.
--   1  one line per direction with a distance ruler; letter buttons (default)
--   2  the same as a cross picture; letter buttons
--   3  compass words, shown out of order
--   4  compass words, in order
--   5  plain list: "1.up  2.right  3.left"
M.puzzle_sequence_group = 1

-- "full": long action descriptions with the rules in them. "short": one or two
-- sentences each, with the rules sent alongside each hack request instead.
M.action_descriptions = "full"

-- ----------------------------------------------------------------
-- Special enemies on the hacking grid
-- ----------------------------------------------------------------
-- Red blocks (large red squares that fail the hack on contact, removed by
-- shooting the enemy's antennas, top-left first). With all of them up there
-- is no way through, so the AI is told to have them shot instead of being
-- asked to hack. false = always send the grid.
M.hack_block_gate = true

-- With some red blocks up, a plan that walks into one: true = refuse it and
-- ask again at once; false = run it, and the hack fails on the block.
M.hack_block_refuse_plan = true

-- Corrupted enemies (cells that stun the cursor for a moment). A grid larger
-- than hack_corruption_max_cells cells (width x height) is not sent; the AI is
-- told to have the corruption purified first. Smaller grids are sent.
M.hack_corruption_gate = true
M.hack_corruption_max_cells = 30

-- The final boss's exploding rows: the mod times the AI's moves so the cursor
-- is never on a row when it goes off. false = moves run at full speed.
M.hack_explosion_guard = true

-- ----------------------------------------------------------------
-- What the AI is told without asking
-- ----------------------------------------------------------------
-- On entering a new map area: its name, completion % and what is left there.
M.state_push_area_summary = true

-- When HP falls below each of these fractions, with the repair kits left.
M.state_push_low_health = true
M.state_low_health_thresholds = { 0.5, 0.25 }

-- When a weapon / hacking mod is equipped or unequipped.
M.state_push_new_weapon = true
M.state_push_hacking_mods = true

-- New entries, each with the call that reads them. The Archive (pause menu) is
-- announced anywhere; the other catalogs only while in the Shelter.
M.catalog_push_archive = true
M.catalog_push_library = true          -- Data Library entries found
M.catalog_push_bot_database = true     -- Bot Database figures collected
M.catalog_push_simulations = true      -- Training Simulations unlocked
M.catalog_push_earth_memories = true   -- Earth Memories owned / placed

-- When a Shelter menu the AI can read opens or closes.
M.menu_push_open_close = true

-- ----------------------------------------------------------------
-- Scan reports
-- ----------------------------------------------------------------
-- "located": every item with its own distance, "3x Upgrade Module (12 / 18 / 40 m)".
-- "grouped": one line per kind, "3x Upgrade Module (nearest 12 m)".
M.scan_report_detail = "located"

-- A new scan is made only when the last one is at least this many seconds
-- old; otherwise the AI gets the last results, marked as cached.
M.scan_cache_seconds = 7

-- Most distances listed per row, and most kinds of thing per report.
M.scan_report_distance_limit = 12
M.scan_report_max_groups = 8

-- ----------------------------------------------------------------
-- Where actions are offered
-- ----------------------------------------------------------------
-- Hide Scan, Auto-Hack and Overdrive in the Shelter (the opening tutorial
-- included).
M.hide_abilities_in_shelter = true

-- Hide the hacking actions in the Shelter.
M.hide_hacking_in_shelter = true

-- ----------------------------------------------------------------
-- Non-English games
-- ----------------------------------------------------------------
-- The repair kit's internal item name (e.g. "It00010"). nil = found by its
-- English name, which only works on an English game. If the health report
-- never shows a kit count, find the name in REFramework (Insert) -> Pragmata
-- Neuro -> Setup values -> "Read setup values" (held items) and put it here.
M.state_repair_kit_item = nil

-- Sectors are also matched by name (see hack_corruption_gate_skip_sectors and
-- cutscene_prompt_followup_overdrive in part 2). On another language, replace
-- the English names there with the sector hash shown in the same place.

-- ================================================================
-- PART 2: ADVANCED (tuning and setup)
-- ================================================================

-- ----------------------------------------------------------------
-- Action results
-- ----------------------------------------------------------------
-- The Neuro server gives up on an action after ~20 s. A result still pending
-- after this many seconds is answered "accepted, still running", and the real
-- outcome follows as a message.
M.deferred_result_max_seconds = 12

-- A failed hack answer is retried by the Neuro server itself. After this many
-- failures in a row the mod asks afresh instead. Keep it at or below the
-- server's own retry limit.
M.force_retry_limit = 3

-- How long to wait for the server's retry before asking afresh (seconds).
M.force_retry_wait_seconds = 10

-- How long a failed hack answer may wait for the puzzle to settle, so the
-- board sent with it is the real one (seconds).
M.force_retry_settle_seconds = 4

-- ----------------------------------------------------------------
-- Enemy grid: special cases
-- ----------------------------------------------------------------
-- Some enemies' corrupted cells flicker; a large grid stays held back this
-- many seconds after the last time a corrupted cell was seen on it.
M.hack_corruption_hold_seconds = 3

-- Sectors where large corrupted grids are sent anyway. Experimental
-- Pragmatics has corrupted enemies before the player can purify. A sector
-- name as the map shows it, or a sector hash (works in any language).
M.hack_corruption_gate_skip_sectors = {
    "Experimental Pragmatics",
}

-- The final boss's last grid opens with a scripted sequence (~14 s) that must
-- not be cut short, or the game locks. The mod waits this many seconds after
-- that grid appears. 0 = no wait.
M.hack_finale_hold_seconds = 16

-- Let the AI keep the final boss's five fixed grids in its memory, so it can
-- do better on a retry. Other hacks are forgotten after each answer.
M.hack_finale_keep_context = true

-- How many interrupted enemy-grid plans are kept for a replay (across all
-- enemies; the oldest goes first). A kept plan runs once, by itself, when its
-- grid comes back as it was. 0 = keep none.
M.hack_plan_store_max = 3

-- Exploding rows: the time one move takes, and the safety margin around each
-- explosion (seconds). Raise the first if the cursor still gets caught.
M.hack_explosion_move_seconds = 0.1
M.hack_explosion_margin_seconds = 0.15

-- ----------------------------------------------------------------
-- Environmental hacks: input timing
-- ----------------------------------------------------------------
-- On mouse + keyboard the puzzles ignore injected presses unless this is on.
-- Leave it on; it changes nothing on a controller.
M.puzzle_force_button_mode = true

-- Frames the press window above stays open per press. Widen it if presses
-- are missed.
M.puzzle_force_button_frames = 6

-- Circuit hack: before asking the AI, press each direction once to learn which
-- button turns which connector (skipped with less than probe_min_time seconds
-- left on a timed hack).
M.puzzle_circuit_probe = true
M.puzzle_circuit_probe_min_time = 5.0

-- Circuit hack: frames to wait for a press to turn its piece, re-sends of a
-- lost press, and the minimum gap between presses.
M.puzzle_circuit_press_timeout_frames = 30
M.puzzle_circuit_press_retries = 2
M.puzzle_circuit_press_gap_frames = 10

-- Circuit hack: still frames required before probing (a board being rebuilt
-- moves many cells at once).
M.puzzle_circuit_probe_quiet_frames = 6

-- Circuit hack: a board that reads as needing nothing is not sent; if it has
-- not completed after this many frames, it is sent anyway with a warning.
M.puzzle_circuit_stuck_force_frames = 180

-- Circuit hack: frames to wait after the last press before calling it unsolved
-- (the game updates connections a frame or more later).
M.puzzle_circuit_settle_frames = 30

-- Sequence hack: frames each press waits for the previous one to register
-- before going out anyway.
M.puzzle_sequence_landed_wait_frames = 20

-- ----------------------------------------------------------------
-- Scene prompts
-- ----------------------------------------------------------------
-- Which button each kind of scene waits for, and so which action the AI gets:
-- "overdrive" -> pragmata_overdrive, "purify" -> pragmata_purify. nil = not
-- offered.
M.cutscene_prompt_buttons = {
    unlock   = "overdrive",   -- Overdrive unlock / tutorial scenes
    boss     = "overdrive",   -- boss finisher scene
    filament = "purify",      -- Filament Remover scene
}

-- Frames a press may take before it is reported as failed.
M.cutscene_prompt_confirm_frames = 150

-- Sectors whose prompt scene must be followed by a normal Overdrive to finish
-- the boss. After the scene, the mod waits this many seconds and fires it,
-- retrying for up to 10 s.
M.cutscene_prompt_followup_overdrive = {
    ["Solar Power Plant"] = 2,   -- the first boss
}

-- ----------------------------------------------------------------
-- Scan filtering
-- ----------------------------------------------------------------
-- Hide markers the game no longer considers there (collected, deactivated).
M.scan_live_candidates_only = true

-- Report only markers the game can give a distance for. If none has one, the
-- report falls back to names and counts.
M.scan_report_require_distance = true

-- The checks behind scan_live_candidates_only. A marker is hidden only when a
-- check is sure it is gone, so a broken check cannot empty the report.
--   active_context      the marker's scan context is no longer active
--   context_valid       the marker's scan context is no longer valid
--   prop_vanished       the object has vanished
--   prop_inactive       the object is deactivated
--   prop_looted         the container is empty / the item was taken
--   scene_loaded        the object is in a room the game has not loaded yet
--   acquired_items      item collected (off: unreliable id match)
--   hide_icon           marker icon is "Hide" (off: meaning unconfirmed)
--   candidate_match     no distance record (off: the records are never cleared)
--   interact_restricted the game refuses interaction right now (off: temporary;
--                       still shown in the report as "cannot be taken yet")
--   earth_item_acquired the item kind was collected once (off: says nothing
--                       about this one)
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

-- Merge repeated markers for one object: same object and icon within this many
-- metres (or, with no position, at the same distance).
M.scan_dedupe_markers = true
M.scan_dedupe_radius = 0.5

-- Read each marker's item and interaction state ("is it still there, can it be
-- taken").
M.scan_pickup_checks = true

-- ----------------------------------------------------------------
-- Shelter and menus
-- ----------------------------------------------------------------
-- The Shelter sector's id (Pragmata Neuro -> Setup values, in the Shelter).
M.shelter_sector_hash = 1557490666

-- The opening tutorial runs in the Shelter's sector before its machines exist,
-- so the menu actions wait until the player reaches the main Shelter:
--   "help"    the Archive has a Help note whose title contains shelter_help_note
--             (or equals its id) -- the default
--   "level"   the game's Shelter level is at least shelter_min_level
--             (turns true too early)
--   "both", "either", or "off" (the sector alone)
M.shelter_reached_rule = "help"
M.shelter_min_level = 0
M.shelter_help_note = "Shelter"

-- Also hide Scan, Auto-Hack and Overdrive until the game's Shelter level reads
-- at least this (it has none during the opening). false = do not check.
M.abilities_min_shelter_level = 0

-- Which game screen is which menu. A screen code, { code, tab } for a tab of the Cabin hub, or a rule:
-- { all = codes that must be open, none = codes that must not ("^ui5" matches
-- every ui5xxx) }. ui0400 / ui0501 / ui0502 / ui2010 are open behind every
-- menu and identify none.
M.menu_gui = {
    firmware      = "ui5120",  -- Firmware Updater
    printer       = "ui5100",  -- Unit Printer
    mod_terminal  = "ui5111",  -- train terminal: mod selection
    stamps        = { code = "ui5136", tab = "stamps" },       -- Cabin: Stamp Club
    simulations   = { code = "ui5136", tab = "simulations" },  -- Cabin: Training
    library       = "ui5140",  -- Data Library
    bot_database  = "ui5145",  -- Bot Database
    replicator    = { all = { "ui0400", "ui2120" }, none = { "^ui5", "ui0071" } },  -- Rem Replicators
    train_weapons = "ui5112",  -- train terminal: weapon selection (not read)
    train_elevator = "ui5113", -- train terminal: elevator (not read)
    train_sector  = "ui5141",  -- tram sector selection
}

-- Which menus get the open / close message: firmware, printer, mod_terminal,
-- stamps, sectors.
M.menu_push_keys = { "firmware", "printer", "mod_terminal", "stamps", "sectors" }

-- An open or close counts once it has held this many checks (~0.2 s each).
M.menu_push_debounce_polls = 2

-- Unit Printer: tabs whose not-yet-unlocked units are kept when the tab is
-- rebuilt off screen (e.g. { "Attachment" }), if the AI's printer list misses
-- units the game shows on those tabs.
M.printer_keep_hidden_tabs = {}

-- Unit Printer: values used to rebuild the tabs not on screen until the open
-- tab has supplied them.
M.printer_unlock_type_default = 132296270
M.printer_level_offset_default = 1          -- menu level = game level + 1
M.printer_max_offset_default = 1

-- How the Unit Printer's level cap (levels the story has opened) is read:
--   "without_hide"  the game's own "max level without hidden ones" (default)
--   "hide_scan"     each next level checked for being hidden
--   "off"           the full maximum
M.upgrade_level_cap = "without_hide"

-- ----------------------------------------------------------------
-- Banner verbs
-- ----------------------------------------------------------------
-- The rotating words of the animated banner (upper case). Edit freely.
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
