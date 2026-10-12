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
and playing the hacking minigames — and streams game state back as context.

How to work on it is in `CLAUDE.md`.

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
    scan_memory.lua          last scan's time / place: scan again or use cache
    ability_state.lua        gauge / readiness / unlock / scan-result emitters
    world_state.lua          scene, checkpoint, combat edges
    autonomy.lua             optional in-combat ability hints
    dialogue.lua             subtitle capture     dialogue_speaker.lua  speaker
    archive.lua              collectible-document capture
    hacking_observer.lua     puzzle lifecycle -> actions/force, for every kind
    hacking_overlay.lua      on-screen "<peer> is hacking" banner
    abilities_debug.lua      ImGui panel + the F6/F7/F8 manual triggers
    hacking_debug.lua        ImGui panel + the only remaining file dump
    puzzle_debug.lua         ImGui panel: sequence-hack group switch, peer view
    game_state.lua           the read-only state actions: pragmata_status
                             (health, location, weapons, mods, inventory);
                             describe_upgrades for State Debug only
    game_state_observer.lua  area / low-HP / equip context pushes
    action_gates.lua         which actions are offered now (Shelter, prompts)
    menu_actions.lua         pragmata_menu_list / _info: every menu below,
                             by a `menu` enum, always registered
    shelter_menu_actions.lua Firmware Updater, Unit Printer, train mod menu
    stamp_actions.lua        the Stamp Club board
    catalog_actions.lua      Data Library, Archive, Bot Database, Training
                             Simulations, Earth Memories + Shelter-only pushes
    sector_actions.lua       the tram's sector selection
    state_debug.lua          ImGui panel for all of the above (F9 / F10 / F11)
    bindings/                everything that names real game types
    util/                    log, emit, json, snake_render, puzzle_render,
                             name_match
```

## Shelter and menu actions

Read-only actions about the player and the game's menus, each answering from
live game data. Their wire format and examples are in `ACTIONS.md`.

- **Two stable actions.** Every menu and catalog is a `menu` value of
  `pragmata_menu_list` / `pragmata_menu_info` (`menu_actions.lua`), registered
  once and never hidden: the Shelter's menus open and close constantly, and
  every change to the action set slows the peer down (BEST_PRACTICES.md). Each
  menu keeps its gate (`mod_config.menu_gui` maps menus to screen codes), and a
  call while it is closed is refused with the gate's reason. Until 2026-10-11
  these were nineteen actions, each announced only while its screen was open.
- **Gating** remains for the abilities and hacking actions: `action_gates`
  polls about five times a second and the dispatcher re-announces the set when
  it changes. In the Shelter the abilities and hacking actions go away.
- **Menus read their own screen** (Firmware Updater, Unit Printer, train mod
  menu, Stamp Club, tram sector selection), so values match what is shown. The
  printer rebuilds the tabs not on screen from the same data.
- **Catalogs read game data** (Data Library, Archive, Bot Database, Training
  Simulations, Earth Memories), so they answer anywhere in the Shelter; the
  Archive anywhere at all. A gain is pushed as silent context only while in
  the Shelter.
- **`pragmata_mods`** reports only equipped mods, each with what it does.

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
`command_input.tick()` (Scan's injected-command queue), `puzzle_input.tick()`
(the other puzzles' paced/gated presses), `puzzle_snake.tick_plan()` (the grid
move dispatcher) and the `tick_plan` of every other puzzle family loaded so
far.

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

**Scene prompts** (`bindings/cutscene_prompt.lua`, `cutscene_prompt_observer.lua`).
Some scripted scenes stop on the Overdrive button icon. The scene is run by
`app.EventActionDeathBlowUnlock_PLWrapperd` (subclasses: the Ch14500 boss and
the Filament Remover). A hook on its `update()` finds the live ones.

The 2026-10-09 trace of a manual press (boss scene) showed the sequence
`Wait → AddGauge → icon.requestOpen → WaitGaugeFullEffect`. The scene waits
there, and a press runs the action's `onSpecialMove()`, which closes the icon.
The next frame the state is `StartedDeathBlow`. `tryDeathblow()` is not
involved, and no command reader is asked for the press: injecting SpecialMove
+ FinishBlow on all three readers did nothing.

So the prompt counts as up while the action is in `WaitGaugeFullEffect` or
`WaitStartDeathBlowButton` and the icon is open. The icon state is latched
from hooks on `FinishBlowGuiMediator.requestOpen` / `requestClose`. The
observer forces `pragmata_overdrive`, and while a prompt is up
`ability_actions` routes that action to `cutscene_prompt.press()`. A press
counts as confirmed when the scene leaves the waiting state.

**Confirmed end to end on 2026-10-10.** The prompt was detected and the force
sent. Neuro's `pragmata_overdrive` pressed it and the scene continued, with the
result `"pressed the scene's Overdrive prompt; the scene continued
(StartedDeathBlow)"`. `press()` therefore calls the action's own
`onSpecialMove()`, and that is its only route. The command-injection and
`tryDeathblow` routes, the extra command readers they needed and the F3 press
trace were removed on 2026-10-11 once all three scene kinds worked; recover them
from git history if a patch changes how a scene reads the press.

The Filament Remover scene, traced on 2026-10-11, behaves the same way: in
`WaitGaugeFullEffect`, a press runs `onSpecialMove()`, which runs
`onStartDeathBlow()` → `startDeathBlow()`, and the state goes to
`StartedDeathBlow`. It asks for the filament-cleaning button, so it is offered
as its own action, `pragmata_purify`
(`cutscene_prompt_buttons.filament = "purify"`). That action is announced only
while its prompt is up, and the observer syncs the action set before forcing
it.

**First boss (Solar Power Plant).** Pressing that scene's prompt ends the
cutscene, but the boss still has to be finished with a normal Overdrive.
Delaying the press did not help (that setting was removed).
Instead, `cutscene_prompt_followup_overdrive` (2 s there) makes the observer
do the following after the prompt clears:
1. wait until the scene action stops updating (`cutscene_prompt.scene_running()`);
2. wait 2 s;
3. call `overdrive.trigger()`, the same call as F8, retrying every 0.5 s for up
   to 10 s until the game confirms Overdrive started.

Confirmed in game on 2026-10-11. The log line "prompt N up" names each
prompt's sector, which is what that setting is keyed on.

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

`pragmata_scan` is both the scan and the re-read. `scan_memory.lua` decides:
a new scan only once the last one (the peer's or the player's) is
`scan_cache_seconds` (7) old; otherwise the held results, labelled as cached
with their age. A "Hugh has moved 5 m" condition was tried and removed on
2026-10-12: the position read through handle `_Core` -> `_Updater` ->
GameObject -> Transform never returned anything. A new scan's result waits for the list to
settle and carries the findings, and that scan is left out of the context
stream.

A player-made scan produces one narrative line naming what the engine can
actually place:

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

## Hacking

The most complete subsystem. Five minigames, one loop — see **The other puzzle
families** below for the four that are not the enemy grid.

### The enemy grid (PuzzleSnake)

The most complete of the five. `bindings/puzzle_snake.lua` hooks `app.PuzzleSnake`
instances, keeps a record per live puzzle, and matches the visible one against
`HackingManager.LastHackingTarget` so an old plan cannot land on a new target.

The reader pulls the grid from `GridAccessor._GridController` / `_ActualGrid`,
compacts skipped rows and columns, tracks the trail, and reads the dynamic
blockers. `hacking_observer.lua` sends an `actions/force` with the rendered grid
the moment `_StartTrg` goes true, and only one force may be outstanding. Every
force carries a `priority` (`mod_config.puzzle_force_priority`): the enemy grid
goes out as `high` because it is nearly always mid-combat, the environmental
hacks as `low`. That is advice to the peer, not arbitration here — the
one-at-a-time rule is unchanged and stays first-come.

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

### The other puzzle families

The other four hacking minigames sit on environmental interactables — switches,
doors, elevators. They share `app.PuzzleBase` with the grid, which is what makes
one observer able to drive all five.

| Family | Types | Mechanic | Action |
|---|---|---|---|
| Circuit | `PuzzleCircuit` (+ `WithTimer`, `Advanced`, level reskins) | rotate 1-3 pieces until each reaches the centre | `pragmata_enviro_hack_rotate` |
| Buttons | `PuzzleButtonTimingNoRotate`, `PuzzleButtonTiming` | press the directions in order, with or without a timing dial | `pragmata_enviro_hack_sequence` |
| SlidePipe | `PuzzleSlidePipe` | slide tiles to complete a pipe run | `pragmata_enviro_hack_slide` |
| ThroughThePath | `PuzzleThroughThePath` | turn columns to open a route | `pragmata_enviro_hack_path` |

Findings worth keeping:

- **Discovery needs no hooks.** `HackingManager.LastHackingTarget` gives a
  `PuzzleUnit`; `get_MyPuzzle()` gives the live puzzle; walking its type's parent
  chain gives the family. Walking the chain is what makes `AdvancedPuzzleCircuit`
  and the `chNNNNN` reskins resolve instead of falling through as unknown.
- **Do not hook `PuzzleBase.success` / `onFailed` / `startPuzzle`.** They are
  virtuals that most concrete puzzles override, so a hook on the base
  implementation only ever sees the families that don't override them. The base
  *fields* (`_State`, `_OpenStatus`/`_CloseStatus`, `_InitTrg`) sit at the same
  offsets on every family and are polled instead.
- **`PuzzleUnit.IsGimmick` is the environmental-vs-enemy discriminator**
  (`_TrailTargetType` = `Prop` | `Enemy` is the fallback).
- **Input is the game's own command layer -- but only on one of two branches.**
  `app.hid.PlayerInputCommand` declares `PuzzleUp` / `PuzzleDown` / `PuzzleLeft`
  / `PuzzleRight`, and `command_input.lua` answers those queries by the same
  route Scan uses. The catch, found the hard way in-game, is that the puzzles
  only ask when `PuzzleBase.getMouseMoveMode()` is false. On mouse + keyboard it
  is true, and the puzzle asks nothing at all: it fills in its own
  `_TrgUp`/`_TrgLeft`/`_TrgRight`/`_TrgDown` from the movement vector
  (`PlayerCommandUpdater.getVec2("Move")`, thresholded at ±0.5) and reads those
  back. `puzzle_mouse_mode.lua` flips that branch for the few frames a press is
  in flight, which is what makes the command route reach every family.
  `puzzle_input.lua` adds pacing (from the game's own
  `PuzzleCommonSettingUserdata._InputEnableInterval`) and gating on top. The
  `_TrgUp`/`_TrgDown`/... fields are read as confirmation and never written:
  one-frame `*Trg` fields drop writes.
- **There is more than one command reader.** `PlayerInputDriver` answers
  `isTrigger`, but `isDown` / `isRelease` / `getVec2` / `getFloat` bypass it
  entirely for `app.PlayerCommandUpdater`. A hook on `PlayerInputDriver` is
  invisible to those. `PuzzleUpForKeyboard` and its three siblings, and
  `PuzzleDecide`, are declared but read by nothing in the game -- the mod no
  longer offers them.
- **The GUI parameter objects are the cleanest read surface.**
  `app.gui.ui3510.OpenParam.Lines` gives the circuit's pieces with their
  rotation and connection state; `app.gui.ui3500.OpenParam` gives the button
  sequence, the current step, the needle angle, `IsInside`, and `NoRotateMode`
  (which distinguishes the timed variant from the untimed one at runtime).
- **The peer plans; the mod times.** The timing variant's window is a few frames
  wide, which no peer can hit over a websocket. The peer supplies the order and
  `puzzle_input` fires each press on a frame the engine's own `_Inside` flag says
  would count.
- **The button sequence IS rendered to the peer.** The whole ring of prompts is
  drawn on screen for the player, so transcribing it is showing the peer the
  screen, not handing over a hidden solution. Nothing else the mod can read —
  the circuit's connectivity solution, a pipe route — is rendered.
- **SlidePipe and ThroughThePath are unverified.** Neither has appeared in a
  capture; their readers and input mapping come from the type dump. They ship
  disabled via `mod_config.puzzle_kinds` and their actions are not registered
  while disabled.

### Outcome reporting

Outcomes come from two sources. The per-puzzle edges read whatever the player is
aimed at. The **backstop** reads `app.player.PuzzleStatus`
(`PuzzleSuccess` = 256, `PuzzleFailed` = 512), which lives on the player and so
fires wherever the aim happens to be.

The backstop exists because of a measured gap: the capture in
`data/pragmata_mailbox/lua_to_bridge.jsonl` holds **9 grid-starts, 5 renders and
3 terminal outcomes**. A hack that finished after the player looked away was
never reported at all. The two sources are de-duplicated within a ~1s window, so
one outcome still produces one line. The backstop only narrates — resolving a
deferred tool result for a puzzle nobody is looking at would be guesswork, and
the record sweep already covers a puzzle that is genuinely gone.

`bindings/player_status.lua` had reflected these flags for a long time; nothing
had ever read them.

### Failures and the server's retry

A `success: false` result to a forced action is retried by the Neuro server
on its own, so the observer does not send a second force beside it. A failure
on a hack that is still live (refused, reset, stopped short, grid changed) is
held until the binding would ask again (`needs_force`), then sent with the
current render appended and the force slot kept. The mod forces afresh only
after `force_retry_limit` failures in a row, no retry reply within
`force_retry_wait_seconds`, or a puzzle that does not settle within
`force_retry_settle_seconds` (then the failure goes out as `success: true`,
"nothing to retry"). Early refusals in a binding's `set_plan` go through
`puzzle_plan.refuse`, which answers the call's own `resolve` and clears the
snapshot so the retry carries a board.

Every deferred result is answered within `deferred_result_max_seconds` (12):
past it the dispatcher replies "accepted, still running" and the real outcome
follows as context. A plan parked on a target the player looked away from is
answered that way at once.

## Context emitted

All context messages are sent with `silent: true`.

| Trigger | Message |
|---|---|
| Subtitle line | `Dialogue: [Conversation] Diana says "Let's finish this!"` |
| Collectible document opened | `Collectible document text: "…"` |
| Overdrive becomes ready | `Overdrive is ready.` |
| Auto-Hack upgrade unlocks | `Auto-Hack upgrade is now available.` |
| Scan results resolve (scans the player makes) | `Diana scanned: 1x escape hatch (32 m), 1x Upgrade Components (49 m).` |
| Scene / area change | `Hugh and Diana entered a new area.` |
| Checkpoint | `Checkpoint reached.` |
| Combat edges | `Combat started.` / `Combat ended.` |
| Hack lifecycle | `Hacking grid started.` / `Hacking grid changed; replanning.` / `Hacking grid was reset.` / `Hack succeeded.` / `Hack failed.` |
| Environmental hack lifecycle | `Device hack started.` / `Circuit hack started.` / same reset/changed wording, same `Hack succeeded.` / `Hack failed.` |
| Autonomy nudge (opt-in) | `Combat is active. Available now: … Consider using these abilities if it would help Hugh.` |

Scene, area and checkpoint **names** are never sent — only opaque hashes are
used internally for transition detection.

`util/emit.lua` distinguishes a `narrative` and a `transient` lane, but
**the lane never reaches the wire**: the assignment at `emit.lua:30` is
commented out, so every context line accumulates identically at the peer. The
lane argument is currently documentation of intent, nothing more. Deciding
whether to enable it is the one live design question in the transport.

## In-game controls

Four ImGui panels under the REFramework menu (**Insert**); the fourth,
**Pragmata State Debug**, covers the state and menu actions and is described
in `CLAUDE.md`.

**Pragmata Abilities Debug** carries the manual triggers. The hotkeys and the
button row share one `TRIGGERS` table, so they cannot drift:

| Key | Button | Calls |
|---|---|---|
| **F6** | `Scan (F6)` | `scan.scan_input()` |
| **F7** | `Auto-Hack (F7)` | `hacking.auto_hack()` |
| **F8** | `Overdrive (F8)` | `overdrive.trigger()` |
| **F4** | `Press scene prompt (F4)` | `cutscene_prompt.press()` |

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
"Dump cells to log" button, which writes `pragmata_mailbox/hacking_dump.log` on
demand. The only other file the mod writes is State Debug's F11
`catalog_dump.log`.

**Pragmata Puzzle Debug** is deliberately small. Its top section switches the
sequence hack's group (`mod_config.puzzle_sequence_group`) for the session: one
button per group, the active one marked, and the result of the last switch. A
switch re-registers `pragmata_enviro_hack_sequence` with the peer and is refused while a
sequence force is waiting for its answer. Below that it shows which puzzle is
live and whether a force is outstanding, a **peer view** with the exact state
text the peer is sent (kept after aim is released, labelled with its age), and
per-family session toggles.

The input probe (Numpad 8/2/4/6 with a consumed/never-asked history), the
circuit board dump, the per-family state readouts and the type-resolution table
mapped these puzzles and were removed on 2026-09-16 once they worked. Recover
them from git history if a game patch breaks a puzzle's input route or board
reading.

## Configuration

Everything tunable is in `pragmata/mod_config.lua`, documented in place, re-read
each game launch. Broad groups: autonomy nudges, hacking render/force options,
scan reporting detail and caps, scan filter layers, dedupe, pickup checks,
archive capture, peer display name, and the hacking overlay.

`puzzle_kinds` enables the non-grid hacking families individually. `slide` and
`path` ship off because they are unverified; a family that is off is still seen
and narrated, but its action is not registered and it is never forced.
`puzzle_path_rotate_command` exists because which button turns a piece in the
path family is the least certain thing in that binding; it defaults to `"up"`
since `"decide"` turned out to name a command nothing reads.
`puzzle_force_button_mode` (default on) is what makes any of these puzzles hear
an injected press on mouse + keyboard; it is a no-op on a pad, and the only
reason to turn it off is to reproduce the original failure.

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
- **The environmental puzzles have never played end to end.** Two of the three
  layers are now confirmed in-game (2026-09-06). The input route works: after
  `puzzle_mouse_mode.lua`, roughly ninety probes across circuit and buttons came
  back consumed within a frame. The loader is fixed: those families' bindings
  had been failing to load entirely, because a `require` first reached at
  runtime does not resolve (see `CLAUDE.md` §3), so the puzzles had no reader
  and were never announced to the peer. What is still unproven is the layer
  above both -- force, peer plan, dispatch, real outcome -- which needs the
  sidecar running; the last test session had none, and all eighteen forces
  expired on the watchdog. `UPGRADE_ENV_PUZZLES.md` lists what is left.
- **Not seen in game yet** (the test save had everything done): the catalog
  "new entry" pushes firing; an owned but unplaced Earth Memory reading as not
  placed; a tram station not reached yet being counted rather than listed; a
  one-page Library / Archive entry no longer repeating its text as `[page 1]`.
- **Train hub, weapon selection and elevator screens** (ui0071 / ui5112 /
  ui5113) have no actions; State Debug -> Menu object (F10) dumps them.

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
