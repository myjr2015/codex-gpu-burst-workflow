#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


REQUIRED_CUSTOM_NODES = [
    "ComfyUI-WanVideoWrapper",
    "ComfyUI-WanAnimatePreprocess",
    "ComfyUI-VideoHelperSuite",
    "ComfyUI-KJNodes",
    "ComfyUI_LayerStyle",
]

REQUIRED_MODELS = [
    "diffusion_models/Wan22Animate/Wan2_2-Animate-14B_fp8_scaled_e4m3fn_KJ_v2.safetensors",
    "text_encoders/umt5-xxl-enc-fp8_e4m3fn.safetensors",
    "vae/wan_2.1_vae.safetensors",
    "clip_vision/clip_vision_h.safetensors",
    "detection/vitpose-l-wholebody.onnx",
    "detection/yolov10m.onnx",
    "loras/lightx2v_elite_it2v_animate_face.safetensors",
    "loras/WAN22_MoCap_fullbodyCOPY_ED.safetensors",
    "loras/FullDynamic_Ultimate_Fusion_Elite.safetensors",
    "loras/Wan2.2-Fun-A14B-InP-Fusion-Elite.safetensors",
    "loras/Wan2.2-Fun-A14B-InP-low-noise-HPS2.1.safetensors",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--custom-nodes-dir", required=True)
    parser.add_argument("--models-dir", required=True)
    args = parser.parse_args()

    custom_nodes_dir = Path(args.custom_nodes_dir)
    models_dir = Path(args.models_dir)

    missing_custom_nodes = [
        name for name in REQUIRED_CUSTOM_NODES
        if not (custom_nodes_dir / name).exists()
    ]
    missing_models = [
        rel for rel in REQUIRED_MODELS
        if not (models_dir / rel).exists()
    ]

    print(json.dumps({
        "custom_nodes_ready": not missing_custom_nodes,
        "models_ready": not missing_models,
        "missing_custom_nodes": missing_custom_nodes,
        "missing_models": missing_models,
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
