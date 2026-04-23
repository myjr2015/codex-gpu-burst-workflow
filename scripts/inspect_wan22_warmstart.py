from __future__ import annotations

import argparse
import json
from pathlib import Path


REQUIRED_CUSTOM_NODES = (
    "ComfyUI-GGUF",
    "ComfyUI-KJNodes",
    "ComfyUI-VideoHelperSuite",
    "ComfyUI-WanAnimatePreprocess",
)

REQUIRED_MODELS = (
    "unet/Wan2.2-Animate-14B-Q4_K_S.gguf",
    "text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors",
    "vae/wan_2.1_vae.safetensors",
    "clip_vision/clip_vision_h.safetensors",
    "loras/lightx2v_elite_it2v_animate_face.safetensors",
    "loras/FullDynamic_Ultimate_Fusion_Elite.safetensors",
    "loras/wan2.2_face_complete_distilled.safetensors",
    "loras/WanAnimate_relight_lora_fp16.safetensors",
    "detection/yolov10m.onnx",
    "detection/vitpose-l-wholebody.onnx",
)


def inspect_runtime_state(custom_nodes_dir: Path, models_dir: Path) -> dict:
    custom_nodes_dir = Path(custom_nodes_dir)
    models_dir = Path(models_dir)

    missing_custom_nodes = [
        node_name for node_name in REQUIRED_CUSTOM_NODES if not (custom_nodes_dir / node_name).is_dir()
    ]
    missing_models = [
        rel_path for rel_path in REQUIRED_MODELS if not (models_dir / rel_path).is_file()
    ]

    return {
        "custom_nodes_ready": not missing_custom_nodes,
        "models_ready": not missing_models,
        "missing_custom_nodes": missing_custom_nodes,
        "missing_models": missing_models,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--custom-nodes-dir", required=True)
    parser.add_argument("--models-dir", required=True)
    args = parser.parse_args()

    state = inspect_runtime_state(
        custom_nodes_dir=Path(args.custom_nodes_dir),
        models_dir=Path(args.models_dir),
    )
    print(json.dumps(state, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
