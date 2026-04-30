#!/usr/bin/env bash
set -euo pipefail

COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/wan22-kj-30s-run}"
WORKFLOW_PATH="${WORKFLOW_PATH:-$RUN_DIR/workflow_runtime.json}"
BOOTSTRAP_PATH="${BOOTSTRAP_PATH:-$RUN_DIR/bootstrap_wan22_kj_30s.sh}"
INPUT_IMAGE_NAME="${INPUT_IMAGE_NAME:-ip_image.png}"
INPUT_VIDEO_NAME="${INPUT_VIDEO_NAME:-reference_30s.mp4}"
COMFY_LOG_PATH="${COMFY_LOG_PATH:-$RUN_DIR/comfyui.log}"
COMFY_PID_PATH="${COMFY_PID_PATH:-$RUN_DIR/comfyui.pid}"

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run.log") 2>&1

stage_event() {
  local stage_name="$1"
  local stage_status="$2"
  echo "[stage] $(date -Iseconds) $stage_name $stage_status"
}

echo "[remote-kj30s] started at $(date -Iseconds)"
echo "[remote-kj30s] comfy app root: $COMFY_APP_ROOT"
echo "[remote-kj30s] comfy data root: $COMFY_ROOT"
echo "[remote-kj30s] run dir: $RUN_DIR"

for required in \
  "$WORKFLOW_PATH" \
  "$BOOTSTRAP_PATH" \
  "$COMFY_ROOT/input/$INPUT_IMAGE_NAME" \
  "$COMFY_ROOT/input/$INPUT_VIDEO_NAME"; do
  if [ ! -f "$required" ]; then
    echo "[remote-kj30s] missing required file: $required" >&2
    exit 1
  fi
done

echo "[remote-kj30s] bootstrapping"
stage_event "remote.bootstrap" "start"
bash "$BOOTSTRAP_PATH"
stage_event "remote.bootstrap" "end"

echo "[remote-kj30s] restarting ComfyUI"
stage_event "remote.restart_comfy" "start"
if [ "$COMFY_APP_ROOT" != "$COMFY_ROOT" ]; then
  mkdir -p "$COMFY_ROOT/input" "$COMFY_ROOT/output" "$COMFY_ROOT/temp" "$COMFY_ROOT/custom_nodes" "$COMFY_ROOT/models"
  for entry in input output temp models; do
    rm -rf "$COMFY_APP_ROOT/$entry"
    ln -s "$COMFY_ROOT/$entry" "$COMFY_APP_ROOT/$entry"
  done
  rm -rf "$COMFY_APP_ROOT/custom_nodes"
  ln -s "$COMFY_ROOT/custom_nodes" "$COMFY_APP_ROOT/custom_nodes"
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

echo "[remote-kj30s] waiting for ComfyUI API"
stage_event "remote.wait_api" "start"
for _ in $(seq 1 360); do
  if curl -sf http://127.0.0.1:8188/object_info > "$RUN_DIR/object_info.json"; then
    break
  fi
  if ! kill -0 "$COMFY_PID" >/dev/null 2>&1; then
    echo "[remote-kj30s] ComfyUI exited before API ready" >&2
    tail -n 240 "$COMFY_LOG_PATH" >&2 || true
    exit 1
  fi
  sleep 5
done
stage_event "remote.wait_api" "end"

if [ ! -s "$RUN_DIR/object_info.json" ]; then
  echo "[remote-kj30s] ComfyUI API did not become ready" >&2
  tail -n 240 "$COMFY_LOG_PATH" >&2 || true
  exit 1
fi

echo "[remote-kj30s] validating object_info"
stage_event "remote.validate_nodes" "start"
python3 - "$RUN_DIR/object_info.json" <<'PY'
import json
import sys
from pathlib import Path

info = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
required = [
    "WanVideoModelLoader",
    "WanVideoTextEncodeCached",
    "WanVideoSampler",
    "WanVideoAnimateEmbeds",
    "WanVideoDecode",
    "OnnxDetectionModelLoader",
    "PoseAndFaceDetection",
    "DrawViTPose",
    "LayerUtility: ImageScaleByAspectRatio V2",
    "LayerUtility: ImageMaskScaleAsV2",
    "VHS_LoadVideo",
    "VHS_VideoCombine",
    "ImageConcatMulti",
]
missing = [name for name in required if name not in info]
if missing:
    print("missing object_info nodes: " + ", ".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
stage_event "remote.validate_nodes" "end"

echo "[remote-kj30s] submitting workflow"
stage_event "remote.submit_workflow" "start"
python3 - "$WORKFLOW_PATH" "$RUN_DIR/prompt_submit.json" <<'PY'
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

workflow_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
prompt = json.loads(workflow_path.read_text(encoding="utf-8"))
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
    output_path.write_text(raw, encoding="utf-8")
    print(raw)
    raise
output_path.write_text(raw, encoding="utf-8")
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
  echo "[remote-kj30s] missing prompt_id in submit response" >&2
  exit 1
fi

echo "[remote-kj30s] submitted at $(date -Iseconds) prompt_id=$PROMPT_ID"
echo "$PROMPT_ID" > "$RUN_DIR/prompt_id.txt"
stage_event "remote.submit_workflow" "end"

echo "[remote-kj30s] waiting for history"
stage_event "remote.wait_history" "start"
python3 - "$PROMPT_ID" "$RUN_DIR/history.json" <<'PY'
import json
import sys
import time
import urllib.request
from pathlib import Path

prompt_id = sys.argv[1]
history_path = Path(sys.argv[2])
deadline = time.time() + 5 * 60 * 60
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

echo "[remote-kj30s] finished at $(date -Iseconds)"
