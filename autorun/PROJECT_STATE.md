# PRAGMATA AI Mod — Project State

What the deployed mod does, and why it does it that way. **The code is the
authority**: where this document and a `.lua` file disagree, the file is right
and this document is a bug.

| Document | Covers |
|---|---|
| `CLAUDE.md` | how to work on the mod: layout, transport, rules, engine facts, verification |
| this file | what each subsystem does, what was measured, what is still open |
| `../neuro-pragmata-main/ACTIONS.md` | the wire surface an AI peer sees (schemas, replies, context) |
| `../neuro-pragmata-main/README.md` | the player-facing overview and install guide |

## Contents

1. [Tested platforms](#tested-platforms)
2. [Per-frame work](#per-frame-work)
3. [Diana's three abilities](#dianas-three-abilities)
4. [Scene prompts](#scene-prompts)
5. [Scan reporting](#scan-reporting)
6. [Hacking](#hacking)
7. [Shelter, menus and catalogs](#shelter-menus-and-catalogs)
8. [Context emitted](#context-emitted)
9. [The mod menu](#the-mod-menu)
10. [Configuration](#configuration)
11. [Open items](#open-items)

## Tested platforms

The mod has been played and tested only on **Windows, with mouse and
keyboard**. It has **not** been tested on Linux (Proton / Steam Deck) or with a
controller. Both can cause input problems:

- **Controller.** The puzzles read input on one of two branches, chosen by the
  input scheme (`PuzzleBase.getMouseMoveMode()`; see
  [The environmental hacks](#the-environmental-hacks)). The mod forces the
  pad branch for the frames a press is in flight. That is the branch a
  controller uses natively, but it has never been exercised with a real pad
  connected, so a pad's own stick and button input may compete with injected
  presses. Scan's injected command and the scene-prompt press have the same
  gap.
- **Linux.** REFramework, the file mailbox under `reframework/data/` and the
  Python sidecar all run under Proton untested. Paths and file locking between
  the game and a native sidecar are the likely trouble spots.

The published README carries the same warning.

## Per-frame work

The transport (file mailbox + Python sidecar) is described in `CLAUDE.md`.
Each frame after startup `pragmata_main` drains the inbox (at most 8 lines),
then calls:

- `command_input.tick()` — Scan's injected-command queue;
- `puzzle_input.tick()` — the other puzzles' paced and gated presses;
- `puzzle_snake.tick_plan()` — the grid move dispatcher;
- the `tick_plan` of every other puzzle family.

`action_gates` polls about five times a second (every 12 frames) and the
dispatcher re-announces the action set when it changes.

## Diana's three abilities

All three are confirmed in game, and each has exactly one dispatch path. There
is no fallback route, so nothing can fire an ability twice.

| Ability | Dispatch | Confirmed by | Window |
|---|---|---|---|
| Scan | `command_input.queue_scan()` injects the game's own Scan command | the engine reaching `ScanManager.requestScan` | 120 frames |
| Auto-Hack | `AutoHackWorkUnit.startAutoHack()` on the live work unit | `get_IsAutoHacking()` rising | 120 frames |
| Overdrive | `app.PlayerDeathblowDriver.tryDeathblow()` | a `DeathblowStatus` start flag, or a real gauge spend | 180 frames |

None of them takes arguments. `startAutoHack()` has no target parameter, so the
lock-on decides the target; the binding resolves it only to refuse early when
nothing is locked on. Abilities are hidden until `GuiManager.getSafeRoomLevel`
reads at least `abilities_min_shelter_level` (the Cradle opening has none), and
in the Shelter's sector.

**Scan** injects at the input layer: `command_input.lua` hooks
`app.PlayerInputDriver.isTrigger` / `isDown` / `isRelease` and answers true for
the Scan command hash for a few frames, which produces the real scan with its
full presentation. `requestScan(bool)` is hooked, never called: the hook is how
`request_progressed()` learns the engine got there. Calling it directly works
but skips the chain that draws the scan. Requests are debounced 8 frames.

**Overdrive** was settled by two entry/exit captures:

```
f15046  ENTER tryDeathblow()        depth 0
f15046    ENTER startDeathBlow()    depth 1
f15046    EXIT  startDeathBlow()    depth 1
f15046  EXIT  tryDeathblow()        depth 0
f15047  canDeathblow() -> false ; DeathblowStatus raised Request
f15050  cleared CanDeathblow|Request, raised Play|Start ; gauge 126.65 -> 26.65
f15133  cleared Play  (ability ends, ~87 frames after dispatch)
```

- `tryDeathblow()` **wraps** `startDeathBlow()`; chaining them as a "fallback"
  would be a second activation.
- Dispatch is on the driver, **not** the command layer: no
  `PlayerInputCommand` changed state in either capture.
- The cost is a fixed **-100 of 150**, a spend, not a "gauge full" requirement.
- Readiness is **`DeathblowStatus.CanDeathblow`**. A usable ability read `36`
  (`CanDeathblow|FindTarget`) while `FinishBlowStatus` / `PuzzleStatus` read
  `0`. `FindTarget` is a precondition, not permission, and is not used.
- The driver raises `Request` and the state machine consumes it four frames
  later, hence the 180-frame window.
- `requestWideFinishBlow`, `execWideFinishBlow`, the Override requests and gauge
  clearing were not called in either capture; nothing resolves them.

## Scene prompts

`bindings/cutscene_prompt.lua`, `cutscene_prompt_observer.lua`.

Some scripted scenes stop on the Overdrive button icon. They are run by
`app.EventActionDeathBlowUnlock_PLWrapperd` (subclasses: the Ch14500 boss and
the Filament Remover); a hook on its `update()` finds the live ones.

A traced manual press showed `Wait → AddGauge → icon.requestOpen →
WaitGaugeFullEffect`. The scene waits there, and a press runs the action's
`onSpecialMove()`, which closes the icon; the next frame the state is
`StartedDeathBlow`. No command reader is asked for the press, and
`tryDeathblow()` is not involved.

- The prompt counts as up while the action is in `WaitGaugeFullEffect` or
  `WaitStartDeathBlowButton` and the icon is open (latched from hooks on
  `FinishBlowGuiMediator.requestOpen` / `requestClose`).
- The observer forces `pragmata_overdrive`; while a prompt is up,
  `ability_actions` routes that action to `cutscene_prompt.press()`, which calls
  `onSpecialMove()`. A press is confirmed when the scene leaves the waiting
  state.
- The Filament Remover asks for the filament-cleaning button, so it gets its own
  action, `pragmata_purify` (`cutscene_prompt_buttons.filament = "purify"`),
  announced only while its prompt is up.
- **First boss (Solar Power Plant).** Pressing that prompt ends the cutscene, but
  the boss still needs a normal Overdrive. `cutscene_prompt_followup_overdrive`
  waits until the scene action stops updating, waits 2 s, then calls
  `overdrive.trigger()` every 0.5 s for up to 10 s until the game confirms it.
  The log line "prompt N up" names the prompt's sector, which is what that
  setting is keyed on.

All three scene kinds are confirmed in game.

## Scan reporting

`pragmata_scan` is both the scan and the re-read. `scan_memory.lua` makes a new
scan only once the last one (the peer's or the player's) is `scan_cache_seconds`
(7) old; otherwise it returns the held results, labelled as cached with their
age. A new scan's result waits for the list to settle and carries the findings;
that scan is left out of the context stream. A scan the player makes produces
one context line:

```
Diana scanned: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m).
```

The leading count is the number of **located** instances and always equals the
number of distances after it. The stages:

- **Naming.** `object_names.lua` resolves hashes through the game's catalogs
  (`GuiDataManager` / ObjectIDs / Variety / ScanIconType). Unnamed markers are
  described by kind (objective marker, escape hatch, point of interest). A
  marker named **(from contents)** was named by the item its container holds. No
  hash reaches the peer.
- **Liveness filters** (`scan_filters`) each answer *dead*, *live* or *no
  evidence*. A marker is dropped only on a definite dead, so a broken layer
  cannot empty the report. `filter_bypassed` marks a scan where everything was
  filtered and the cut was abandoned.
- **Join.** Distances come from `ScanCandidateUnit`, matched per instance where
  possible. The inventory's `join` counters (`context` / `pair` / `none`) show
  how well; `context = 0` with a non-zero `pair` means distances have degraded
  to per-type.
- **Dedupe.** Same object id + icon within `scan_dedupe_radius` m collapse.
  Without a world position the distance is the identity, which can merge two
  same-type objects at equal range.
- **Located-only cut.** Only markers with a distance are reported; if none has
  one, the cut is abandoned (`distance_bypassed`) and the line degrades to names
  and counts.
- **Pickability.** `cannot be taken yet` comes from `RestrictInteractData.IsRestrict`
  (the game refusing interaction right now). The partial case carries no number,
  because the flag is counted over the whole group and the row lists only
  located instances.

The report carries no marker totals: counts the peer cannot act on contradicted
the rows beside them. They are still in `get_inventory()`.

## Hacking

Three minigames, one loop (`hacking_observer.lua`): the enemy grid and two
environmental families. They share `app.PuzzleBase`. Only one `actions/force` is
outstanding at a time; each carries a `priority` (`puzzle_force_priority`: the
enemy grid `high`, the rest `low`), which is advice to the peer, not
arbitration here. The enemy grid's force is also `silent: true`
(`puzzle_force_silent`): the peer answers without commenting on each one. The
other families and the scene-prompt force (`cutscene_prompt_force_silent`) send
no `silent` key.

### The enemy grid (PuzzleSnake)

`bindings/puzzle_snake.lua` keeps a record per live puzzle and matches the
visible one against `HackingManager.LastHackingTarget`, so an old plan cannot
land on a new target. The reader takes the grid from
`GridAccessor._GridController` / `_ActualGrid`, compacts skipped rows and
columns, tracks the trail and reads the dynamic blockers.

Moves are dispatched by writing the next absolute cell into
`PuzzleSnake._NextMovePosition` (`via.Int2`) at ~130 ms a cell. That runs the
engine's own `updateInput -> updateNextPosition -> updatePuzzleMovement ->
onEnterGrid`, so walls block, traps fire and the goal completes the puzzle.
`Unit.move(via.Int2)` would teleport instead, and is not used.

Findings:

- **Sticky-bomb removal never changes the grid dimensions.** Removed rows and
  columns are flagged per cell and listed on `GridAccessor` (`get_SkipRow()` /
  `get_SkipCol()`), then restored by `expansionRow()` / `expansionCol()`.
  `GRID_ACTUAL_SIZE_X/Y` keeps the full size.
- **Red error nodes are not a `_GridType`.** They read `None`; the marker is
  `Grid._ObstacleReasons`, a bitmask of `ObstacleReason` (`ObstacleGrid=1`,
  `DeadFilament=2`, `Ch16092=4`, `Ch14100=8`, `AllPassed=16`). Bits change
  mid-fight. They render as `d`, distinct from walls `#`, because entering one
  resets the whole hack.
- **`_IsGoldenPath` is not rendered.** It is the engine's auto-hack route and
  would hand the peer a solved path.
- **A plan into a wall runs** like a player's input would; the peer gets the
  outcome as the tool result and the grid again. Only plans into red blocks are
  refused up front (`hack_block_refuse_plan`).

### Enemy grid modifiers

Read by `bindings/puzzle_snake_modifiers.lua`, field reads only (method calls
every frame locked the game on the final boss). All three were tested in game.

**Red blocks** (`app.ch16092PuzzleSnake`; the jamming-panel enemies ch14100 /
ch16200 use the same rectangle shape). Large rectangles that fail the hack on
contact, removed one at a time by shooting the enemy's antennas, top-left
first; they can grow back.

- Read from `ObstacleGridUnit.<ManagedObstacleGridList>`: each block has
  `<GridPosition>{StartPoint, EndPoint}` (**EndPoint is inclusive**) and
  `<IsActive>`. Bit 4 marks exactly the covered cells. Index 0 is top-left.
- `get_isProgressImpossibleGrid()` reads **false even with all 4 up**, so the
  gate counts blocks instead.
- Cells render as `R` and are part of the structure signature, so a block
  appearing or going replans.
- **Gate** (`hack_block_gate`): with all blocks up, no force; one spoken notice
  per puzzle per block count, "sealed … shoot the antennas … top-left first".
- The start cell can sit inside a block.

**Corruption** ("dead filament"). Dithered cells that stun the cursor for a
moment without failing the hack; the player clears them with filament
purification.

- A cell is corrupted with `_DeadFilamentType` Random/Fixed, ObstacleReason bit
  2, or type `DeadFilament`. Corruption is decided by the cells alone.
- Rendered as `c` (walkable, avoid when a clean route exists).
- **Gate** (`hack_corruption_gate`): a corrupted grid over
  `hack_corruption_max_cells` (30, compacted size) is not forced; one spoken
  "purify the corruption first". The cells flicker, so a large grid stays gated
  `hack_corruption_hold_seconds` (3) after the last look that had one. An
  unsettled gate answer is never cached.
- `hack_corruption_gate_skip_sectors` exempts Experimental Pragmatics, whose
  corrupted enemies come before the scene that unlocks purification. Matching is
  by the map's sector name (language-dependent; a sector hash also works).
- **Dispatch.** While `_MoveBlockReasonFlag ~= 0` the queue holds (capped at
  5 s). A move eaten by a stun is retried, at most 3 times, and only if the move
  block was seen in the last 0.6 s: `_LastUnitMoveResult` stays `Stun` long
  after the stun ends, so it cannot be used.

**Exploding rows** (final boss, `app.ch14500PuzzleSnake`;
`<attackController>.<AttackUnitList>`). Whole rows pulse (Sign, 1.2 s) and
explode (Attack, 0.2 s); a cursor on one fails the hack.

- **Not rendered** (they are short-lived and would cover the goal and bonuses).
- `_explosion_gate` simulates the queue at `hack_explosion_move_seconds` with
  `hack_explosion_margin_seconds` margins: go, hold on a safe cell, or step to a
  safe neighbour and back. A hold over 4 s moves on anyway.
- `_guard_idle` covers the time no plan runs, which is when the cursor actually
  got caught: it steps off a pulsing row and back.
- A reset within 1 s of an explosion is reported as "An exploding row caught the
  cursor". Switch: `hack_explosion_guard`.

**Grids offered instead of forced.** With `hacking_auto_force = false` every
enemy grid, and with `"not_open"` a grid on an enemy already open from the last
hack, goes out as one silent context message (`force_blocked` returns it)
instead of a force: the grid only (`snake_render.render_grid_only`; legend with
`hacking_context_legend`), once per layout per enemy (`rec.offer`). The peer
decides: an unforced `pragmata_enemy_hack_plan` is adopted for that grid
(`unforced_offer_id` / `adopt_offer`; refused with the current grid if the
cursor or board moved since the offer) and its failures resolve directly,
since the server retries only forced actions. A hack ending clears `rec.offer`
(`resolve_plan` and the completion claims), because the game puts the same layout
back for the next hack.

The environment families get the same treatment from the observer itself
(`hacking_observer` `send_offer` / `_adopt_offer`), with `hacking_auto_force =
false` only: where `_reconcile` would force, it sends the family's
`render_state(id, { board_only = true, legend = hacking_context_legend })` as
silent context (the board without the instructions; `puzzle_render` drops the
answer format, how-to-solve text and, without `legend`, the reading key) and
takes the force snapshot (so
`needs_force` stays false until the board changes, and the circuit's
`forced_view` reconciles the answer). An unforced call of the family's action is
adopted for that board, or refused when the hack is gone or not taking input, or
refused with the current render when `needs_force` says the board changed.

**Checked plans.** `set_plan` (or the first dispatch of a parked plan) walks
the plan with `snake_render.check_plan`: on the board, plain walkable cells
only, never the trail, ends on G. A checked plan interrupted from outside
resolves `success: true` saying why: the player stopping aiming or turning to
another target (20-frame grace), the layout changing (`tick_plan`'s structure
check, or the observer's `discard_plan` on a grid-change edge), the enemy dying
(sweep; not kept). Only then is it stored in `_plan_store` (at most
`hack_plan_store_max`, 3, across enemies; oldest dropped). `replay_cached`
reruns a stored plan once, without asking, when the same record shows the same
layout with the cursor at the plan's start, and removes it as it starts; a
replay is not stored again. The observer asks it before forcing or offering.
`resolve_plan` (reset, failed, completed) and the sweep drop that record's
plans. Storing at check time (the first version) replayed a completed plan on
the reset grid several times in a row.

**Enemies already open.** A successful hack leaves the enemy open for a while.
`force_blocked` reads
`_TargetPuzzleUnit` → `_EnemyUpdater` → `<HackingDriver>k__BackingField` →
`EnemyHackingDriver.get_InHackingMode()` (a method call, at most every 0.25 s,
only while the grid is interactive). An unreadable answer counts as not open. If the window ends
while the grid is still up, the peer is asked. `InHackingMode` reading as
"open" is confirmed in game.

**The finale.** The final boss's last hack is five fixed stages, identical
across runs (`FINALE_STAGES` at the end of `puzzle_snake.lua`, keyed by
`snake_render.layout_fingerprint`, i.e. what the peer sees). Stage 5 opens with
a ~14 s scripted "optimizing hacking matrix" sequence during which the puzzle
reads as playable field for field; solving it then cut the animation and
soft-locked the game. No engine flag distinguishes it, so the mod holds stage 5
for `hack_finale_hold_seconds` (16) from first sight. All five stages are forced
with `ephemeral_context = false` (`hack_finale_keep_context`).

### The environmental hacks

| Family | Types | Action | State |
|---|---|---|---|
| Circuit | `PuzzleCircuit` (+ `WithTimer`, `Advanced`, level reskins) | `pragmata_enviro_hack_rotate` | played in game |
| Buttons | `PuzzleButtonTimingNoRotate`, `PuzzleButtonTiming` | `pragmata_enviro_hack_sequence` | played in game |

- **Discovery needs no hooks.** `HackingManager.LastHackingTarget` →
  `PuzzleUnit.get_MyPuzzle()` → walk the type's parent chain to the family (so
  `AdvancedPuzzleCircuit` and the `chNNNNN` reskins resolve).
  `PuzzleUnit.IsGimmick` tells environmental from enemy (`_TrailTargetType` is
  the fallback).
- **Lifecycle is polled**, from `PuzzleBase` fields that sit at the same offsets
  on every family (`_State`, `_OpenStatus` / `_CloseStatus`, `_InitTrg`).
- **Input goes through the command layer, on one of two branches.** The puzzles
  query `PuzzleUp/Down/Left/Right` only while `PuzzleBase.getMouseMoveMode()` is
  false (pad). On mouse + keyboard it is true and they ask nothing, filling
  `_TrgUp`… from `PlayerCommandUpdater.getVec2("Move")` instead.
  `puzzle_mouse_mode.lua` reports false for the frames a press is in flight
  (`puzzle_force_button_mode`, `puzzle_force_button_frames`). `puzzle_input.lua`
  paces presses by the game's `_InputEnableInterval`. `_Trg*` fields are read as
  confirmation, never written.
- **GUI parameter objects are the read surface.** `app.gui.ui3510.OpenParam.Lines`
  for the circuit; the sequence comes from the puzzle's own button list (the GUI
  copy, `ui3500.OpenParam`, came back undecodable).
- **The peer plans; the mod times.** The timed sequence's window is a few frames
  wide; `puzzle_input` fires each press on a frame the engine's `_Inside` flag
  accepts.
- **What is rendered is what the player sees.** The button ring is on screen, so
  it is transcribed. The circuit's solution is computed (the press counts) only
  after the mod's wiring model reproduced the engine's connection flags on that
  board; connector names are measured by pressing each direction once before
  the force.
- A disabled family (`puzzle_kinds`) is still detected and narrated, but its
  action is not registered and it is never forced.

### Outcomes, failures and retries

Outcomes come from the puzzle the player aims at and from a **backstop** on
`app.player.PuzzleStatus` (`PuzzleSuccess` = 256, `PuzzleFailed` = 512), which
fires wherever the aim is; the two are de-duplicated within ~1 s. The backstop
only narrates; it never resolves a deferred result.

A `success: false` result to a forced action is retried by the Neuro server, so
the observer sends no second force. A failure on a still-live hack is held until
the binding would ask again (`needs_force`), then sent with the current board
and the force slot kept. A fresh force goes out only after `force_retry_limit`
failures in a row, no retry within `force_retry_wait_seconds`, or a puzzle that
does not settle within `force_retry_settle_seconds` (then the failure goes out
as `success: true`, "nothing to retry"). A plan that ends short without moving
re-forces, up to 3 times. Refusals in `set_plan` go through
`puzzle_plan.refuse`. Every deferred result is answered within
`deferred_result_max_seconds` (12).

## Shelter, menus and catalogs

Read-only actions about the player and the game's menus. Wire format in
`ACTIONS.md`; the menu → screen code → data table is in `CLAUDE.md` §3.

- **The main Shelter** is the Shelter's sector once the player is past the
  opening tutorial (which runs in the same sector). By default it is judged by
  the Archive's Help note about the Shelter (`shelter_reached_rule = "help"`);
  the game's Shelter level (`bindings/shelter_progress.lua`) turns true too
  early.
- **Two stable actions read the open menu.** `pragmata_menu_list` (no arguments)
  and `pragmata_menu_info` (`names`) answer for whichever menu is on screen
  (`menu_actions.lua`; `menu_gui` maps menus to screen codes); the reply's first
  line names it. They are registered in the main Shelter or while one of the
  screens is open, not per menu, because every change to the action set slows
  the peer down. `menu_observer.lua` pushes "<menu> is open / closed" (debounced
  two polls; nothing during loads).
- **Menus are read only while open.** Closed-menu readings (game data and
  snapshots) were tried and gave wrong answers, so buying and mod changes were
  dropped with them.
- **Levels are shown up to the stage cap**, the levels the story has opened
  (`upgrade_level_cap`). The Firmware screen carries its cap
  (`UnitInfo.UnlockMaxLevel`); the printer uses
  `ReinforceManager.getMaxLevelWithOutHide(id, false)`.
- **The Unit Printer lists all three tabs** (Weapon, Attachment, HackingNode):
  the one on screen, those seen this visit (a per-visit cache, refreshed every
  ~1 s) and those not viewed yet (rebuilt from game data, under a warning).
  A tab that rebuilt empty is listed with a "cannot be read" line.
- **The catalogs are the Archive pair's `catalog` choice.** `pragmata_archive_list`
  / `_info` (always registered) read the Archive anywhere, and `library`,
  `bot_database`, `simulations`, `earth_memories` in the main Shelter or with
  their screen open. A gain is pushed as silent context only in the Shelter,
  except a new Archive document (Help notes included), which is pushed anywhere.
  Each push carries the call that reads the new entries. More than six new
  entries at once is taken as a save load and not announced.

## Context emitted

The full list with examples is in `ACTIONS.md` → *Context messages emitted by
the mod*. Everything goes through `util/emit.lua`, silent by default.

`emit.lua` distinguishes a `narrative` and a `transient` lane, but **the lane
never reaches the wire**: the line that would add it (`emit.lua:30`) is
commented out. Whether to enable it is the one open design question in the
transport.

Scene, area and checkpoint **codes** are never sent; opaque hashes are used for
transition detection. The map area's player-facing name is sent with the area
summary.

### Dialogue

Subtitles go out as spoken lines, `speech/started` / `speech/ended`
(`dialogue.lua`, `dialogue_transport = "speech"`), not as context. The text
comes from the subtitle panel (`bindings/subtitle_panel.lua`, GUI path
`UI/Asset/ui2000/gui/ui2010`). The speaker, line type and length come from
`MessageManager`'s current message (`bindings/speaker_resolver.lua`). A line
is open while its text is on screen. It ends when the text changes (the next
line starts on the same frame), when it has been gone for
`dialogue_end_grace_frames` (12), when the panel stops drawing for 30 frames,
or on a script reset. `expected_duration_ms` is the message's
`_DispEndTime - _DispStartTime`.

The reply level comes from `ConversationManager` (`bindings/dialogue_talk.lua`):
the playing talk's id, the source table holding it, and the serious / event
flags. First match wins: serious talk, cutscene line or scripted event →
`always`; a talk from `dialogue_ambient_sources` → `never`; anything else →
`maybe`.

Measured in-game (2026-11-16: one session of 80 lines in speech mode, an
earlier one of 186 for the levels):

- 73 of 79 ended lines stayed open within a second of their expected length
  plus the grace: a 1.5 s bark about 90 frames, a 3.0 s talk about 180.
  Replaced lines ended at once, a second or two early.
- The game closing ends no line: the last one stayed open and the server's
  own timeout closes it.
- `_PlayingTalkID` is already set on the subtitle's first frame.
- Sources seen: combat barks `battle` (never), Diana and Hugh in the Shelter
  `shelter` (maybe), story talk while exploring `stage` (maybe, or always when
  flagged serious), door and switch remarks `gimmick` (never). Cutscene
  subtitles have no talk id and read as `Cinematic` (always).
- The "[IDUS transmission signal]" caption has no talk id, no speaker and no
  length: it goes out as "Unknown voice", type `Dialogue`, reply `maybe`.

The server's startup acknowledgement is stored (`dispatcher.session()`) and
shown in the mod menu. Nothing else uses it.

## The mod menu

`mod_menu.lua`, under the REFramework menu (**Insert**) → **Pragmata Neuro**.
Drawing it reads only the mod's own state; no game call runs while it is open.

- **Status**: the bridge (mailbox ready, both file sizes, when the last message
  came in), the actions (registered, held by the peer, when last re-sent), a
  hack request waiting for an answer, a scene prompt waiting, and the session
  log's path.
- **Re-send actions**: `dispatcher.reregister_all()`, exactly as if the server
  asked: `startup`, the full action list, the startup rules, and the
  re-register hooks (which free the hack and scene-prompt force slots).
- **Reset hacking**: `hacking_observer.reset()`: answers a held failure,
  resolves every live puzzle's pending plan as stopped, discards the plans and
  snapshots, frees the force slot and drops the offer, so the hack on screen is
  asked about afresh.
- **Rescan archive and catalogs**: `catalog_actions.rescan()` (trackers
  re-baselined, screen caches dropped; nothing already found is announced as
  new).
- **Clear bridge files**: `bridge_mailbox.clear()`, two clicks within 5 s:
  empties both `.jsonl` files and reads the inbox from its new start; the
  sidecar notices the outbox shrinking.
- **Setup values**: on a button press, the current sector's name and hash and
  every held item's internal name (`state_repair_kit_item`, the sector names
  in part 2 of the config).

The four developer panels (Abilities / Hacking / Puzzle / State Debug, F4–F11)
and the `debug_*` readers behind them were removed for release; they are in
git history.

Files the mod writes under `reframework/data/`: the mailbox `.jsonl` files
(append-only, across sessions) and one log per session in
`pragmata_logs/pragmata_<date>_<time>.log` (delete old ones by hand).

## Configuration

Everything tunable is in `pragmata/mod_config.lua`, documented in place and
re-read each launch. Settings worth knowing about:

- `puzzle_kinds`: switch the circuit or the sequence hack off for the AI.
- `puzzle_force_button_mode` (on): what makes the puzzles hear an injected press
  on mouse + keyboard; turning it off only reproduces the original failure.
- `action_descriptions = "short"` sends one-sentence descriptions and moves the
  long rules into each force's state (`rules_in_force`) or one context message.

## Open items

**Not verified in game** (code written; last recorded as awaiting a test):

- Shelter: the Archive "new entry" push after its two fixes (first document of a
  new game, Help notes); the Help-note "main Shelter" rule on a new game;
  abilities waiting for the Shelter level; the screen-catalog rebuild and sector
  fallback on a new game; menu open/close pushes; the argument-less menu actions;
  the printer's three-tab listing, and the Hide filter (if the AI's printer
  list misses Attachment units the game shows, set
  `printer_keep_hidden_tabs = { "Attachment" }`).
- Catalogs: the "new entry" pushes firing; an owned but unplaced Earth Memory
  reading as not placed; an unreached tram station counted rather than listed;
  a one-page entry no longer repeating its text as `[page 1]`.
- Hacking: the corruption-gate fixes in Experimental Pragmatics; the drain fix
  for a last move that does not land; the exploding-row timing
  (`hack_explosion_move_seconds`) and idle guard; the finale stage-5 hold.
- Linux and controller play: see [Tested platforms](#tested-platforms).

**Known gaps:**

- Context lanes are inert (`emit.lua:30`).
- Directional grid cells (`OneWay`, `TwoWay*`) have never been seen in a grid;
  `OneWay` renders as `?`.
- Dialogue capture depends on the GUI path `UI/Asset/ui2000/gui/ui2010`
  ([Dialogue](#dialogue)).
- Train hub, weapon selection and elevator screens (ui0071 / ui5112 / ui5113)
  have no actions.
- `../neuro-pragmata-main/autorun/` is a stale mirror; sync it as a release step.
