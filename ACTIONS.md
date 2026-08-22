# Pragmata Neuro-SDK Mod — Action & Context Reference

Reference for AI integrators wiring up to this mod. All wire content is standard
Neuro-SDK JSON over WebSocket.

Every example message in this document is real output copied from
`reframework/data/pragmata_mailbox/lua_to_bridge.jsonl`.

## Actions registered by the mod

Six actions are sent in `actions/register` at mod startup.

| Action | Arguments | Effect |
|---|---|---|
| [`pragmata_ping`](#pragmata_ping) | none | Sanity check. |
| [`pragmata_scan`](#pragmata_scan) | none | Diana scans the environment. |
| [`pragmata_scan_results`](#pragmata_scan_results) | none | Re-read the last scan. Read-only. |
| [`pragmata_auto_hack`](#pragmata_auto_hack) | none | Auto-hack the locked-on target. |
| [`pragmata_overdrive`](#pragmata_overdrive) | none | Fire Overdrive. |
| [`pragmata_hack_plan`](#pragmata_hack_plan) | `moves` | Route the hacking grid. Auto-forced. |

**All three of Diana's abilities take no arguments.** Their schema is exactly
`{"type": "object"}`. There is nothing to choose: Scan is a single input
command, Overdrive is a single driver call, and Auto-Hack's engine entry point
(`startAutoHack()`) has no target parameter — the game's lock-on decides the
target. Only `pragmata_hack_plan` takes arguments, and only because it is
answering a question the mod asked.

### Confirmed, not acknowledged

Scan, Auto-Hack and Overdrive all use **deferred results**. The mod does not
reply when it asks the engine to act; it replies when the engine is observed to
have acted, or when a confirmation window expires.

| Action | Confirmation signal | Window |
|---|---|---|
| `pragmata_scan` | the engine reaches `ScanManager.requestScan` | 120 frames (~2 s) |
| `pragmata_auto_hack` | the work unit reports Auto-Hack running | 120 frames (~2 s) |
| `pragmata_overdrive` | a Deathblow start flag, or a real gauge spend | 180 frames (~3 s) |

So a `success: true` here means the game actually started the ability. Two
consequences worth designing around: results arrive a beat late, and a
precondition failure comes back **immediately** while a genuine no-op comes back
at the end of the window with a `did not produce its expected game-state
transition` message.

---

### `pragmata_ping`

Sanity check. Confirms mod, sidecar, and peer are wired up end to end.

- **Schema:** `{"type": "object"}` — no arguments.
- **Result:** always `success: true`, message `"pong"`. Synchronous.

---

### `pragmata_scan`

Diana's environmental scan. Highlights nearby objectives, paths, and — with the
in-game Object Scan upgrade — pickups such as REM disks, Upgrade Modules, Mods
and Pure Lunum.

- **Schema:** `{"type": "object"}` — no arguments.
- **Dispatch:** injects the game's own Scan input command (the one bound to
  **C** by default). No OS key event and no virtual device is involved.
- **Result on success:**

  ```
  success: true   "scan started (request-specific progression observed)"
  ```

- **Result on refusal** (immediate):

  ```
  success: false  "FAIL: scan manager singleton unavailable"
  success: false  "FAIL: scan request is locally debounced"
  ```

  Scan requests are debounced 8 frames, so hammering the action is refused
  rather than queued.

**The findings arrive separately.** The action result only confirms the scan
started. What it found is emitted moments later as a context message, because
the engine fills in the result list over several frames:

```
Diana scanned: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m).
```

See [Scan results](#scan-results) for how to read that line.

---

### `pragmata_scan_results`

Read back the most recent scan. **Read-only — it does not scan.** Re-reading is
free, so the peer never has to spend a scan just to recall what it saw.

- **Schema:** `{"type": "object"}` — no arguments.
- **Result:**

  ```
  success: true   "Last scan: 1x escape hatch (32 m), 1x Upgrade Components (49 m)."
  ```

  When the held result is older than the engine's own display window:

  ```
  success: true   "Last scan (possibly out of date): 1x escape hatch (32 m), …"
  ```

  With nothing held at all:

  ```
  success: true   "no scan results are currently held; run pragmata_scan first"
  ```

  Note that "nothing to report" is a **success**, not a failure — it is a true
  answer to the question asked.

#### Scan results

One row per kind of thing, with the distance to each instance:

```
Diana scanned: 3x escape hatches (8 / 44 / 97 m), 2x Upgrade Components (34 / 67 m), 1x Lunafilament (67 m).
```

- The leading count is the number of instances listed, and **always equals the
  number of distances after it**. `2x Upgrade Components (34 / 67 m)` is two
  separate pickups, at 34 m and at 67 m — not a group summarised by its nearest.
- Names come from the game's own catalogs. Markers the catalogs do not name are
  described by what they are: `objective marker`, `sub-objective marker`,
  `escape hatch`, `item marker`. No hashes or internal codes ever appear.
- Only **live, locatable** markers are listed. Collected items, deactivated
  objects, markers in rooms the engine has not streamed in, and anything the
  engine cannot place are all omitted — including from any total. There are
  deliberately no marker counts in the line: a number the peer cannot act on
  was pure noise, and it contradicted the rows printed beside it.
- `cannot be taken yet` means the game is refusing interaction with every
  instance in that row right now — a cutscene or a locked phase. It means "not
  yet", not "never". `some cannot be taken yet` is the partial case.
- `(+N more marker types)` means the report hit its group cap
  (`scan_report_max_groups`, default 8). Nothing vanishes silently.

When the engine can name things but cannot place any of them, the line degrades
to names and counts alone:

```
Diana scanned: 12x Upgrade Components, 3x Lunafilament, 1x Mods, 1x Pure Lunum, 24x sub-objective markers, 15x markers (some cannot be taken yet), 4x escape hatches, 3x objective markers (+1 more marker type).
```

---

### `pragmata_auto_hack`

Auto-hack the target Diana is currently locked on to. Consumes part of the
hacking gauge to bypass the manual minigame. **Requires the in-game Auto-Hack
upgrade**, which unlocks mid-game from the Unit Printer.

- **Schema:** `{"type": "object"}` — no arguments.
- **Result on success:** `success: true`, `"auto-hack started"` — the work unit
  reports Auto-Hack actually running, not merely that preconditions passed.
- **Results on refusal** (all immediate, and each names the specific reason):

  ```
  "not implemented: auto-hack not currently available (locked, missing driver, or per-target disabled)"
  "jamming active in this area; auto-hack would be refused"
  "auto-hack already in progress"
  "no valid hack target (nothing is locked on)"
  "hacking gauge empty; cannot pay auto-hack cost"
  ```

  Lock on to a target before calling, or the fourth message is what comes back.

---

### `pragmata_overdrive`

Fire Diana's Overdrive Protocol. AoE pulse that stuns and exposes weak points on
nearby enemies. The ability itself unlocks during the Sector 1 boss fight.

- **Schema:** `{"type": "object"}` — no arguments.
- **Dispatch:** `app.PlayerDeathblowDriver.tryDeathblow()` — the game's own
  entry point, which re-runs all of its normal guards. Runtime captures settled
  this: it is **not** command-driven, and it wraps the lower-level start call,
  so there is exactly one route and no fallback.
- **Cost:** a fixed **100** gauge points. Not a "gauge must be full"
  requirement.
- **Readiness:** the engine's own `canDeathblow()`, corroborated by the
  `DeathblowStatus.CanDeathblow` flag, with the gauge threshold as a last
  resort.
- **Result on success:**

  ```
  success: true   "the game started Overdrive (canDeathblow cleared)"
  ```

  Other confirmations you may see, depending on which evidence lands first:
  `"the game started Overdrive (gauge spent 100.0 points)"`.

- **Results on refusal:**

  ```
  "the game reports Overdrive is not currently usable (canDeathblow() is false; gauge holds 26.7 points)"
  "no engine readiness signal and the gauge holds 26.7 of the 100 points one activation costs"
  "hacking gauge is unreachable (not in gameplay?)"
  "the Deathblow driver is not captured (not in gameplay?)"
  "an overdrive request is already awaiting confirmation"
  ```

- **If the window expires:** `success: false`, `"overdrive did not produce its
  expected game-state transition"`. That means the call was accepted but the
  game never started the ability — distinct from the refusals above, which are
  the game saying no up front.

Activation is not instantaneous: the driver call raises a request that the
engine's state machine consumes about four frames later, and the ability runs
for roughly 90 frames after that.

> **⚠️ Save-safety note:** Overdrive drives a cinematic/animation pipeline.
> Calling it in unexpected scene states (loading, paused, mid-cinematic) carries
> a small but real save-corruption risk.

---

### `pragmata_hack_plan`

Plan a path through an active hacking grid (the `app.PuzzleSnake` minigame).
Fired automatically by the mod via `actions/force` the moment a grid appears
(`mod_config.hacking_auto_force`, on by default). This is the one action with
arguments, because it is a reply.

The peer reads the grid from the force's `state` field and returns an ordered
list of cardinal moves.

- **Schema** depends on `mod_config.hacking_require_reasoning` (default
  `false`).

  Default — faster reaction:

  ```json
  {
    "type": "object",
    "required": ["moves"],
    "properties": {
      "moves": {
        "type": "array",
        "items": {"enum": ["up", "down", "left", "right"]},
        "minItems": 1, "maxItems": 32
      }
    }
  }
  ```

  With `hacking_require_reasoning = true`, a `reasoning` string is required
  **before** `moves`. The property order is pinned in the serialized schema on
  purpose: a trace generated after the moves is a post-hoc rationalization that
  does not even have to match them.

- **Result:** the mod queues the plan and dispatches one cell per ~130 ms by
  writing each target into `app.PuzzleSnake._NextMovePosition`. The engine's own
  input pipeline then runs every per-cell side effect — walls block, directional
  gates enforce, trail flags update, bonus and skill cells trigger, `EraseCode`
  traps fire, and **goal arrival auto-completes the puzzle** with the full
  completion flow. The terminal outcome arrives as a context message
  (`Hack succeeded.` / `Hack failed.`).

#### Reading the grid render

Coordinates are `(x, y)` with `(0, 0)` at **top-left**; `up` is `-y`.

| Glyph | Meaning |
|---|---|
| `@` | cursor — current position |
| `G` | goal — reach it to finish the hack |
| `.` | walkable floor |
| `O` | **blue OPEN node** — the bonus that makes a hack deal damage |
| `A` | **blue ATTACK node** — what `O` becomes on an exposed hack; same value |
| `*` | yellow skill node — effective but limited-use |
| `C` | chain node |
| `#` | wall — the cursor stops |
| `d` | **red error node — entering one RESETS the whole hack** |
| `X` | `EraseCode` trap — fails the hack |
| `~` | your own trail — retracing it undoes the bonuses already collected |
| `S` start, `s` shield, `b` / `B` bomb 3x3 / 5x5, `P` purge | less common cell types |
| `=` `J` `7` `L` `r` and the vertical bar | two-way directional cells |
| `?` | a directional `OneWay` cell — never yet observed in a live grid |

The routing objective is to **maximize collected bonuses**, not to take the
shortest path: a longer winding route through more `O`/`A` nodes is better, as
long as it ends on `G` and never steps on `#`, `d`, `X`, or `~`. Collect nodes
by passing *through* them going forward — detouring out and back retraces the
trail and undoes them.

The render also carries an "Adjacency from cursor" block (legal first moves,
suppressible via `hacking_render_adjacency`), a bonus-node list, and a dynamic
legend listing only the glyphs actually present (`hacking_render_legend`).

#### Notable engine-internals findings

Useful to other RE Engine modders; all derived from in-game captures.

- **Sticky-bomb row/column removal never changes the grid dimensions.** Removed
  rows/cols are flagged per cell (`Grid.<IsSkipRow>/<IsSkipCol>`), tracked as
  index lists on `GridAccessor` (`get_SkipRow()`/`get_SkipCol()`), and restored
  over time by `expansionRow()`/`expansionCol()`. `GRID_ACTUAL_SIZE_X/Y` keeps
  reporting the full size, so a reader that ignores the skip flags renders rows
  that no longer exist — and a dimension-based structural check misses both the
  removal and the gradual restore.
- **The red error nodes are not a `_GridType`.** They read as plain `None`; the
  live marker is `Grid._ObstacleReasons`, a bitmask of `ObstacleReason`
  (`ObstacleGrid=1` verified in-game, plus `DeadFilament=2`, `Ch16092=4`,
  `Ch14100=8`, `AllPassed=16`). The engine sets and clears bits mid-fight, so
  treat it as dynamic state, not authored layout. A cell reader keyed only off
  `_GridType` cannot see them at all.
- **`_NextMovePosition` is the move-dispatch entry point.** Writing an absolute
  target cell into this polled `via.Int2` routes the move through the engine's
  own input pipeline with every side effect intact. Calling `Unit.move(via.Int2)`
  instead *teleports* the cursor and bypasses all of them.
- **Polled state fields propagate; one-frame `*Trg`/`*Trigger` fields silently
  drop writes.** Value-type fields must be mutated on an engine-supplied
  wrapper — a fresh `sdk.create_instance("via.Int2")` exposes no writable fields
  on the builds tested.
- **`_IsGoldenPath` is deliberately not rendered.** It marks the engine's own
  auto-hack route and floods most walkable cells; rendering it as the blue-node
  marker would bury the real bonuses and hand the peer a pre-solved path.

---

## Context messages emitted by the mod

Sent as Neuro-SDK `context` messages with `silent: true`. Every example below is
verbatim from a real session.

### Dialogue

```
Dialogue: [Conversation] Diana says "Let's finish this!"
Dialogue: [Conversation] Hugh says "Check."
```

Format is `Dialogue: [<Type>] <Speaker> says "<text>"`, or
`Dialogue: [<Type>] "<text>"` when no speaker resolves. `<Type>` is the
dialogue category from the engine's `MessageInfo`. Multi-line wrapped subtitles
are combined, so each utterance is forwarded once.

Collectible documents, when `mod_config.archive_gui_path` is configured, arrive
as `Collectible document text: "…"`.

### Ability state

| Trigger | Example |
|---|---|
| Gauge crosses 25 / 50 / 75 / 100% upward | `Hacking gauge: 75%` |
| Overdrive becomes ready | `Overdrive is ready.` |
| Auto-Hack upgrade unlocks | `Auto-Hack upgrade is now available.` |
| Scan results resolve | `Diana scanned: 1x escape hatch (32 m), 1x Upgrade Components (49 m).` |

Gauge crossings fire only on **upward** movement; the drop after Overdrive fires
is covered by the readiness edge instead of a redundant downward crossing.

### Hack lifecycle

| Trigger | Example |
|---|---|
| Grid appears | `Hacking grid started.` |
| Grid changed under an in-flight plan | `Hacking grid changed; replanning.` |
| Grid reset | `Hacking grid was reset.` |
| Terminal outcome | `Hack succeeded.` / `Hack failed.` |

### World state

| Trigger | Example |
|---|---|
| Scene/area transition | `Hugh and Diana entered a new area.` |
| Checkpoint activation | `Checkpoint reached.` |
| Combat starts | `Combat started.` |
| Combat ends | `Combat ended.` |

The mod deliberately does **not** send scene names, area names, or checkpoint
names — only opaque hash identifiers are used internally for transition
detection.

### Autonomy nudges (opt-in)

When `autonomy_nudges` is true in
[`mod_config.lua`](autorun/pragmata/mod_config.lua), the mod emits an in-combat
hint at most once per `autonomy_nudge_interval_frames` (default ~30 s):

```
Combat is active. Available now: Overdrive Protocol is ready; Auto-Hack is available. Consider using these abilities if it would help Hugh.
```

The available set is recomputed on each emission; if nothing is available, no
nudge fires.

## Wire protocol notes

Standard Neuro-SDK message shapes throughout. The mod sends:

- `startup` on connect
- `actions/register` immediately after startup
- `context` for all the categories above
- `actions/force` on hacking-grid start, with
  `action_names: ["pragmata_hack_plan"]`, `ephemeral_context: true`, and the
  rendered grid in `state`
- `action/result` in response to incoming `action` commands

The mod handles incoming `action` commands. Other Neuro-SDK message types are
not currently produced or consumed.
