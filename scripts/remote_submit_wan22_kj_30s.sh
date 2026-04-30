#!/usr/bin/env bash
set -euo pipefail

COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/wan22-kj-30s-run}"
MODELS_DIR="${MODELS_DIR:-$COMFY_ROOT/models}"
WORKFLOW_PATH="${WORKFLOW_PATH:-$RUN_DIR/workflow_runtime.json}"
BOOTSTRAP_PATH="${BOOTSTRAP_PATH:-$RUN_DIR/bootstrap_wan22_kj_30s.sh}"
INPUT_IMAGE_NAME="${INPUT_IMAGE_NAME:-ip_image.png}"
INPUT_VIDEO_NAME="${INPUT_VIDEO_NAME:-reference_30s.mp4}"
COMFY_LOG_PATH="${COMFY_LOG_PATH:-$RUN_DIR/comfyui.log}"
COMFY_PID_PATH="${COMFY_PID_PATH:-$RUN_DIR/comfyui.pid}"
HF_SPEEDTEST="${HF_SPEEDTEST:-0}"
HF_MIN_MIB_PER_SEC="${HF_MIN_MIB_PER_SEC:-15}"
HF_MAX_ESTIMATED_DOWNLOAD_MINUTES="${HF_MAX_ESTIMATED_DOWNLOAD_MINUTES:-30}"
HF_SPEEDTEST_SAMPLE_MIB="${HF_SPEEDTEST_SAMPLE_MIB:-256}"
HF_SPEEDTEST_MAX_SECONDS="${HF_SPEEDTEST_MAX_SECONDS:-120}"
HF_SPEEDTEST_ONLY="${HF_SPEEDTEST_ONLY:-0}"

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run.log") 2>&1

stage_event() {
  local stage_name="$1"
  local stage_status="$2"
  echo "[stage] $(date -Iseconds) $stage_name $stage_status"
}

run_hf_speedtest_preflight() {
  if [ "$HF_SPEEDTEST" != "1" ]; then
    echo "[hf-speedtest] disabled"
    return 0
  fi

  stage_event "remote.hf_speedtest" "start"

  local model_manifest=(
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors|diffusion_models/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors|17317143060"
    "https://huggingface.co/realung/umt5-xxl-enc-fp8_e4m3fn.safetensors/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors|text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors|6731333792"
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/wan_2.1_vae.safetensors|vae/wan_2.1_vae.safetensors|253815318"
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/clip_vision_h.safetensors|clip_vision/clip_vision_h.safetensors|1264219396"
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/vitpose-l-wholebody.onnx|detection/vitpose-l-wholebody.onnx|1234579166"
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/yolov10m.onnx|detection/yolov10m.onnx|61659339"
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/lightx2v_elite_it2v_animate_face.safetensors|loras/lightx2v_elite_it2v_animate_face.safetensors|3257907064"
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/WAN22_MoCap_fullbodyCOPY_ED.safetensors|loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors|2129598528"
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors|loras/FullDynamic_Ultimate_Fusion_Elite.safetensors|987745068"
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors|loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors|858457612"
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors|loras/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors|858457436"
  )

  local total_bytes=0
  local remaining_bytes=0
  local cached_count=0
  local missing_count=0
  local test_url=""
  local item=""
  for item in "${model_manifest[@]}"; do
    local url=""
    local relative_path=""
    local size_bytes=""
    IFS='|' read -r url relative_path size_bytes <<< "$item"
    if [ -z "$test_url" ]; then
      test_url="$url"
    fi
    total_bytes=$((total_bytes + size_bytes))

    local target="$MODELS_DIR/$relative_path"
    if [ -f "$target" ]; then
      local current_size=0
      current_size="$(stat -c%s "$target" 2>/dev/null || echo 0)"
      if [ "$current_size" -ge $((size_bytes * 95 / 100)) ]; then
        cached_count=$((cached_count + 1))
      else
        local missing_bytes=$((size_bytes - current_size))
        if [ "$missing_bytes" -gt 0 ]; then
          remaining_bytes=$((remaining_bytes + missing_bytes))
        fi
        missing_count=$((missing_count + 1))
      fi
    else
      remaining_bytes=$((remaining_bytes + size_bytes))
      missing_count=$((missing_count + 1))
    fi
  done

  if [ "$remaining_bytes" -le 0 ]; then
    python3 - "$RUN_DIR/hf_speedtest.json" "$total_bytes" "$remaining_bytes" "$cached_count" "$missing_count" <<'PY'
import json
import sys
from datetime import datetime, timezone

output, total, remaining, cached, missing = sys.argv[1:6]
payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "enabled": True,
    "decision": "pass",
    "reason": "all configured model files already exist",
    "total_model_bytes": int(total),
    "remaining_model_bytes": int(remaining),
    "cached_model_count": int(cached),
    "missing_model_count": int(missing),
    "speed_mib_per_sec": None,
    "estimated_download_minutes": 0.0,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY
    echo "[hf-speedtest] pass: all configured model files already exist"
    stage_event "remote.hf_speedtest" "end"
    return 0
  fi

  local sample_mib="$HF_SPEEDTEST_SAMPLE_MIB"
  if ! [[ "$sample_mib" =~ ^[0-9]+$ ]] || [ "$sample_mib" -le 0 ]; then
    sample_mib=256
  fi
  local max_seconds="$HF_SPEEDTEST_MAX_SECONDS"
  if ! [[ "$max_seconds" =~ ^[0-9]+$ ]] || [ "$max_seconds" -le 0 ]; then
    max_seconds=120
  fi
  local sample_bytes=$((sample_mib * 1024 * 1024))
  local range_end=$((sample_bytes - 1))
  local metrics_path="$RUN_DIR/hf_speedtest.curl_metrics.txt"

  echo "[hf-speedtest] total_model_bytes=$total_bytes remaining_model_bytes=$remaining_bytes cached=$cached_count missing=$missing_count"
  echo "[hf-speedtest] sample_url=$test_url sample_mib=$sample_mib max_seconds=$max_seconds"

  local curl_code=0
  set +e
  curl --http1.1 -L --fail --silent --show-error \
    --retry 2 --retry-delay 2 --retry-all-errors \
    --connect-timeout 30 --max-time "$max_seconds" \
    -r "0-$range_end" \
    -o /dev/null \
    -w "speed_download=%{speed_download}\ntime_total=%{time_total}\nsize_download=%{size_download}\nhttp_code=%{http_code}\n" \
    "$test_url" > "$metrics_path"
  curl_code=$?
  set -e

  local speed_bps=""
  local time_total=""
  local size_download=""
  local http_code=""
  speed_bps="$(awk -F= '$1=="speed_download"{print $2}' "$metrics_path" | tail -n 1)"
  time_total="$(awk -F= '$1=="time_total"{print $2}' "$metrics_path" | tail -n 1)"
  size_download="$(awk -F= '$1=="size_download"{print $2}' "$metrics_path" | tail -n 1)"
  http_code="$(awk -F= '$1=="http_code"{print $2}' "$metrics_path" | tail -n 1)"

  local decision_code=0
  set +e
  python3 - "$RUN_DIR/hf_speedtest.json" \
    "$total_bytes" "$remaining_bytes" "$cached_count" "$missing_count" \
    "$speed_bps" "$time_total" "$size_download" "$http_code" "$curl_code" \
    "$HF_MIN_MIB_PER_SEC" "$HF_MAX_ESTIMATED_DOWNLOAD_MINUTES" \
    "$sample_bytes" "$test_url" <<'PY'
import json
import math
import sys
from datetime import datetime, timezone

(
    output,
    total,
    remaining,
    cached,
    missing,
    speed_bps,
    time_total,
    size_download,
    http_code,
    curl_code,
    min_mibps,
    max_minutes,
    sample_bytes,
    sample_url,
) = sys.argv[1:15]

def as_float(value, default=0.0):
    try:
        number = float(str(value).strip())
        return number if math.isfinite(number) else default
    except Exception:
        return default

def as_int(value, default=0):
    try:
        return int(float(str(value).strip()))
    except Exception:
        return default

total = as_int(total)
remaining = as_int(remaining)
cached = as_int(cached)
missing = as_int(missing)
speed_bps_value = as_float(speed_bps)
time_total_value = as_float(time_total)
size_download_value = as_int(size_download)
http_code_value = str(http_code or "").strip()
curl_code_value = as_int(curl_code)
min_mibps_value = as_float(min_mibps)
max_minutes_value = as_float(max_minutes)
sample_bytes_value = as_int(sample_bytes)

mibps = speed_bps_value / 1024 / 1024 if speed_bps_value > 0 else 0.0
estimated_seconds = remaining / speed_bps_value if speed_bps_value > 0 else None
estimated_minutes = estimated_seconds / 60 if estimated_seconds is not None else None
downloaded_enough = size_download_value >= min(10 * 1024 * 1024, max(1, sample_bytes_value // 10))

reasons = []
decision = "pass"
if speed_bps_value <= 0 or not downloaded_enough:
    decision = "reject"
    reasons.append("speed sample did not download enough data")
if curl_code_value not in (0, 28) and not downloaded_enough:
    decision = "reject"
    reasons.append(f"curl failed with exit code {curl_code_value}")
if min_mibps_value > 0 and mibps < min_mibps_value:
    decision = "reject"
    reasons.append(f"speed {mibps:.2f} MiB/s below minimum {min_mibps_value:.2f} MiB/s")
if max_minutes_value > 0 and estimated_minutes is not None and estimated_minutes > max_minutes_value:
    decision = "reject"
    reasons.append(f"estimated model download {estimated_minutes:.1f} min above maximum {max_minutes_value:.1f} min")

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "enabled": True,
    "decision": decision,
    "reason": "; ".join(reasons) if reasons else "speed and estimated model download time are acceptable",
    "total_model_bytes": total,
    "total_model_gib": round(total / 1024 ** 3, 3),
    "remaining_model_bytes": remaining,
    "remaining_model_gib": round(remaining / 1024 ** 3, 3),
    "cached_model_count": cached,
    "missing_model_count": missing,
    "sample_url": sample_url,
    "sample_requested_bytes": sample_bytes_value,
    "sample_downloaded_bytes": size_download_value,
    "sample_time_seconds": time_total_value,
    "curl_exit_code": curl_code_value,
    "http_code": http_code_value,
    "speed_bytes_per_sec": speed_bps_value,
    "speed_mib_per_sec": round(mibps, 3),
    "estimated_download_seconds": round(estimated_seconds, 3) if estimated_seconds is not None else None,
    "estimated_download_minutes": round(estimated_minutes, 3) if estimated_minutes is not None else None,
    "min_mib_per_sec": min_mibps_value,
    "max_estimated_download_minutes": max_minutes_value,
}

with open(output, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, ensure_ascii=False, indent=2)
    handle.write("\n")

estimate_text = "unknown" if estimated_minutes is None else f"{estimated_minutes:.1f} min"
print(
    "[hf-speedtest] "
    f"decision={decision} speed={mibps:.2f} MiB/s "
    f"estimated_model_download={estimate_text} "
    f"remaining={remaining / 1024 ** 3:.2f} GiB "
    f"threshold_min_speed={min_mibps_value:.2f} MiB/s "
    f"threshold_max_minutes={max_minutes_value:.1f}"
)
if reasons:
    print("[hf-speedtest] reason=" + "; ".join(reasons))

raise SystemExit(0 if decision == "pass" else 42)
PY
  decision_code=$?
  set -e

  stage_event "remote.hf_speedtest" "end"
  if [ "$decision_code" -ne 0 ]; then
    echo "[hf-speedtest] reject: stopping before bootstrap to avoid slow model download"
    exit "$decision_code"
  fi
}

echo "[remote-kj30s] started at $(date -Iseconds)"
echo "[remote-kj30s] comfy app root: $COMFY_APP_ROOT"
echo "[remote-kj30s] comfy data root: $COMFY_ROOT"
echo "[remote-kj30s] run dir: $RUN_DIR"

run_hf_speedtest_preflight

if [ "$HF_SPEEDTEST_ONLY" = "1" ]; then
  echo "[remote-kj30s] HF_SPEEDTEST_ONLY=1, stopping before bootstrap"
  exit 0
fi

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
