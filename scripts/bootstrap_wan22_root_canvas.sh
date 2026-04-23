#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/wan22-root-canvas-run}"
BUNDLE_DIR="${BUNDLE_DIR:-$RUN_DIR/node-bundles}"
CUSTOM_NODES_DIR="$COMFY_ROOT/custom_nodes"
MODELS_DIR="$COMFY_ROOT/models"
PREWARMED_IMAGE="${PREWARMED_IMAGE:-0}"
WARM_START="${WARM_START:-0}"
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
  python3 -m pip install \
    --timeout "$PIP_TIMEOUT" \
    --retries "$PIP_RETRIES" \
    "$@"
}

extract_zip() {
  local zip_path="$1"
  local dest_dir="$2"
  python3 - "$zip_path" "$dest_dir" <<'PY'
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
target_dir = Path(sys.argv[2])
target_dir.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(zip_path, "r") as zf:
    zf.extractall(target_dir)
print(f"extracted {zip_path.name} -> {target_dir}")
PY
}

python_has_module() {
  local module_name="$1"
  python3 - "$module_name" <<'PY' >/dev/null 2>&1
import importlib.util
import sys

module_name = sys.argv[1]
raise SystemExit(0 if importlib.util.find_spec(module_name) else 1)
PY
}

torch_stack_matches_expected() {
  python3 <<'PY' >/dev/null 2>&1
import importlib
import sys

required = ("torch", "torchvision", "torchaudio")
for name in required:
    try:
        importlib.import_module(name)
    except Exception:
        raise SystemExit(1)

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

if not torch.cuda.is_available():
    raise SystemExit(1)

try:
    if torch.cuda.device_count() < 1:
        raise SystemExit(1)
    _ = torch.cuda.get_device_name(0)
except Exception:
    raise SystemExit(1)

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

ensure_torch_stack() {
  if [ "$FORCE_TORCH_REINSTALL" = "1" ]; then
    echo "[bootstrap] FORCE_TORCH_REINSTALL=1, reinstalling torch stack"
  elif torch_stack_matches_expected; then
    describe_existing_torch_stack
    echo "[bootstrap] existing torch stack is compatible with this workflow runtime"
    return 0
  elif [ "$PREWARMED_IMAGE" = "1" ] && python_has_module "torch" && python_has_module "torchvision" && python_has_module "torchaudio"; then
    echo "[bootstrap] prewarmed image provides torch torchvision torchaudio"
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
    "torch",
    "torchvision",
    "torchaudio",
    "accelerate",
    "diffusers",
    "transformers",
    "peft",
    "clip-interrogator",
    "clip_interrogator",
    "open-clip-torch",
    "open_clip_torch",
    "spandrel",
    "timm",
    "triton",
    "xformers",
    "flash-attn",
    "flash_attn",
    "bitsandbytes",
    "cupy",
    "nvidia-",
    "nvidia_",
    "cuda-",
    "cuda_",
)

lines = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
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
    "torch",
    "torchvision",
    "torchaudio",
    "accelerate",
    "diffusers",
    "transformers",
    "peft",
    "clip-interrogator",
    "clip_interrogator",
    "open-clip-torch",
    "open_clip_torch",
    "spandrel",
    "timm",
    "triton",
    "xformers",
    "flash-attn",
    "flash_attn",
    "bitsandbytes",
    "cupy",
    "nvidia-",
    "nvidia_",
    "cuda-",
    "cuda_",
)

lines = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
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

extract_or_sync_plugin() {
  local zip_path="$1"
  local dest_dir="$2"
  local repo_url="${3:-}"

  rm -rf "$dest_dir"
  if [ -f "$zip_path" ]; then
    extract_zip "$zip_path" "$dest_dir"
    install_filtered_requirements_if_present "$dest_dir"
    return 0
  fi

  if [ -n "$repo_url" ]; then
    echo "[bootstrap] bundle missing, fallback git clone: $(basename "$dest_dir")"
    sync_git_plugin "$repo_url" "$dest_dir"
    install_filtered_requirements_if_present "$dest_dir"
    return 0
  fi

  echo "[bootstrap] missing bundle: $zip_path" >&2
  exit 1
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
  curl -L --fail --retry 5 --retry-delay 8 -o "$target" "$url"
  stage_event "$stage_name" "end"
}

inspect_warmstart_state() {
  python3 "$RUN_DIR/inspect_wan22_warmstart.py" \
    --custom-nodes-dir "$CUSTOM_NODES_DIR" \
    --models-dir "$MODELS_DIR"
}

echo "[bootstrap] preparing custom nodes"
stage_event "bootstrap.custom_nodes" "start"
if [ "$PREWARMED_IMAGE" != "1" ]; then
  mkdir -p "$BUNDLE_DIR"

  if [ "$WARM_START" = "1" ]; then
    warm_state="$(inspect_warmstart_state)"
    if python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
raise SystemExit(0 if state["custom_nodes_ready"] else 1)
PY
    then
      echo "[bootstrap] warm-start hit: custom_nodes"
      stage_event "bootstrap.custom_nodes" "skip"
    else
      echo "[bootstrap] warm-start miss: custom_nodes"
      python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
print("[bootstrap] missing custom nodes: " + ", ".join(state["missing_custom_nodes"]))
PY
      find "$CUSTOM_NODES_DIR" -mindepth 1 -maxdepth 1 \
        ! -name 'ComfyUI-Manager' \
        -exec rm -rf {} +
    fi
  else
    find "$CUSTOM_NODES_DIR" -mindepth 1 -maxdepth 1 \
      ! -name 'ComfyUI-Manager' \
      -exec rm -rf {} +
  fi

  if [ "$WARM_START" != "1" ] || ! python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
raise SystemExit(0 if state["custom_nodes_ready"] else 1)
PY
  then
    declare -a BUNDLES=(
      "ComfyUI-VideoHelperSuite.zip:ComfyUI-VideoHelperSuite"
      "ComfyUI-KJNodes.zip:ComfyUI-KJNodes"
      "ComfyUI-WanAnimatePreprocess.zip:ComfyUI-WanAnimatePreprocess"
    )

    for bundle in "${BUNDLES[@]}"; do
      zip_name="${bundle%%:*}"
      dir_name="${bundle##*:}"
      zip_path="$BUNDLE_DIR/$zip_name"
      dest_dir="$CUSTOM_NODES_DIR/$dir_name"
      extract_or_sync_plugin "$zip_path" "$dest_dir"
    done

    extract_or_sync_plugin \
      "$BUNDLE_DIR/ComfyUI-GGUF.zip" \
      "$CUSTOM_NODES_DIR/ComfyUI-GGUF" \
      "https://github.com/city96/ComfyUI-GGUF.git"
  fi
else
  echo "[bootstrap] prewarmed image mode: skip custom node extraction"
fi
stage_event "bootstrap.custom_nodes" "end"

echo "[bootstrap] installing python dependencies"
echo "[bootstrap] ensuring ComfyUI runtime essentials"
stage_event "bootstrap.python_dependencies" "start"
ensure_torch_stack
install_filtered_requirements_file "$COMFY_APP_ROOT/requirements.txt" "comfyui-core-requirements"
ensure_python_package "sqlalchemy>=2.0" "sqlalchemy"
ensure_python_package "alembic" "alembic"
ensure_python_package "blake3" "blake3"
ensure_python_package "filelock>=3.16.0" "filelock"
ensure_python_package "safetensors" "safetensors"
ensure_python_package "simpleeval>=1.0.0" "simpleeval"
ensure_python_package "av>=14.2.0" "av"
ensure_python_package "pydantic>=2.11.10" "pydantic"
ensure_python_package "pydantic-settings>=2.10.1" "pydantic_settings"
ensure_python_package "PyOpenGL" "OpenGL"
ensure_python_package "glfw" "glfw"
ensure_python_package_no_deps "kornia_rs>=0.1.10" "kornia_rs"
ensure_python_package_no_deps "kornia" "kornia"
ensure_python_package_no_deps "comfy-kitchen>=0.2.8" "comfy_kitchen"
ensure_python_package_no_deps "comfy-aimdo>=0.2.12" "comfy_aimdo"
echo "[bootstrap] ensuring core workflow runtime packages"
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
ensure_python_package "pillow>=10.3.0" "PIL"
ensure_python_package "protobuf" "google.protobuf"
ensure_python_package "pyloudnorm" "pyloudnorm"
ensure_python_package "requests" "requests"
ensure_python_package "transformers>=4.50.3" "transformers"
ensure_python_package "PyNaCl" "nacl"
ensure_python_package "lark" "lark"
ensure_python_package "scipy" "scipy"
ensure_python_package "sentencepiece>=0.2.0" "sentencepiece"
ensure_python_package "torchsde" "torchsde"
ensure_python_package "color-matcher" "color_matcher"
stage_event "bootstrap.python_dependencies" "end"

echo "[bootstrap] creating model directories"
stage_event "bootstrap.model_downloads" "start"
mkdir -p \
  "$MODELS_DIR/unet" \
  "$MODELS_DIR/loras" \
  "$MODELS_DIR/vae" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/clip_vision" \
  "$MODELS_DIR/detection"

if [ "$WARM_START" = "1" ]; then
  warm_state="$(inspect_warmstart_state)"
  if python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
raise SystemExit(0 if state["models_ready"] else 1)
PY
  then
    echo "[bootstrap] warm-start hit: models"
    stage_event "bootstrap.model_downloads" "skip"
  else
    echo "[bootstrap] warm-start miss: models"
    python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
print("[bootstrap] missing models: " + ", ".join(state["missing_models"]))
PY
  fi
fi

if [ "$WARM_START" != "1" ] || ! python3 - "$warm_state" <<'PY'
import json
import sys
state = json.loads(sys.argv[1])
raise SystemExit(0 if state["models_ready"] else 1)
PY
then
  download_if_missing \
    "https://huggingface.co/QuantStack/Wan2.2-Animate-14B-GGUF/resolve/main/Wan2.2-Animate-14B-Q4_K_S.gguf" \
    "$MODELS_DIR/unet/Wan2.2-Animate-14B-Q4_K_S.gguf"

  download_if_missing \
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" \
    "$MODELS_DIR/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

  download_if_missing \
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
    "$MODELS_DIR/vae/wan_2.1_vae.safetensors"

  download_if_missing \
    "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
    "$MODELS_DIR/clip_vision/clip_vision_h.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/lightx2v_it2v_adaptive_fusionv_1.safetensors/resolve/main/lightx2v_elite_it2v_animate_face.safetensors" \
    "$MODELS_DIR/loras/lightx2v_elite_it2v_animate_face.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors" \
    "$MODELS_DIR/loras/FullDynamic_Ultimate_Fusion_Elite.safetensors"

  download_if_missing \
    "https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/wan2.2_face_complete_distilled.safetensors" \
    "$MODELS_DIR/loras/wan2.2_face_complete_distilled.safetensors"

  download_if_missing \
    "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Wan22_relight/WanAnimate_relight_lora_fp16.safetensors" \
    "$MODELS_DIR/loras/WanAnimate_relight_lora_fp16.safetensors"

  download_if_missing \
    "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" \
    "$MODELS_DIR/detection/yolov10m.onnx"

  download_if_missing \
    "https://huggingface.co/JunkyByte/easy_ViTPose/resolve/main/onnx/wholebody/vitpose-l-wholebody.onnx" \
    "$MODELS_DIR/detection/vitpose-l-wholebody.onnx"
fi
stage_event "bootstrap.model_downloads" "end"

mkdir -p "$COMFY_ROOT/input" "$COMFY_ROOT/output"

echo "[bootstrap] done"
