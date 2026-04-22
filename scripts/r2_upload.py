#!/usr/bin/env python3
import argparse
import mimetypes
import sys
from pathlib import Path
from urllib.parse import quote

import boto3


def iter_files(path: Path):
    if path.is_file():
        yield path, path.name
        return

    for file_path in sorted(p for p in path.rglob("*") if p.is_file()):
        yield file_path, file_path.relative_to(path).as_posix()


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    parser = argparse.ArgumentParser()
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--access-key-id", required=True)
    parser.add_argument("--secret-access-key", required=True)
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--local-path", required=True)
    parser.add_argument("--remote-prefix", required=True)
    parser.add_argument("--public-base-url")
    args = parser.parse_args()

    local_path = Path(args.local_path).resolve()
    if not local_path.exists():
        raise FileNotFoundError(local_path)

    endpoint_url = f"https://{args.account_id}.r2.cloudflarestorage.com"
    client = boto3.client(
        "s3",
        endpoint_url=endpoint_url,
        aws_access_key_id=args.access_key_id,
        aws_secret_access_key=args.secret_access_key,
        region_name="auto",
    )

    public_base = args.public_base_url.rstrip("/") if args.public_base_url else None
    remote_prefix = args.remote_prefix.strip("/")

    for file_path, relative_key in iter_files(local_path):
        key = f"{remote_prefix}/{relative_key}".strip("/")
        content_type, _ = mimetypes.guess_type(file_path.name)
        extra = {}
        if content_type:
            extra["ExtraArgs"] = {"ContentType": content_type}
        client.upload_file(str(file_path), args.bucket, key, **extra)
        if public_base:
            print(f"{file_path} -> {public_base}/{quote(key)}")
        else:
            print(f"{file_path} -> s3://{args.bucket}/{key}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
