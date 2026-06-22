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
