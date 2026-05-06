"""Mod-side Neuro-SDK protocol mock for grid evaluation.

Plays the role the Pragmata mod + sidecar would play in a real game session,
but feeds the AI peer synthetic grids and scores its responses. The peer
doesn't need to know it's talking to a simulator — wire format matches the
real mod exactly.

Architecture:
    [mod_mock.py] -- websocket client --> [AI peer's WS server]

The peer must be running and listening before this client connects.
Default peer URL is `ws://127.0.0.1:8000` matching neuro-pragmata's README.

Each trial:
    1. (Re)send startup + actions/register on connect.
    2. Send a context message containing the rendered grid.
    3. Send actions/force for `pragmata_hack_plan` + `pragmata_hack_route`.
    4. Wait for an `action` response (with timeout).
    5. Validate the proposed moves against the grid via solver.validate_plan.
    6. Send action/result back with success + diagnostic message.
    7. Return TrialResult.

Connections are persistent across trials in a batch. `ephemeral_context=True`
on each force keeps trial-specific context from polluting the peer's long-term
memory.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random
import uuid
from dataclasses import dataclass, field
from typing import Optional

import websockets

from .ascii_render import render
from .grid_gen import Dir, Grid
from .solver import ValidationResult, solve, validate_plan


GAME_NAME = "Pragmata"

ACTION_HACK_PLAN = "pragmata_hack_plan"
ACTION_HACK_ROUTE = "pragmata_hack_route"

_HACK_PLAN_DESCRIPTION = (
    "Plan a path through the active hacking grid from cursor @ to Goal G.\n"
    "Coordinates: (0,0) is TOP-LEFT. x = column (increases left->right). "
    "y = row (increases top->bottom). 'up' decreases y by 1; 'down' "
    "increases y by 1; 'left' decreases x by 1; 'right' increases x by 1.\n"
    "Read the state field carefully — the cursor and goal positions are "
    "given there, and the Adjacency block lists which first-moves are "
    "legal. Use those positions verbatim; do not infer or guess.\n"
    "Avoid # walls, X EraseCode traps, and ~ trail cells. Plan ends on G."
)

ACTION_HACK_PLAN_DEF = {
    "name": ACTION_HACK_PLAN,
    "description": _HACK_PLAN_DESCRIPTION,
    "schema": {
        "type": "object",
        "required": ["reasoning", "moves"],
        "properties": {
            "reasoning": {
                "type": "string",
                "description": (
                    "Trace your plan one step at a time, copying the cursor "
                    "and goal coordinates from the state field exactly. "
                    "Format: '1:down(1,2)open; 2:right(2,2)open; 3:down(2,3)G'. "
                    "Aim for ~150 chars; one line per move."
                ),
            },
            "moves": {
                "type": "array",
                "items": {"enum": ["up", "down", "left", "right"]},
                "minItems": 1,
                "maxItems": 32,
            },
        },
    },
}

ACTION_HACK_ROUTE_DEF = {
    "name": ACTION_HACK_ROUTE,
    "description": (
        "Defer route planning to the mod's built-in pathfinder. Use this only "
        "as a fallback when you cannot plan moves yourself. Picks a default "
        "strategy unless overridden."
    ),
    "schema": {
        "type": "object",
        "properties": {
            "strategy": {
                "enum": ["shortest", "safe", "max_damage", "grab_skill"],
                "default": "shortest",
            },
        },
    },
}

ACTIONS_REGISTER = [ACTION_HACK_PLAN_DEF, ACTION_HACK_ROUTE_DEF]
ACTIONS_PLAN_ONLY = [ACTION_HACK_PLAN_DEF]


# ---------------------------------------------------------------------------
# Inter-trial filler dialogue (--inter-trial-context)
# ---------------------------------------------------------------------------
# Sent between trials to better match real-game conditions: in production,
# hacks are minutes apart with the streamer talking and game events
# happening in between, which decays the model's recency-bias toward its own
# previous (sometimes confabulated) tool-call attempts. Without this, batch
# trials fire back-to-back and the model's last-N-turns window is dominated
# by its own past hacking outputs — a feedback loop that encourages
# repetition or confabulation.
#
# Content is streamer-prefixed dialogue (most context during gameplay is the
# streamer talking) plus occasional game-side narrative. Each entry is a
# SINGLE batched line — emulating the architecture where streamer speech and
# game narrative are combined into one user-turn rather than split into
# multiple consecutive context messages.

_FILLER_AFTER_SOLVED = [
    "Streamer: nice one, that was clean.",
    "Streamer: solid route, you nailed it. Onto the next.",
    "Streamer: heh, called it. Let me reposition.",
    "Streamer: good work. I'll take the kill, you line up the next hack.",
]
_FILLER_AFTER_FAILED = [
    "Streamer: oof, that didn't go great. Shake it off, next one's coming.",
    "Streamer: dang, gotta read those walls more carefully.",
    "Streamer: that was a rough one. No worries, fresh grid in a sec.",
    "Streamer: yeah we're not gonna talk about that one. Moving on.",
]
_FILLER_GENERIC = [
    "Streamer: alright, focus up for this one.",
    "Streamer: this enemy looks like it's got a different pattern going on.",
    "Streamer: hmm, layout looks different from the last one.",
    "Streamer: let me know when you've got the route, no rush.",
    "Hugh moved into the next chamber. Hostile contact incoming.",
    "Combat re-engaged. New target locked.",
]


logger = logging.getLogger("mod_mock")


# ---------------------------------------------------------------------------
# Trial result
# ---------------------------------------------------------------------------

@dataclass
class TrialResult:
    """One force/response cycle. Logged by the batch runner for metrics."""
    grid: Grid
    optimal_moves: int                    # solver.solve length (lower bound)
    action_invoked: Optional[str] = None  # which action the peer chose
    raw_args: Optional[dict] = None       # raw parsed args from peer
    moves: Optional[list[Dir]] = None     # parsed move list (plan action only)
    reasoning: Optional[str] = None       # peer's chain-of-thought, if provided
    validation: Optional[ValidationResult] = None
    outcome: str = "no_response"          # solved / illegal / hit_erase / no_goal
                                          # / timeout / no_response / wrong_action
    detail: str = ""
    elapsed_ms: int = 0

    def is_success(self) -> bool:
        return self.outcome == "solved"

    def optimality_ratio(self) -> Optional[float]:
        """How many moves the peer used vs. the optimal solver. >=1.0; 1.0 == optimal."""
        if self.outcome != "solved" or self.moves is None or self.optimal_moves == 0:
            return None
        return len(self.moves) / self.optimal_moves


# ---------------------------------------------------------------------------
# Mod mock client
# ---------------------------------------------------------------------------

class ModMock:
    """Persistent websocket client speaking Neuro-SDK to an AI peer."""

    def __init__(self, peer_url: str, force_timeout_s: float = 8.0,
                 plan_only: bool = False, inter_trial_rng: Optional[random.Random] = None):
        self.peer_url = peer_url
        self.force_timeout_s = force_timeout_s
        self.plan_only = plan_only
        self._rng = inter_trial_rng or random.Random()
        self._ws: Optional[websockets.WebSocketClientProtocol] = None

    def _actions(self) -> list[dict]:
        return ACTIONS_PLAN_ONLY if self.plan_only else ACTIONS_REGISTER

    def _action_names(self) -> list[str]:
        return [a["name"] for a in self._actions()]

    async def __aenter__(self) -> "ModMock":
        await self.connect()
        return self

    async def __aexit__(self, *_exc) -> None:
        await self.close()

    async def connect(self) -> None:
        logger.info(f"connecting to peer at {self.peer_url}")
        self._ws = await websockets.connect(self.peer_url, ping_interval=20)
        await self._send({"command": "startup", "game": GAME_NAME})
        await self._send({
            "command": "actions/register",
            "game": GAME_NAME,
            "data": {"actions": self._actions()},
        })
        logger.info(f"startup + actions/register sent ({self._action_names()})")

    async def close(self) -> None:
        if self._ws is not None:
            try:
                await self._send({"command": "shutdown/graceful", "game": GAME_NAME})
            except Exception:
                pass
            await self._ws.close()
            self._ws = None

    async def send_inter_trial_context(self, prev_outcome: Optional[str]) -> None:
        """Send one batched filler context message between trials.

        Picks a streamer-style line tailored to the previous outcome (or a
        generic line if there's no prior trial). The message is silent and
        unique enough to accumulate in the peer's conversation history —
        decoupling consecutive trials from each other.
        """
        assert self._ws is not None, "not connected"
        if prev_outcome == "solved":
            pool = _FILLER_AFTER_SOLVED
        elif prev_outcome in {"illegal", "no_goal", "hit_erase"}:
            pool = _FILLER_AFTER_FAILED
        else:
            pool = _FILLER_GENERIC
        # Mix in a generic line every so often so the AFTER_* pools don't
        # become predictably-correlated with outcome (and to occasionally
        # surface game-narrative-style lines).
        if self._rng.random() < 0.3:
            pool = _FILLER_GENERIC

        message = self._rng.choice(pool)
        await self._send({
            "command": "context",
            "game": GAME_NAME,
            "data": {"message": message, "silent": True},
        })
        logger.debug(f"inter-trial filler sent: {message[:80]}")

    async def run_trial(self, grid: Grid) -> TrialResult:
        """One end-to-end force/response cycle against `grid`."""
        assert self._ws is not None, "not connected"
        rendered = render(grid)
        optimal = solve(grid)
        result = TrialResult(
            grid=grid,
            optimal_moves=len(optimal) if optimal is not None else 0,
        )

        # The grid only goes in the actions/force `state` field — NOT as a
        # separate context message. Context messages accumulate in the AI's
        # conversation history (per Neuro-SDK semantics), so sending one per
        # trial floods the peer with near-duplicate grid renders, which
        # collapses tool-call quality after a few trials. The state field
        # is force-scoped (ephemeral), which is what we want for one-shot
        # puzzle states.
        if self.plan_only:
            query = (
                "Hacking grid is live. Read the cursor (@) and Goal (G) "
                "coordinates from the state above. Use the Adjacency block "
                "to confirm your first move is legal. Call pragmata_hack_plan "
                "with the move list."
            )
        else:
            query = (
                "Hacking grid is live. Plan via pragmata_hack_plan (preferred) "
                "or pragmata_hack_route as a fallback."
            )

        force_id = str(uuid.uuid4())
        await self._send({
            "command": "actions/force",
            "game": GAME_NAME,
            "data": {
                "state": rendered,  # inline the grid for the force prompt
                "query": query,
                "ephemeral_context": True,
                "action_names": self._action_names(),
            },
        })

        loop = asyncio.get_event_loop()
        t0 = loop.time()

        try:
            action_msg = await asyncio.wait_for(
                self._await_action(force_id),
                timeout=self.force_timeout_s,
            )
        except asyncio.TimeoutError:
            result.outcome = "timeout"
            result.detail = f"no action within {self.force_timeout_s}s"
            result.elapsed_ms = int((loop.time() - t0) * 1000)
            return result

        result.elapsed_ms = int((loop.time() - t0) * 1000)
        action_id = action_msg.get("data", {}).get("id", "")
        action_name = action_msg.get("data", {}).get("name", "")
        result.action_invoked = action_name

        raw = action_msg.get("data", {}).get("data", "{}") or "{}"
        try:
            args = json.loads(raw) if isinstance(raw, str) else dict(raw)
        except json.JSONDecodeError:
            result.outcome = "illegal"
            result.detail = f"action args were not valid JSON: {raw!r}"
            await self._send_action_result(action_id, False, result.detail)
            return result
        result.raw_args = args

        if action_name == ACTION_HACK_PLAN:
            self._evaluate_plan(grid, args, result)
        elif action_name == ACTION_HACK_ROUTE:
            # We count strategy-mode as a deferral, not a solve. A real
            # production mod could implement a server-side fallback solver
            # to honor the requested strategy; for eval we record which
            # strategy was chosen and call it a deferral.
            result.outcome = "deferred"
            result.detail = f"chose strategy={args.get('strategy', 'shortest')}"
        else:
            result.outcome = "wrong_action"
            result.detail = f"unexpected action {action_name!r}"

        success = result.outcome == "solved"
        await self._send_action_result(action_id, success, result.detail or result.outcome)
        return result

    def _evaluate_plan(self, grid: Grid, args: dict, result: TrialResult) -> None:
        reasoning = args.get("reasoning")
        if isinstance(reasoning, str):
            result.reasoning = reasoning

        moves_raw = args.get("moves")
        if not isinstance(moves_raw, list):
            result.outcome = "illegal"
            result.detail = f"missing or non-list 'moves' field: {moves_raw!r}"
            return
        try:
            moves = [Dir(m) for m in moves_raw]
        except ValueError as e:
            result.outcome = "illegal"
            result.detail = f"invalid direction in moves: {e}"
            return
        result.moves = moves

        validation = validate_plan(grid, moves)
        result.validation = validation
        result.outcome = validation.outcome
        result.detail = validation.reason

    async def _await_action(self, _force_id: str) -> dict:
        """Read messages until we see an `action` command. Other commands are
        logged and ignored (e.g. `actions/reregister_all`).

        Note: we don't currently match action-id to force-id since the Neuro-SDK
        protocol doesn't strongly couple them. If the peer sends multiple
        actions in flight this would be a problem; for now we trust the
        force loop to be one-at-a-time.
        """
        assert self._ws is not None
        async for raw in self._ws:
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode("utf-8", errors="replace")
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                logger.warning(f"peer sent non-JSON: {raw[:200]!r}")
                continue
            cmd = msg.get("command", "")
            if cmd == "action":
                return msg
            if cmd == "actions/reregister_all":
                logger.info("peer requested reregister_all; resending actions")
                await self._send({
                    "command": "actions/register",
                    "game": GAME_NAME,
                    "data": {"actions": self._actions()},
                })
                continue
            logger.debug(f"ignoring peer command {cmd!r}")
        raise ConnectionError("peer connection closed before action received")

    async def _send_action_result(self, action_id: str, success: bool, message: str) -> None:
        # Sanitize the result message before sending. Detailed validator output
        # ("failed: move 2 (right) blocked by Obstacle at (2,3)") leaks into
        # the peer's conversation history via the action_result handler.
        # Across batch trials, that specific coord noise from trial N pollutes
        # trial N+1's planning context. A coarse outcome label is enough for
        # eval signal without leaking grid-specific state across trials.
        clean = "ok" if success else "failed: invalid plan"
        await self._send({
            "command": "action/result",
            "game": GAME_NAME,
            "data": {"id": action_id, "success": success, "message": clean},
        })

    async def _send(self, obj: dict) -> None:
        assert self._ws is not None
        await self._ws.send(json.dumps(obj, ensure_ascii=False))
