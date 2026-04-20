#!/usr/bin/env bash
set -euo pipefail

COMFY_ROOT=${COMFY_ROOT:-/workspace/ComfyUI}
MODELS_DIR="$COMFY_ROOT/models"

python3 -m pip install huggingface_hub

mkdir -p "$MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"
hf download TencentGameMate/chinese-wav2vec2-base --repo-type model --local-dir "$MODELS_DIR/transformers/TencentGameMate/chinese-wav2vec2-base"

mkdir -p "$MODELS_DIR/loras"
curl -L --fail -o "$MODELS_DIR/loras/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"

mkdir -p "$MODELS_DIR/controlnet"
curl -L --fail -o "$MODELS_DIR/controlnet/Wan21_Uni3C_controlnet_fp16.safetensors" "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_Uni3C_controlnet_fp16.safetensors"

mkdir -p "$MODELS_DIR/diffusion_models"
curl -L --fail -o "$MODELS_DIR/diffusion_models/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors" "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors"

mkdir -p "$MODELS_DIR/diffusion_models"
curl -L --fail -o "$MODELS_DIR/diffusion_models/WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors" "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors"

mkdir -p "$MODELS_DIR/clip_vision"
curl -L --fail -o "$MODELS_DIR/clip_vision/clip_vision_h.safetensors" "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors"

mkdir -p "$MODELS_DIR/text_encoders"
curl -L --fail -o "$MODELS_DIR/text_encoders/umt5-xxl-enc-bf16.safetensors" "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors"

mkdir -p "$MODELS_DIR/vae"
curl -L --fail -o "$MODELS_DIR/vae/wan_2.1_vae.safetensors" "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors"
