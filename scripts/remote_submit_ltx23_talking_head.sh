#!/usr/bin/env bash
set -euo pipefail

COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/ltx23-talking-head-run}"
WORKFLOW_PATH="${WORKFLOW_PATH:-$RUN_DIR/workflow_runtime.json}"
BOOTSTRAP_PATH="${BOOTSTRAP_PATH:-$RUN_DIR/bootstrap_ltx23_talking_head.sh}"
INPUT_IMAGE_NAME="${INPUT_IMAGE_NAME:-speaker.png}"
INPUT_AUDIO_NAME="${INPUT_AUDIO_NAME:-speech.wav}"
INPUT_REFERENCE_VIDEO_NAME="${INPUT_REFERENCE_VIDEO_NAME:-}"
COMFY_LOG_PATH="${COMFY_LOG_PATH:-$RUN_DIR/comfyui.log}"
COMFY_PID_PATH="${COMFY_PID_PATH:-$RUN_DIR/comfyui.pid}"

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run.log") 2>&1

stage_event() {
  local stage_name="$1"
  local stage_status="$2"
  echo "[stage] $(date -Iseconds) $stage_name $stage_status"
}

echo "[remote-ltx23] started at $(date -Iseconds)"
echo "[remote-ltx23] comfy app root: $COMFY_APP_ROOT"
echo "[remote-ltx23] comfy data root: $COMFY_ROOT"
echo "[remote-ltx23] run dir: $RUN_DIR"

if [ ! -f "$WORKFLOW_PATH" ]; then
  echo "[remote-ltx23] missing workflow: $WORKFLOW_PATH" >&2
  exit 1
fi

if [ ! -f "$BOOTSTRAP_PATH" ]; then
  echo "[remote-ltx23] missing bootstrap: $BOOTSTRAP_PATH" >&2
  exit 1
fi

if [ ! -f "$COMFY_ROOT/input/$INPUT_IMAGE_NAME" ]; then
  echo "[remote-ltx23] missing input image: $COMFY_ROOT/input/$INPUT_IMAGE_NAME" >&2
  exit 1
fi

if [ ! -f "$COMFY_ROOT/input/$INPUT_AUDIO_NAME" ]; then
  echo "[remote-ltx23] missing input audio: $COMFY_ROOT/input/$INPUT_AUDIO_NAME" >&2
  exit 1
fi

if [ -n "$INPUT_REFERENCE_VIDEO_NAME" ] && [ ! -f "$COMFY_ROOT/input/$INPUT_REFERENCE_VIDEO_NAME" ]; then
  echo "[remote-ltx23] missing input reference video: $COMFY_ROOT/input/$INPUT_REFERENCE_VIDEO_NAME" >&2
  exit 1
fi

echo "[remote-ltx23] bootstrapping"
stage_event "remote.bootstrap" "start"
bash "$BOOTSTRAP_PATH"
stage_event "remote.bootstrap" "end"

echo "[remote-ltx23] restarting ComfyUI"
stage_event "remote.restart_comfy" "start"
if [ "$COMFY_APP_ROOT" != "$COMFY_ROOT" ]; then
  mkdir -p "$COMFY_ROOT/input" "$COMFY_ROOT/output" "$COMFY_ROOT/custom_nodes" "$COMFY_ROOT/models"
  for entry in input output models custom_nodes; do
    rm -rf "$COMFY_APP_ROOT/$entry"
    ln -s "$COMFY_ROOT/$entry" "$COMFY_APP_ROOT/$entry"
  done
fi

pkill -f 'python.*main.py' || true
cd "$COMFY_APP_ROOT"
rm -f "$COMFY_LOG_PATH" "$COMFY_PID_PATH"
(
  cd "$COMFY_APP_ROOT"
  PYTHONUNBUFFERED=1 python3 -u main.py --listen 0.0.0.0 --port 8188 2>&1 | tee -a "$COMFY_LOG_PATH"
) &
COMFY_PID="$!"
echo "$COMFY_PID" > "$COMFY_PID_PATH"
stage_event "remote.restart_comfy" "end"

echo "[remote-ltx23] waiting for ComfyUI API"
stage_event "remote.wait_api" "start"
for _ in $(seq 1 240); do
  if curl -sf http://127.0.0.1:8188/object_info > "$RUN_DIR/object_info.json"; then
    break
  fi
  if ! kill -0 "$COMFY_PID" >/dev/null 2>&1; then
    echo "[remote-ltx23] ComfyUI process exited before API became ready" >&2
    if [ -f "$COMFY_LOG_PATH" ]; then
      echo "[remote-ltx23] --- comfyui.log tail ---" >&2
      tail -n 200 "$COMFY_LOG_PATH" >&2 || true
    fi
    exit 1
  fi
  sleep 5
done
stage_event "remote.wait_api" "end"

if ! test -s "$RUN_DIR/object_info.json"; then
  echo "[remote-ltx23] ComfyUI API did not become ready in time" >&2
  if [ -f "$COMFY_LOG_PATH" ]; then
    echo "[remote-ltx23] --- comfyui.log tail ---" >&2
    tail -n 200 "$COMFY_LOG_PATH" >&2 || true
  fi
  exit 1
fi

echo "[remote-ltx23] validating required node classes"
stage_event "remote.validate_nodes" "start"
python3 - "$RUN_DIR/object_info.json" "$WORKFLOW_PATH" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
workflow = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
required = sorted({node.get("class_type") for node in workflow.values() if node.get("class_type")})
missing = [name for name in required if name not in payload]
if missing:
    print("[remote-ltx23] missing required nodes: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(2)
print("[remote-ltx23] required nodes ok: " + ", ".join(required))
PY
stage_event "remote.validate_nodes" "end"

echo "[remote-ltx23] submitting workflow"
stage_event "remote.submit_workflow" "start"
python3 - "$WORKFLOW_PATH" "$RUN_DIR/prompt_submit.json" <<'PY'
import json
import sys
import urllib.error
import urllib.request

workflow_path = sys.argv[1]
output_path = sys.argv[2]

with open(workflow_path, "r", encoding="utf-8") as handle:
    prompt = json.load(handle)

payload = json.dumps({"prompt": prompt}).encode("utf-8")
request = urllib.request.Request(
    "http://127.0.0.1:8188/prompt",
    data=payload,
    headers={"Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(request, timeout=120) as response:
        raw = response.read().decode("utf-8")
except urllib.error.HTTPError as exc:
    raw = exc.read().decode("utf-8", errors="replace")
    with open(output_path, "w", encoding="utf-8") as handle:
        handle.write(raw)
    print(raw)
    raise

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(raw)

print(raw)
PY

PROMPT_ID="$(python3 - "$RUN_DIR/prompt_submit.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload.get("prompt_id", ""))
PY
)"

if [ -z "$PROMPT_ID" ]; then
  echo "[remote-ltx23] missing prompt_id in submit response" >&2
  exit 1
fi

echo "[remote-ltx23] submitted at $(date -Iseconds) prompt_id=$PROMPT_ID"
echo "$PROMPT_ID" > "$RUN_DIR/prompt_id.txt"
stage_event "remote.submit_workflow" "end"

echo "[remote-ltx23] waiting for history"
stage_event "remote.wait_history" "start"
python3 - "$PROMPT_ID" "$RUN_DIR/history.json" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

prompt_id = sys.argv[1]
history_path = Path(sys.argv[2])
deadline = time.time() + 4 * 60 * 60
url = f"http://127.0.0.1:8188/history/{prompt_id}"

while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except Exception:
        payload = {}

    if prompt_id in payload:
        history_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print("history-ready")
        raise SystemExit(0)

    time.sleep(10)

print("history-timeout", file=sys.stderr)
raise SystemExit(124)
PY
stage_event "remote.wait_history" "end"

echo "[remote-ltx23] finished at $(date -Iseconds)"
