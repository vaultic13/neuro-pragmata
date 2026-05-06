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

return M
