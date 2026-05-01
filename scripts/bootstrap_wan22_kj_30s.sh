#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/wan22-kj-30s-run}"
MODELS_DIR="$COMFY_ROOT/models"
CUSTOM_NODES_DIR="$COMFY_ROOT/custom_nodes"
WARM_START="${WARM_START:-0}"
KJ_ENV_IMAGE="${KJ_ENV_IMAGE:-0}"
KJ_CUSTOM_NODE_SEED_DIR="${KJ_CUSTOM_NODE_SEED_DIR:-/opt/codex/kj-custom_nodes}"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu124}"
FORCE_TORCH_REINSTALL="${FORCE_TORCH_REINSTALL:-0}"
PIP_TIMEOUT="${PIP_TIMEOUT:-1800}"
PIP_RETRIES="${PIP_RETRIES:-20}"

mkdir -p "$CUSTOM_NODES_DIR" "$MODELS_DIR" "$RUN_DIR"

stage_event() {
  local stage_name="$1"
  local stage_status="$2"
  echo "[stage] $(date -Iseconds) $stage_name $stage_status"
}

pip_install() {
  python3 -m pip install --timeout "$PIP_TIMEOUT" --retries "$PIP_RETRIES" "$@"
}

python_has_module() {
  local module_name="$1"
  python3 - "$module_name" <<'PY' >/dev/null 2>&1
import importlib.util
import sys
raise SystemExit(0 if importlib.util.find_spec(sys.argv[1]) else 1)
PY
}

ensure_python_package() {
  local package_spec="$1"
  local module_name="$2"
  if python_has_module "$module_name"; then
    echo "[bootstrap] python module exists: $module_name"
    return 0
  fi
  echo "[bootstrap] installing package: $package_spec"
  pip_install --upgrade-strategy only-if-needed "$package_spec"
}

ensure_python_package_no_deps() {
  local package_spec="$1"
  local module_name="$2"
  if python_has_module "$module_name"; then
    echo "[bootstrap] python module exists: $module_name"
    return 0
  fi
  echo "[bootstrap] installing package without deps: $package_spec"
  pip_install --upgrade-strategy only-if-needed --no-deps "$package_spec"
}

torch_stack_matches_expected() {
  python3 <<'PY' >/dev/null 2>&1
import importlib
for name in ("torch", "torchvision", "torchaudio"):
    importlib.import_module(name)
import torch
cuda_version = getattr(torch.version, "cuda", None) or ""
parts = cuda_version.split(".")
try:
    major = int(parts[0])
    minor = int(parts[1]) if len(parts) > 1 else 0
except Exception:
    raise SystemExit(1)
if major < 12 or (major == 12 and minor < 4):
    raise SystemExit(1)
if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
    raise SystemExit(1)
_ = torch.cuda.get_device_name(0)
raise SystemExit(0)
PY
}

describe_existing_torch_stack() {
  python3 <<'PY' 2>/dev/null || true
import importlib
for name in ("torch", "torchvision", "torchaudio"):
    importlib.import_module(name)
import torch
print(
    f"[bootstrap] reusing existing torch stack: "
    f"torch={torch.__version__} "
    f"cuda={getattr(torch.version, 'cuda', '')} "
    f"device={torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu'}"
)
PY
}

ensure_torch_stack() {
  if [ "$FORCE_TORCH_REINSTALL" = "1" ]; then
    echo "[bootstrap] FORCE_TORCH_REINSTALL=1, reinstalling torch stack"
  elif torch_stack_matches_expected; then
    describe_existing_torch_stack
    echo "[bootstrap] existing torch stack is compatible with this workflow runtime"
    return 0
  fi

  echo "[bootstrap] reinstalling torch stack from $PYTORCH_INDEX_URL"
  pip_install --upgrade --force-reinstall --index-url "$PYTORCH_INDEX_URL" torch torchvision torchaudio
}

install_filtered_requirements_if_present() {
  local plugin_dir="$1"
  local requirements_path="$plugin_dir/requirements.txt"
  if [ ! -f "$requirements_path" ]; then
    return 0
  fi

  local filtered_path="$RUN_DIR/$(basename "$plugin_dir")-requirements.filtered.txt"
  python3 - "$requirements_path" "$filtered_path" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
skip_prefixes = (
    "torch", "torchvision", "torchaudio",
    "xformers", "flash-attn", "flash_attn",
    "bitsandbytes", "cupy",
    "nvidia-", "nvidia_", "cuda-", "cuda_",
)

lines = []
for raw in src.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or line.startswith("--"):
        continue
    match = re.match(r"[A-Za-z0-9_.-]+", line)
    normalized = (match.group(0) if match else line).lower()
    if normalized.startswith(skip_prefixes):
        print(f"[bootstrap] skip heavy requirement: {line}")
        continue
    lines.append(line)

dest.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print(f"[bootstrap] wrote filtered requirements: {dest}")
PY

  if [ ! -s "$filtered_path" ]; then
    echo "[bootstrap] no lightweight requirements left for $(basename "$plugin_dir")"
    return 0
  fi

  echo "[bootstrap] installing filtered requirements for $(basename "$plugin_dir")"
  pip_install --upgrade-strategy only-if-needed -r "$filtered_path"
}

install_filtered_requirements_file() {
  local requirements_path="$1"
  local label="$2"
  if [ ! -f "$requirements_path" ]; then
    return 0
  fi

  local filtered_path="$RUN_DIR/$label.filtered.txt"
  python3 - "$requirements_path" "$filtered_path" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dest = Path(sys.argv[2])
skip_prefixes = (
    "torch", "torchvision", "torchaudio",
    "xformers", "flash-attn", "flash_attn",
    "bitsandbytes", "cupy",
    "nvidia-", "nvidia_", "cuda-", "cuda_",
)

lines = []
for raw in src.read_text(encoding="utf-8", errors="ignore").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or line.startswith("--"):
        continue
    match = re.match(r"[A-Za-z0-9_.-]+", line)
    normalized = (match.group(0) if match else line).lower()
    if normalized.startswith(skip_prefixes):
        print(f"[bootstrap] skip heavy requirement: {line}")
        continue
    lines.append(line)

dest.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print(f"[bootstrap] wrote filtered requirements: {dest}")
PY

  if [ ! -s "$filtered_path" ]; then
    echo "[bootstrap] no lightweight requirements left for $label"
    return 0
  fi

  echo "[bootstrap] installing filtered requirements for $label"
  pip_install --upgrade-strategy only-if-needed -r "$filtered_path"
}

sync_git_plugin() {
  local repo_url="$1"
  local target_dir="$2"
  if [ ! -d "$target_dir/.git" ]; then
    git clone --depth 1 "$repo_url" "$target_dir"
  else
    git -C "$target_dir" pull --ff-only
  fi
  git -C "$target_dir" submodule update --init --recursive || true
}

required_custom_nodes_ready() {
  local required_nodes=(
    "ComfyUI-WanVideoWrapper"
    "ComfyUI-WanAnimatePreprocess"
    "ComfyUI-VideoHelperSuite"
    "ComfyUI-KJNodes"
    "ComfyUI_LayerStyle"
  )
  for node_name in "${required_nodes[@]}"; do
    if [ ! -d "$CUSTOM_NODES_DIR/$node_name" ]; then
      return 1
    fi
  done
  return 0
}

seed_preinstalled_custom_nodes() {
  if [ "$KJ_ENV_IMAGE" != "1" ]; then
    return 1
  fi
  if required_custom_nodes_ready; then
    return 0
  fi
  if [ ! -d "$KJ_CUSTOM_NODE_SEED_DIR" ]; then
    echo "[bootstrap] KJ_ENV_IMAGE=1 but seed dir missing: $KJ_CUSTOM_NODE_SEED_DIR"
    return 1
  fi

  echo "[bootstrap] seeding KJ custom nodes from image: $KJ_CUSTOM_NODE_SEED_DIR"
  mkdir -p "$CUSTOM_NODES_DIR"
  for plugin_dir in "$KJ_CUSTOM_NODE_SEED_DIR"/*; do
    if [ -d "$plugin_dir" ]; then
      rm -rf "$CUSTOM_NODES_DIR/$(basename "$plugin_dir")"
      cp -a "$plugin_dir" "$CUSTOM_NODES_DIR/"
    fi
  done
  required_custom_nodes_ready
}

install_custom_node_requirements() {
  for plugin_dir in \
    "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" \
    "$CUSTOM_NODES_DIR/ComfyUI-WanAnimatePreprocess" \
    "$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite" \
    "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" \
    "$CUSTOM_NODES_DIR/ComfyUI_LayerStyle"; do
    install_filtered_requirements_if_present "$plugin_dir"
  done
}

download_if_missing() {
  local url="$1"
  local target="$2"
  local stage_name="download.$(basename "$target")"
  if [ -f "$target" ]; then
    echo "[bootstrap] exists: $target"
    stage_event "$stage_name" "skip"
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  echo "[bootstrap] downloading: $(basename "$target")"
  stage_event "$stage_name" "start"
  curl --http1.1 -L --fail --retry 10 --retry-delay 8 --retry-all-errors \
    --connect-timeout 30 --max-time 7200 -o "$target" "$url"
  stage_event "$stage_name" "end"
}

inspect_warmstart_state() {
  python3 "$RUN_DIR/inspect_wan22_kj_30s_warmstart.py" \
    --custom-nodes-dir "$CUSTOM_NODES_DIR" \
    --models-dir "$MODELS_DIR"
}

echo "[bootstrap] preparing KJ custom nodes"
stage_event "bootstrap.custom_nodes" "start"
warm_state='{"custom_nodes_ready":false,"models_ready":false,"missing_custom_nodes":[],"missing_models":[]}'
custom_nodes_resolved=0
if seed_preinstalled_custom_nodes; then
  echo "[bootstrap] preinstalled KJ custom nodes are ready"
  custom_nodes_resolved=1
fi

if [ "$custom_nodes_resolved" != "1" ] && [ "$WARM_START" = "1" ] && [ -f "$RUN_DIR/inspect_wan22_kj_30s_warmstart.py" ]; then
  warm_state="$(inspect_warmstart_state)"
  if python3 - "$warm_state" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1])["custom_nodes_ready"] else 1)
PY
  then
    echo "[bootstrap] warm-start hit: custom_nodes"
    custom_nodes_resolved=1
  else
    echo "[bootstrap] warm-start miss: custom_nodes"
    python3 - "$warm_state" <<'PY'
import json, sys
state = json.loads(sys.argv[1])
print("[bootstrap] missing custom nodes: " + ", ".join(state["missing_custom_nodes"]))
PY
  fi
fi

if [ "$custom_nodes_resolved" != "1" ] && { [ "$WARM_START" != "1" ] || ! python3 - "$warm_state" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1])["custom_nodes_ready"] else 1)
PY
}; then
  find "$CUSTOM_NODES_DIR" -mindepth 1 -maxdepth 1 ! -name 'ComfyUI-Manager' -exec rm -rf {} +
  sync_git_plugin "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"
  sync_git_plugin "https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git" "$CUSTOM_NODES_DIR/ComfyUI-WanAnimatePreprocess"
  sync_git_plugin "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite"
  sync_git_plugin "https://github.com/kijai/ComfyUI-KJNodes.git" "$CUSTOM_NODES_DIR/ComfyUI-KJNodes"
  sync_git_plugin "https://github.com/chflame163/ComfyUI_LayerStyle.git" "$CUSTOM_NODES_DIR/ComfyUI_LayerStyle"
fi
stage_event "bootstrap.custom_nodes" "end"

echo "[bootstrap] installing Python dependencies"
stage_event "bootstrap.python_dependencies" "start"
ensure_torch_stack
install_filtered_requirements_file "$COMFY_APP_ROOT/requirements.txt" "comfyui-core-requirements"
install_custom_node_requirements
ensure_python_package "accelerate" "accelerate"
ensure_python_package "albumentations" "albumentations"
ensure_python_package "av>=14.2.0" "av"
ensure_python_package "blake3" "blake3"
ensure_python_package "color-matcher" "color_matcher"
ensure_python_package "diffusers" "diffusers"
ensure_python_package "einops" "einops"
ensure_python_package "ftfy" "ftfy"
ensure_python_package "gguf>=0.17.1" "gguf"
ensure_python_package "huggingface_hub" "huggingface_hub"
ensure_python_package "imageio-ffmpeg" "imageio_ffmpeg"
ensure_python_package "matplotlib" "matplotlib"
ensure_python_package "numpy" "numpy"
ensure_python_package "onnx" "onnx"
ensure_python_package "onnxruntime-gpu" "onnxruntime"
ensure_python_package "opencv-python" "cv2"
ensure_python_package "peft" "peft"
ensure_python_package "pillow>=10.3.0" "PIL"
ensure_python_package "protobuf" "google.protobuf"
ensure_python_package "pyloudnorm" "pyloudnorm"
ensure_python_package "requests" "requests"
ensure_python_package "safetensors" "safetensors"
ensure_python_package "scikit-image" "skimage"
ensure_python_package "scipy" "scipy"
ensure_python_package "sentencepiece>=0.2.0" "sentencepiece"
ensure_python_package "simpleeval>=1.0.0" "simpleeval"
ensure_python_package "timm" "timm"
ensure_python_package "torchsde" "torchsde"
ensure_python_package "transformers>=4.50.3" "transformers"
ensure_python_package_no_deps "kornia_rs>=0.1.10" "kornia_rs"
ensure_python_package_no_deps "kornia" "kornia"
ensure_python_package_no_deps "comfy-kitchen>=0.2.8" "comfy_kitchen"
ensure_python_package_no_deps "comfy-aimdo>=0.2.12" "comfy_aimdo"
stage_event "bootstrap.python_dependencies" "end"

echo "[bootstrap] preparing KJ model directories"
stage_event "bootstrap.model_downloads" "start"
mkdir -p \
  "$MODELS_DIR/diffusion_models/Wan22Animate" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/clip_vision" \
  "$MODELS_DIR/detection" \
  "$MODELS_DIR/loras"

if [ "$WARM_START" = "1" ] && [ -f "$RUN_DIR/inspect_wan22_kj_30s_warmstart.py" ]; then
  warm_state="$(inspect_warmstart_state)"
  if python3 - "$warm_state" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1])["models_ready"] else 1)
PY
  then
    echo "[bootstrap] warm-start hit: models"
    stage_event "bootstrap.model_downloads" "skip"
  else
    echo "[bootstrap] warm-start miss: models"
    python3 - "$warm_state" <<'PY'
import json, sys
state = json.loads(sys.argv[1])
print("[bootstrap] missing models: " + ", ".join(state["missing_models"]))
PY
  fi
fi

if [ "$WARM_START" != "1" ] || ! python3 - "$warm_state" <<'PY'
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1])["models_ready"] else 1)
PY
then
  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors" \
    "$MODELS_DIR/diffusion_models/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors"

  download_if_missing \
    "https://huggingface.co/realung/umt5-xxl-enc-fp8_e4m3fn.safetensors/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors" \
    "$MODELS_DIR/text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors"

  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/wan_2.1_vae.safetensors" \
    "$MODELS_DIR/vae/wan_2.1_vae.safetensors"

  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/clip_vision_h.safetensors" \
    "$MODELS_DIR/clip_vision/clip_vision_h.safetensors"

  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/vitpose-l-wholebody.onnx" \
    "$MODELS_DIR/detection/vitpose-l-wholebody.onnx"

  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/yolov10m.onnx" \
    "$MODELS_DIR/detection/yolov10m.onnx"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/lightx2v_elite_it2v_animate_face.safetensors" \
    "$MODELS_DIR/loras/lightx2v_elite_it2v_animate_face.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/WAN22_MoCap_fullbodyCOPY_ED.safetensors" \
    "$MODELS_DIR/loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors" \
    "$MODELS_DIR/loras/FullDynamic_Ultimate_Fusion_Elite.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors" \
    "$MODELS_DIR/loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors"

  download_if_missing \
    "https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors" \
    "$MODELS_DIR/loras/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors"
fi
stage_event "bootstrap.model_downloads" "end"

mkdir -p "$COMFY_ROOT/input" "$COMFY_ROOT/output" "$COMFY_ROOT/temp"
echo "[bootstrap] done"
