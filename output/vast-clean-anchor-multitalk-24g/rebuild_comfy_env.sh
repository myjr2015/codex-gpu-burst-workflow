#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=${COMFY_ROOT:-/workspace/ComfyUI}
CUSTOM_NODES_DIR="$COMFY_ROOT/custom_nodes"
MODELS_DIR="$COMFY_ROOT/models"

mkdir -p "$CUSTOM_NODES_DIR"

if [ ! -d "$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite" ]; then
  git clone https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite "$CUSTOM_NODES_DIR/ComfyUI-VideoHelperSuite"
fi

if [ ! -d "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper" ]; then
  git clone https://github.com/kijai/ComfyUI-WanVideoWrapper "$CUSTOM_NODES_DIR/ComfyUI-WanVideoWrapper"
fi

# Core ComfyUI dependencies for the checked-out revision
python3 -m pip install -r "$COMFY_ROOT/requirements.txt"
# Re-pin PyTorch to a CUDA 12.8 build that matches current Vast GPU hosts
python3 -m pip install --force-reinstall torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

# Shared Python dependencies for the workflow
python3 -m pip install "accelerate>=1.2.1" "diffusers>=0.33.0" "einops" "ftfy" "gguf>=0.17.1" "imageio-ffmpeg" "opencv-python" "peft>=0.17.0" "protobuf" "pyloudnorm" "scipy" "sentencepiece>=0.2.0"

# Create expected model directories
mkdir -p "$MODELS_DIR/clip_vision"
mkdir -p "$MODELS_DIR/controlnet"
mkdir -p "$MODELS_DIR/diffusion_models"
mkdir -p "$MODELS_DIR/loras"
mkdir -p "$MODELS_DIR/text_encoders"
mkdir -p "$MODELS_DIR/transformers"
mkdir -p "$MODELS_DIR/vae"

# Required model files
# TencentGameMate/chinese-wav2vec2-base -> $MODELS_DIR/transformers
# Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors -> $MODELS_DIR/loras
# Wan21_Uni3C_controlnet_fp16.safetensors -> $MODELS_DIR/controlnet
# Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors -> $MODELS_DIR/diffusion_models
# WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors -> $MODELS_DIR/diffusion_models
# clip_vision_h.safetensors -> $MODELS_DIR/clip_vision
# umt5-xxl-enc-bf16.safetensors -> $MODELS_DIR/text_encoders
# wan_2.1_vae.safetensors -> $MODELS_DIR/vae

# Required workflow input assets
# clean-anchor-audio.wav
# clean-anchor-image.png

echo "Rebuild scaffold ready. Next: copy model files, upload input assets, then import workflow_api_24g_pruned.json into ComfyUI."
