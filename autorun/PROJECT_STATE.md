# PRAGMATA AI Mod — Project State

The current state of the deployed mod. **The code is the authority**: where this
document and a `.lua` file disagree, the file is right and this document is a
bug. It replaces `PROJECT_ANALYSIS.md`, `RUNTIME_DATA_COLLECTION.md` and
`plan.md`, all of which described a discovery phase that is now finished.

A player-facing overview lives in `../neuro-pragmata-main/README.md`; the wire
surface an AI peer sees is in `../neuro-pragmata-main/ACTIONS.md`.

## What it is

A REFramework Lua mod for Pragmata (IL2CPP RE Engine) that lets an AI peer act
as Diana. It exposes four gameplay capabilities — Scan, Auto-Hack, Overdrive,
and routing the hacking minigame — and streams game state back as context.

Lua talks to the game only through REFramework's `sdk` reflection and hooks;
there are no native offsets, no injected DLL, no virtual input device, and no
OS-level key synthesis.

## Layout

```
autorun/
  pragmata_main.lua          entrypoint: boots the mailbox, registers actions,
                             pumps the inbox and the two per-frame tickers
  pragmata/
    dispatcher.lua           action registry + deferred-result plumbing
    bridge_mailbox.lua       JSONL transport under reframework/data/
    mod_config.lua           every user-tunable setting, commented in place
    ability_actions.lua      deferred confirmation windows for the 3 abilities
    ability_state.lua        gauge / readiness / unlock / scan-result emitters
    world_state.lua          scene, checkpoint, combat edges
    autonomy.lua             optional in-combat ability hints
    dialogue.lua             subtitle capture     dialogue_speaker.lua  speaker
    archive.lua              collectible-document capture
    hacking_observer.lua     grid lifecycle -> actions/force
    hacking_overlay.lua      on-screen "<peer> is hacking" banner
    abilities_debug.lua      ImGui panel + the F6/F7/F8 manual triggers
    hacking_debug.lua        ImGui panel + the only remaining file dump
    bindings/                everything that names real game types
    util/                    log, emit, json, snake_render
```

`bindings/` is the only place internal type and method names appear. Its public
functions return neutral values, so the rest of the mod reads without spoilers.

## Data flow

```
game frame
  -> bindings read/hook managed state, dispatch actions
  -> observers turn state transitions into context or actions/force
  -> bridge_mailbox appends to data/pragmata_mailbox/lua_to_bridge.jsonl
  -> Python sidecar tails it and speaks Neuro-SDK over a WebSocket
  <- sidecar appends replies to bridge_to_lua.jsonl; Lua drains <=8 per frame
```

REFramework's Lua sandbox cannot open sockets, which is the whole reason the
file mailbox and the sidecar exist.

Each frame after startup `pragmata_main` drains the inbox, then calls
`command_input.tick()` (Scan's injected-command queue) and
`puzzle_snake.tick_plan()` (the hack move dispatcher).

## Diana's three abilities

All three are runtime-confirmed and each has exactly one dispatch path. The
route-selection machinery that existed while they were being found is gone —
along with any way to reintroduce a fallback that would fire an ability twice.

| Ability | Dispatch | Confirmed by | Window |
|---|---|---|---|
| Scan | `command_input.queue_scan()` injects the game's own Scan command | the engine reaching `ScanManager.requestScan` | 120 frames |
| Auto-Hack | `AutoHackWorkUnit.startAutoHack()` on the live work unit | `get_IsAutoHacking()` rising | 120 frames |
| Overdrive | `app.PlayerDeathblowDriver.tryDeathblow()` | a `DeathblowStatus` start flag, or a real gauge spend | 180 frames |

None of the three takes arguments. `startAutoHack()` has no target parameter, so
the lock-on decides the target; the binding resolves it only to refuse early
when nothing is locked on.

**Scan** injects at the input layer: `command_input.lua` hooks
`app.PlayerInputDriver.isTrigger` / `isDown` / `isRelease` and answers true for
the Scan command hash for a few frames. That is why it produces the real scan
with its full presentation. `requestScan(bool)` is resolved and *hooked* but
never called — the hook is how `request_progressed()` learns the engine got
there. Calling it directly works but skips the action-driver chain that draws
the scan. Requests are debounced 8 frames locally.

**Overdrive** was the hard one, and two entry/exit captures settled it:

```
f15046  ENTER tryDeathblow()        depth 0
f15046    ENTER startDeathBlow()    depth 1
f15046    EXIT  startDeathBlow()    depth 1
f15046  EXIT  tryDeathblow()        depth 0
f15047  canDeathblow() -> false ; DeathblowStatus raised Request
f15050  cleared CanDeathblow|Request, raised Play|Start ; gauge 126.65 -> 26.65
f15133  cleared Play  (ability ends, ~87 frames after dispatch)
```

- `tryDeathblow()` **wraps** `startDeathBlow()`. They are one call, so chaining
  them as a "fallback" would be a second activation, not a retry.
- Dispatch is on the driver, **not** the command layer: `command_diff` was `0`
  across both entire captures. No `PlayerInputCommand` changes state, which is
  why the command-publish approach never worked and why `player_command.lua`
  was deleted.
- The cost is a fixed **-100.0 of 150**, twice — a spend, not a reset, and not
  a "gauge full" requirement.
- Readiness is **`DeathblowStatus.CanDeathblow`**. While the ability was
  usable, `DeathblowStatus` read `36` (`CanDeathblow|FindTarget`) and
  `FinishBlowStatus`/`PuzzleStatus` both read `0` — the flags the binding used
  to check would have called a usable ability "not ready". `FindTarget` is
  deliberately not treated as readiness: a target in range is a precondition,
  not permission.
- Activation is not instantaneous. The driver call raises `Request` and the
  state machine consumes it four frames later, hence the 180-frame window.

`requestWideFinishBlow(Int32)`, `execWideFinishBlow()`, the Override requests
and gauge clearing were **not** called in either capture, so nothing resolves
them any more.

## Scan reporting

A scan produces one narrative line naming what the engine can actually place:

```
Diana scanned: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m).
```

The leading count is the number of **located** instances and always equals the
number of distances after it. Getting there involves several stages, all
visible in the abilities panel:

- **Naming.** `object_names.lua` resolves hashes through the game's own catalogs
  (`GuiDataManager` / ObjectIDs / Variety / ScanIconType). Markers the catalogs
  do not name are described by what they are — objective marker, escape hatch,
  point of interest. A marker named **(from contents)** was named by the item
  its container holds. No hash ever reaches the peer.
- **Liveness filters** (`mod_config.scan_filters`) each answer *dead*, *live*,
  or *no evidence*. A marker is dropped **only** on a definite dead, so a
  broken layer cannot empty the report. `filter_bypassed` marks the case where
  everything was filtered and the cut was abandoned instead.
- **Join.** Distances come from `ScanCandidateUnit`, matched per instance where
  possible. `join: ctx=… pair=… none=…` in the panel reports how well that
  worked; `ctx=0` with a non-zero `pair` means the per-instance hypothesis is
  wrong and distances degrade to per-type. Pair-joined pings consume distinct
  candidate records, which is what fixed reports like `51 / 51 / 51 m`.
- **Dedupe.** Same object id + icon within `scan_dedupe_radius` metres collapse.
  Where a candidate has no world position the *distance* is used as identity,
  which will merge two same-type objects at equal range in different
  directions. Both survivors and casualties appear in the **Filtered out** tree.
- **Located-only cut.** Only markers with a distance are reported. If nothing at
  all has one, the cut is abandoned for that scan (`distance_bypassed`) rather
  than claiming an empty area.
- **Pickability.** `cannot be taken yet` / `some cannot be taken yet` come from
  `RestrictInteractData.IsRestrict` — the game refusing interaction *right now*
  (cutscene, locked phase). It means "not yet", not "never", which is why it is
  reported rather than filtered. The partial case carries no number on purpose:
  the flag is counted across the whole group while the row lists only its
  located instances, so a count there could contradict the count beside it.

The report deliberately carries **no marker totals**. Counts the peer cannot act
on — unlocated instances, markers at unknown range, the grand total — were
removed; each would have contradicted the rows printed next to it. They are all
still in `get_inventory()`, the log, and the panel trees.

When distances are unavailable wholesale the line degrades gracefully to names
and counts only:

```
Diana scanned: 12x Upgrade Components, 3x Lunafilament, 1x Mods, 1x Pure Lunum,
24x sub-objective markers, 15x markers (some cannot be taken yet),
4x escape hatches, 3x objective markers (+1 more marker type).
```

## Hacking (PuzzleSnake)

The most complete subsystem. `bindings/puzzle_snake.lua` hooks `app.PuzzleSnake`
instances, keeps a record per live puzzle, and matches the visible one against
`HackingManager.LastHackingTarget` so an old plan cannot land on a new target.

The reader pulls the grid from `GridAccessor._GridController` / `_ActualGrid`,
compacts skipped rows and columns, tracks the trail, and reads the dynamic
blockers. `hacking_observer.lua` sends an `actions/force` with the rendered grid
the moment `_StartTrg` goes true, and only one force may be outstanding.

Moves are dispatched by writing the next absolute cell into
`PuzzleSnake._NextMovePosition` (`via.Int2`, offset `0x1ac`) at ~130 ms a cell.
That routes through the engine's own `updateInput -> updateNextPosition ->
updatePuzzleMovement -> onEnterGrid` pipeline, so walls block, gates enforce,
trail flags update, bonus and skill cells fire, `EraseCode` traps fire, and goal
arrival auto-completes the puzzle. `Unit.move(via.Int2)` *teleports* and
bypasses all of that, so it survives only behind the debug panel's poke buttons.

Engine findings worth keeping:

- **Sticky-bomb row/column removal never changes the grid dimensions.** Removed
  rows are flagged per cell and listed on `GridAccessor` (`get_SkipRow()` /
  `get_SkipCol()`), then restored by `expansionRow()`/`expansionCol()`.
  `GRID_ACTUAL_SIZE_X/Y` keeps reporting the full size, so a reader ignoring
  the skip flags renders rows that no longer exist.
- **The red error nodes are not a `_GridType`.** They read as `None`; the live
  marker is `Grid._ObstacleReasons`, a bitmask of `ObstacleReason`
  (`ObstacleGrid=1` verified in-game, plus `DeadFilament`, `Ch16092`,
  `Ch14100`, `AllPassed`). The engine sets and clears bits mid-fight, so it is
  dynamic state, not authored layout. They render as `d`, distinct from walls
  `#`, because entering one **resets the whole hack** while a wall merely stops
  the cursor.
- **Polled fields propagate; one-frame `*Trg`/`*Trigger` fields silently drop
  writes.** Value-type fields must be mutated on an engine-supplied wrapper —
  a fresh `sdk.create_instance("via.Int2")` exposes no writable fields on the
  builds tested.
- **`_IsGoldenPath` is deliberately not rendered.** It marks the engine's own
  auto-hack route and floods most walkable cells; showing it would bury the
  real bonuses and hand the peer a pre-solved path. Debug dump only.

## Context emitted

All context messages are sent with `silent: true`.

| Trigger | Message |
|---|---|
| Subtitle line | `Dialogue: [Conversation] Diana says "Let's finish this!"` |
| Collectible document opened | `Collectible document text: "…"` |
| Gauge crosses 25/50/75/100% upward | `Hacking gauge: 75%` |
| Overdrive becomes ready | `Overdrive is ready.` |
| Auto-Hack upgrade unlocks | `Auto-Hack upgrade is now available.` |
| Scan results resolve | `Diana scanned: 1x escape hatch (32 m), 1x Upgrade Components (49 m).` |
| Scene / area change | `Hugh and Diana entered a new area.` |
| Checkpoint | `Checkpoint reached.` |
| Combat edges | `Combat started.` / `Combat ended.` |
| Hack lifecycle | `Hacking grid started.` / `Hacking grid changed; replanning.` / `Hacking grid was reset.` / `Hack succeeded.` / `Hack failed.` |
| Autonomy nudge (opt-in) | `Combat is active. Available now: … Consider using these abilities if it would help Hugh.` |

Scene, area and checkpoint **names** are never sent — only opaque hashes are
used internally for transition detection.

`util/emit.lua` distinguishes a `narrative` and a `transient` lane, but
**the lane never reaches the wire**: the assignment at `emit.lua:30` is
commented out, so every context line accumulates identically at the peer. The
lane argument is currently documentation of intent, nothing more. Deciding
whether to enable it is the one live design question in the transport.

## In-game controls

Two ImGui panels under the REFramework menu (**Insert**).

**Pragmata Abilities Debug** carries the manual triggers. The hotkeys and the
button row share one `TRIGGERS` table, so they cannot drift:

| Key | Button | Calls |
|---|---|---|
| **F6** | `Scan (F6)` | `scan.scan_input()` |
| **F7** | `Auto-Hack (F7)` | `hacking.auto_hack()` |
| **F8** | `Overdrive (F8)` | `overdrive.trigger()` |

Each calls **the same binding function the peer's action calls**, so a working
key proves the peer's route and a failure is a real failure rather than a broken
harness. The only thing skipped is the deferred confirmation window. Outcomes
show as `Last: <ability> [F6|button]: <ok> (<message>)` and go to
`reframework/log.txt`.

Overdrive drives a cinematic pipeline — test on a disposable save. With an empty
gauge F8 must **refuse with a readiness reason**; a silent success there would
mean the readiness check is not doing its job.

The rest of the panel is read-only: singleton and driver capture state, gauge
readouts, the confirmation state machine, the scan inventory tree, the
**Filtered out** tree, and live (session-only) toggles for each filter layer.
`markers: N reported / M raw` and `rows: N reported / M built` are the filter
and the located-only cut at work.

**Pragmata Hacking Debug** shows grid state, a synthetic-grid button, and a
"Dump cells to log" button — the only thing in the mod that still writes a file
of its own (`pragmata_mailbox/hacking_dump.log`), and only on demand.

## Configuration

Everything tunable is in `pragmata/mod_config.lua`, documented in place, re-read
each game launch. Broad groups: autonomy nudges, hacking render/force options,
scan reporting detail and caps, scan filter layers, dedupe, pickup checks,
archive capture, peer display name, and the hacking overlay.

`archive_gui_path` is the one setting with no sensible default: it is
build-dependent and must be discovered with `archive_discover_paths = true`.
Until it is set, document capture is idle.

## Known gaps

- **Context lanes are inert** (`emit.lua:30`), as above.
- **`archive_gui_path` is unset**, so collectible-document capture does nothing
  yet, and `archive_discover_paths` is still on.
- **Directional grid cells** (`OneWay`, `TwoWay*`) exist in the enum but have
  never been seen in a test grid; `OneWay` renders as a generic `?`.
- **Dialogue capture is build-sensitive** — it depends on the GUI path
  `UI/Asset/ui2000/gui/ui2010` continuing to resolve.
- **The source mirror in `../neuro-pragmata-main/` is stale.** Its `autorun/`
  tree predates this round of work; only its two markdown files are current.

## Recovering the discovery rigs

The trace rigs that found these paths — `ability_diagnostics.lua`,
`overdrive_probe.lua`, `probe_gui.lua` — and the input layers they exercised —
`gamepad.lua`, `keyboard_input.lua`, `player_command.lua` — were deleted once
all three abilities were confirmed. They are all in git history; recover one
from there if a game patch breaks a path. Nothing in the mod writes a trace file
any more.

If a new path ever does need mapping, the approach that worked was: resolve the
candidate methods with `sdk.find_type_definition` + `get_method(signature)`,
hook them with `sdk.hook` to capture the real `this` and call order during
**one** manual player action, record entry/exit with a depth counter, and only
then call the specific route the capture proved. Keep each scenario to a single
ability — never trace two at once — and treat "the metadata resolved" as no
evidence at all that invocation will be accepted.
