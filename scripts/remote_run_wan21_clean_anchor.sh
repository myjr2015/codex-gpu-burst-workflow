#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/workspace/codex-gpu-burst-workflow}"
COMFY_ROOT="${COMFY_ROOT:-/opt/workspace-internal/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/wan21-clean-anchor-run}"
WORKFLOW_PATH="${WORKFLOW_PATH:-$REPO_ROOT/output/vast-clean-anchor-multitalk-24g/workflow_api_24g_pruned.json}"
BOOTSTRAP_PATH="${BOOTSTRAP_PATH:-$REPO_ROOT/output/vast-clean-anchor-multitalk-24g/bootstrap_wan21_clean_anchor.sh}"
INPUT_IMAGE_URL="${INPUT_IMAGE_URL:?INPUT_IMAGE_URL is required}"
INPUT_AUDIO_URL="${INPUT_AUDIO_URL:?INPUT_AUDIO_URL is required}"

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run.log") 2>&1

echo "[remote-run] started at $(date -Iseconds)"
echo "[remote-run] repo root: $REPO_ROOT"
echo "[remote-run] comfy root: $COMFY_ROOT"
echo "[remote-run] run dir: $RUN_DIR"

export COMFY_ROOT

mkdir -p "$COMFY_ROOT/input"

echo "[remote-run] bootstrapping comfy environment"
bash "$BOOTSTRAP_PATH"

echo "[remote-run] downloading input assets"
curl -L --fail "$INPUT_IMAGE_URL" -o "$COMFY_ROOT/input/clean-anchor-image.png"
curl -L --fail "$INPUT_AUDIO_URL" -o "$COMFY_ROOT/input/clean-anchor-audio.wav"

echo "[remote-run] restarting ComfyUI"
pkill -f 'python.*main.py' || true
cd "$COMFY_ROOT"
nohup python3 main.py --listen 0.0.0.0 --port 8188 > "$RUN_DIR/comfyui.log" 2>&1 &

echo "[remote-run] waiting for ComfyUI API"
for _ in $(seq 1 180); do
  if curl -sf http://127.0.0.1:8188/system_stats > "$RUN_DIR/system_stats.json"; then
    break
  fi
  sleep 10
done

if ! test -s "$RUN_DIR/system_stats.json"; then
  echo "[remote-run] ComfyUI API did not become ready in time" >&2
  exit 1
fi

echo "[remote-run] submitting workflow"
python3 - "$WORKFLOW_PATH" "$RUN_DIR/prompt_submit.json" <<'PY'
import json
import sys
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

with urllib.request.urlopen(request, timeout=120) as response:
    raw = response.read().decode("utf-8")

with open(output_path, "w", encoding="utf-8") as handle:
    handle.write(raw)

print(raw)
PY

echo "[remote-run] submitted workflow at $(date -Iseconds)"
