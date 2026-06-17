# Pragmata Neuro-SDK Mod

A REFramework Lua mod for [Pragmata](https://www.capcom-games.com/pragmata/) that exposes Diana's abilities and the game's world state to **Neuro**, an AI peer, over a standard Neuro-SDK WebSocket connection. Neuro can perform Diana's actions (scan, auto-hack, overdrive) and receive context updates (dialogue, gauge state, scene transitions, combat state).

> **Status: experimental, actively developed.** This integration is built and tested as I play through Pragmata, so coverage grows over time. The hacking integration and cinematic dialogue capture are confirmed working in-game. The ability bindings (scan, auto-hack, overdrive) are derived from the static IL2CPP dump and not all runtime-verified yet, so expect bugs there.

## What's exposed

**AI-callable actions** (registered as Neuro-SDK actions):

| Action | Effect |
|---|---|
| `pragmata_ping` | Sanity check; returns `pong`. |
| `pragmata_scan` | Triggers Diana's environmental scan. |
| `pragmata_auto_hack` | Auto-hacks a target (requires the in-game Auto-Hack upgrade). |
| `pragmata_hack_plan` | Plans a path through the active hacking grid. Auto-forced on grid-start. |
| `pragmata_overdrive` | Fires Diana's Overdrive Protocol (requires gauge to be full). |

**Context emitted to Neuro** (as Neuro-SDK `context` messages):

- Subtitle dialogue, formatted with speaker name + dialogue type
- Hacking gauge crossings (25 / 50 / 75 / 100%)
- Overdrive readiness edges
- Auto-Hack upgrade unlock event
- Scan result summaries
- Scene/area transitions
- Checkpoint reached events
- Combat start/end edges
- Optional: in-combat ability hints (autonomy nudges, off by default)

See [ACTIONS.md](ACTIONS.md) for the full action surface, schemas, and context message shapes.

## Architecture

```
+------------------------+         JSONL files        +-------------------+        WebSocket         +----------------+
|   pragmata_main.lua    | <--- mailbox transport --> |  pragmata_mailbox |  <-- Neuro-SDK JSON -->  |   Neuro        |
|  (in-game, Lua via     |  reframework/data/         |     (Python       |  (default                |  (AI peer)     |
|   REFramework)         |  pragmata_mailbox/         |      sidecar)     |   ws://127.0.0.1:8000)   |                |
+------------------------+                            +-------------------+                          +----------------+
```

REFramework's Lua sandbox can't open sockets, so a small Python sidecar process bridges file-mailbox writes to a WebSocket connection. The mod itself never speaks to the network directly.

## Install

### Prerequisites

- **Pragmata** (PC).
- **REFramework** for Pragmata. Drop `dinput8.dll` from a [REFramework nightly](https://github.com/praydog/REFramework-nightly/releases) into the Pragmata install folder. Confirm it works by pressing **Insert** in-game and seeing the REFramework menu.
- **Python 3.10+** with `pip` (for the sidecar).
- **Neuro** (or any Neuro-SDK-compatible peer) running and listening on a WebSocket endpoint. The mod connects out to whatever URL you configure.

### One-time setup

1. **Install the mod files.** Copy the contents of `autorun/` into Pragmata's REFramework autorun directory:

   ```
   cp -r autorun/* "<Pragmata>/reframework/autorun/"
   ```

   You should now have `pragmata_main.lua` and a `pragmata/` subdirectory inside `<Pragmata>/reframework/autorun/`.

2. **Create the mailbox directory.** Both the mod and sidecar expect this path:

   ```
   mkdir "<Pragmata>/reframework/data/pragmata_mailbox"
   ```

   (The sidecar will create it if missing, but pre-creating avoids a startup race.)

3. **Install sidecar dependencies:**

   ```
   pip install -r sidecar/requirements.txt
   ```

### Each run

Three things need to be running simultaneously, in any order:

1. **Neuro** on a WebSocket port of your choice.

2. **The Pragmata mailbox sidecar:**

   ```
   python sidecar/pragmata_mailbox.py \
       --mailbox-dir "<Pragmata>/reframework/data/pragmata_mailbox" \
       --bridge-url "ws://127.0.0.1:8000"
   ```

   (Replace the URL with Neuro's actual endpoint. You can also set `PRAGMATA_BRIDGE_WS` instead of passing `--bridge-url`.)

3. **Pragmata** with REFramework loaded — the mod loads automatically when the game starts.

When all three are running, Neuro should see a `startup` message followed by `actions/register` listing the exposed Pragmata actions.

## Configuration

User-tunable settings live in [`autorun/pragmata/mod_config.lua`](autorun/pragmata/mod_config.lua):

- `autonomy_nudges` (default `false`) — when true, the mod emits an in-combat hint listing which abilities are currently available, encouraging Neuro to use them proactively. When false, Neuro only acts on direct request.
- `autonomy_nudge_interval_frames` — minimum frames between consecutive nudges (default `1800`, i.e. ~30s at 60fps).
- `hacking_auto_force` (default `true`) — auto-send an `actions/force` the moment a hacking grid appears, prompting Neuro to plan immediately.
- `hacking_render_legend` (default `true`) — include the cell-glyph legend in each grid render.
- `hacking_require_reasoning` (default `false`) — require a step-by-step `reasoning` string alongside the moves (more accurate, slower).
- `display_name` (default `"Neuro"`) — name shown in the on-screen hacking banner. Purely cosmetic; nothing in the wire protocol or dispatch logic reads it.
- `hacking_show_overlay` (default `true`) — draw the on-screen "`<display_name>` is hacking" banner while Neuro is planning/executing a hack. No-ops on builds without REFramework's `draw` API.
- `hacking_overlay_x_fraction` (default `0.5`) / `hacking_overlay_y_fraction` (default `0.08`) — horizontal/vertical placement of that banner as fractions of screen size; nudge them if it overlaps the game HUD.

Two ImGui diagnostic panels are available in the REFramework menu (Insert): **Pragmata Hacking Debug** and **Pragmata Abilities Debug** (live Scan / Overdrive binding state + manual trigger buttons).

Edit this file in the deployed mod directory (`reframework/autorun/pragmata/mod_config.lua`); it's re-read each game launch.

## Context message lanes

The mod uses an optional `lane` field on Neuro-SDK `context` messages to distinguish:

- **`narrative`** — discrete events (scene change, scan fired, combat started). These accumulate as conversation context.
- **`transient`** — replaceable state snapshots (current gauge %, in-combat hints). Each new transient message conceptually supersedes the prior one of the same kind.

This is a forward-compatible extension. Lane-aware consumers can implement replacement semantics for `transient`; pure Neuro-SDK consumers ignore the field and treat every line as cumulative context. The mod functions correctly either way — `transient` just helps avoid context bloat for state-style updates if your integration supports it.

## Hacking integration

The hacking minigame (the `app.PuzzleSnake` cursor-routing puzzle that pops up when Diana initiates a hack) is the most fully-integrated subsystem. The flow:

1. The mod observes `_StartTrg` on the active `PuzzleSnake` instance and, the moment a grid appears, sends an `actions/force` to Neuro with the rendered grid as the `state` field and `pragmata_hack_plan` as the only allowed action.
2. Neuro returns a list of cardinal moves (`up` / `down` / `left` / `right`). The render highlights **bonus nodes** — cells that do more damage to the enemy and make the hack last longer — and asks Neuro to route through as many as possible en route to the goal (a longer bonus-collecting path beats the shortest path, as long as it still reaches the goal and avoids `X` traps and `~` trail cells).
3. The mod dispatches the moves one cell per ~130ms by writing the target coords into `PuzzleSnake._NextMovePosition`. The engine's natural input pipeline (`updateInput → updateNextPosition → updatePuzzleMovement → onEnterGrid`) then processes each move for free: walls block, directional gates enforce, trail flags update, skill/bonus cells trigger, `EraseCode` traps fire, and **goal arrival auto-completes the puzzle** with the full COMPLETE animation. (Writing `_NextMovePosition` replaced an earlier `Unit.move(via.Int2)` + `_RequestForceSuccess` approach, which bypassed those per-cell side-effects; `Unit.move` is retained only for the debug-panel poke buttons.)

While Neuro is driving a hack, the mod draws a prominent, HUD-styled on-screen **"`<display_name>` is hacking"** banner (planning → executing move N/M → resuming/replanning → COMPLETE/FAILED) so it's clear Neuro — not the player — is moving the cursor. The displayed name comes from `display_name`; toggle the banner with `hacking_show_overlay` and reposition with the `*_fraction` settings.

For full schemas, message shapes, and integration notes, see [ACTIONS.md](ACTIONS.md#pragmata_hack_plan).

## Files referencing game internals

Files under [`autorun/pragmata/bindings/`](autorun/pragmata/bindings/) reference real Pragmata class and method names extracted from the IL2CPP dump. The public API surface (the `pragmata.bindings.<system>.*` Lua module functions) is intentionally neutral — internal type/method names live inside the binding files but are never returned to callers, so other modules in this mod can be read without exposure.

## Troubleshooting

**Mod logs `mailbox dir not ready`** — the directory `<Pragmata>/reframework/data/pragmata_mailbox/` doesn't exist. Create it manually.

**Sidecar logs `bridge connection failed`** — Neuro isn't running, or it's bound to a different port than `--bridge-url`. Check the URL.

**Mod doesn't load** — check `<Pragmata>/reframework/log.txt` for Lua errors. Most common cause: the `pragmata/` subfolder didn't get copied; both `pragmata_main.lua` AND the `pragmata/` directory must be inside `reframework/autorun/`.

**An action call returns success but nothing visibly happened in-game** — several bindings (notably `pragmata_auto_hack` and `pragmata_overdrive`) are flagged medium/low confidence in their headers. They confirm preconditions, but the actual engine-side dispatch may not be reached due to private-method reflection or per-target gating. See `autorun/pragmata/bindings/<system>.lua` for the binding's confidence comments and untested risks.

**Dialogue lines aren't being captured** — verify `<Pragmata>/reframework/log.txt` shows `[pragmata] dialogue: …` lines as subtitles appear. If not, the game's GUI hierarchy may have changed in a patch; check that `UI/Asset/ui2000/gui/ui2010` still resolves.

## Open items

Binding code is the least runtime-verified part of the mod. Current open items:

- Runtime-verifying the ability bindings (everything in `bindings/` outside the hacking path is static-dump-derived).
- A driver-board lookup helper for hacking and overdrive (would upgrade three bindings from medium/low to high confidence).
- Disambiguating save vs. load in `checkpoint.is_saving()`.
- Mission/objective state binding (not yet implemented).

## License

[MIT](LICENSE).
