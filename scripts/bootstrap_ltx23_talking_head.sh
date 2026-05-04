#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT="${COMFY_ROOT:-/workspace/ComfyUI}"
COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
RUN_DIR="${RUN_DIR:-/workspace/ltx23-talking-head-run}"
MODELS_DIR="$COMFY_ROOT/models"
PYTORCH_INDEX_URL="${PYTORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
PIP_TIMEOUT="${PIP_TIMEOUT:-1800}"
PIP_RETRIES="${PIP_RETRIES:-20}"
LTX_UPDATE_COMFYUI="${LTX_UPDATE_COMFYUI:-1}"

mkdir -p "$MODELS_DIR" "$RUN_DIR" "$COMFY_ROOT/input" "$COMFY_ROOT/output" "$COMFY_ROOT/custom_nodes"

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

python_has_module() {
  local module_name="$1"
  python3 - "$module_name" <<'PY' >/dev/null 2>&1
import importlib.util
import sys

module_name = sys.argv[1]
raise SystemExit(0 if importlib.util.find_spec(module_name) else 1)
PY
}

ensure_python_package() {
  local package_spec="$1"
  local module_name="$2"
  if python_has_module "$module_name"; then
    echo "[bootstrap-ltx23] python module exists: $module_name"
    return 0
  fi

  echo "[bootstrap-ltx23] installing package: $package_spec"
  pip_install --upgrade-strategy only-if-needed "$package_spec"
}

torch_stack_matches_expected() {
  python3 <<'PY' >/dev/null 2>&1
import importlib

for name in ("torch", "torchvision", "torchaudio"):
    importlib.import_module(name)

import torch

version = tuple(int(part) for part in torch.__version__.split("+", 1)[0].split(".")[:2])
cuda_version = getattr(torch.version, "cuda", None) or ""
parts = cuda_version.split(".")
major = int(parts[0]) if parts and parts[0] else 0
minor = int(parts[1]) if len(parts) > 1 and parts[1] else 0

if version < (2, 7):
    raise SystemExit(1)
if major < 12 or (major == 12 and minor < 8):
    raise SystemExit(1)
if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
    raise SystemExit(1)

_ = torch.cuda.get_device_name(0)
raise SystemExit(0)
PY
}

describe_torch_stack() {
  python3 <<'PY' 2>/dev/null || true
import importlib

for name in ("torch", "torchvision", "torchaudio"):
    importlib.import_module(name)

import torch
print(
    "[bootstrap-ltx23] torch stack: "
    f"torch={torch.__version__} "
    f"cuda={getattr(torch.version, 'cuda', '')} "
    f"device={torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu'}"
)
PY
}

ensure_torch_stack() {
  if torch_stack_matches_expected; then
    describe_torch_stack
    echo "[bootstrap-ltx23] existing torch stack is compatible with LTX2.3"
    return 0
  fi

  echo "[bootstrap-ltx23] installing torch stack from $PYTORCH_INDEX_URL"
  pip_install --upgrade --index-url "$PYTORCH_INDEX_URL" torch torchvision torchaudio
  describe_torch_stack
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
    "xformers",
    "flash-attn",
    "flash_attn",
    "triton",
    "nvidia-",
    "nvidia_",
    "cuda-",
    "cuda_",
)
managed_prefixes = (
    "kornia",
    "kornia-rs",
    "kornia_rs",
)

lines = []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = re.match(r"[A-Za-z0-9_.-]+", line)
    normalized = (match.group(0) if match else line).lower()
    if normalized.startswith(skip_prefixes):
        print(f"[bootstrap-ltx23] skip CUDA/torch requirement: {line}")
        continue
    if normalized.startswith(managed_prefixes):
        print(f"[bootstrap-ltx23] skip managed requirement: {line}")
        continue
    lines.append(line)

dest.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print(f"[bootstrap-ltx23] wrote filtered requirements: {dest}")
PY

  if [ ! -s "$filtered_path" ]; then
    echo "[bootstrap-ltx23] no lightweight requirements left for $label"
    return 0
  fi

  echo "[bootstrap-ltx23] installing filtered requirements for $label"
  pip_install --upgrade-strategy only-if-needed -r "$filtered_path"
}

ensure_kornia_compat() {
  if python3 <<'PY' >/dev/null 2>&1
import kornia
import kornia.filters

raise SystemExit(0 if getattr(kornia, "__version__", "") == "0.7.1" else 1)
PY
  then
    echo "[bootstrap-ltx23] kornia compatibility pin exists: 0.7.1"
    return 0
  fi

  echo "[bootstrap-ltx23] installing kornia compatibility pin: 0.7.1"
  pip_install --force-reinstall --no-deps "kornia==0.7.1"
  python3 -m pip uninstall -y kornia-rs kornia_rs >/dev/null 2>&1 || true
  python3 <<'PY'
import kornia
import kornia.filters

print(f"[bootstrap-ltx23] kornia ready: {kornia.__version__}")
PY
}

download_if_missing() {
  local url="$1"
  local target="$2"
  local stage_name="download.$(basename "$target")"
  if [ -f "$target" ]; then
    echo "[bootstrap-ltx23] exists: $target"
    stage_event "$stage_name" "skip"
    return 0
  fi

  mkdir -p "$(dirname "$target")"
  local tmp="$target.part"
  echo "[bootstrap-ltx23] downloading: $(basename "$target")"
  stage_event "$stage_name" "start"
  curl --http1.1 --fail --location --show-error \
    --retry 10 --retry-delay 8 --retry-all-errors \
    --connect-timeout 30 --max-time 7200 \
    -C - -o "$tmp" "$url"
  mv "$tmp" "$target"
  stage_event "$stage_name" "end"
}

download_motion_lora_if_requested() {
  local requested_name="${LTX23_MOTION_LORA_NAME:-}"
  local requested_url="${LTX23_MOTION_LORA_URL:-}"

  if [ -z "$requested_name" ] && [ "${LTX23_DOWNLOAD_VBVR:-0}" != "1" ]; then
    return 0
  fi

  if [ -z "$requested_name" ]; then
    requested_name="Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors"
  fi

  case "$requested_name" in
    "Ltx2.3-Licon-VBVR-I2V-240K-R32.safetensors"|"Ltx2.3-Licon-VBVR-I2V-390K-R32.safetensors"|"Ltx2.3-Licon-VBVR-I2V-96000-R32.safetensors")
      requested_url="https://huggingface.co/LiconStudio/Ltx2.3-VBVR-lora-I2V/resolve/main/$requested_name"
      ;;
  esac

  if [ -z "$requested_url" ]; then
    echo "[bootstrap-ltx23] LTX23_MOTION_LORA_NAME is set but no known URL is available: $requested_name" >&2
    echo "[bootstrap-ltx23] Set LTX23_MOTION_LORA_URL or use a known LiconStudio VBVR LoRA filename." >&2
    exit 2
  fi

  download_if_missing "$requested_url" "$MODELS_DIR/loras/$requested_name"
}

install_custom_node_repo() {
  local repo_url="$1"
  local target_dir="$2"
  local label="$3"

  if [ -d "$target_dir/.git" ]; then
    echo "[bootstrap-ltx23] updating custom node: $label"
    git -C "$target_dir" pull --ff-only || echo "[bootstrap-ltx23] custom node update skipped after git pull failure: $label"
  else
    echo "[bootstrap-ltx23] installing custom node: $label"
    rm -rf "$target_dir"
    git clone --depth 1 "$repo_url" "$target_dir"
  fi

  install_filtered_requirements_file "$target_dir/requirements.txt" "custom-node-$label-requirements"
}

echo "[bootstrap-ltx23] start"

if [ "$LTX_UPDATE_COMFYUI" = "1" ] && [ -d "$COMFY_APP_ROOT/.git" ]; then
  echo "[bootstrap-ltx23] updating ComfyUI app checkout"
  stage_event "bootstrap.update_comfyui" "start"
  git -C "$COMFY_APP_ROOT" pull --ff-only || echo "[bootstrap-ltx23] ComfyUI update skipped after git pull failure"
  stage_event "bootstrap.update_comfyui" "end"
fi

echo "[bootstrap-ltx23] installing python dependencies"
stage_event "bootstrap.python_dependencies" "start"
ensure_torch_stack
install_filtered_requirements_file "$COMFY_APP_ROOT/requirements.txt" "comfyui-core-requirements"
ensure_kornia_compat
ensure_python_package "huggingface_hub[hf_xet]>=0.31.0" "huggingface_hub"
ensure_python_package "safetensors" "safetensors"
ensure_python_package "transformers>=4.53.0" "transformers"
ensure_python_package "sentencepiece>=0.2.0" "sentencepiece"
ensure_python_package "protobuf" "google.protobuf"
ensure_python_package "accelerate" "accelerate"
ensure_python_package "einops" "einops"
ensure_python_package "av>=14.2.0" "av"
ensure_python_package "soundfile" "soundfile"
ensure_python_package "librosa" "librosa"
ensure_python_package "spandrel" "spandrel"
ensure_python_package "torchao" "torchao"
ensure_python_package "torchsde" "torchsde"
ensure_python_package "pydantic>=2.11.10" "pydantic"
stage_event "bootstrap.python_dependencies" "end"

echo "[bootstrap-ltx23] installing custom nodes"
stage_event "bootstrap.custom_nodes" "start"
install_custom_node_repo \
  "https://github.com/kijai/ComfyUI-KJNodes.git" \
  "$COMFY_ROOT/custom_nodes/ComfyUI-KJNodes" \
  "ComfyUI-KJNodes"
stage_event "bootstrap.custom_nodes" "end"

echo "[bootstrap-ltx23] downloading models"
stage_event "bootstrap.model_downloads" "start"
mkdir -p \
  "$MODELS_DIR/checkpoints" \
  "$MODELS_DIR/text_encoders" \
  "$MODELS_DIR/loras" \
  "$MODELS_DIR/latent_upscale_models"

download_if_missing \
  "https://huggingface.co/Lightricks/LTX-2.3-fp8/resolve/main/ltx-2.3-22b-dev-fp8.safetensors" \
  "$MODELS_DIR/checkpoints/ltx-2.3-22b-dev-fp8.safetensors"

download_if_missing \
  "https://huggingface.co/Comfy-Org/ltx-2/resolve/main/split_files/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors" \
  "$MODELS_DIR/text_encoders/gemma_3_12B_it_fp4_mixed.safetensors"

download_if_missing \
  "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-22b-distilled-lora-384.safetensors" \
  "$MODELS_DIR/loras/ltx-2.3-22b-distilled-lora-384.safetensors"

download_if_missing \
  "https://huggingface.co/Lightricks/LTX-2.3/resolve/main/ltx-2.3-spatial-upscaler-x2-1.0.safetensors" \
  "$MODELS_DIR/latent_upscale_models/ltx-2.3-spatial-upscaler-x2-1.0.safetensors"

download_motion_lora_if_requested

stage_event "bootstrap.model_downloads" "end"

echo "[bootstrap-ltx23] done"
