from __future__ import annotations

import argparse
import base64
import json
import sys
import urllib.request

from nacl import encoding, public


def api_request(url: str, token: str, method: str = "GET", payload: bytes | None = None) -> dict:
    request = urllib.request.Request(url, data=payload, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=60) as response:
        body = response.read().decode("utf-8")
        return json.loads(body) if body else {}


def encrypt(public_key_b64: str, secret_value: str) -> str:
    sealed_box = public.SealedBox(public.PublicKey(public_key_b64.encode("utf-8"), encoding.Base64Encoder()))
    encrypted = sealed_box.encrypt(secret_value.encode("utf-8"))
    return base64.b64encode(encrypted).decode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", required=True)
    parser.add_argument("--repo", required=True, help="owner/repo")
    parser.add_argument("--name", required=True)
    parser.add_argument("--value", required=True)
    args = parser.parse_args()

    owner, repo = args.repo.split("/", 1)
    key_url = f"https://api.github.com/repos/{owner}/{repo}/actions/secrets/public-key"
    key_payload = api_request(key_url, args.token)
    encrypted_value = encrypt(key_payload["key"], args.value)

    put_url = f"https://api.github.com/repos/{owner}/{repo}/actions/secrets/{args.name}"
    payload = json.dumps(
        {
            "encrypted_value": encrypted_value,
            "key_id": key_payload["key_id"],
        }
    ).encode("utf-8")
    api_request(put_url, args.token, method="PUT", payload=payload)
    print(f"secret-set:{args.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
