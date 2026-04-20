import argparse
import json
from pathlib import Path


MODEL_DOWNLOADS = {
    "wan_2.1_vae.safetensors": {
        "dir": "vae",
        "url": "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors",
    },
    "umt5-xxl-enc-bf16.safetensors": {
        "dir": "text_encoders",
        "url": "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors",
    },
    "Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors": {
        "dir": "diffusion_models",
        "url": "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors",
    },
    "WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors": {
        "dir": "diffusion_models",
        "url": "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors",
    },
    "Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors": {
        "dir": "loras",
        "url": "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors",
    },
    "Wan21_Uni3C_controlnet_fp16.safetensors": {
        "dir": "controlnet",
        "url": "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_Uni3C_controlnet_fp16.safetensors",
    },
    "clip_vision_h.safetensors": {
        "dir": "clip_vision",
        "url": "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors",
    },
}

HF_REPO_DOWNLOADS = {
    "TencentGameMate/chinese-wav2vec2-base": {
        "dir": "transformers/TencentGameMate/chinese-wav2vec2-base",
        "repo": "TencentGameMate/chinese-wav2vec2-base",
    }
}


def build_download_script(manifest):
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "COMFY_ROOT=${COMFY_ROOT:-/workspace/ComfyUI}",
        "MODELS_DIR=\"$COMFY_ROOT/models\"",
        "",
        "python3 -m pip install huggingface_hub",
    ]

    for model in manifest.get("models", []):
        if model in MODEL_DOWNLOADS:
            item = MODEL_DOWNLOADS[model]
            lines.extend(
                [
                    "",
                    f"mkdir -p \"$MODELS_DIR/{item['dir']}\"",
                    f"curl -L --fail -o \"$MODELS_DIR/{item['dir']}/{model}\" \"{item['url']}\"",
                ]
            )
        elif model in HF_REPO_DOWNLOADS:
            item = HF_REPO_DOWNLOADS[model]
            lines.extend(
                [
                    "",
                    f"mkdir -p \"$MODELS_DIR/{item['dir']}\"",
                    f"hf download {item['repo']} --repo-type model --local-dir \"$MODELS_DIR/{item['dir']}\"",
                ]
            )
        else:
            lines.extend(["", f"# Missing download rule for: {model}"])

    lines.append("")
    return "\n".join(lines)


def write_script(output_path, text):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description="Generate model download commands from requirements manifest.")
    parser.add_argument("--manifest", required=True, help="Path to requirements_manifest.json")
    parser.add_argument("--output", required=True, help="Path to output shell script")
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    text = build_download_script(manifest)
    write_script(Path(args.output), text)


if __name__ == "__main__":
    main()
