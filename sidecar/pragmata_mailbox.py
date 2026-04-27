"""Pragmata file-mailbox sidecar.

Bridges the Pragmata Lua mod's file mailbox to a Neuro-SDK WebSocket peer.
The Lua mod runs inside a sandboxed REFramework Lua environment that can't
open sockets, so we use newline-delimited JSON files in
<Pragmata>/reframework/data/pragmata_mailbox/ as the transport:

    lua_to_bridge.jsonl  Lua appends, this sidecar tails -> WS to peer
    bridge_to_lua.jsonl  WS from peer -> this sidecar appends, Lua tails

Wire content is opaque Neuro-SDK JSON. The sidecar does no protocol
validation — it forwards lines verbatim in both directions.

Usage:
    python pragmata_mailbox.py \\
        --mailbox-dir "<Pragmata>/reframework/data/pragmata_mailbox" \\
        --bridge-url ws://127.0.0.1:8000

Set the WebSocket URL of your Neuro-SDK peer with --bridge-url, or via the
PRAGMATA_BRIDGE_WS environment variable. Reconnects on disconnect with
linear backoff. Exits on SIGINT.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import signal
import sys
from pathlib import Path

import websockets


DEFAULT_BRIDGE_WS = "ws://127.0.0.1:8769"
POLL_INTERVAL_SEC = 0.033  # ~30 Hz; matches Lua frame-loop polling
RECONNECT_BACKOFF_SEC = 3.0

logger = logging.getLogger("pragmata_mailbox")


def _configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [pragmata_mailbox] %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    for noisy in ("websockets", "asyncio"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


async def _tail_outbox(path: Path, send_queue: asyncio.Queue[str], stop: asyncio.Event) -> None:
    """Tail lua_to_bridge.jsonl. Push each new line into send_queue.

    Skips any pre-existing content on first open so a stale outbox from a
    previous session doesn't get replayed to the bridge. The Lua side does
    the same for its inbox.
    """
    offset = 0
    if path.exists():
        offset = path.stat().st_size
        logger.info(f"outbox exists at startup; skipping {offset} bytes of stale content")

    while not stop.is_set():
        try:
            if path.exists():
                size = path.stat().st_size
                if size > offset:
                    with path.open("r", encoding="utf-8", errors="replace") as f:
                        f.seek(offset)
                        for line in f:
                            line = line.rstrip("\r\n")
                            if line:
                                await send_queue.put(line)
                        offset = f.tell()
        except Exception:
            logger.exception("tail_outbox: read failed")
        try:
            await asyncio.wait_for(stop.wait(), timeout=POLL_INTERVAL_SEC)
        except asyncio.TimeoutError:
            pass


async def _ws_writer(ws, send_queue: asyncio.Queue[str], stop: asyncio.Event) -> None:
    """Forward queued lines to the bridge."""
    while not stop.is_set():
        try:
            line = await asyncio.wait_for(send_queue.get(), timeout=0.5)
        except asyncio.TimeoutError:
            continue
        try:
            await ws.send(line)
            logger.debug(f"-> bridge: {line[:120]}")
        except Exception:
            # Re-queue line for next connection attempt
            await send_queue.put(line)
            raise


async def _ws_reader(ws, inbox_path: Path, stop: asyncio.Event) -> None:
    """Receive messages from the bridge, append them as JSONL to the inbox file."""
    async for raw in ws:
        if stop.is_set():
            return
        if isinstance(raw, (bytes, bytearray)):
            raw = raw.decode("utf-8", errors="replace")
        # Validate it's JSON before writing so the Lua side doesn't have to
        # cope with a half-baked line. If it's not JSON we drop and log.
        try:
            json.loads(raw)
        except json.JSONDecodeError:
            logger.warning(f"bridge sent non-JSON, dropping: {raw[:120]!r}")
            continue
        line = raw.replace("\n", " ").replace("\r", " ")
        try:
            with inbox_path.open("a", encoding="utf-8") as f:
                f.write(line + "\n")
            logger.debug(f"<- bridge: {line[:120]}")
        except Exception:
            logger.exception("ws_reader: inbox append failed")


async def _connect_loop(
    bridge_url: str,
    outbox: Path,
    inbox: Path,
    stop: asyncio.Event,
) -> None:
    send_queue: asyncio.Queue[str] = asyncio.Queue()

    # Start tailing the outbox immediately. Buffered messages will be sent
    # as soon as the WS connects (or re-queued on disconnect).
    tail_task = asyncio.create_task(_tail_outbox(outbox, send_queue, stop), name="tail_outbox")

    try:
        while not stop.is_set():
            logger.info(f"connecting to {bridge_url}")
            try:
                async with websockets.connect(bridge_url, ping_interval=20) as ws:
                    logger.info("connected to bridge")
                    writer = asyncio.create_task(_ws_writer(ws, send_queue, stop), name="ws_writer")
                    reader = asyncio.create_task(_ws_reader(ws, inbox, stop), name="ws_reader")
                    done, pending = await asyncio.wait(
                        {writer, reader, asyncio.create_task(stop.wait())},
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    for t in pending:
                        t.cancel()
                    for t in done:
                        if t.exception() and not isinstance(t.exception(), asyncio.CancelledError):
                            logger.warning(f"task ended with: {t.exception()}")
            except (OSError, websockets.exceptions.WebSocketException) as e:
                logger.warning(f"bridge connection failed: {e}")
            if stop.is_set():
                break
            logger.info(f"reconnecting in {RECONNECT_BACKOFF_SEC}s")
            try:
                await asyncio.wait_for(stop.wait(), timeout=RECONNECT_BACKOFF_SEC)
            except asyncio.TimeoutError:
                pass
    finally:
        tail_task.cancel()
        try:
            await tail_task
        except asyncio.CancelledError:
            pass


async def _amain(args: argparse.Namespace) -> int:
    mailbox_dir = Path(args.mailbox_dir).expanduser().resolve()
    mailbox_dir.mkdir(parents=True, exist_ok=True)
    outbox = mailbox_dir / "lua_to_bridge.jsonl"
    inbox = mailbox_dir / "bridge_to_lua.jsonl"
    # Touch the inbox so the Lua side's open-for-read succeeds immediately.
    if not inbox.exists():
        inbox.touch()

    logger.info(f"mailbox_dir={mailbox_dir}")
    logger.info(f"outbox={outbox.name} inbox={inbox.name}")

    stop = asyncio.Event()

    def _handle_signal(signum, _frame=None):
        logger.info(f"signal {signum} received; shutting down")
        stop.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, _handle_signal)
        except (ValueError, OSError):
            pass

    await _connect_loop(args.bridge_url, outbox, inbox, stop)
    logger.info("stopped")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Pragmata mailbox sidecar")
    parser.add_argument(
        "--mailbox-dir",
        required=True,
        help="Path to <Pragmata>/reframework/data/pragmata_mailbox/",
    )
    parser.add_argument(
        "--bridge-url",
        default=os.environ.get("PRAGMATA_BRIDGE_WS", DEFAULT_BRIDGE_WS),
        help=f"WebSocket URL of the Neuro-SDK peer (default {DEFAULT_BRIDGE_WS})",
    )
    args = parser.parse_args()
    _configure_logging()
    try:
        return asyncio.run(_amain(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
