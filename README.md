# Pragmata Neuro-SDK Mod

A REFramework Lua mod for [Pragmata](https://www.capcom-games.com/pragmata/) that exposes Diana's abilities and the game's world state to a Neuro-SDK-compatible AI peer. The AI can perform Diana's actions (scan, auto-hack, overdrive) and receive context updates (dialogue, gauge state, scene transitions, combat state) over a standard Neuro-SDK WebSocket connection.

> **Status: experimental.** This is **not** a full, finished Neuro integration — it aims to be a useful starting point for anyone working on one. **No gameplay functionality has been tested in-game.** The author has been avoiding spoilers in order to play the game first on stream, so most bindings have only been validated against the static IL2CPP dump, not at runtime. There are probably bugs. Cinematic dialogue capture is the one piece that's been confirmed working.

## What's exposed

**AI-callable actions** (registered as Neuro-SDK actions):

| Action | Effect |
|---|---|
| `pragmata_ping` | Sanity check; returns `pong`. |
| `pragmata_scan` | Triggers Diana's environmental scan. |
| `pragmata_auto_hack` | Auto-hacks a target (requires the in-game Auto-Hack upgrade). |
| `pragmata_hack_plan` | Plans a path through the active hacking grid. Auto-forced on grid-start. |
| `pragmata_overdrive` | Fires Diana's Overdrive Protocol (requires gauge to be full). |

**Context emitted to the AI** (as Neuro-SDK `context` messages):

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
|   pragmata_main.lua    | <--- mailbox transport --> |  pragmata_mailbox |  <-- Neuro-SDK JSON -->  |   AI peer      |
|  (in-game, Lua via     |  reframework/data/         |     (Python       |  (default                |  (your         |
|   REFramework)         |  pragmata_mailbox/         |      sidecar)     |   ws://127.0.0.1:8000)   |   integration) |
+------------------------+                            +-------------------+                          +----------------+
```

REFramework's Lua sandbox can't open sockets, so a small Python sidecar process bridges file-mailbox writes to a WebSocket connection. The mod itself never speaks to the network directly.

## Install

### Prerequisites

- **Pragmata** (PC).
- **REFramework** for Pragmata. Drop `dinput8.dll` from a [REFramework nightly](https://github.com/praydog/REFramework-nightly/releases) into the Pragmata install folder. Confirm it works by pressing **Insert** in-game and seeing the REFramework menu.
- **Python 3.10+** with `pip` (for the sidecar).
- A **Neuro-SDK-compatible AI peer** running and listening on a WebSocket endpoint. The mod connects out to whatever URL you configure.

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

1. **Your Neuro-SDK AI peer** on a WebSocket port of your choice.

2. **The Pragmata mailbox sidecar:**

   ```
   python sidecar/pragmata_mailbox.py \
       --mailbox-dir "<Pragmata>/reframework/data/pragmata_mailbox" \
       --bridge-url "ws://127.0.0.1:8000"
   ```

   (Replace the URL with your AI peer's actual endpoint. You can also set `PRAGMATA_BRIDGE_WS` instead of passing `--bridge-url`.)

3. **Pragmata** with REFramework loaded — the mod loads automatically when the game starts.

When all three are running, the AI peer should see a `startup` message followed by `actions/register` listing the exposed Pragmata actions.

## Configuration

User-tunable settings live in [`autorun/pragmata/mod_config.lua`](autorun/pragmata/mod_config.lua):

- `autonomy_nudges` (default `false`) — when true, the mod emits an in-combat hint listing which abilities are currently available, encouraging the AI to use them proactively. When false, the AI only acts on direct request.
- `autonomy_nudge_interval_frames` — minimum frames between consecutive nudges (default `1800`, i.e. ~30s at 60fps).

Edit this file in the deployed mod directory (`reframework/autorun/pragmata/mod_config.lua`); it's re-read each game launch.

## Context message lanes

The mod uses an optional `lane` field on Neuro-SDK `context` messages to distinguish:

- **`narrative`** — discrete events (scene change, scan fired, combat started). These accumulate as conversation context.
- **`transient`** — replaceable state snapshots (current gauge %, in-combat hints). Each new transient message conceptually supersedes the prior one of the same kind.

This is a forward-compatible extension. Lane-aware consumers can implement replacement semantics for `transient`; pure Neuro-SDK consumers ignore the field and treat every line as cumulative context. The mod functions correctly either way — `transient` just helps avoid context bloat for state-style updates if your integration supports it.

## Hacking integration

The hacking minigame (the `app.PuzzleSnake` cursor-routing puzzle that pops up when Diana initiates a hack) is the most fully-integrated subsystem. The flow:

1. The mod observes `_StartTrg` on the active `PuzzleSnake` instance and, the moment a grid appears, sends an `actions/force` to the AI peer with the rendered grid as the `state` field and `pragmata_hack_plan` as the only allowed action.
2. The peer returns a list of cardinal moves (`up` / `down` / `left` / `right`).
3. The mod dispatches the moves one cell per ~130ms via `app.PuzzleSnake.Unit.move(via.Int2)`, with each move passing the cursor's current `_Position` mutated by the direction delta.
4. When the cursor reaches the goal cell, the mod writes `PuzzleBase._RequestForceSuccess = true` on the `PuzzleSnake` instance. The engine polls this field each tick and runs its full natural completion flow (COMPLETE overlay, hack damage commit, dialogue progression, auto-reset for chain-hacking).

Why step 4 is necessary: calling `Unit.move` directly bypasses the engine's per-cell goal-detection. The engine's natural input pipeline (controller → `updatePuzzleMovement` → cursor) sets internal flags that fire goal detection on arrival; programmatic cursor moves don't, so the puzzle would otherwise just sit on the goal cell with no completion. `_RequestForceSuccess` is the engine's own request-flag for forcing that completion path.

For full schemas, message shapes, and integration notes, see [ACTIONS.md](ACTIONS.md#pragmata_hack_plan).

## Files referencing game internals

Files under [`autorun/pragmata/bindings/`](autorun/pragmata/bindings/) reference real Pragmata class and method names extracted from the IL2CPP dump. The public API surface (the `pragmata.bindings.<system>.*` Lua module functions) is intentionally neutral — internal type/method names live inside the binding files but are never returned to callers, so other modules in this mod can be read without exposure.

## Troubleshooting

**Mod logs `mailbox dir not ready`** — the directory `<Pragmata>/reframework/data/pragmata_mailbox/` doesn't exist. Create it manually.

**Sidecar logs `bridge connection failed`** — your AI peer isn't running, or it's bound to a different port than `--bridge-url`. Check the URL.

**Mod doesn't load** — check `<Pragmata>/reframework/log.txt` for Lua errors. Most common cause: the `pragmata/` subfolder didn't get copied; both `pragmata_main.lua` AND the `pragmata/` directory must be inside `reframework/autorun/`.

**An action call returns success but nothing visibly happened in-game** — several bindings (notably `pragmata_auto_hack` and `pragmata_overdrive`) are flagged medium/low confidence in their headers. They confirm preconditions, but the actual engine-side dispatch may not be reached due to private-method reflection or per-target gating. See `autorun/pragmata/bindings/<system>.lua` for the binding's confidence comments and untested risks.

**Dialogue lines aren't being captured** — verify `<Pragmata>/reframework/log.txt` shows `[pragmata] dialogue: …` lines as subtitles appear. If not, the game's GUI hierarchy may have changed in a patch; check that `UI/Asset/ui2000/gui/ui2010` still resolves.

## Contributing

This mod was developed under spoiler-isolation constraints, which means binding code received less review than transport/dispatcher code. Improvements especially welcome in:

- Runtime-verified bindings (everything currently in `bindings/` is static-dump-derived).
- A driver-board lookup helper for hacking and overdrive (would upgrade three bindings from medium/low to high confidence).
- Disambiguating save vs. load in `checkpoint.is_saving()`.
- Mission/objective state binding (intentionally omitted from this version because objective text is heavily spoiler-bearing and needs a redaction strategy).

## License

[MIT](LICENSE).
