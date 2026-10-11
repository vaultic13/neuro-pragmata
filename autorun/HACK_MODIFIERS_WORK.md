# Enemy hacking-grid modifiers — work tracker

Temporary. Delete when all three parts are done, after moving what is still true
into `CLAUDE.md` §3 and `PROJECT_STATE.md` (as with the Shelter round).

Each part is implemented and tested **on its own**. Status per part at the bottom.

## The spec (from the user)

- **(a) Red blocks.** Large red rectangles, 4 of them, each much bigger than one
  cell. Touching one fails the hack instantly. The player removes them one at a
  time by shooting objects on the enemy; the removal order is fixed, the
  top-left one goes first. The mod does not shoot. It only tells the peer what
  has to be done.
  - With all 4 up, hacking is impossible (it fails the instant it starts). Send
    the peer the info that the blocks must be cleared first, not a grid.
  - With 1–3 up, hacking works. The grid sent must show which cells are blocked.
- **(b) Corruption.** A corrupted enemy has dithered "poison" cells that stop the
  next move for a moment (it doesn't fail the hack). The player clears corruption
  with a special action.
  - A grid with **more than 30 cells** (width × height) on a corrupted enemy is
    not hacked. Send the info to clear the corruption first.
  - A grid of 30 cells or fewer is hacked, with the corrupted cells shown.
- **(c) Final boss explosions.** Many cells pulse red and explode after a while.
  A cursor on a cell when it explodes fails the hack.
  - Mark them on the grid.
  - The move executor times the moves. Crossing a pulsing cell, or several in a
    row, is fine if the cursor reaches the next safe cell before the first of
    them explodes. Otherwise it stops on a safe cell shortly before the
    explosion and continues after it.

Wording uses engine names until the user corrects it after testing: "shoot the
enemy's antennas (weak points)" and "purify the corruption".

## Engine findings (dump: `reframework/sdk_ida/il2cpp_dump.json`)

Nothing below has been confirmed in game.

### (a) Red blocks

There are two candidate enemy kinds. Both use rectangles, so both match "large".

- **`app.ch16092PuzzleSnake`** (cell bit `ObstacleReason.Ch16092 = 4`):
  - `ObstacleGridUnit` → `<ManagedObstacleGridList>` (a List of `ObstacleGrid`).
  - Each `ObstacleGrid` has `<GridPosition>{StartPoint, EndPoint}` (via.Int2) and `<IsActive>`.
  - Unit methods: `getActiveObstacleCount()`, `isActiveObstacle(int)`.
  - **`get_isProgressImpossibleGrid()`**: the engine's own "no way through" flag.
  - Enemy side: `Ch16092Updater.AntennaController`, with 4 antenna parts (UpL/UpR/DownL/DownR) and an antenna recovery timer. **The blocks can come back.**
- **`app.ch14100PuzzleSnake`** (cell bit `Ch14100 = 8`):
  - `_JammingPanelUnit.get_CurrentPanelList()` returns a `JammingPanel[]`.
  - Each panel has `<StartRectPoint>`, `<EndRectPoint>`, `<IsActive>`.
  - Static `TopLeft..BottomRight` panels.
- **`app.ch16200PuzzleSnake`**: same panels, in a List `JammingPanelUnits` (each unit keyed by Level in `JammingPanelLevelDict`).
- **Generic:** `PuzzleSnake.getObstacleInfo() -> bool[]`. The GUI enum `ObstacleGridPos {LT, RT, LU, RU}`.
- **Correction:** `puzzle_snake.lua` used to call bits 4 and 8 "purple slow nodes (walkable)". The dump does not support that. Bit 1 (`ObstacleGrid`) is the **single-cell** red error node (`d`, resets), a different mechanic.

### (b) Corruption = "dead filament"

- **Enemy flag:**
  - `PuzzleSnake._IsDeadFilamentEnemy`.
  - `_DeadFilamentHandle` (`PuzzleSnakeDeadFilamentModule`), with `isDeadFilament()`, `isDeadFilamentEnemy()`, `isErode()`.
  - On the enemy, `EnemyDeadFilamentDriver.<isDeadFilament>`.
- **Per cell:** `_DeadFilamentType` (None/Random/Fixed) and ObstacleReason bit 2.
- **The stun:**
  - `PuzzleSnake._MoveBlockReasonFlag` with `PuzzleSnakeMoveBlockInputReason.DeadFilament`.
  - `_LastUnitMoveResult` (`UnitMoveResultType`: Normal, RollBack, Reset, **Stun = 3**, Block).
  - Block time: `PuzzleSnakeCommonGridUserData._DeadFilamentMoveBlockTime`.
- **Clearing:** filament purification (`PuzzleSnake.onPureFixedDeadFilament`, `PlayerFilamentPurificationDriver`).

### (c) Boss explosions = the PuzzleSnakeAttack system

- **Where it lives:** only `app.ch14500PuzzleSnake.PuzzleThink` (`Ch14500PuzzleThink`) owns it, so ch14500 is presumably the final boss.
- **Path:** `<attackController>` → `<AttackUnitList>`. Each unit has:
  - `<AttackPositionList>` (`PuzzleSnakeGridPosition {X, Y}`)
  - `<Vertical/HorizontalAttackLineList>`
  - `<attackState>` (`PuzzleSnakeAttackState` None / Sign / Attack / End)
  - `SignTimer`, `AttackTimer` (`app.Timer`: `get_RemainingTime()`, `get_TransitTime()`, `_TimeLimit`)
  - `get_attackSignTime()`, `get_attackTime()`, `isHitAttack(Int2)`
- **GUI copy:** `PuzzleSnakeGuiStatus.<AttackViewList>`.

## Part 0 — discovery tools (done 2026-10-08)

- `pragmata/bindings/puzzle_snake_modifiers.lua` reads all three modifiers (read-only, engine coordinates):
  - `read_blocks` tries the ch16092 unit, then the jamming panels, then `getObstacleInfo`.
  - `read_corruption` and `read_explosions` are the raw readouts for parts B and C.
- `puzzle_snake.debug_modifiers()` gives the runtime subclass, the three readouts, the cells per ObstacleReason bit, the stun and dead-filament cells, and the **rect_check**. The rect_check tests whether the rectangles cover exactly the block-bit cells, with `EndPoint` counted both inclusive and exclusive.
- **Hacking Debug → "Enemy modifiers"** panel:
  - The **F5** key (`mod_config.hack_modifier_snapshot_key`) snapshots all of it plus the peer's render.
  - It keeps the last 4 snapshots and appends them to `data/pragmata_mailbox/hacking_dump.log`.

## Part A — red blocks (DONE 2026-10-08)

**What it does:**
- **Cell marking** (`get_state`): a cell is `in_block` when an active rectangle covers it (inclusive) or when it carries bit 4 or 8. `state.blocks` carries `{ source, total, active, impossible, next_corner, corners_up }`.
- **Rendering:**
  - Glyph `R`, with the legend line "red block - CANNOT enter; touching it FAILS the hack".
  - A note line: "RED BLOCKS: N of T still up ... next to go: the top-left one".
  - The routing rule says never step on an R.
  - R cells are never listed as bonuses.
- **Gate** (`_gate`): fires when `impossible == true` or all of 4 or more blocks are up.
  - `force_blocked` stops the force.
  - `blocked_notice` sends the peer, once per puzzle per block count and **not silent**, "sealed ... shoot the antennas ... top-left first". The observer asks for this notice even while the puzzle isn't interactive, because a sealed grid fails on start.
  - Turned off with `mod_config.hack_block_gate = false`.
- **Plans:**
  - `set_plan` refuses a plan that walks into an `R` cell, with a tool result naming the step and the cell, and re-forces the same grid.
  - `tick_plan` checks the next move as a safety net.
  - `R` cells are in the structure signature, so a block disappearing (or coming back) mid-plan aborts the plan and replans.

**In-game test (on the antenna enemy):**
1. Aim with all 4 blocks up and press **F5**. Check:
   - `type` is ch16092 (or ch14100 / ch16200);
   - `blocks.rects` has 4 large rectangles matching the screen;
   - `impossible` is true;
   - `rect_check.inclusive` has `bit_cells_outside = 0` and `rect_cells_without_bit = 0`. If only `exclusive` is 0/0, `EndPoint` is exclusive: fix the rectangle test in `get_state`.
2. With all 4 up, try to hack. `lua_to_bridge.jsonl` should hold one non-silent context with the "sealed" message and no `actions/force`.
3. Shoot one antenna and press F5:
   - Is the removed block index 0, and is its `corner` top-left?
   - Is `active` now 3?
4. Hack. The force `state` should show the R cells (compare with the screen), the RED BLOCKS line and "next to go".
5. While a plan runs, shoot a second antenna. Expect "The grid changed mid-plan ... red block came or went" and a new force without that block.
6. If the antennas regrow: block back → replan, all 4 back → the sealed message again.

**Results (2026-10-08): done.**
- The user tested it by hand.
  - The R cells match the screen.
  - With all 4 up, the hack is refused.
  - No errors were seen.
- The wire traffic confirms it: 2 "sealed" notices and 24 forces carrying the RED BLOCKS line.
- Change requested after the test: refusing a plan that enters an R cell (with 1–3 blocks up) is now a setting, `mod_config.hack_block_refuse_plan`.
  - true = refuse and re-send at once;
  - false = let the run fail on the block.
- **F5 never recorded anything.** No `hacking_dump.log` was written and there is no "snapshot" log line.
  - The key handler now logs the press first and pcalls the snapshot, so the next try shows where it stops.
  - `os.date` is guarded in case the sandbox lacks it.
- **F5 re-test (2026-10-08, two snapshots): everything confirmed.**
  - The enemy is `app.ch16092PuzzleSnake`; the source is `obstacle_unit`.
  - The 4 rectangles are 2×2 squares in the corners of a 5×5 grid. **EndPoint is inclusive:** inclusive covers 16 cells, 0 cells are outside, 0 lack the bit. Exclusive leaves 12 bit cells uncovered.
  - Bit 4 (Ch16092) marks exactly the covered cells.
  - Index 0 is the top-left block and is removed first. After one shot: active 3, and the "next to go" names the top-right block.
  - `get_isProgressImpossibleGrid()` read **false even with all 4 up**, so the gate's block count is what decides, not this flag.
  - The start cell can sit inside a block (the cursor started at (0,0) in the top-left one).

## Part B — corruption (DONE 2026-10-08)

**What it does:**
- **Cell marking** (`read_cell`): a cell is `corrupted` if it has any of `_DeadFilamentType` (Random/Fixed), ObstacleReason bit 2, or type `DeadFilament`.
  - This replaces the old "purple slow node" reading. Those cells were already known from game footage to be walkable with a brief pause, which matches corruption.
  - Cells of type `DeadFilament` were drawn as walls before; they are now corrupted cells.
- **State:** `state.corruption = { enemy_flag, cells }` when either `_DeadFilamentHandle.isDeadFilament()` is true or at least one corrupted cell is on the grid.
- **Gate:** corrupted, and width × height over `hack_corruption_max_cells` (30; it was 36 until the user lowered it), gives one spoken notice, "the enemy is corrupted ... too large ... purify the corruption first", and no force.
  - The width × height count uses the compacted grid, i.e. after any sticky-bomb removals.
  - Turned off with `hack_corruption_gate = false`.
  - Gate results are now cached per puzzle for 0.25 s, because this check reads the whole grid.
- **Rendering:**
  - Glyph `c`. Legend: "walkable, but stuns ... does NOT fail; avoid when a clean route exists".
  - A "CORRUPTED ENEMY" note line.
  - An adjacency line, "legal -- corrupted".
  - A corrupted blue node is still listed as a bonus.
- **Dispatcher:**
  - While `_MoveBlockReasonFlag ~= 0`, the queue holds instead of dispatching. The hold is capped at 5 s, then it dispatches anyway.
  - A move that didn't land, with the cursor still on its cell during or just after a stun (or a last move result of Stun), is re-queued and retried, up to 5 times. It is no longer read as a wall.
  - Corrupted cells stay out of the structure signature.

**In-game test:**
1. On a corrupted enemy, aim and press **F5** (it should now record; see Part A).
   - Under `corruption`: is `is_dead_filament` true?
   - Under `bits.DeadFilament` and `dead_filament_cells`: do they match the dithered cells?
2. **Large grid (> 30 cells):** expect one spoken "purify the corruption first" context in `lua_to_bridge.jsonl` and no `actions/force`.
3. **Purify, then F5 again.** Did `is_dead_filament` go false and the cells vanish? If the flag stays true, the gate never lets go. Then it has to rely on the cells alone; tell me.
4. **Small grid (≤ 30):**
   - The force shows the `c` cells matching the screen, plus the CORRUPTED ENEMY line.
   - Let a plan cross a `c`: the run should pause and continue, with no "Move blocked by a wall" result.
   - The log shows `move ... dropped by a stun; retrying` if the stun ate a move.
5. A normal (uncorrupted) enemy: no `c`, no note, and moves no slower than before. Watch for a `move block held 300 frames` warning in the log: it means the flag is non-zero on normal grids too.

**Sector 5 leak (2026-10-11), fix awaiting the in-game test.** In the
"Experimental Pragmatic" sector, 6x6 and 7x7 corrupted grids were forced
anyway, usually just after the "too large" notice. The notice also repeated,
which means the gate kept clearing and coming back. Two causes:
- **The cache.** `_gate` skips the corruption check while the puzzle isn't
  interactive. That "no gate" answer was cached for 0.25 s, so a puzzle that
  went live inside the window was forced. Fix: `_gate` now returns a `settled`
  flag, and an unsettled answer is never cached.
- **Flicker.** Those enemies' corrupted cells come and go, so one look with
  zero `c` cells cleared the gate. Fix: `rec.corruption_seen` keeps a large
  grid gated for `hack_corruption_hold_seconds` (3) after the last look that
  had a corrupted cell. Purifying still clears it, 3 s later.
- **Then exempted in that sector (user, 2026-10-11).** In Experimental
  Pragmatics the corrupted enemies come before the Filament Remover scene,
  which is what unlocks purification. The gate was therefore asking for
  something the player could not do yet.
  `hack_corruption_gate_skip_sectors = { "Experimental Pragmatics" }` sends
  large corrupted grids there anyway, with the `c` cells drawn and stuns waited
  out. Other sectors are still gated.
  - Matching is by the map's sector name (`area_progress.current_sector()`),
    or by a sector hash in the list. The name follows the game's language, so
    on a non-English install put the hash from State Debug → Location in its
    place.

**Results (2026-10-08): done.**
- The user tested it: corrupted cells are detected and the gate works. They asked for the cell limit to drop from 36 to 30; it is set in `mod_config.hack_corruption_max_cells`.
- **A bug the log showed:** the stun retry also fired for moves that were simply blocked. For example, a planned move back onto the plan's own trail was retried five times before failing.
  - Cause: `_LastUnitMoveResult` stays `Stun` long after the stun is over.
  - Fix: a retry now needs the move block to have been seen within the last 0.6 s, and is allowed at most 3 times. The last move result is no longer used.
- The holds while the block flag was up worked: the log shows ~0.7 s pauses before moves after stepping on a `c`.

## Boss test, 2026-10-08 — findings

- **Explosions** (F5 at 15:29, `app.ch14500PuzzleSnake`):
  - Whole ROWS are hit (`horizontal = [2]`, then `[3]`).
  - Sign lasts 1.2 s (`sign_timer.remaining` counts down), Attack lasts 0.2 s.
  - Moves take ~0.075 s each, so plans mostly cross before a row goes off. The user saw them handled well without any Part C code.
- **The final cutscene hack** (F5 at 15:45, base `app.PuzzleSnake`, 9×9):
  - The grey cells are plain walls (`#`). There is no modifier: blocks, corruption and explosions are all empty.
  - Targeting is fine: the hack is matched (id 8, interactive) and forced at once.
  - **It failed in two ways:**
    - **The peer's route walked into a wall.** The grid is a maze whose only route is a ~26-move detour.
    - **The mod stalled after the second plan.** That plan was a single move into the same wall. A last move that doesn't land was never checked: it was reported as "ran all moves without reaching the goal", and since the cursor hadn't moved, `needs_force` never asked again. The time limit ran out.
  - **Fixes** (awaiting the in-game test):
    - The drain branch now checks the last move like the others: a stun retries, anything else goes to the settle machine, which classifies it and re-forces.
    - A plan that ends short without moving still re-forces, up to 3 times in a row.
    - A pre-run refusal for plans into walls / error nodes / off the grid was tried and **removed at the user's request**.
      - Such a plan now runs like a player's input would.
      - The peer gets the outcome as the tool result ("Move blocked by a wall after N move(s)…", or the error-node reset).
      - The grid is then sent again if the hack is still going.
      - Plans are refused up front only for red blocks (`hack_block_refuse_plan`).
- **Logs:**
  - REFramework rewrites `re2_framework_log.txt` on every start. `util/log.lua` now also writes each session to its own file, `reframework/data/pragmata_logs/pragmata_<date>_<time>.log`, falling back to `pragmata_mailbox/`. Old files are deleted by hand.
  - The mailbox `.jsonl` files and `hacking_dump.log` already append across sessions: nothing in the mod truncates them. CLAUDE.md's Transport note says otherwise; fix it at close-out.

## Part C — boss explosions (implemented 2026-10-09, awaiting the in-game test)

**Why it was needed (2026-10-09 16:17, the Eight fight).** Three hacks failed in
a row. Each time the cursor was on row 3 when it went off:
- at 16:17:24 the plan walked along the row, (4,2) → (4,3) → (3,3);
- at 16:17:27 a plan ended at (4,3) and the cursor sat there ~2 s waiting for
  the peer's next reply.

The peer's grid showed row 3 as floor. The tool result said "Hit an error
node", which an explosion failure looks identical to: the hack restarts from
the start.

**What was built:**
- **Read.** `puzzle_snake_modifiers.read_danger(inst)` uses field reads only.
  The state hash is named once through `getName` and cached, and the timers are
  `_TimeLimit - _TransitTime`. It sets `last_attack_clock` whenever a row is
  going off.
- **State.** `get_state()` sets `c.danger = { explodes_in, ends_in, exploding }`
  per cell, in engine coordinates mapped through `remap()`, so sticky-bomb
  compaction is handled. It also sets `state.explosions`. `danger` is not
  structural, so a row going off is never read as "the grid changed".
- **Render: nothing.** The danger is not drawn, at the user's request
  (2026-10-09). Rows are short-lived, can start mid-hack, and would cover the
  goal and the bonus nodes. A `!` glyph was tried and removed.
- **Dispatch timing.** `_explosion_gate` runs before each move. It simulates
  the queue at `hack_explosion_move_seconds`, with
  `hack_explosion_margin_seconds` on both sides of each explosion window:
  - **go:** every danger cell ahead is left before its window.
  - **hold:** wait on the current cell, which is safe until the way clears.
  - **dodge:** the current cell is about to go off. Insert a step to a safe
    neighbour and back (a retrace is preferred), so the plan stays valid.
  - A hold longer than 4 s moves on anyway.
- **Idle guard.** `_guard_idle` covers the time while no plan runs, and also
  the ~0.5 s drain after a plan ends short of the goal. Testing showed this is
  the case that actually fails: the cursor stops mid-grid while the peer
  replans, and a row goes off under it. If the
  cursor stands on a pulsing cell it steps aside, then steps back once the cell
  has gone off. If a plan arrives first, the way back is put in front of it. A
  force sent while the cursor is aside forgets the way back
  (`snapshot_force_target`).
- **Failure text.** A reset within 1 s of a row going off is reported as
  "An exploding row caught the cursor".
- **Switch.** Everything is off with `hack_explosion_guard = false`.

**To check in game:**
- the log lines "holding for an exploding row", "stepping … out of it" and
  "row cleared; stepping … back";
- whether 0.1 s per move is right (raise `hack_explosion_move_seconds` if a
  crossing is still caught);
- a cursor parked mid-grid while the peer replans is moved off a pulsing row
  and back.

The original plan, kept for reference:

1. **Discovery (F5 during the boss's attack):**
   - Do the unit `cells` match the pulsing squares?
   - Do the `sign_timer` / `attack_timer` remaining times count down to the explosion?
   - How long is Attack?
   - Does an explosion fire the failed trigger?
   - What is the real per-move time?
2. **Binding:** `state.explosions`, with `danger = { explodes_in, exploding }` per cell (the soonest wins).
3. **Render:** glyph `!`, plus one line saying the mod times the crossings. No timers in the text.
4. **Timed dispatch:**
   - Simulate the rest of the queue at the measured move time.
   - Every run of danger cells must reach the next safe cell before the earliest explosion in the run, plus a margin.
   - Otherwise hold on the current safe cell until those cells have exploded and cleared.
   - If the cursor's own cell is going to explode: step to a neighbour that is safe in time (prefer retracing), then re-force.

## Finale lock-up, 2026-10-08 (fix awaiting the in-game test)

**What the user saw:** in the final boss's last stage, the hack UI started its shrinking-grid animation, was cut off and vanished. The game didn't freeze, but couldn't continue. Without the mod the stage plays normally: the grid shrinks a few times, then can be hacked. The 15:36 session's finale, where the mod saw nothing after "Combat started", was probably the same thing.

**Logs:** the mod wrote nothing to the game after the previous stage's success. Its only write is `_NextMovePosition`.

**Suspected cause (not proven):** Part A made the observer call `blocked_notice()` every frame even while the puzzle isn't taking input, which is exactly during that animation. Part B added `get_state()` to it. On the finale's plain `app.PuzzleSnake` that meant these engine **method calls** every frame:
- `getObstacleInfo()`;
- the corruption module's `isDeadFilament()` / `isDeadFilamentEnemy()` / `isErode()` and `getFixedDeadFilamentNum()`;
- get_state's accessor, EnhanceManager and skill calls.

Before this work, nothing ran in that window.

**Fix:**
- The every-frame modifier reads are field-only.
- The method calls and `getObstacleInfo` are made only in the F5 snapshot (`debug = true`).
- The corruption gate (which runs `get_state`) runs only while the puzzle is interactive.
- Corruption is now decided by the corrupted cells alone; `isDeadFilament()` is a snapshot-only value.

**If it still breaks:** test with `hacking_auto_force = false` to see whether the plan/force path matters at all. The next suspects are the long-standing `sdk.hook` on the PuzzleSnake update method and `.ctor` in `puzzle_snake.lua`.

**Re-test (16:21 session): the field-only fix did NOT help; `hacking_auto_force = false` did.**
- **Real cause (from the logs):**
  - The last stage opens with a scripted sequence ("Optimizing hacking matrix: Initiate!") that shrinks the grid a few times. It runs ~40 s; without the mod the user solved it at 16:29:35, 42 s after the previous stage.
  - Throughout it, the puzzle reads `_State` = Play with the GUI up, so `is_interactive()` was true.
  - The mod forced the grid at 16:24:42 and drove a 10-move plan to the goal at 16:24:45. The stage "succeeded" mid-sequence, the animation was cut and the UI vanished.
- **Fix (awaiting the test):** `is_interactive()` is now false while `M.grid_change_reason()` is set, so nothing is forced or dispatched then. The reason is set when either of:
  - `_ChangeGridRequests._size > 0` (queued grid changes);
  - `_IsDeathblowChanging` is true.
- Every switch of the guard is logged ("grid change guard ON/off"). This shows whether it covers the sequence, and whether it ever fires on ordinary grids (sticky bombs also queue grid changes).
- F5 now also dumps every plain field of the puzzle, its unit, the grid-change processing data and the block-input timer. If the guard misses the sequence, comparing a during-animation snapshot with a solvable one shows the real flag.

**Re-test (16:34 session): the grid-change guard never fired. Replaced by a finale-only hold.**
- The field dump at the start of the sequence (16:38:10) matches a playable grid field for field:
  - `_State` = 1;
  - an empty change queue;
  - no deathblow change;
  - move block 0;
  - the block-input timer idle.
- There is no engine flag to wait on.
- **Timeline of the user-played run (16:26):**
  - 16:29:20, "Let me try something!": the grid appears.
  - 16:29:23, "Optimizing hacking matrix: Initiate!".
  - About 16:29:34, the sequence ends.
  - 16:29:35, the user solves it.
  - So the sequence takes ~14 s from appearance.
- **The final grid is identical in every run** (16:12, 16:29, 16:38):
  - 7×7, start (3,0), goal (3,6);
  - error nodes at `0,0 0,1 0,4 0,6 1,2 1,5 2,0 5,4 5,6 6,2 6,3` (engine coordinates).
- **Fix (awaiting the test):** `M.finale_hold_reason()` recognises that grid by fingerprint (size, goal and error-node cells; field reads only, re-read at most once a second). For `mod_config.hack_finale_hold_seconds` (15) after it first appears, `is_interactive()` is false: no force and no dispatch. No other grid is affected.
  - The log shows "final-stage grid recognised" and "finale hold ON/off".
  - The generic queue / deathblow guard was removed (it never fired, and could have held back sticky-bomb grids).

**Re-test (16:43 session): the hold never fired, because the fingerprint never matched.**
- It was built from the engine's raw `_ActualGrid`. That array is larger than the playable grid, so the "7x7" size check failed silently.
- **Replaced** by `snake_render.layout_fingerprint(state)`, i.e. what the peer sees: `"WxH|goal|rows"`, with each cell `#` / `d` / `R` or `.`.
- The finale is **five fixed stages, identical across three runs**, recorded in `FINALE_STAGES` at the end of `puzzle_snake.lua`:
  1. 9×9 maze, goal (4,4)
  2. 7×9 "ladder", goal (3,8)
  3. 9×9, goal (4,6)
  4. 7×7 maze, goal (6,6)
  5. the final 7×7, goal (3,6)
- The code's five keys were checked against the fingerprints computed from every logged force: all match.
- **Stage 5:** the hold applies for `hack_finale_hold_seconds` (now 16) from first sight.
- **All 5 stages:** forced with `ephemeral_context = false` (`M.force_ephemeral`, `hack_finale_keep_context`), so the peer keeps each stage and its attempts in context.
- The log shows "finale stage N recognised" and "finale hold ON/off".
