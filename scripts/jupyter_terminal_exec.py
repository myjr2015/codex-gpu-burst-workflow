#!/usr/bin/env python3
import argparse
import json
import re
import ssl
import sys
import uuid

import requests
import websocket
from websocket import WebSocketTimeoutException


ANSI_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]|\x1B\].*?\x07")


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text).replace("\r", "")


def build_session() -> requests.Session:
    session = requests.Session()
    session.trust_env = False
    return session


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--command", required=True)
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()

    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
    session = build_session()
    create = session.post(
        f"{args.base_url.rstrip('/')}/api/terminals",
        params={"token": args.token},
        verify=False,
        timeout=30,
    )
    create.raise_for_status()
    name = create.json()["name"]

    ws_url = (
        f"{args.base_url.rstrip('/').replace('https://', 'wss://').replace('http://', 'ws://')}"
        f"/terminals/websocket/{name}?token={args.token}"
    )
    websocket.setdefaulttimeout(10)
    ws = websocket.create_connection(ws_url, sslopt={"cert_reqs": ssl.CERT_NONE})

    sentinel = f"__CODEX_DONE_{uuid.uuid4().hex}__"
    payload = f"{args.command}; printf '\\n{sentinel}:%s\\n' $?\\n"
    exit_code = None

    try:
        for _ in range(2):
            try:
                ws.recv()
            except Exception:
                break

        ws.send(json.dumps(["stdin", payload + "\r"]))
        end_time = requests.sessions.preferred_clock() + args.timeout

        while requests.sessions.preferred_clock() < end_time:
            try:
                message = ws.recv()
            except WebSocketTimeoutException:
                continue
            kind, data = json.loads(message)
            if kind != "stdout":
                continue

            clean = strip_ansi(data)
            if clean:
                sys.stdout.write(clean)
                sys.stdout.flush()

            match = re.search(rf"{re.escape(sentinel)}:(\d+)", clean)
            if match:
                exit_code = int(match.group(1))
                break
    finally:
        ws.close()

    if exit_code is None:
        print("\nTimed out waiting for command completion.", file=sys.stderr)
        return 124
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
