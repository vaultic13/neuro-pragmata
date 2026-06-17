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

-- Whether to include the cell-glyph legend in each grid render. Useful
-- the first few hacks while the AI is learning the format; can be
-- turned off later to save tokens.
M.hacking_render_legend = true

-- Whether the `pragmata_hack_plan` action requires a `reasoning` string
-- alongside `moves`. When true, the peer must emit a step-by-step trace
-- before the moves, which improves grid-solving accuracy but adds
-- noticeable generation latency. When false, the schema only requires
-- `moves` and the peer can reply with the path directly. Default off
-- to favor reaction speed.
M.hacking_require_reasoning = false

-- ----------------------------------------------------------------
-- AI peer display name
-- ----------------------------------------------------------------
-- Name shown in the on-screen UI (the "<NAME> IS HACKING" banner, etc.).
-- This repo is public, so the committed default is the generic peer name;
-- set it locally to your peer's name before streaming. Purely cosmetic —
-- nothing in the wire protocol or dispatch logic reads this value.
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
