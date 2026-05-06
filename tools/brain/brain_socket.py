#!/usr/bin/env python3
"""
brain_socket.py — Socket Mode bridge between Slack and brain.rail.

Holds a persistent WebSocket to Slack via the app-level token. When a
message starts with "brain " (case-insensitive), the rest is fed into
~/.ledatic/brain/perception.txt; brain.rail runs one tick; the
contents of ~/.ledatic/brain/last_response.txt are posted back in
the same thread.

Tokens (file paths, never inline):
  ~/.fleet/slack_app_token   -- xapp-* (Socket Mode)
  ~/.fleet/slack_token       -- xoxb-* (Bot OAuth, for chat.postMessage)

Logs to ~/.fleet/brain_socket/{stdout.log, stderr.log}.

Run as ~/Library/LaunchAgents/com.ledatic.brain_socket.plist with
KeepAlive=true so the WebSocket reconnects on disconnect.
"""

import subprocess
import sys
import time
from pathlib import Path

from slack_sdk import WebClient
from slack_sdk.socket_mode import SocketModeClient
from slack_sdk.socket_mode.request import SocketModeRequest
from slack_sdk.socket_mode.response import SocketModeResponse

HOME = Path.home()
APP_TOKEN_FILE = HOME / ".fleet" / "slack_app_token"
BOT_TOKEN_FILE = HOME / ".fleet" / "slack_token"
BRAIN_DIR = HOME / ".ledatic" / "brain"
PERCEPTION = BRAIN_DIR / "perception.txt"
RESPONSE = BRAIN_DIR / "last_response.txt"
RAIL_REPO = HOME / "projects" / "rail-https"
RAIL_BIN = RAIL_REPO / "rail_native"
BRAIN_RAIL = RAIL_REPO / "tools" / "brain" / "brain.rail"

LOG_DIR = HOME / ".fleet" / "brain_socket"
LOG_DIR.mkdir(parents=True, exist_ok=True)


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(f"[{ts}] {msg}", flush=True)


def run_brain(message: str) -> str:
    """Drop perception, invoke rail_native run brain.rail, read response."""
    BRAIN_DIR.mkdir(parents=True, exist_ok=True)
    PERCEPTION.write_text(message)
    try:
        subprocess.run(
            [str(RAIL_BIN), "run", str(BRAIN_RAIL)],
            cwd=str(RAIL_REPO),
            capture_output=True,
            timeout=30,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return "(brain timed out after 30s)"
    if RESPONSE.exists():
        return RESPONSE.read_text().rstrip("\n")
    return "(brain produced no response)"


def make_handler(web: WebClient):
    bot_user = web.auth_test()["user_id"]
    log(f"connected as bot user {bot_user}")

    def handler(client: SocketModeClient, req: SocketModeRequest) -> None:
        # Always ack first so Slack doesn't redeliver.
        client.send_socket_mode_response(
            SocketModeResponse(envelope_id=req.envelope_id)
        )

        if req.type != "events_api":
            return

        ev = (req.payload or {}).get("event", {})
        if ev.get("type") != "message":
            return
        if ev.get("subtype"):
            return  # join/leave/edit/delete
        if ev.get("bot_id") or ev.get("user") == bot_user:
            return  # don't echo-loop on our own posts

        text = (ev.get("text") or "").strip()
        if not text:
            return

        # Trigger: any message whose first word is "brain" (case-insensitive).
        first, _, rest = text.partition(" ")
        if first.lower() != "brain":
            return

        message = rest.strip() or "(empty)"
        channel = ev.get("channel")
        thread_ts = ev.get("thread_ts") or ev.get("ts")
        log(f"brain msg from {ev.get('user')} in {channel}: {message[:80]}")

        try:
            response = run_brain(message)
        except Exception as e:
            response = f"(brain crashed: {e!r})"
            log(response)

        try:
            web.chat_postMessage(
                channel=channel,
                thread_ts=thread_ts,
                text=f"*brain*\n```\n{response[:2800]}\n```",
                mrkdwn=True,
            )
        except Exception as e:
            log(f"post failed: {e!r}")

    return handler


def main() -> int:
    if not APP_TOKEN_FILE.is_file() or not BOT_TOKEN_FILE.is_file():
        log("missing token file(s); aborting")
        return 1

    app_token = APP_TOKEN_FILE.read_text().strip()
    bot_token = BOT_TOKEN_FILE.read_text().strip()

    web = WebClient(token=bot_token)
    client = SocketModeClient(app_token=app_token, web_client=web)
    client.socket_mode_request_listeners.append(make_handler(web))

    client.connect()
    log("WebSocket connected; awaiting events")
    # Block forever; LaunchAgent KeepAlive restarts us if we die.
    try:
        while True:
            time.sleep(60)
    except KeyboardInterrupt:
        log("interrupted; shutting down")
        return 0


if __name__ == "__main__":
    sys.exit(main())
