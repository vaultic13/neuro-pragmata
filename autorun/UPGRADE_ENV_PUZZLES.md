# Upgrade target: environmental hacking puzzles

Status document for one upgrade. When it is finished and its findings have been folded
into `PROJECT_STATE.md`, this file can be deleted.

## The problem

The mod understands exactly one hacking puzzle: `app.PuzzleSnake`, the cursor-routing
grid on enemies. `bindings/puzzle_snake.lua` is the only module that resolves an engine
puzzle type, and `hacking_observer.lua` imports it directly. Every other hacking puzzle
in the game — the ones on switches, doors and elevators — is structurally invisible.

Those puzzles are entered the same way, use the same controls, and produce the same
kind of result. The capture in `data/pragmata_mailbox/lua_to_bridge.jsonl` shows the
damage:

- **9** `Hacking grid started.` events
- **5** grid renders (`actions/force`)
- **3** terminal outcomes (`Hack succeeded.`)

Hacks the peer never got to play, and hacks it played but never saw end. Two causes,
both fixed here:

1. Non-snake puzzles are never detected at all.
2. Even for snake, lifecycle triggers are read only from the instance matching
   `HackingManager.LastHackingTarget`, so an outcome that fires while the player's aim
   is elsewhere is never observed.

## Goal

The AI peer can detect, read and *play* every hacking puzzle in the game through the
same force -> plan -> deferred-result loop it already uses for the snake grid.

## Engine findings

### The shared base

Everything derives from **`app.PuzzleBase`** (`: app.AppBehaviorBase`). These fields sit
at identical offsets on every concrete kind, which makes them the generic lifecycle
surface:

| Field | Offset | Meaning |
|---|---|---|
| `_TargetPuzzleUnit` | 0x58 | the `app.PuzzleUnit` this puzzle is bound to |
| `_OpenStatus` / `_CloseStatus` | 0x68 / 0x70 | `app.puzzle.Status` bitmask |
| `_LastSuccessArgs` | 0x80 | `PuzzleBase.SuccessArgs` |
| `_State` | 0xa0 | `PuzzleState` = `Play` \| `Stop` |
| `_InitTrg` | 0xa4 | init edge |
| `_RequestForceSuccess` | 0xa5 | polled request field (writable) |
| `_ToggleMouseMode` | 0xa6 | |
| `_FailedToFinish` | 0xa7 | |

`app.puzzle.Status` (bitmask) carries the useful ones: `Play=1`, `Open=8`, `Close=16`,
`Failed=64`, `Success=1024`, `Success_Lv1..Lv4=2048..16384`, `Progress=2^30`,
`Jamming=562949953421312`.

`app.PuzzleBase.PuzzleState` has exactly two members: `Play`, `Stop`.

### The socket

`app.PuzzleUnit` owns a puzzle and is what `HackingManager` tracks:

| Field | Offset | Meaning |
|---|---|---|
| `_MyPuzzle` | 0xd8 | the live `PuzzleBase` — also `get_MyPuzzle()` |
| `_Hash` | 0x110 | |
| `_InoperableCause` | 0x114 | `PuzzleInoperableCauseType` = `Lock\|Erode\|Jamming\|None` |
| `_TrailTargetType` | 0x13c | `PuzzleUnit.Type` = `Enemy` \| `Prop` |
| `_PuzzlePriorityType` | 0x140 | `Enemy\|EnemyHigh\|PropForBattle\|Prop` |
| `_Enabled` / `_IsPlayablePuzzle` | 0x174 / 0x175 | |
| `IsGimmick` | 0x17a | **environmental (switch/door/elevator)** |
| `IsEnemy` | 0x17b | |
| `_EnableAutoHack` | 0x179 | |

`IsGimmick` / `Type.Prop` is the environmental-vs-enemy discriminator.

### The five families

| Family | Types | Mechanic | Read surface |
|---|---|---|---|
| **Snake** *(already done)* | `app.PuzzleSnake` + `ch14100` / `ch14500` / `ch16092` / `ch16200` variants | route a cursor to Goal | `GridAccessor` |
| **Circuit** | `app.PuzzleCircuit`, `PuzzleCircuitWithTimer`, `AdvancedPuzzleCircuit`, `PuzzleCircuitCh14310`, `ch17020MissilePuzzleCircuit`, `ch18000MissilePuzzleCircuit` | rotate 1-3 pieces until each connects to the centre | `_Question : Grid[][]` @0xc8, `_Goals : HashSet<Int2>` @0xd0, `_GuiParam : app.gui.ui3510.OpenParam` @0xe0 |
| **Buttons** | `app.PuzzleButtonTimingNoRotate` (untimed), `app.PuzzleButtonTiming` (timed) | press up/down/left/right in order | `_Buttons : List<Button>` @0xb8, `_Current` @0xe0, `_Max` @0xf8, `_Inside` @0x106, `_CurrentAngle` @0xe4, `_ParamBuff : app.gui.ui3500.OpenParam` @0xd0 |
| **SlidePipe** | `app.PuzzleSlidePipe` | 15-puzzle sliding tiles connecting pipes | `_Board : Board` @0xb8 (`_Grids : Grid[][]`, `_EmptyPosition`, `moveInput(Direction)`, `isComplete()`) |
| **ThroughThePath** | `app.PuzzleThroughThePath` | rotate rows of a 5x5 board to open a path | `_Grids : Grid[,]` @0xb8, `_SelectingColumn` @0xd8, `get_RotatableRow()`, `IsThroughThePath(Int2,Int2)` |

Circuit's per-cell `Grid`: `_SourceType` @0x10 (`None\|Start\|Goal\|Open\|FinishBlow`),
`_PathType` @0x14 (`None\|Up\|Down\|Left\|Right`, the pipe openings), `_PathSource`
@0x18, `IsConnectingToGoal` @0x1c, `_IsRotatable` @0x1d; methods `rotateClockwise`,
`rotateCounterclockwise`.

Buttons' per-step `Button`: `Command : PuzzleButtonTiming.Way` @0x10
(`Up\|Down\|Left\|Right`), `AngleRange : via.Range` @0x14.

### The GUI params are the cleanest state source

Prefer these over walking raw boards where they suffice.

**`app.gui.ui3510.OpenParam`** (Circuit, on `_GuiParam`):
`Lines : Line[]` where `Line = { LineType:int, QuestionTarget, Rotation:int,
Connected:bool }`; `RemainingTime : float?`; `TimerRate : float?`; `Success`;
`Failed`; `InitTrg`. `#Lines` is literally the "1-3 things to rotate".

**`app.gui.ui3500.OpenParam`** (Buttons, on `_ParamBuff`):
`InputCommands : Way[]` (the required order; it IS rendered -- see *Where the
build differs from the plan*),
`CircleNum` / `CurrentCircle` (total / current step), `CurrentAngle`,
`SuccessAngles : float[]`, `SuccessRanges : float[]`, `IsInside`, **`NoRotateMode`**
(distinguishes the timed from the untimed variant at runtime), `StartTrg`,
`SuccessTrg`, `FailedTrg`, `InitTrg`.

### Discovery needs no hooks

`app.HackingManager` (singleton) holds `LastHackingTarget : PuzzleUnit` @0x28 and
`_PuzzleDriverList : List<PuzzleDriver>` @0x30, with `getSortedPuzzleDrivers()`.
`app.PuzzleDriver` has `get_CurrentPuzzle()` and `Units : PuzzleUnit[]`. So:

```
HackingManager.LastHackingTarget      -- an app.PuzzleUnit
  -> PuzzleUnit.get_MyPuzzle()        -- an app.PuzzleBase
  -> get_type_definition():get_full_name(), walked up the parent chain
  -> the family
```

Walking the parent chain matters: `AdvancedPuzzleCircuit` and the `chNNNNN` reskins
must resolve to their family rather than falling through as unknown.

**Do not hook `PuzzleBase.success` / `onFailed` / `startPuzzle`.** They are virtuals
that most concrete kinds override, so a hook on the base implementation would see only
the non-overriding kinds. Poll the base *fields* instead.

### Input already exists and is already injectable

`app.hid.PlayerInputCommand` declares, among others:

```
PuzzleUp  PuzzleDown  PuzzleLeft  PuzzleRight  PuzzleDecide
PuzzleMode  PuzzleMoveMouse  PuzzleSnakeProgressReset
PuzzleUpForKeyboard  PuzzleDownForKeyboard  PuzzleLeftForKeyboard  PuzzleRightForKeyboard
```

`bindings/command_input.lua` already hooks
`app.PlayerInputDriver.isTrigger / isDown / isRelease(System.UInt32)` and answers true
for a named command — exactly how Scan works today, and it enumerates the command table
from the running game rather than guessing hashes.

Corroborating evidence that the puzzles read commands by hash:
`PuzzleButtonTiming` carries a static `INPUT_KEY : uint[]` @0x50 and
`convertInputHashToWay(uint)`; `PuzzleCircuit` has `updateTrigger(app.PlayerHandle)`
feeding `_TrgUp` / `_TrgDown` / `_TrgLeft` / `_TrgRight`, and
`app.PlayerHandle.get_Command()` returns `app.hid.IPlayerCommand`.

Pacing should come from the engine: `PuzzleCommonSettingUserdata.PuzzleInputSetting.
_InputEnableInterval`, reachable from `PuzzleCircuit._PuzzleCommonSettingUserdata`.

### Cross-kind completion backstop

Already reflected in `bindings/player_status.lua` but never read by the observer:
`app.player.PuzzleStatus` with `PuzzleSuccess = 256` and `PuzzleFailed = 512`. These
live on the player driver, not on a puzzle instance, so they fire regardless of where
the player is aiming. `app.PlayerHandle` also exposes `onSuccessPuzzle` /
`onFailedPuzzle`.

## Decisions

- **AI plans, mod validates.** The mod can read the answer — `InputCommands` *is* the
  button order — but must not put it in the render. The peer gets what a player sees;
  the mod dispatches its reply and reports the real outcome. No auto-solve fallback.
- **The mod owns frame timing.** For `PuzzleButtonTiming` the peer supplies the
  *order*; the mod watches `_Inside` / `_CurrentAngle` each frame and fires each press
  on a valid frame. A peer cannot hit a few-frame window over a websocket.
- **One action per family.** `pragmata_hack_plan` stays snake-only and untouched.
- **All five families in scope.** SlidePipe and ThroughThePath are written against the
  dump only and ship behind config flags, default off.

## Architecture

### New files

```
pragmata/bindings/puzzle_registry.lua   discovery + kind resolution + PuzzleBase reads
pragmata/bindings/puzzle_input.lua      paced/gated Puzzle* command presses
pragmata/bindings/puzzle_mouse_mode.lua force the branch that reads commands
pragmata/bindings/puzzle_circuit.lua    Circuit family
pragmata/bindings/puzzle_buttons.lua    ButtonTiming + ButtonTimingNoRotate
pragmata/bindings/puzzle_slide.lua      SlidePipe
pragmata/bindings/puzzle_path.lua       ThroughThePath
pragmata/util/puzzle_render.lua         renderers for the four new families
pragmata/puzzle_debug.lua               ImGui panel: live kinds, raw state, input probe
```

`util/snake_render.lua` is untouched — its glyph vocabulary is snake-shaped by design.

### The family-binding interface

`hacking_observer.lua` currently calls ~17 functions on `bindings.puzzle_snake`
directly. That set becomes an interface every family implements, so the observer
becomes kind-agnostic:

```
M.kind                      -- "snake" | "circuit" | "buttons" | "slide" | "path"
M.action_name               -- the dispatcher action this kind answers with
M.get_state(id)             -- plain Lua table, no engine values
M.render(state, opts)       -- text for the force's `state` field
M.struct_sig(state)         -- fingerprint; excludes progress, includes layout
M.snapshot_force_target(id) / M.struct_changed(id) / M.needs_force(id)
M.set_plan(id, plan, resolve) / M.discard_plan(id) / M.has_plan(id)
M.current_plan_status(id) / M.consume_plan_events(id)
M.is_interactive(id) / M.tick_plan()
```

Reuse verbatim from `puzzle_snake.lua`: the deferred-result plumbing (resolve parked on
the **record**, not the plan, fired exactly once), the structural-signature staleness
check, the parked-plan / re-aim model, and the one-outstanding-force rule. Those are
the parts that took the most tuning and none of them are snake-specific.

### Actions

| Action | Family | Schema |
|---|---|---|
| `pragmata_hack_plan` | Snake | unchanged |
| `pragmata_hack_rotate` | Circuit | `{ rotations: [{ piece:int, steps:int }] }` |
| `pragmata_hack_sequence` | Buttons | `{ order: ["up"\|"down"\|"left"\|"right", ...] }` — order only; the mod times each press |
| `pragmata_hack_slide` | SlidePipe | `{ moves: ["up"\|"down"\|"left"\|"right", ...] }` |
| `pragmata_hack_rows` | ThroughThePath | `{ rotations: [{ row:int, steps:int }] }` |

Each mirrors `pragmata_hack_plan`'s handler shape: hand the reply to the observer, park
it on the puzzle the in-flight force was for, and `return ctx.defer()`.

## Phases

**Code status: phases 2-6 are written. Phase 1 failed on its first run, was
fixed, and PASSES on its second — the input route is now proven in-game. What
had been hiding behind it was a loader bug, not a design problem: see *Loading*
below.**

- [x] **1. Prove the input route.** RUN AND PASSED (2026-09-06). The first run
      failed — every probe came back "never asked about by the game", correctly,
      because on mouse + keyboard these puzzles ask nothing (see *The input
      route*). After `bindings/puzzle_mouse_mode.lua`, the second run fired
      roughly ninety probes across the circuit and buttons families and all but
      two came back `CONSUMED as PuzzleUp/Down/Left/Right after 1 frames`. The
      two misses were each the last press of a burst, most likely frames where
      the puzzle was mid-animation and consulted nothing;
      `mod_config.puzzle_force_button_frames` exists to widen the window if that
      rate ever grows.
- [x] **2. Registry + generic lifecycle.** `puzzle_registry.lua`, observer generalised,
      start/success/fail context for every kind including the currently-invisible ones.
      This alone closes the orphan-completion gap.
- [x] **3. Buttons family.** Simplest state, and it proves the gated-press path for the
      timing variant.
- [x] **4. Circuit family.** Read via `ui3510.OpenParam.Lines` first; fall back to
      walking `_Question` only if `Lines` proves insufficient.
- [x] **5. SlidePipe and ThroughThePath.** Dump-only. Ship behind
      `mod_config.puzzle_kinds`, default off until seen working in-game.
- [x] **6. Docs refresh.** `ACTIONS.md`, `README.md`, `PROJECT_STATE.md`.

## Where the build differs from the plan

Two deliberate departures, both worth knowing about.

**The button sequence IS rendered to the peer.** The plan said never to put
`InputCommands` in the render, on the principle that the mod must not hand over
an answer it read from memory. That was wrong for this puzzle specifically: the
whole ring of prompts is drawn on screen for the player, so transcribing it is
showing the peer the screen, and withholding it would make the action
unanswerable — there would be nothing for the peer to reason from. The principle
still holds everywhere else: the circuit's connectivity solution and any pipe
route are computable from what the mod reads, and neither is rendered.

**The path action is `pragmata_hack_path` with `column`, not
`pragmata_hack_rows` with `row`.** The dump turned out to describe a single
rotatable row with a selection that moves along the COLUMNS
(`_SelectingColumn`, `get_RotatableRow()` returning one index), so addressing by
row would have been meaningless.

Also worth noting, though it is an addition rather than a departure: actions for
a family disabled in `mod_config.puzzle_kinds` are not registered at all. An
action the observer will never force could only ever tell the peer there was
nothing to plan.

## The input route

This is what phase 1 found, and it is the one thing in this document that was
measured rather than inferred. The type dump said the puzzles read
`PlayerInputCommand` hashes; that is true, but only half the time.

**`app.PuzzleBase.getMouseMoveMode()` picks one of two branches**, and which one
depends on how the player is playing:

| Mouse mode | What the puzzle does |
|---|---|
| `false` (pad) | `PuzzleCircuit.updatePuzzleInput` / `PuzzleButtonTiming.updateInput` call `app.PlayerInputDriver.isTrigger` with `PuzzleUp`/`PuzzleDown`/`PuzzleLeft`/`PuzzleRight`. This is the route `command_input.lua` answers. |
| `true` (mouse + keyboard) | The puzzle asks **nothing**. `updateMoveInput` reads `app.PlayerCommandUpdater.getVec2("Move")`, thresholds it at ±0.5 into the puzzle's own `_TrgUp`/`_TrgLeft`/`_TrgRight`/`_TrgDown`, and the input branch reads those flags straight back. |

So the probe's verdict was exact. Nothing was ever asked.

The fix is `bindings/puzzle_mouse_mode.lua`: one post-hook on
`getMouseMoveMode()` that reports `false` for the few frames a press is in
flight, so the puzzle takes the branch that asks a question we have an answer
for. Scoped to the press and requested only by `puzzle_input.lua`, so the
player's own mouse control is untouched the rest of the time. The alternative --
hooking `getVec2` and returning a fake stick vector -- was rejected: a
struct-by-value return is not reliably settable from a REFramework post-hook, and
a fabricated movement vector can leak into player movement on a frame before the
puzzle's own `setInhibit(Move)` lands.

## Loading

The second run proved the input route and immediately exposed the thing sitting
above it: **the family bindings were never loading at all.**

```
puzzle_registry: failed to load pragmata.bindings.puzzle_circuit:
    module 'pragmata.bindings.puzzle_circuit' not found:
```

The files were on disk the whole time. The search list printed in the error
names the game root, the `lua/` and `share/lua/5.4/` conventions and `.\` — and
never `reframework/autorun/`. **REFramework's module search path carries this
directory only while it is loading scripts at startup**; a `require` first
reached at runtime fails.

Every other module in the mod is reached at boot, which is why nothing had ever
hit this. The apparent counter-example proves it: `hacking_observer`'s runtime
`require` of `bindings/player_status` works only because `bindings/overdrive`
pulled it in at boot, making it a `package.loaded` cache hit. `puzzle_circuit`,
`puzzle_buttons`, `puzzle_plan` and `util/puzzle_render` were required by
nothing at boot — and they are exactly the modules that failed.

Because `binding_for` latches its failures, one error per family meant that for
the rest of the session those puzzles had no reader, no render, no plan and no
action, and the peer was never told they existed. Fixed by
`puzzle_registry.preload()`, called once from `pragmata_main` at boot. Nothing
in the mod may lazily `require` anything, ever.

Three further facts came out of the same investigation:

- **`PuzzleUpForKeyboard`, `PuzzleDownForKeyboard`, `PuzzleLeftForKeyboard`,
  `PuzzleRightForKeyboard` and `PuzzleDecide` are dead constants.** They are
  declared in `app.hid.PlayerInputCommand` and referenced nowhere else in the
  shipped code. `puzzle_input.lua` used to press the keyboard variants alongside
  the pad ones; they are gone, and `puzzle_path_rotate_command` no longer
  defaults to `"decide"`.
- **`PuzzleSlidePipe` and `PuzzleThroughThePath` have no mouse gate.** Both call
  `PlayerInputDriver.isTrigger` with the direction hashes unconditionally, so
  those two families are reachable by the existing hook either way. They stay
  behind `mod_config.puzzle_kinds` because their *readers* are still unverified,
  which is a separate question from their input.
- **`PlayerInputDriver.isDown` / `isRelease` are never reached from puzzle
  code.** `app.PlayerUpdater.isTrigger` forwards to `PlayerInputDriver`, but
  `isDown` / `isRelease` / `getVec2` / `getFloat` go straight to
  `app.PlayerCommandUpdater`. `PuzzleSnakeProgressReset` is read through
  `PlayerCommandUpdater.isDown`, which is why it was dropped from the command
  table rather than left in place to be silently ignored.

### Correction: the `PuzzleBase` offsets above are 8 bytes low

Every row of the `app.PuzzleBase` table in *Engine findings* understates the
offset by 8. The real values are `_TargetPuzzleUnit` `0x60`, `_OpenStatus` /
`_CloseStatus` `0x70` / `0x78`, `_State` `0xA8`, `_InitTrg` `0xAC`,
`_RequestForceSuccess` `0xAD`, `_ToggleMouseMode` `0xAE`, `_FailedToFinish`
`0xAF`. Derived-class offsets in this document are correct as written.

Nothing in the mod is affected -- every field is resolved by name, not by offset
-- but this document is used to plan work, so the numbers in it should not be
wrong.

## Open unknowns

Each of these is a real question the dump cannot answer. Record the answer here when
the game answers it.

- **Do the new puzzles read `PlayerInputDriver.isTrigger` with the `Puzzle*`
  hashes?** ANSWERED: **only when `getMouseMoveMode()` is false.** On a pad, yes,
  and the four direction hashes are the right ones. On mouse + keyboard they read
  nothing at all. See *The input route* above. The `*ForKeyboard` variants and
  `PuzzleDecide` are dead constants and were never the answer.
- **Circuit input mapping.** Does a direction press rotate the piece on that side
  (`button2Index(ButtonIndex,int,int)` suggests so), or move a selection that
  `PuzzleDecide` then rotates?
- **Do injected commands actually set `_TrgUp` ... `_TrgDown`?** They are one-frame
  `*Trg` fields, so they can be *read* as confirmation but never written.
- **The real value of `_InputEnableInterval`.**
- **SlidePipe and ThroughThePath input mapping.** Entirely unverified. Neither appears
  in any capture in `data/pragmata_mailbox/`.
- **Is `Lines[i]` order in `ui3510.OpenParam` a stable on-screen piece order?** It must
  be, or the peer's `piece` index means nothing.
- **Which variant is which.** `NoRotateMode` on `ui3500.OpenParam` should distinguish
  the timed from the untimed button puzzle at runtime; confirm it matches the concrete
  type (`PuzzleButtonTimingNoRotate` vs `PuzzleButtonTiming`).

## Verification

No automated tests are possible for engine-facing code. Every item is an in-game
check. **Item 1 has been run: it failed, was diagnosed, and is fixed** -- see
*The input route*. It is now the pass condition rather than the open question,
and items 2-8 are still unvalidated.

1. **Input route (blocking).** Puzzle Debug panel, **Input probe** node, real
   environmental puzzle. First read *Input branch*: `mouse move mode` TRUE plus a
   trigger flag flickering on a **manual** press is the original failure, seen
   directly. Then fire a probe: it must read `CONSUMED` **and** the puzzle must
   visibly react. Both -- a consumed command on its own only proves the game
   asked us a question. `hook fired` stuck at 0 means the branch hook is not in
   the call path, which is a different fault from the mode being false.
2. **Kind resolution.** Panel shows the correct family, `IsGimmick`, and stable ids
   while walking between a hackable enemy and a hackable door without ids churning.
3. **Lifecycle coverage.** Replay the capture scenario — several enemies hacked while
   switching aim, plus one door or switch. Every start must now have exactly one
   terminal outcome in `lua_to_bridge.jsonl`. The 9-start / 3-outcome asymmetry is the
   regression baseline.
4. **Per family, end to end.** Force fires -> peer answers -> mod dispatches -> puzzle
   completes -> the peer's *deferred* tool result reports what actually happened. Test
   a deliberately wrong plan too: it must resolve as a real failure, not "applied".
5. **Timing variant.** The press lands while `_Inside` is true. A press outside the
   window is withheld, not fired late.
6. **No contention.** Trigger a Scan (F6) mid-puzzle-dispatch; neither is lost.
7. **Regression on snake.** F6/F7/F8, `pragmata_hack_plan`, the overlay phases and the
   abilities panel unchanged. `python -m sim.run_eval --peer-url ... --trials 20`
   against `sim/stub_peer.py` still round-trips.
8. **Spoiler boundary.** `grep -rn 'sdk\.\|app\.[A-Z]' pragmata --include=*.lua` outside
   `bindings/` stays empty except comments, and no rendered force contains the solution
   the mod read from `InputCommands`.
