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
M.hacking_render_adjacency = true

-- Whether the `pragmata_hack_plan` action requires a `reasoning` string
-- alongside `moves`. When true, the peer must emit a step-by-step trace
-- before the moves, which improves grid-solving accuracy but adds
-- noticeable generation latency. When false, the schema only requires
-- `moves` and the peer can reply with the path directly. Default off
-- to favor reaction speed.
M.hacking_require_reasoning = false

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

return M
