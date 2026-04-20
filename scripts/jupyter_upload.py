#!/usr/bin/env python3
import argparse
import base64
import mimetypes
from pathlib import Path

import requests


def build_session() -> requests.Session:
    session = requests.Session()
    session.trust_env = False
    return session


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--local-path", required=True)
    parser.add_argument("--remote-path", required=True)
    args = parser.parse_args()

    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]

    local_path = Path(args.local_path)
    data = local_path.read_bytes()
    mime, _ = mimetypes.guess_type(local_path.name)
    payload = {
        "type": "file",
        "format": "base64",
        "content": base64.b64encode(data).decode("ascii"),
        "mimetype": mime or "application/octet-stream",
    }
    session = build_session()
    response = session.put(
        f"{args.base_url.rstrip('/')}/api/contents/{args.remote_path.lstrip('/')}",
        params={"token": args.token},
        json=payload,
        verify=False,
        timeout=600,
    )
    response.raise_for_status()
    print(response.json().get("path", args.remote_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
