import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image


REQUIRED_RUNTIME_CLASSES = {
    "DWPreprocessor",
    "LTXAddVideoICLoRAGuide",
    "LTXVReferenceAudio",
    "LTXVAudioVAEEncode",
    "LTXVConcatAVLatent",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Check a local LTX2.3 matte-action prepare job.")
    parser.add_argument("--asset-manifest", required=True)
    parser.add_argument("--job-dir", required=True)
    return parser.parse_args()


def load_json(path):
    with Path(path).open("r", encoding="utf-8") as handle:
        return json.load(handle)


def collect_class_types(value, out):
    if isinstance(value, dict):
        class_type = value.get("class_type")
        if isinstance(class_type, str):
            out.add(class_type)
        for child in value.values():
            collect_class_types(child, out)
    elif isinstance(value, list):
        for child in value:
            collect_class_types(child, out)


def check_reference_video(path, expected, failures, warnings):
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        failures.append(f"reference video cannot be opened: {path}")
        return {}

    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)
    fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
    frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    matte_rgb = np.array(expected["matte_color_rgb"], dtype=np.int16)

    if width != int(expected["width"]) or height != int(expected["height"]):
        failures.append(f"reference video size mismatch: got {width}x{height}")
    if abs(fps - float(expected["fps"])) > 0.75:
        failures.append(f"reference video fps mismatch: got {fps:.3f}")
    if frame_count != int(expected["frame_count"]):
        failures.append(f"reference video frame count mismatch: got {frame_count}")

    indices = sorted({0, max(0, frame_count // 2), max(0, frame_count - 2)})
    matte_ratios = []
    non_matte_ratios = []
    for index in indices:
        cap.set(cv2.CAP_PROP_POS_FRAMES, index)
        ok, frame = cap.read()
        if not ok or frame is None:
            warnings.append(f"cannot read reference sample frame {index}")
            continue
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB).astype(np.int16)
        distance = np.abs(rgb - matte_rgb).max(axis=2)
        matte_ratio = float(np.mean(distance <= 14))
        matte_ratios.append(matte_ratio)
        non_matte_ratios.append(1.0 - matte_ratio)

    cap.release()

    matte_ratio_min = min(matte_ratios) if matte_ratios else 0.0
    non_matte_ratio_max = max(non_matte_ratios) if non_matte_ratios else 0.0
    if matte_ratio_min < 0.15:
        failures.append(f"reference video has too little clean matte background: min={matte_ratio_min:.3f}")
    if non_matte_ratio_max < 0.05:
        failures.append(f"reference video appears nearly empty: max_non_matte={non_matte_ratio_max:.3f}")

    return {
        "width": width,
        "height": height,
        "fps": fps,
        "frame_count": frame_count,
        "matte_ratio_min": matte_ratio_min,
        "non_matte_ratio_max": non_matte_ratio_max,
    }


def check_anchor(path, expected, failures):
    try:
        image = Image.open(path)
    except Exception as exc:
        failures.append(f"anchor image cannot be opened: {path}: {exc}")
        return {}

    if image.size != (int(expected["width"]), int(expected["height"])):
        failures.append(f"anchor image size mismatch: got {image.size}")
    if image.mode != "RGB":
        failures.append(f"anchor image mode mismatch: got {image.mode}")
    return {"width": image.size[0], "height": image.size[1], "mode": image.mode}


def main():
    args = parse_args()
    asset_manifest_path = Path(args.asset_manifest).resolve()
    job_dir = Path(args.job_dir).resolve()
    failures = []
    warnings = []

    asset_manifest = load_json(asset_manifest_path)
    manifest = load_json(job_dir / "manifest.json")
    metadata = load_json(job_dir / "workflow_runtime.metadata.json")
    runtime = load_json(job_dir / "workflow_runtime.json")

    method = str(asset_manifest.get("method", ""))
    segmentation = asset_manifest.get("segmentation", {})
    if method.startswith("fallback_") or not segmentation.get("real_backend", False):
        failures.append(f"segmentation backend is not production-grade: {method}")

    artifacts = asset_manifest.get("artifacts", {})
    output = asset_manifest.get("output", {})
    reference_video = Path(artifacts.get("reference_video", ""))
    anchor_png = Path(artifacts.get("anchor_png", ""))
    contact_sheet = Path(artifacts.get("reference_contact_sheet", ""))

    for label, path in {
        "reference_video": reference_video,
        "anchor_png": anchor_png,
        "reference_contact_sheet": contact_sheet,
        "background_prompt": Path(artifacts.get("background_prompt", "")),
        "positive_prompt": Path(artifacts.get("positive_prompt", "")),
    }.items():
        if not path.exists():
            failures.append(f"missing {label}: {path}")

    reference_summary = check_reference_video(reference_video, output, failures, warnings) if reference_video.exists() else {}
    anchor_summary = check_anchor(anchor_png, output, failures) if anchor_png.exists() else {}

    if metadata.get("mode") != "action_mimic":
        failures.append(f"metadata mode is not action_mimic: {metadata.get('mode')}")
    if int(metadata.get("action_guide_node_count") or 0) < 1:
        failures.append("runtime metadata has no LTXAddVideoICLoRAGuide node")
    if metadata.get("input_reference_video_name") != "reference_video.mp4":
        failures.append("runtime metadata does not use staged reference_video.mp4")
    if metadata.get("input_audio_name") != "speech.wav":
        failures.append("runtime metadata does not use staged speech.wav")
    if int(metadata.get("frame_count") or 0) != int(output.get("frame_count") or -1):
        failures.append("runtime metadata frame_count does not match asset manifest")
    if int(metadata.get("output_width") or 0) != int(output.get("width") or -1):
        failures.append("runtime metadata output_width does not match asset manifest")
    if int(metadata.get("output_height") or 0) != int(output.get("height") or -1):
        failures.append("runtime metadata output_height does not match asset manifest")

    positive_prompt = str(asset_manifest.get("positive_prompt", ""))
    if "clean matte reference video" not in positive_prompt:
        failures.append("positive prompt does not describe the clean matte reference constraint")
    if "not for background" not in positive_prompt or "not for background, text, logos, or identity" not in positive_prompt:
        failures.append("positive prompt does not block reference background/text/identity leakage")
    if "no subtitles" not in positive_prompt or "no logos" not in positive_prompt:
        failures.append("positive prompt is missing text/logo guardrails")

    runtime_classes = set()
    collect_class_types(runtime, runtime_classes)
    missing_classes = sorted(REQUIRED_RUNTIME_CLASSES - runtime_classes)
    if missing_classes:
        failures.append("runtime workflow is missing classes: " + ", ".join(missing_classes))

    staged_reference = Path(manifest["local"]["input_reference_video"])
    staged_audio = Path(manifest["local"]["input_audio"])
    staged_anchor = Path(manifest["local"]["input_image"])
    for label, path in {
        "staged_reference": staged_reference,
        "staged_audio": staged_audio,
        "staged_anchor": staged_anchor,
    }.items():
        if not path.exists():
            failures.append(f"missing {label}: {path}")

    summary = {
        "status": "fail" if failures else "pass",
        "asset_manifest": str(asset_manifest_path),
        "job_dir": str(job_dir),
        "method": method,
        "reference_video": reference_summary,
        "anchor": anchor_summary,
        "runtime_required_classes_present": sorted(REQUIRED_RUNTIME_CLASSES & runtime_classes),
        "warnings": warnings,
        "failures": failures,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
