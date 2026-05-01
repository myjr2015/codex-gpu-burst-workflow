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
KJ_TORCH_AUX_INSTALL_STRICT="${KJ_TORCH_AUX_INSTALL_STRICT:-0}"
KJ_MODEL_DOWNLOAD_PARALLELISM="${KJ_MODEL_DOWNLOAD_PARALLELISM:-3}"
KJ_REMOTE_STOP_AFTER="${KJ_REMOTE_STOP_AFTER:-}"
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

refresh_nvidia_python_ld_paths() {
  local paths_file="/tmp/kj-bootstrap-nvidia-python-ld-paths.txt"
  python3 - "$paths_file" <<'PY'
import site
import sys
import sysconfig
from pathlib import Path

out = Path(sys.argv[1])
roots = []
for value in site.getsitepackages():
    roots.append(value)
for key in ("purelib", "platlib"):
    value = sysconfig.get_paths().get(key)
    if value:
        roots.append(value)

paths = []
seen = set()
for root in roots:
    base = Path(root)
    if not base.exists():
        continue
    for candidate in sorted(base.glob("nvidia/*/lib")):
        if candidate.is_dir():
            resolved = str(candidate.resolve())
            if resolved not in seen:
                seen.add(resolved)
                paths.append(resolved)

out.write_text("\n".join(paths) + ("\n" if paths else ""), encoding="utf-8")
PY

  if [ ! -s "$paths_file" ]; then
    return 0
  fi

  local joined_paths
  joined_paths="$(paste -sd: "$paths_file")"
  if [ -n "$joined_paths" ]; then
    export LD_LIBRARY_PATH="$joined_paths:${LD_LIBRARY_PATH:-}"
    echo "[bootstrap] LD_LIBRARY_PATH includes Python NVIDIA libraries"
  fi

  if [ -d /etc/ld.so.conf.d ] && [ -w /etc/ld.so.conf.d ]; then
    cp "$paths_file" /etc/ld.so.conf.d/codex-nvidia-python-libs.conf
    ldconfig || true
  fi
}

onnxruntime_cuda_static_ready() {
  python3 <<'PY' >/dev/null 2>&1
import ctypes
import onnxruntime as ort

if hasattr(ort, "preload_dlls"):
    ort.preload_dlls(directory="")

providers = set(ort.get_available_providers())
if "CUDAExecutionProvider" not in providers:
    raise SystemExit(1)

for lib in (
    "libcublasLt.so.12",
    "libcublas.so.12",
    "libcudart.so.12",
    "libcudnn.so.9",
):
    ctypes.CDLL(lib)
PY
}

validate_onnxruntime_cuda_gpu() {
  local output_path="${1:-$RUN_DIR/onnxruntime_cuda_validation.json}"
  python3 - "$output_path" <<'PY'
import ctypes
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
from onnx import TensorProto, helper

if hasattr(ort, "preload_dlls"):
    ort.preload_dlls(directory="")

providers = ort.get_available_providers()
required_provider = "CUDAExecutionProvider"
if required_provider not in providers:
    raise SystemExit(f"onnxruntime missing {required_provider}; providers={providers}")

loaded_libs = []
for lib in (
    "libcublasLt.so.12",
    "libcublas.so.12",
    "libcudart.so.12",
    "libcudnn.so.9",
):
    ctypes.CDLL(lib)
    loaded_libs.append(lib)

input_info = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 2])
output_info = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 2])
node = helper.make_node("Identity", ["x"], ["y"])
graph = helper.make_graph([node], "codex_onnxruntime_cuda_smoke", [input_info], [output_info])
model = helper.make_model(
    graph,
    producer_name="codex-kj-smoke",
    opset_imports=[helper.make_operatorsetid("", 13)],
)
model.ir_version = 8

with tempfile.TemporaryDirectory() as temp_dir:
    model_path = Path(temp_dir) / "identity.onnx"
    onnx.save(model, model_path)
    session = ort.InferenceSession(str(model_path), providers=[required_provider])
    session_providers = session.get_providers()
    if not session_providers or session_providers[0] != required_provider:
        raise SystemExit(f"onnxruntime session did not use CUDA first; session_providers={session_providers}")
    result = session.run(None, {"x": np.array([[1.0, 2.0]], dtype=np.float32)})[0]
    if result.tolist() != [[1.0, 2.0]]:
        raise SystemExit(f"unexpected onnxruntime output: {result!r}")

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "onnxruntime": ort.__version__,
    "available_providers": providers,
    "required_provider": required_provider,
    "session_providers": session_providers,
    "loaded_libraries": loaded_libs,
    "gpu_session_checked": True,
}
Path(output_path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
print("[bootstrap] onnxruntime CUDA validation passed: " + json.dumps(payload, sort_keys=True))
PY
}

ensure_onnxruntime_cuda_package() {
  refresh_nvidia_python_ld_paths
  if onnxruntime_cuda_static_ready; then
    echo "[bootstrap] onnxruntime CUDA provider and CUDA12 libraries already available"
  else
    echo "[bootstrap] installing onnxruntime GPU package with CUDA/cuDNN runtime dependencies"
    python3 -m pip uninstall -y onnxruntime || true
    pip_install --upgrade --upgrade-strategy only-if-needed "onnxruntime-gpu[cuda,cudnn]>=1.21.0"
    refresh_nvidia_python_ld_paths
  fi
  validate_onnxruntime_cuda_gpu "$RUN_DIR/onnxruntime_cuda_validation.json"
}

model_download_not_needed_for_remote_stop() {
  case "$KJ_REMOTE_STOP_AFTER" in
    onnx_cuda|wait_api|validate_nodes)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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
if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
    raise SystemExit(1)
_ = torch.cuda.get_device_name(0)
raise SystemExit(0)
PY
}

describe_existing_torch_stack() {
  python3 <<'PY' 2>/dev/null || true
import torch
print(
    f"[bootstrap] reusing existing torch stack: "
    f"torch={torch.__version__} "
    f"cuda={getattr(torch.version, 'cuda', '')} "
    f"device={torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'cpu'}"
)
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
  echo "[bootstrap] installing missing torch auxiliary packages without reinstalling torch: ${aux_specs[*]} from $aux_index_url"
  if pip_install --upgrade-strategy only-if-needed --no-deps --index-url "$aux_index_url" "${aux_specs[@]}"; then
    return 0
  fi

  if [ "$KJ_TORCH_AUX_INSTALL_STRICT" = "1" ]; then
    echo "[bootstrap] failed to install missing torch auxiliary packages and KJ_TORCH_AUX_INSTALL_STRICT=1"
    return 1
  fi

  echo "[bootstrap] warning: failed to install optional torch auxiliary packages: ${aux_specs[*]}"
  echo "[bootstrap] continuing because torch core, CUDA, and GPU are already compatible"
}

ensure_torch_stack() {
  if [ "$FORCE_TORCH_REINSTALL" = "1" ]; then
    echo "[bootstrap] FORCE_TORCH_REINSTALL=1, reinstalling torch stack"
  elif torch_core_matches_expected; then
    describe_existing_torch_stack
    echo "[bootstrap] existing torch stack is compatible with this workflow runtime"
    ensure_torch_aux_packages
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
  local temp_target="$target.part.${BASHPID:-$$}"
  rm -f "$temp_target"
  if ! curl --http1.1 -L --fail --retry 10 --retry-delay 8 --retry-all-errors \
    -C - \
    --connect-timeout 30 --max-time 7200 -o "$temp_target" "$url"; then
    rm -f "$temp_target"
    stage_event "$stage_name" "fail"
    return 1
  fi
  if ! mv -f "$temp_target" "$target"; then
    rm -f "$temp_target"
    stage_event "$stage_name" "fail"
    return 1
  fi
  stage_event "$stage_name" "end"
}

download_model_entry() {
  local entry="$1"
  local url=""
  local target=""
  IFS='|' read -r url target <<< "$entry"
  download_if_missing "$url" "$target"
}

model_download_manifest() {
  cat <<EOF
https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors|$MODELS_DIR/diffusion_models/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors
https://huggingface.co/realung/umt5-xxl-enc-fp8_e4m3fn.safetensors/resolve/main/umt5-xxl-enc-fp8_e4m3fn.safetensors|$MODELS_DIR/text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors
https://huggingface.co/VladimirSoch/For_Work/resolve/main/wan_2.1_vae.safetensors|$MODELS_DIR/vae/wan_2.1_vae.safetensors
https://huggingface.co/VladimirSoch/For_Work/resolve/main/clip_vision_h.safetensors|$MODELS_DIR/clip_vision/clip_vision_h.safetensors
https://huggingface.co/VladimirSoch/For_Work/resolve/main/vitpose-l-wholebody.onnx|$MODELS_DIR/detection/vitpose-l-wholebody.onnx
https://huggingface.co/VladimirSoch/For_Work/resolve/main/yolov10m.onnx|$MODELS_DIR/detection/yolov10m.onnx
https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/lightx2v_elite_it2v_animate_face.safetensors|$MODELS_DIR/loras/lightx2v_elite_it2v_animate_face.safetensors
https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/WAN22_MoCap_fullbodyCOPY_ED.safetensors|$MODELS_DIR/loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors
https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/FullDynamic_Ultimate_Fusion_Elite.safetensors|$MODELS_DIR/loras/FullDynamic_Ultimate_Fusion_Elite.safetensors
https://huggingface.co/eddy1111111/Wan_toolkit/resolve/main/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors|$MODELS_DIR/loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors
https://huggingface.co/VladimirSoch/For_Work/resolve/main/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors|$MODELS_DIR/loras/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors
EOF
}

download_all_models() {
  local parallelism="$KJ_MODEL_DOWNLOAD_PARALLELISM"
  if ! [[ "$parallelism" =~ ^[0-9]+$ ]] || [ "$parallelism" -lt 1 ]; then
    parallelism=1
  fi
  if [ "$parallelism" -gt 4 ]; then
    parallelism=4
  fi

  mapfile -t model_entries < <(model_download_manifest)
  echo "[bootstrap] model download parallelism=$parallelism"
  if [ "$parallelism" -le 1 ]; then
    local entry=""
    for entry in "${model_entries[@]}"; do
      download_model_entry "$entry"
    done
    return 0
  fi

  local active=0
  local failed=0
  local entry=""
  for entry in "${model_entries[@]}"; do
    download_model_entry "$entry" &
    active=$((active + 1))
    if [ "$active" -ge "$parallelism" ]; then
      if ! wait -n; then
        failed=1
      fi
      active=$((active - 1))
    fi
  done
  while [ "$active" -gt 0 ]; do
    if ! wait -n; then
      failed=1
    fi
    active=$((active - 1))
  done
  return "$failed"
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
stage_event "bootstrap.onnx_cuda" "start"
ensure_onnxruntime_cuda_package
stage_event "bootstrap.onnx_cuda" "end"
if [ "$KJ_REMOTE_STOP_AFTER" = "onnx_cuda" ]; then
  echo "[bootstrap] KJ_REMOTE_STOP_AFTER=onnx_cuda, stopping before remaining dependencies and model downloads"
  stage_event "bootstrap.python_dependencies" "partial_stop"
  exit 0
fi
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

if model_download_not_needed_for_remote_stop; then
  echo "[bootstrap] skipping model downloads because KJ_REMOTE_STOP_AFTER=$KJ_REMOTE_STOP_AFTER will not submit workflow"
  stage_event "bootstrap.model_downloads" "skip"
  exit 0
fi

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
  download_all_models
fi
stage_event "bootstrap.model_downloads" "end"

mkdir -p "$COMFY_ROOT/input" "$COMFY_ROOT/output" "$COMFY_ROOT/temp"
echo "[bootstrap] done"
