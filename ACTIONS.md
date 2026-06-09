# Pragmata Neuro-SDK Mod — Action & Context Reference

Reference for AI integrators wiring up to this mod. All wire content is standard Neuro-SDK JSON over WebSocket; the optional `lane` field on context messages is a forward-compatible extension (see [README.md](README.md#context-message-lanes)).

## Actions registered by the mod

These are the actions the AI peer can invoke. They're sent to the AI as part of the `actions/register` message at mod startup.

### `pragmata_ping`

Sanity check. Confirms the mod, sidecar, and AI peer are wired up end-to-end.

- **Schema:** `{}` (no arguments)
- **Result:** always succeeds with message `"pong"`.

### `pragmata_scan`

Triggers Diana's environmental scan. Highlights nearby objectives, paths, and (with the in-game Object Scan upgrade) pickups like REM disks, Upgrade Modules, Mods, and Pure Lunum.

- **Schema:** `{}` (no arguments)
- **Result:** fire-and-forget. Scan results arrive as separate `narrative`-lane context messages as they appear (see below).
- **Confidence:** unverified in-game (open issue). `app.ScanManager` resolves as a managed singleton the same way the working `HackingManager` does, and the only trigger methods in the dump are `requestScan(bool)` / `requestScanObjective()` — both of which the binding now tries (broad scan first, objective-only as a fallback if the primary is rejected/errors). The action result message reports exactly which step succeeded or failed. Use the **Pragmata Abilities Debug** ImGui panel to watch `isScanning` and the last-trigger outcome live.

### `pragmata_auto_hack`

Auto-hacks a target. Consumes part of the hacking gauge to bypass the manual minigame. **Requires the in-game Auto-Hack upgrade**, which unlocks mid-game from the Unit Printer; calls before unlock fail gracefully.

- **Schema:**
  ```json
  {
    "type": "object",
    "properties": {
      "target_id": {
        "type": "string",
        "description": "Optional. Identifier of the target to hack. Omit to use the currently locked-on target."
      }
    }
  }
  ```
- **Result:** returns success on precondition pass (gauge non-empty, not jammed, target reachable). **Success here means preconditions passed; it does NOT guarantee the engine actually completed the hack.** Look for follow-up context updates to confirm.
- **Confidence:** medium — preconditions are high-confidence; the actual start transition may require an input-synthesis follow-up at higher load levels.

### `pragmata_hack_plan`

Plan a path through an active hacking grid (the `app.PuzzleSnake` minigame). Fired automatically by the mod via `actions/force` the moment a grid appears in-game (controlled by `mod_config.hacking_auto_force`, on by default). The peer reads the grid render from the force's `state` field — including cursor `@`, Goal `G`, walls `#`, EraseCode traps `X`, an "Adjacency from cursor" block listing legal first-moves, a "Bonus nodes" block, and a glyph legend — and returns an ordered list of cardinal moves.

**Bonus nodes / routing objective.** Passing the cursor through bonus nodes improves the hack — more damage to the enemy and a longer-lasting hack — and the goal is to **maximize collected bonuses**: a longer, winding path through more bonus nodes is preferred over the shortest path, as long as the plan still ends on `G` and never steps on an `X` trap or a `~` trail cell. Two node colours, mapped against in-game dumps:

- **BLUE `O` (most valuable).** The "golden path" reward nodes. These are *not* a distinct grid type — they read as plain `Open` — so the engine flags them via `app.PuzzleSnake.Grid._IsGoldenPath`, which the cell reader surfaces as `is_golden_path` and the renderer draws as `O`. Grab these first.
- **YELLOW `*` (secondary).** The skill node — the `ActiveSkill` grid type (with `1`/`2`/`3` variants).

The render lists both in a "Bonus nodes" block, blue first. Other special grid types (`F` FinishBlow, `A` Attack, `b`/`B` Bomb, `C` Chain, `P` Purge) still render but aren't currently treated as collect-targets. Mapping derived from the "Dump cells to log" button in the hacking debug panel, which now shows `_IsGoldenPath` / `IsParryHacking` per cell.

- **Schema:** depends on the `mod_config.hacking_require_reasoning` flag (default `false`).

  When `false` (default — faster reaction):
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

  When `true` (better accuracy, slower):
  ```json
  {
    "type": "object",
    "required": ["reasoning", "moves"],
    "properties": {
      "reasoning": {
        "type": "string",
        "description": "Step-by-step trace of the planned path. Format: '1:down(1,2)open; 2:right(2,2)open; 3:down(2,3)G'. ~150 chars."
      },
      "moves": {
        "type": "array",
        "items": {"enum": ["up", "down", "left", "right"]},
        "minItems": 1, "maxItems": 32
      }
    }
  }
  ```
- **Result:** the mod queues the returned plan and dispatches the moves one cell per ~130ms by writing each target cell into `app.PuzzleSnake._NextMovePosition` (a `via.Int2` at offset 0x1ac). The engine's natural input pipeline (`updateInput → updateNextPosition → updatePuzzleMovement → onEnterGrid`) then processes each move with all side-effects intact — walls block, directional gates enforce, trail flags update, skill/bonus cells trigger, EraseCode traps fire, and **goal arrival auto-completes the puzzle** with the full COMPLETE flow (overlay, hack-damage commit, dialogue progression, auto-reset for chain-hacking). No `_RequestForceSuccess` write is needed on this path.
- **Confidence:** HIGH on the full pipeline (grid read → plan return → cursor dispatch → natural completion). One known caveat: directional cells (`OneWay` / `TwoWay*` arrows) are present in the dump's enum but render with a generic `?` glyph because we haven't seen them in test grids — refine if you observe them in production. Grid-state extraction reads the `_ActualGrid` jagged array directly because REFramework can't reliably dispatch `executeEachGrid`'s `System.Action<Grid>` callback; falls back gracefully to narrative-only if reflection fails.

#### Notable engine-internals findings

These came up during development and may be useful for other RE Engine modders building Neuro-SDK integrations:

- **`PuzzleSnake._NextMovePosition` is the move-dispatch entry point.** Writing an absolute target cell into this polled `via.Int2` field routes the move through the engine's own input pipeline, so every per-cell side-effect (walls, directional gates, trail flags, skill/bonus cells, EraseCode, goal auto-complete) runs naturally. Calling `Unit.move(via.Int2)` directly instead *teleports* the cursor and bypasses all of those, so it's retained only for the debug-panel poke buttons.
- **Polled state fields propagate; one-frame edge fields (`*Trg` / `*Trigger`) silently drop writes.** Both `_NextMovePosition` and `PuzzleBase._RequestForceSuccess` are write-and-the-engine-polls entry points (the latter is the legacy goal-completion nudge that the `_NextMovePosition` path made unnecessary). Value-type fields must be mutated on an engine-supplied wrapper — fresh `sdk.create_instance("via.Int2")` wrappers don't expose writable fields on the builds we tested.
- **`_StartTrg` can be cleared faster than ~10 Hz polling catches.** The observer polls every frame to reliably catch the false→true transition at puzzle creation.

### `pragmata_overdrive`

Fires Diana's Overdrive Protocol. AoE pulse that stuns and exposes weak points on nearby enemies and grants Hugh a brief energy / Suit Integrity buffer. Requires the hacking gauge to be full (the Overdrive ability itself unlocks during the Sector 1 boss fight).

- **Schema:** `{}` (no arguments)
- **Result:** fails gracefully if gauge isn't full or if engine reflection refuses the dispatch.
- **Confidence:** low on the trigger path (calls `requestWideFinishBlow`, marked private in the dump). The precondition/gauge queries are higher-confidence now that the driver actually resolves: `app.PlayerFinishBlowDriver` and `app.PlayerPuzzleControlDriver` are **not** managed singletons (so the previous `get_managed_singleton` lookup always returned nil — the reason Overdrive did nothing), so they're now captured live via a per-frame `onUpdate` hook, the same pattern the hacking integration uses for `PuzzleSnake`. Watch the driver-capture state and last-trigger outcome in the **Pragmata Abilities Debug** ImGui panel.

> **⚠️ Save-safety note:** Overdrive hooks into a cinematic/animation pipeline. Calling it via reflection in unexpected scene states (loading, paused, mid-other-cinematic) carries a small but real save-corruption risk. Test on a disposable save first.

## Context messages emitted by the mod

These are sent to the AI as Neuro-SDK `context` messages with `silent: true`. The `lane` field is optional (extension; pure Neuro-SDK consumers ignore it).

### Dialogue (lane: not set, accumulates)

Format: `Dialogue: [<Type>] <Speaker> says "<text>"` (or `Dialogue: [<Type>] "<text>"` if no speaker).

`<Type>` is the dialogue category (cinematic, system, etc.) resolved from the engine's MessageInfo. `<Speaker>` is the resolved character name when available. Subtitles are forwarded once per logical utterance (multi-line wrapped subtitles are combined).

### Ability state (mixed lanes)

| Trigger | Lane | Example |
|---|---|---|
| Hacking gauge crosses 25/50/75/100% upward | `transient` | `Hacking gauge: 75%` |
| Overdrive becomes ready | `narrative` | `Diana's Overdrive Protocol is ready.` |
| Overdrive fires (gauge drops from full) | `narrative` | `Overdrive Protocol fired.` |
| Auto-Hack upgrade gets unlocked | `narrative` | `Auto-Hack upgrade is now available.` |
| Scan returns ping results | `narrative` | `Diana scanned: 3 enemy, 1 pickup.` |

Gauge crossings only fire on upward movement; downward gauge changes after firing Overdrive are covered by the readiness-edge narrative event.

### World state (all `narrative`)

| Trigger | Example |
|---|---|
| Scene/area transition | `Hugh and Diana entered a new area.` |
| Checkpoint activation | `Checkpoint reached.` |
| Combat starts | `Combat started.` |
| Combat ends | `Combat ended.` |

The mod intentionally does **not** pass scene names, area names, or checkpoint names to the AI peer — only opaque hash identifiers are used internally for transition detection.

### Autonomy nudges (lane: `transient`, opt-in)

When `autonomy_nudges` is true in [`mod_config.lua`](autorun/pragmata/mod_config.lua), the mod emits an in-combat hint at most once per `autonomy_nudge_interval_frames` (default 30s):

```
Combat is active. Available now: Overdrive Protocol is ready; Auto-Hack is available. Consider using these abilities if it would help Hugh.
```

The set of "available" abilities is dynamically computed each emission. If no abilities are currently available, no nudge fires.

## Wire protocol notes

Standard Neuro-SDK message shapes are used throughout. The mod sends:

- `startup` on connect
- `actions/register` immediately after startup
- `context` messages for all the categories above
- `action/result` in response to incoming `action` commands

The mod handles incoming:

- `action` commands (the dispatcher routes them to the right binding handler)

Other Neuro-SDK message types are not currently produced or consumed.
