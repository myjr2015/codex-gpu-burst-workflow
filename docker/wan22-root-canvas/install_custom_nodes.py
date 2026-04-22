from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path


REPOS = [
    {
        "name": "ComfyUI-GGUF",
        "url": "https://github.com/city96/ComfyUI-GGUF.git",
        "sha": "6ea2651e7df66d7585f6ffee804b20e92fb38b8a",
    },
    {
        "name": "ComfyUI-Easy-Use",
        "url": "https://github.com/yolain/ComfyUI-Easy-Use.git",
        "sha": "ff5e3a34fc793992e864529658c4394a35ba6a4a",
    },
    {
        "name": "ComfyUI-WanVideoWrapper",
        "url": "https://github.com/kijai/ComfyUI-WanVideoWrapper.git",
        "sha": "df8f3e49daaad117cf3090cc916c83f3d001494c",
    },
    {
        "name": "ComfyUI-WanAnimatePreprocess",
        "url": "https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git",
        "sha": "1a35b81a418bbba093356ad19b19bf2a76a24f4e",
    },
    {
        "name": "ComfyUI-KJNodes",
        "url": "https://github.com/kijai/ComfyUI-KJNodes.git",
        "sha": "38cccdee6a484a702e4ac1a8b9a3cee0c4ed83f4",
    },
    {
        "name": "ComfyUI-segment-anything-2",
        "url": "https://github.com/kijai/ComfyUI-segment-anything-2.git",
        "sha": "0c35fff5f382803e2310103357b5e985f5437f32",
    },
    {
        "name": "ComfyUI-VideoHelperSuite",
        "url": "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git",
        "sha": "2984ec4c4b93292421888f38db74a5e8802a8ff8",
    },
]

SKIP_PREFIXES = (
    "torch",
    "torchvision",
    "torchaudio",
    "triton",
    "xformers",
    "flash-attn",
    "flash_attn",
    "bitsandbytes",
    "cupy",
    "nvidia-",
    "nvidia_",
    "cuda-",
    "cuda_",
)


def run(*args: str, cwd: Path | None = None) -> None:
    print(f"[image-build] run: {' '.join(args)}")
    subprocess.run(args, cwd=str(cwd) if cwd else None, check=True)


def clone_repo(entry: dict[str, str], custom_nodes_dir: Path) -> Path:
    target = custom_nodes_dir / entry["name"]
    if target.exists():
        shutil.rmtree(target)

    run("git", "clone", entry["url"], str(target))
    run("git", "checkout", entry["sha"], cwd=target)
    run("git", "submodule", "update", "--init", "--recursive", cwd=target)
    git_dir = target / ".git"
    if git_dir.exists():
        shutil.rmtree(git_dir, ignore_errors=True)
    return target


def install_filtered_requirements(plugin_dir: Path) -> None:
    requirements = plugin_dir / "requirements.txt"
    if not requirements.exists():
        return

    keep: list[str] = []
    for raw in requirements.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        normalized = re.split(r"[<>=!~\[\s]", line, maxsplit=1)[0].lower()
        if normalized.startswith(SKIP_PREFIXES):
            print(f"[image-build] skip heavy requirement: {line}")
            continue
        keep.append(line)

    if not keep:
        print(f"[image-build] no lightweight requirements for {plugin_dir.name}")
        return

    run("python3", "-m", "pip", "install", "--upgrade-strategy", "only-if-needed", *keep)


def main() -> None:
    comfy_root = Path(os.environ.get("COMFY_ROOT", "/workspace/ComfyUI"))
    custom_nodes_dir = comfy_root / "custom_nodes"
    custom_nodes_dir.mkdir(parents=True, exist_ok=True)

    for entry in REPOS:
        plugin_dir = clone_repo(entry, custom_nodes_dir)
        install_filtered_requirements(plugin_dir)

    print("[image-build] custom nodes installed")


if __name__ == "__main__":
    main()
