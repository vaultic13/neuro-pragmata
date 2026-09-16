# Pragmata Neuro-SDK Mod

A REFramework Lua mod for [Pragmata](https://www.capcom-games.com/pragmata/)
that exposes Diana's abilities and the game's world state to **Neuro**, an AI
peer, over a standard Neuro-SDK WebSocket connection. Neuro can perform Diana's
actions (scan, auto-hack, overdrive), route the hacking minigame, and receive
context updates (dialogue, gauge state, scene transitions, combat state).

> **Status: working, actively developed.** All three of Diana's abilities are
> now runtime-confirmed in-game, as are the hacking integration and dialogue
> capture. Each ability has exactly one dispatch path, and each reports success
> only after the game is observed to have started it. Coverage still grows as I
> play through the game.

## What Neuro can do

| Action | Arguments | Effect |
|---|---|---|
| `pragmata_ping` | none | Sanity check; returns `pong`. |
| `pragmata_scan` | none | Diana scans the environment. |
| `pragmata_scan_results` | none | Re-read the last scan. Read-only, costs nothing. |
| `pragmata_auto_hack` | none | Auto-hacks the locked-on target (needs the Auto-Hack upgrade). |
| `pragmata_overdrive` | none | Fires Overdrive (needs 100 gauge points). |
| `pragmata_hack_plan` | `moves` | Plans a path through the active hacking grid. Auto-forced on grid-start. |

**Diana's three abilities take no arguments.** There is nothing to choose: Scan
is a single input command, Overdrive is a single driver call, and the engine's
Auto-Hack entry point has no target parameter, so the game's lock-on decides the
target. `pragmata_hack_plan` is the only action with arguments, because it is a
reply to a grid the mod sent.

**Success means the game acted.** All three abilities use deferred results — the
mod answers when it sees the engine start the ability (within 2–3 seconds), not
when it asks. A precondition failure comes back immediately with the specific
reason; a call the game silently ignored comes back as a failure at the end of
the window.

```
pragmata_scan       -> true   "scan started (request-specific progression observed)"
pragmata_overdrive  -> true   "the game started Overdrive (canDeathblow cleared)"
pragmata_auto_hack  -> false  "no valid hack target (nothing is locked on)"
```

### Context emitted to Neuro

All sent as `context` messages with `silent: true`:

- Subtitle dialogue with speaker and dialogue type —
  `Dialogue: [Conversation] Diana says "Let's finish this!"`
- Collectible-document text, when a document is opened (needs
  `mod_config.archive_gui_path` set — see [Configuration](#configuration))
- `Hacking gauge: 75%` on upward crossings of 25 / 50 / 75 / 100%
- `Overdrive is ready.` · `Auto-Hack upgrade is now available.`
- `Diana scanned: …` result summaries
- `Hacking grid started.` · `Hack succeeded.` · `Hack failed.`
- `Hugh and Diana entered a new area.` · `Checkpoint reached.`
- `Combat started.` · `Combat ended.`
- Optional in-combat ability hints (autonomy nudges, off by default)

Scene, area and checkpoint **names** are never sent — only opaque hashes are
used internally for transition detection.

See [ACTIONS.md](ACTIONS.md) for schemas, every result and refusal message, the
grid render format, and the full context surface.

## Architecture

```
+------------------------+         JSONL files        +-------------------+        WebSocket         +----------------+
|   pragmata_main.lua    | <--- mailbox transport --> |  pragmata_mailbox |  <-- Neuro-SDK JSON -->  |   Neuro        |
|  (in-game, Lua via     |  reframework/data/         |     (Python       |  (default                |  (AI peer)     |
|   REFramework)         |  pragmata_mailbox/         |      sidecar)     |   ws://127.0.0.1:8000)   |                |
+------------------------+                            +-------------------+                          +----------------+
```

REFramework's Lua sandbox can't open sockets, so a small Python sidecar bridges
file-mailbox writes to a WebSocket connection. The mod never speaks to the
network directly, and it reaches the game only through REFramework's reflection
and hooks — no native offsets, no injected DLL, no virtual input device, and no
OS-level key synthesis.

## Install

### Prerequisites

- **Pragmata** (PC).
- **REFramework** for Pragmata. Drop `dinput8.dll` from a
  [REFramework nightly](https://github.com/praydog/REFramework-nightly/releases)
  into the Pragmata install folder. Confirm it works by pressing **Insert**
  in-game and seeing the REFramework menu.
- **Python 3.10+** with `pip` (for the sidecar).
- **Neuro** (or any Neuro-SDK-compatible peer) listening on a WebSocket
  endpoint. The mod connects out to whatever URL you configure.

### One-time setup

1. **Install the mod files.** Copy the contents of `autorun/` into Pragmata's
   REFramework autorun directory:

   ```
   cp -r autorun/* "<Pragmata>/reframework/autorun/"
   ```

   You should now have `pragmata_main.lua` and a `pragmata/` subdirectory inside
   `<Pragmata>/reframework/autorun/`.

2. **Create the mailbox directory.** Both the mod and sidecar expect this path:

   ```
   mkdir "<Pragmata>/reframework/data/pragmata_mailbox"
   ```

   (The sidecar will create it if missing, but pre-creating avoids a startup
   race.)

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

   (Replace the URL with Neuro's actual endpoint. You can also set
   `PRAGMATA_BRIDGE_WS` instead of passing `--bridge-url`.)

3. **Pragmata** with REFramework loaded — the mod loads automatically when the
   game starts.

When all three are running, Neuro should see a `startup` message followed by
`actions/register` listing the six exposed actions.

## Testing without the AI

The **Pragmata Abilities Debug** panel (REFramework menu, **Insert**) binds each
ability to a function key and to a button in the same row:

| Key | Button | Ability |
|---|---|---|
| **F6** | `Scan (F6)` | Scan |
| **F7** | `Auto-Hack (F7)` | Auto-Hack |
| **F8** | `Overdrive (F8)` | Overdrive |

Each calls **exactly the same binding function Neuro's action calls**, so a
working key proves Neuro's route rather than a parallel test path. The outcome
appears at the top of the panel and in `reframework/log.txt`. The rest of the
panel is read-only: binding state, gauge readouts, the scan inventory, and what
the scan filters removed.

Overdrive drives a cinematic pipeline — test it on a disposable save. With an
empty gauge, F8 should refuse with a readiness reason; a silent success there
would mean the readiness check isn't working.

## Configuration

User-tunable settings live in
[`autorun/pragmata/mod_config.lua`](autorun/pragmata/mod_config.lua), documented
inline and re-read each game launch. Edit it in the **deployed** mod directory
(`reframework/autorun/pragmata/mod_config.lua`).

**Autonomy**

- `autonomy_nudges` (default `false`) — emit an in-combat hint listing which
  abilities are currently available, encouraging Neuro to act proactively. When
  false, Neuro only acts on direct request.
- `autonomy_nudge_interval_frames` (default `1800`, ~30 s) — minimum frames
  between nudges.

**Hacking**

- `hacking_auto_force` (default `true`) — send `actions/force` the moment a grid
  appears, so Neuro plans immediately.
- `hacking_render_legend` (default `true`) — include the cell-glyph legend. It
  only lists glyphs actually present in the current puzzle.
- `hacking_render_adjacency` (default `true`) — include the per-direction legal
  first-move block. It's the largest chunk of per-puzzle text; turn it off to
  test whether the grid alone is enough.
- `hacking_require_reasoning` (default `false`) — require a step-by-step
  `reasoning` string before the moves. More accurate, noticeably slower.
- `hacking_show_overlay` (default `true`) — draw the on-screen
  "`<display_name>` is hacking" banner. No-ops on builds without REFramework's
  `draw` API.
- `hacking_overlay_x_fraction` / `hacking_overlay_y_fraction` (`0.5` / `0.08`) —
  banner placement as fractions of screen size; nudge if it overlaps the HUD.

**Scan reporting**

- `scan_report_detail` (default `"located"`) — `"located"` lists every instance
  individually; `"grouped"` gives one line per kind with the nearest distance.
- `scan_report_require_distance` (default `true`) — report only markers the
  engine can actually place. Abandoned automatically for a scan where nothing
  has a distance, rather than reporting an empty area.
- `scan_report_distance_limit` (default `12`) — most individual distances one
  row prints before summarising the rest.
- `scan_report_max_groups` (default `8`) — most distinct marker kinds named
  before `(+N more marker types)`.
- `scan_filters` — the liveness filter layers, each independently switchable.
  Every layer answers *dead*, *live*, or *no evidence*, and a marker is hidden
  **only** on a definite dead, so a broken layer cannot empty the report. The
  panel can toggle them live for the session.
- `scan_dedupe_markers` / `scan_dedupe_radius` (`true` / `0.5`) — collapse
  repeated pings describing one physical object.
- `scan_pickup_checks` (default `true`) — read each marker's own item and
  interaction state, which is what answers "is that pickup still there".

**Other**

- `display_name` (default `"Neuro"`) — name shown in the on-screen hacking
  banner. Purely cosmetic.
- `archive_enabled` / `archive_gui_path` / `archive_discover_paths` —
  collectible-document capture. `archive_gui_path` is build-dependent and has no
  default: set `archive_discover_paths = true`, open a document in-game, and
  watch `reframework/log.txt` for the candidate path. Capture is idle until it's
  set.

## Hacking integration

The hacking minigame (the `app.PuzzleSnake` cursor-routing puzzle) is the most
fully-integrated subsystem:

1. The mod observes `_StartTrg` on the active `PuzzleSnake` instance and, the
   moment a grid appears, sends an `actions/force` with the rendered grid as the
   `state` field and `pragmata_hack_plan` as the only allowed action. Only one
   force may be outstanding, so replies are never ambiguous.
2. Neuro returns a list of cardinal moves. The render highlights **bonus
   nodes** — cells that do more damage and make the hack last longer — and asks
   Neuro to route through as many as possible en route to the goal. A longer
   bonus-collecting path beats the shortest path, as long as it still reaches
   the goal and avoids traps, error nodes, and its own trail.
3. The mod dispatches one cell per ~130 ms by writing the target coords into
   `PuzzleSnake._NextMovePosition`. The engine's natural input pipeline
   (`updateInput → updateNextPosition → updatePuzzleMovement → onEnterGrid`)
   then processes each move for free: walls block, directional gates enforce,
   trail flags update, bonus and skill cells trigger, `EraseCode` traps fire,
   and **goal arrival auto-completes the puzzle** with the full completion
   animation.

While Neuro drives a hack the mod draws a HUD-styled **"`<display_name>` is
hacking"** banner (planning → executing move N/M → COMPLETE/FAILED), so it's
clear Neuro and not the player is moving the cursor.

Full schemas, the glyph table, and integration notes are in
[ACTIONS.md](ACTIONS.md#pragmata_hack_plan).

## Files referencing game internals

Files under [`autorun/pragmata/bindings/`](autorun/pragmata/bindings/) reference
real Pragmata class and method names extracted from the IL2CPP dump. The public
API surface (the `pragmata.bindings.<system>.*` Lua functions) is intentionally
neutral — internal type and method names live inside the binding files and are
never returned to callers, so the rest of the mod reads without exposure.

## Troubleshooting

**Mod logs `mailbox dir not ready`** — the directory
`<Pragmata>/reframework/data/pragmata_mailbox/` doesn't exist. Create it.

**Sidecar logs `bridge connection failed`** — Neuro isn't running, or it's bound
to a different port than `--bridge-url`.

**Mod doesn't load** — check `<Pragmata>/reframework/log.txt` for Lua errors.
Most common cause: the `pragmata/` subfolder didn't get copied. Both
`pragmata_main.lua` **and** the `pragmata/` directory must be inside
`reframework/autorun/`.

**An ability action fails** — read the message; each refusal names its own
cause (nothing locked on, gauge empty, jamming active, upgrade not unlocked,
not in gameplay). Then press the matching **F6/F7/F8** key: since the key calls
the same binding, a key that also fails means the game is refusing, while a key
that works means the problem is in the action plumbing rather than the ability.

**An ability reports failure but the effect happened anyway** — the confirmation
window (2–3 s) expired before the engine's state transition was observed. Check
the abilities panel, which shows which confirmation evidence was and wasn't
seen.

**Dialogue lines aren't captured** — verify `reframework/log.txt` shows
`[pragmata] dialogue: …` lines as subtitles appear. If not, the GUI hierarchy
may have changed in a patch; check that `UI/Asset/ui2000/gui/ui2010` still
resolves.

## Open items

- **`archive_gui_path` is unset by default**, so collectible-document capture
  does nothing until it's discovered per build.
- **Directional grid cells** (`OneWay`, `TwoWay*`) exist in the engine's enum
  but have never appeared in an observed grid; `OneWay` renders as a generic
  `?`.
- **Mission/objective state** is not yet bound.

## License

[MIT](LICENSE).
