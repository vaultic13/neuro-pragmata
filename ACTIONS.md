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
- **Confidence:** high — the underlying binding has a clear engine entry point.

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

Plan a path through an active hacking grid (the `app.PuzzleSnake` minigame). Fired automatically by the mod via `actions/force` the moment a grid appears in-game (controlled by `mod_config.hacking_auto_force`, on by default). The peer reads the grid render from the force's `state` field — including cursor `@`, Goal `G`, walls `#`, EraseCode traps `X`, an "Adjacency from cursor" block listing legal first-moves, and a glyph legend — and returns an ordered list of cardinal moves.

- **Schema:**
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
- **Result:** the mod queues the returned plan and dispatches the moves one cell per ~130ms via `app.PuzzleSnake.Unit.move(via.Int2)`. When the cursor reaches the goal cell, the mod writes `_RequestForceSuccess = true` on the active `PuzzleSnake` instance — the engine polls this field each tick and runs the full natural completion flow (COMPLETE overlay, hack damage commit, dialogue progression, auto-reset for chain-hacking). Until that field write, the engine treats `Unit.move` as out-of-band cursor manipulation and does not auto-complete on goal arrival.
- **Confidence:** HIGH on the full pipeline (grid read → plan return → cursor dispatch → natural completion). One known caveat: directional cells (`OneWay` / `TwoWay*` arrows) are present in the dump's enum but render with a generic `?` glyph because we haven't seen them in test grids — refine if you observe them in production. Grid-state extraction reads the `_ActualGrid` jagged array directly because REFramework can't reliably dispatch `executeEachGrid`'s `System.Action<Grid>` callback; falls back gracefully to narrative-only if reflection fails.

#### Notable engine-internals findings

These came up during development and may be useful for other RE Engine modders building Neuro-SDK integrations:

- **`Unit.move(via.Int2)` accepts an absolute target, not a delta.** The `via.Int2` argument must be obtained from `_CurrentUnit:get_Position()` and mutated in place — fresh `sdk.create_instance("via.Int2")` wrappers don't have writable fields on REFramework builds we tested.
- **`PuzzleBase._RequestForceSuccess` is the natural-completion entry point.** Naming convention distinguishes polled request fields (`Request*`) from one-frame edge outputs (`*Trg` / `*Trigger`); writes to edge fields are silently dropped, but writes to request fields propagate and are honored by the engine's tick loop.
- **`_StartTrg` can be cleared faster than ~10 Hz polling catches.** The observer polls every frame to reliably catch the false→true transition at puzzle creation.

### `pragmata_overdrive`

Fires Diana's Overdrive Protocol. AoE pulse that stuns and exposes weak points on nearby enemies and grants Hugh a brief energy / Suit Integrity buffer. Requires the hacking gauge to be full (the Overdrive ability itself unlocks during the Sector 1 boss fight).

- **Schema:** `{}` (no arguments)
- **Result:** fails gracefully if gauge isn't full or if engine reflection refuses the dispatch.
- **Confidence:** low on the trigger path (calls a method marked private in the dump). High on the precondition queries.

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
