import argparse
import sys


def main():
    try:
        import numpy as np
        from PIL import Image
    except ImportError as exc:
        raise SystemExit(
            "缺少背景板依赖，请执行: .\\.venv-faster-whisper\\Scripts\\python.exe -m pip install pillow numpy"
        ) from exc

    parser = argparse.ArgumentParser(description="Build a median background plate from sampled frames.")
    parser.add_argument("--output", required=True)
    parser.add_argument("frames", nargs="+")
    args = parser.parse_args()

    images = []
    for frame_path in args.frames:
        image = Image.open(frame_path).convert("RGB")
        images.append(np.asarray(image, dtype=np.uint8))

    if not images:
        raise SystemExit("没有可用采样帧。")

    stack = np.stack(images, axis=0)
    median = np.median(stack, axis=0).astype(np.uint8)
    Image.fromarray(median, mode="RGB").save(args.output)
    sys.stdout.write(args.output)


if __name__ == "__main__":
    main()
