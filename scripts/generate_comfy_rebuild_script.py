import argparse
import json
from pathlib import Path


PACKAGE_REPOS = {
    "ComfyUI-WanVideoWrapper": "https://github.com/kijai/ComfyUI-WanVideoWrapper",
    "ComfyUI-VideoHelperSuite": "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite",
}

MODEL_DIR_RULES = {
    "wan_2.1_vae.safetensors": "vae",
    "umt5-xxl-enc-bf16.safetensors": "text_encoders",
    "Wan2_1-I2V-14B-480P_fp8_e4m3fn.safetensors": "diffusion_models",
    "WanVideo_2_1_Multitalk_14B_fp8_e4m3fn.safetensors": "diffusion_models",
    "Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors": "loras",
    "Wan21_Uni3C_controlnet_fp16.safetensors": "controlnet",
    "clip_vision_h.safetensors": "clip_vision",
    "TencentGameMate/chinese-wav2vec2-base": "transformers",
}


def build_rebuild_script(manifest):
    packages = manifest.get("custom_node_packages", [])
    dependency_lines = []
    for package in packages:
        for dep in manifest.get("python_dependencies", {}).get(package, []):
            dependency_lines.append(dep)

    unique_deps = sorted(set(dependency_lines))
    model_dirs = sorted({MODEL_DIR_RULES.get(model) for model in manifest.get("models", []) if MODEL_DIR_RULES.get(model)})

    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
        "COMFY_ROOT=${COMFY_ROOT:-/workspace/ComfyUI}",
        "CUSTOM_NODES_DIR=\"$COMFY_ROOT/custom_nodes\"",
        "MODELS_DIR=\"$COMFY_ROOT/models\"",
        "",
        "mkdir -p \"$CUSTOM_NODES_DIR\"",
    ]

    for package in packages:
        repo = PACKAGE_REPOS.get(package)
        if repo:
            lines.extend(
                [
                    "",
                    f"if [ ! -d \"$CUSTOM_NODES_DIR/{package}\" ]; then",
                    f"  git clone {repo} \"$CUSTOM_NODES_DIR/{package}\"",
                    "fi",
                ]
            )

    if unique_deps:
        quoted_deps = [f'"{dep}"' for dep in unique_deps]
        lines.extend(
            [
                "",
                "# Core ComfyUI dependencies for the checked-out revision",
                "python3 -m pip install -r \"$COMFY_ROOT/requirements.txt\"",
                "",
                "# Shared Python dependencies for the workflow",
                "python3 -m pip install " + " ".join(quoted_deps),
            ]
        )

    lines.extend(["", "# Create expected model directories"])
    for model_dir in model_dirs:
        lines.append(f"mkdir -p \"$MODELS_DIR/{model_dir}\"")

    lines.extend(["", "# Required model files"])
    for model in manifest.get("models", []):
        target_dir = MODEL_DIR_RULES.get(model, "UNKNOWN_DIR")
        lines.append(f"# {model} -> $MODELS_DIR/{target_dir}")

    lines.extend(["", "# Required workflow input assets"])
    for asset in manifest.get("input_assets", []):
        lines.append(f"# {asset}")

    lines.extend(
        [
            "",
            "echo \"Rebuild scaffold ready. Next: copy model files, upload input assets, then import workflow_api_24g_pruned.json into ComfyUI.\"",
            "",
        ]
    )
    return "\n".join(lines)


def write_script(output_path, text):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(text, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description="Generate a rebuild shell script from a Comfy workflow requirements manifest.")
    parser.add_argument("--manifest", required=True, help="Path to requirements_manifest.json")
    parser.add_argument("--output", required=True, help="Path to output shell script")
    args = parser.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    text = build_rebuild_script(manifest)
    write_script(Path(args.output), text)


if __name__ == "__main__":
    main()
