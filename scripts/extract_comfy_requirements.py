import argparse
import json
import tomllib
from pathlib import Path


NODE_PACKAGE_RULES = {
    "WanVideo": "ComfyUI-WanVideoWrapper",
    "MultiTalk": "ComfyUI-WanVideoWrapper",
    "LoadWanVideo": "ComfyUI-WanVideoWrapper",
    "DownloadAndLoadWav2VecModel": "ComfyUI-WanVideoWrapper",
    "VHS_": "ComfyUI-VideoHelperSuite",
}

MODEL_INPUT_KEYS = {"model", "model_name", "lora", "clip_name"}
ASSET_INPUT_KEYS = {"audio", "image"}
IGNORED_STRING_INPUT_KEYS = {
    "precision",
    "base_precision",
    "load_device",
    "quantization",
    "attention_mode",
    "scheduler",
    "crop",
    "combine_embeds",
    "format",
    "pix_fmt",
    "normalization",
    "multi_audio_type",
    "rope_function",
    "filename_prefix",
    "audioUI",
    "prompt",
}


def infer_package_name(class_type):
    for prefix, package_name in NODE_PACKAGE_RULES.items():
        if class_type.startswith(prefix):
            return package_name
    return None


def is_model_reference(key, value):
    if not isinstance(value, str) or not value:
        return False
    if key in MODEL_INPUT_KEYS:
        return True
    if key in IGNORED_STRING_INPUT_KEYS:
        return False
    if value.endswith(".safetensors"):
        return True
    if "/" in value and "." not in value.rsplit("/", 1)[-1]:
        return True
    return False


def is_asset_reference(class_type, key, value):
    if not isinstance(value, str) or not value:
        return False
    if class_type == "LoadAudio" and key == "audio":
        return True
    if class_type == "LoadImage" and key == "image":
        return True
    return key in ASSET_INPUT_KEYS and Path(value).suffix.lower() in {".png", ".jpg", ".jpeg", ".wav", ".mp3", ".mp4"}


def load_python_dependencies(bundle_dir):
    deps = []
    pyproject_path = bundle_dir / "pyproject.toml"
    if pyproject_path.exists():
        data = tomllib.loads(pyproject_path.read_text(encoding="utf-8"))
        deps.extend(data.get("project", {}).get("dependencies", []))
    requirements_path = bundle_dir / "requirements.txt"
    if requirements_path.exists():
        deps.extend(
            line.strip()
            for line in requirements_path.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        )
    return sorted({normalize_dependency(dep) for dep in deps})


def normalize_dependency(dep):
    return "".join(dep.split())


def summarize_workflow_requirements(workflow, node_bundles_root):
    class_types = sorted({node.get("class_type") for node in workflow.values() if node.get("class_type")})
    models = set()
    input_assets = set()
    custom_node_packages = set()

    for node in workflow.values():
        class_type = node.get("class_type", "")
        package_name = infer_package_name(class_type)
        if package_name:
            custom_node_packages.add(package_name)
        inputs = node.get("inputs", {})
        for key, value in inputs.items():
            if is_model_reference(key, value):
                models.add(value)
            elif is_asset_reference(class_type, key, value):
                input_assets.add(value)

    python_dependencies = {}
    for package_name in sorted(custom_node_packages):
        bundle_dir = Path(node_bundles_root) / package_name
        python_dependencies[package_name] = load_python_dependencies(bundle_dir) if bundle_dir.exists() else []

    return {
        "class_types": class_types,
        "custom_node_packages": sorted(custom_node_packages),
        "models": sorted(models),
        "input_assets": sorted(input_assets),
        "python_dependencies": python_dependencies,
    }


def main():
    parser = argparse.ArgumentParser(description="Extract model and custom node requirements from a ComfyUI workflow_api.json.")
    parser.add_argument("--workflow", required=True, help="Path to workflow_api.json")
    parser.add_argument("--node-bundles-root", default="output/vast-node-bundles/src", help="Path to local custom node bundle directories")
    parser.add_argument("--output", help="Optional path to write JSON summary")
    args = parser.parse_args()

    workflow_path = Path(args.workflow)
    workflow = json.loads(workflow_path.read_text(encoding="utf-8"))
    summary = summarize_workflow_requirements(workflow, Path(args.node_bundles_root))
    text = json.dumps(summary, ensure_ascii=False, indent=2)

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text + "\n", encoding="utf-8")
    else:
        print(text)


if __name__ == "__main__":
    main()
