#!/usr/bin/env bash
set -euo pipefail

COMFY_APP_ROOT="${COMFY_APP_ROOT:-/opt/workspace-internal/ComfyUI}"
WORKSPACE_COMFY_ROOT="${WORKSPACE_COMFY_ROOT:-/workspace/ComfyUI}"
SEED_DIR="${KJ_CUSTOM_NODE_SEED_DIR:-/opt/codex/kj-custom_nodes}"
PIP_TIMEOUT="${PIP_TIMEOUT:-1800}"
PIP_RETRIES="${PIP_RETRIES:-20}"

pip_install() {
  python3 -m pip install --timeout "$PIP_TIMEOUT" --retries "$PIP_RETRIES" --no-cache-dir "$@"
}

python_has_module() {
  local module_name="$1"
  python3 - "$module_name" <<'PY' >/dev/null 2>&1
import importlib.util
import sys
raise SystemExit(0 if importlib.util.find_spec(sys.argv[1]) else 1)
PY
}

python_can_import() {
  local module_name="$1"
  python3 - "$module_name" <<'PY' >/dev/null 2>&1
import importlib
import sys
importlib.import_module(sys.argv[1])
PY
}

ensure_python_package() {
  local package_spec="$1"
  local module_name="$2"
  if python_has_module "$module_name"; then
    echo "[kj-env-image] python module exists: $module_name"
    return 0
  fi
  echo "[kj-env-image] installing package: $package_spec"
  pip_install --upgrade-strategy only-if-needed "$package_spec"
}

ensure_python_package_no_deps() {
  local package_spec="$1"
  local module_name="$2"
  if python_has_module "$module_name"; then
    echo "[kj-env-image] python module exists: $module_name"
    return 0
  fi
  echo "[kj-env-image] installing package without deps: $package_spec"
  pip_install --upgrade-strategy only-if-needed --no-deps "$package_spec"
}

torch_core_matches_expected() {
  python3 <<'PY' >/dev/null 2>&1
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
raise SystemExit(0)
PY
}

torch_aux_package_specs() {
  python3 - "$@" <<'PY'
import re
import sys

import torch

version = torch.__version__.split("+", 1)[0]
match = re.match(r"^(\d+)\.(\d+)\.(\d+)", version)
if not match:
    for name in sys.argv[1:]:
        print(name)
    raise SystemExit(0)

major = int(match.group(1))
minor = int(match.group(2))
patch = int(match.group(3))
torch_version = f"{major}.{minor}.{patch}"
vision_minor = minor + 15 if major == 2 else None

for name in sys.argv[1:]:
    if name == "torchvision" and vision_minor is not None:
        print(f"torchvision==0.{vision_minor}.0")
    elif name == "torchaudio":
        print(f"torchaudio=={torch_version}")
    else:
        print(name)
PY
}

torch_aux_index_url() {
  python3 <<'PY'
import torch

cuda_version = getattr(torch.version, "cuda", None) or ""
parts = cuda_version.split(".")
try:
    major = int(parts[0])
    minor = int(parts[1]) if len(parts) > 1 else 0
except Exception:
    print("https://download.pytorch.org/whl/cu124")
    raise SystemExit(0)
print(f"https://download.pytorch.org/whl/cu{major}{minor}")
PY
}

ensure_torch_aux_packages() {
  local missing=()
  if ! python_can_import "torchvision"; then
    missing+=("torchvision")
  fi
  if ! python_can_import "torchaudio"; then
    missing+=("torchaudio")
  fi
  if [ "${#missing[@]}" -eq 0 ]; then
    return 0
  fi
  mapfile -t aux_specs < <(torch_aux_package_specs "${missing[@]}")
  local aux_index_url
  aux_index_url="$(torch_aux_index_url)"
  echo "[kj-env-image] installing missing torch auxiliary packages without reinstalling torch: ${aux_specs[*]} from $aux_index_url"
  pip_install --upgrade-strategy only-if-needed --no-deps --index-url "$aux_index_url" "${aux_specs[@]}"
}

install_filtered_requirements_file() {
  local requirements_path="$1"
  local label="$2"
  if [ ! -f "$requirements_path" ]; then
    return 0
  fi

  local filtered_path="/tmp/$label.filtered.txt"
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
        print(f"[kj-env-image] skip heavy requirement: {line}")
        continue
    lines.append(line)

dest.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
print(f"[kj-env-image] wrote filtered requirements: {dest}")
PY

  if [ ! -s "$filtered_path" ]; then
    echo "[kj-env-image] no lightweight requirements left for $label"
    return 0
  fi

  echo "[kj-env-image] installing filtered requirements for $label"
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

copy_seed_nodes() {
  local target_root="$1"
  if [ -z "$target_root" ]; then
    return 0
  fi
  mkdir -p "$target_root"
  for plugin_dir in "$SEED_DIR"/*; do
    if [ -d "$plugin_dir" ]; then
      rm -rf "$target_root/$(basename "$plugin_dir")"
      cp -a "$plugin_dir" "$target_root/"
    fi
  done
}

mkdir -p "$SEED_DIR"
if torch_core_matches_expected; then
  ensure_torch_aux_packages
else
  echo "[kj-env-image] base torch stack is not cu124-compatible; leaving runtime bootstrap to repair it"
fi

sync_git_plugin "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "$SEED_DIR/ComfyUI-WanVideoWrapper"
sync_git_plugin "https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git" "$SEED_DIR/ComfyUI-WanAnimatePreprocess"
sync_git_plugin "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$SEED_DIR/ComfyUI-VideoHelperSuite"
sync_git_plugin "https://github.com/kijai/ComfyUI-KJNodes.git" "$SEED_DIR/ComfyUI-KJNodes"
sync_git_plugin "https://github.com/chflame163/ComfyUI_LayerStyle.git" "$SEED_DIR/ComfyUI_LayerStyle"

if [ -d "$COMFY_APP_ROOT" ]; then
  copy_seed_nodes "$COMFY_APP_ROOT/custom_nodes"
  install_filtered_requirements_file "$COMFY_APP_ROOT/requirements.txt" "comfyui-core-requirements"
fi

if [ -d "$WORKSPACE_COMFY_ROOT" ]; then
  copy_seed_nodes "$WORKSPACE_COMFY_ROOT/custom_nodes"
fi

for plugin_dir in "$SEED_DIR"/*; do
  if [ -d "$plugin_dir" ]; then
    install_filtered_requirements_file "$plugin_dir/requirements.txt" "$(basename "$plugin_dir")-requirements"
  fi
done

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

python3 - <<'PY' || true
import json
from pathlib import Path

payload = {
    "kind": "wan22_kj_30s_env_image",
    "models_included": False,
    "custom_node_seed_dir": "/opt/codex/kj-custom_nodes",
}
try:
    import torch
    payload["torch"] = {
        "version": torch.__version__,
        "cuda": getattr(torch.version, "cuda", ""),
    }
except Exception as exc:
    payload["torch_error"] = str(exc)
for name in ("torchvision", "torchaudio"):
    try:
        module = __import__(name)
        payload[name] = {"version": getattr(module, "__version__", "")}
    except Exception as exc:
        payload[name] = {"error": str(exc)}
Path("/opt/codex/kj-env-image.json").write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY

python3 - <<'PY' || true
import importlib

import torch

parts = [f"torch={torch.__version__}", f"cuda={getattr(torch.version, 'cuda', '')}"]
for name in ("torchvision", "torchaudio"):
    try:
        module = importlib.import_module(name)
        parts.append(f"{name}={getattr(module, '__version__', '')}")
    except Exception as exc:
        parts.append(f"{name}=missing:{exc}")
print("[kj-env-image] " + " ".join(parts))
PY

python3 -m pip cache purge || true
