import argparse
import json
import mimetypes
import os
import sys
import time
from pathlib import Path

import requests


DEFAULT_BASE_URL = "https://www.runninghub.cn"
DEFAULT_TIMEOUT = 120


def load_dotenv(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        name = name.strip()
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        if name:
            values[name] = value
    return values


def load_api_backup(path):
    entries = {}
    if not path.exists():
        return entries
    lines = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    index = 0
    while index + 1 < len(lines):
        site = lines[index]
        value = lines[index + 1]
        if site and value:
            entries[site] = value
        index += 2
    return entries


def resolve_api_key(repo_root, explicit):
    if explicit:
        return explicit

    for name in ("RUNNINGHUB_API_KEY", "RUNNINGHUB_KEY"):
        value = os.environ.get(name)
        if value:
            return value

    dotenv_values = load_dotenv(repo_root / ".env")
    for name in ("RUNNINGHUB_API_KEY", "RUNNINGHUB_KEY"):
        value = dotenv_values.get(name)
        if value:
            return value

    backup_values = load_api_backup(repo_root / "api.txt")
    for name in ("RunningHub", "runninghub", "runninghub.cn", "RunningHub API Key"):
        value = backup_values.get(name)
        if value:
            return value

    raise RuntimeError("Missing RunningHub API key in env, .env, or api.txt.")


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def redact_payload(payload):
    copied = json.loads(json.dumps(payload, ensure_ascii=False))
    if "apiKey" in copied:
        copied["apiKey"] = "***"
    return copied


def assert_success(response_json, action):
    if not isinstance(response_json, dict):
        raise RuntimeError(f"{action} returned non-object JSON: {response_json!r}")
    if response_json.get("code") != 0:
        message = response_json.get("msg") or response_json.get("errorMessages") or response_json
        raise RuntimeError(f"{action} failed: {message}")
    return response_json.get("data")


def post_json(base_url, path, payload):
    response = requests.post(
        base_url.rstrip("/") + path,
        json=payload,
        timeout=DEFAULT_TIMEOUT,
        headers={"Content-Type": "application/json"},
    )
    response.raise_for_status()
    return response.json()


def infer_file_type(path, explicit):
    if explicit:
        return explicit
    suffix = path.suffix.lower()
    if suffix in (".png", ".jpg", ".jpeg", ".webp", ".bmp"):
        return "image"
    if suffix in (".mp4", ".mov", ".mkv", ".webm"):
        return "video"
    if suffix in (".wav", ".mp3", ".m4a", ".aac", ".flac"):
        return "audio"
    raise RuntimeError(f"Cannot infer RunningHub fileType from suffix: {path}")


def normalize_uploaded_ref(data):
    if isinstance(data, str):
        return data
    if isinstance(data, dict):
        for key in ("fileName", "filename", "file_name", "name", "path"):
            value = data.get(key)
            if value:
                return value
        if isinstance(data.get("data"), str):
            return data["data"]
    raise RuntimeError(f"Could not find uploaded file reference in response data: {data!r}")


def upload_file(base_url, api_key, path, file_type):
    path = path.resolve()
    if not path.exists():
        raise FileNotFoundError(path)
    mime_type = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
    with path.open("rb") as handle:
        files = {"file": (path.name, handle, mime_type)}
        data = {"apiKey": api_key, "fileType": file_type}
        response = requests.post(base_url.rstrip("/") + "/task/openapi/upload", data=data, files=files, timeout=DEFAULT_TIMEOUT)
    response.raise_for_status()
    response_json = response.json()
    uploaded = assert_success(response_json, "upload")
    return response_json, normalize_uploaded_ref(uploaded)


def parse_node(value):
    if ":" not in value or "=" not in value:
        raise argparse.ArgumentTypeError("node override must be NODE_ID:field=value")
    left, raw_value = value.split("=", 1)
    node_id, field = left.split(":", 1)
    node_id = node_id.strip()
    field = field.strip()
    if not node_id or not field:
        raise argparse.ArgumentTypeError("node override must include node id and field name")
    try:
        node_id_int = int(node_id)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("node id must be an integer") from exc
    return {"nodeId": str(node_id_int), "fieldName": field, "fieldValue": coerce_value(raw_value)}


def coerce_value(value):
    value = value.strip()
    if value.startswith("@"):
        path = Path(value[1:])
        return path.read_text(encoding="utf-8").strip()
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in ("null", "none"):
        return None
    try:
        if "." not in value:
            return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        return value


def load_node_info(args):
    if args.payload:
        payload = json.loads(Path(args.payload).read_text(encoding="utf-8"))
        if "nodeInfoList" not in payload:
            raise RuntimeError("payload JSON must include nodeInfoList")
        if args.workflow_id and str(payload.get("workflowId")) != str(args.workflow_id):
            payload["workflowId"] = str(args.workflow_id)
        return payload
    return {"workflowId": str(args.workflow_id), "nodeInfoList": args.node or []}


def save_status(job_dir, index, status_json):
    write_json(job_dir / f"runninghub-status-{index:02d}.json", status_json)


def download_outputs(outputs_json, output_dir):
    data = assert_success(outputs_json, "outputs")
    if not isinstance(data, list):
        raise RuntimeError(f"outputs data must be a list: {data!r}")
    output_dir.mkdir(parents=True, exist_ok=True)
    downloaded = []
    for index, item in enumerate(data, start=1):
        url = item.get("fileUrl") if isinstance(item, dict) else None
        if not url:
            continue
        name = url.rstrip("/").split("/")[-1] or f"output-{index}.bin"
        node_id = str(item.get("nodeId", index)) if isinstance(item, dict) else str(index)
        destination = output_dir / f"{index:02d}_{node_id}_{name}"
        with requests.get(url, stream=True, timeout=DEFAULT_TIMEOUT) as response:
            response.raise_for_status()
            with destination.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if chunk:
                        handle.write(chunk)
        downloaded.append(str(destination))
    return downloaded


def cmd_upload(args):
    repo_root = Path(args.repo_root).resolve()
    api_key = resolve_api_key(repo_root, args.api_key)
    path = Path(args.file)
    file_type = infer_file_type(path, args.file_type)
    response_json, file_ref = upload_file(args.base_url, api_key, path, file_type)
    record = {
        "file": str(path.resolve()),
        "fileType": file_type,
        "fieldValue": file_ref,
        "response": response_json,
    }
    if args.output_json:
        write_json(Path(args.output_json), record)
    print(file_ref)


def cmd_run(args):
    repo_root = Path(args.repo_root).resolve()
    job_dir = Path(args.job_dir).resolve()
    job_dir.mkdir(parents=True, exist_ok=True)

    api_key = resolve_api_key(repo_root, args.api_key)
    payload = load_node_info(args)
    payload["apiKey"] = api_key
    if not payload.get("workflowId"):
        raise RuntimeError("workflowId is required")
    if not payload.get("nodeInfoList"):
        raise RuntimeError("nodeInfoList is empty")

    write_json(job_dir / "runninghub-submit-payload.json", redact_payload(payload))
    create_json = post_json(args.base_url, "/task/openapi/create", payload)
    write_json(job_dir / "runninghub-create-response.json", create_json)
    create_data = assert_success(create_json, "create")
    task_id = str(create_data.get("taskId") or "")
    if not task_id:
        raise RuntimeError(f"create response did not include taskId: {create_data!r}")
    print(f"task_id={task_id}")

    last_status = None
    for index in range(1, args.max_checks + 1):
        status_payload = {"apiKey": api_key, "taskId": task_id}
        status_json = post_json(args.base_url, "/task/openapi/status", status_payload)
        save_status(job_dir, index, status_json)
        last_status = assert_success(status_json, "status")
        print(f"poll={index} status={last_status}")
        if str(last_status).upper() in ("SUCCESS", "FAILED", "FAILURE", "ERROR"):
            break
        time.sleep(args.interval_seconds)

    outputs_json = post_json(args.base_url, "/task/openapi/outputs", {"apiKey": api_key, "taskId": task_id})
    write_json(job_dir / "runninghub-outputs.json", outputs_json)
    if str(last_status).upper() != "SUCCESS":
        raise RuntimeError(f"RunningHub task did not succeed, final status={last_status}")

    downloaded = download_outputs(outputs_json, job_dir / "downloads")
    write_json(
        job_dir / "manifest.json",
        {
            "job_name": args.job_name or job_dir.name,
            "workflow_id": str(payload["workflowId"]),
            "runninghub_task_id": task_id,
            "downloaded_files": downloaded,
        },
    )
    for path in downloaded:
        print(f"downloaded={path}")


def cmd_outputs(args):
    repo_root = Path(args.repo_root).resolve()
    api_key = resolve_api_key(repo_root, args.api_key)
    payload = {"apiKey": api_key, "taskId": str(args.task_id)}
    outputs_json = post_json(args.base_url, "/task/openapi/outputs", payload)
    if args.output_json:
        write_json(Path(args.output_json), outputs_json)
    print(json.dumps(outputs_json, ensure_ascii=False, indent=2))


def build_parser():
    parser = argparse.ArgumentParser(description="Small RunningHub OpenAPI helper for this project.")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--api-key", default="")
    subparsers = parser.add_subparsers(dest="command", required=True)

    upload = subparsers.add_parser("upload")
    upload.add_argument("--file", required=True)
    upload.add_argument("--file-type", choices=["image", "video", "audio"], default="")
    upload.add_argument("--output-json", default="")
    upload.set_defaults(func=cmd_upload)

    run = subparsers.add_parser("run")
    run.add_argument("--workflow-id", default="")
    run.add_argument("--payload", default="")
    run.add_argument("--node", action="append", type=parse_node, default=[])
    run.add_argument("--job-dir", required=True)
    run.add_argument("--job-name", default="")
    run.add_argument("--interval-seconds", type=int, default=20)
    run.add_argument("--max-checks", type=int, default=90)
    run.set_defaults(func=cmd_run)

    outputs = subparsers.add_parser("outputs")
    outputs.add_argument("--task-id", required=True)
    outputs.add_argument("--output-json", default="")
    outputs.set_defaults(func=cmd_outputs)
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
