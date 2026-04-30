import argparse
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path


try:
    import cv2
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
except ImportError as exc:
    raise SystemExit(
        "缺少依赖，请先安装 opencv-python pillow numpy，例如: D:\\code\\YuYan\\python\\python.exe -m pip install opencv-python pillow numpy"
    ) from exc


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from analyze_reference_overlay_risk import resolve_ffmpeg  # noqa: E402


REPO_FFPROBE_CANDIDATES = (
    Path("node_modules/ffprobe-static/bin/win32/x64/ffprobe.exe"),
    Path(r"D:\code\KuangJia\ffmpeg\ffprobe.exe"),
    Path(r"D:\code\KuangJia\ffmpeg\bin\ffprobe.exe"),
)

SENSITIVE_ROI_NORM = (0.18, 0.18, 0.82, 0.96)


def parse_args():
    parser = argparse.ArgumentParser(
        description="按参考视频污染风险报告，对字幕、红点、定位 pin、贴纸和横幅做保守局部清理。"
    )
    parser.add_argument("--video", required=True, help="原参考视频")
    parser.add_argument("--risk-report", required=True, help="analyze_reference_overlay_risk.py 输出的 overlay-risk-report.json")
    parser.add_argument("--output-video", required=True, help="清理后参考视频输出路径")
    parser.add_argument("--output-dir", required=True, help="报告和 before/after 拼图输出目录")
    parser.add_argument("--ffmpeg", help="ffmpeg.exe 路径")
    parser.add_argument("--ffprobe", help="ffprobe.exe 路径")
    parser.add_argument("--min-level", choices=("medium", "high"), default="medium", help="默认清理 medium/high 风险窗口")
    parser.add_argument("--window-padding", type=float, default=0.25, help="窗口前后补偿秒数，默认 0.25")
    parser.add_argument("--persistent-ratio", type=float, default=0.18, help="同位置颜色块出现比例超过该值时视为原始常驻元素")
    parser.add_argument("--max-sheet-items", type=int, default=24, help="before/after 拼图最多展示多少个时刻")
    parser.add_argument("--start-seconds", type=float, default=0.0, help="只处理该起点之后的视频，默认 0")
    parser.add_argument("--end-seconds", type=float, help="只处理到该时间点，默认处理到视频结尾")
    parser.add_argument("--keep-work", action="store_true", help="保留抽帧临时目录，默认清理")
    return parser.parse_args()


def resolve_ffprobe(explicit_path):
    candidates = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    which = shutil.which("ffprobe")
    if which:
        candidates.append(Path(which))
    candidates.extend(REPO_FFPROBE_CANDIDATES)

    for candidate in candidates:
        if candidate and candidate.is_file():
            return str(candidate.resolve())
    raise SystemExit("找不到 ffprobe.exe，请用 --ffprobe 指定路径。")


def run_command(command):
    subprocess.run(command, check=True)


def read_video_info(ffprobe_path, video_path):
    command = [
        ffprobe_path,
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height,avg_frame_rate,r_frame_rate,nb_frames",
        "-show_entries",
        "format=duration",
        "-of",
        "json",
        str(video_path),
    ]
    payload = json.loads(subprocess.check_output(command, text=True, encoding="utf-8"))
    stream = payload["streams"][0]
    rate = stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "16/1"
    numerator, denominator = rate.split("/")
    fps = float(numerator) / float(denominator or 1)
    duration = float(payload.get("format", {}).get("duration") or 0)
    return {
        "width": int(stream["width"]),
        "height": int(stream["height"]),
        "fps": fps,
        "duration": duration,
        "nb_frames": int(stream["nb_frames"]) if str(stream.get("nb_frames", "")).isdigit() else None,
    }


def ensure_empty_dir(path, allowed_root):
    path = path.resolve()
    allowed_root = allowed_root.resolve()
    if path == allowed_root or allowed_root not in path.parents:
        raise SystemExit(f"拒绝清理非工作目录: {path}")
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def extract_frames(ffmpeg_path, video_path, frames_dir, start_seconds=0.0, duration_seconds=None):
    frame_pattern = str(frames_dir / "frame_%06d.png")
    command = [ffmpeg_path, "-hide_banner", "-loglevel", "error", "-y"]
    if start_seconds > 0:
        command.extend(["-ss", f"{start_seconds:.6f}"])
    command.extend(["-i", str(video_path)])
    if duration_seconds is not None:
        command.extend(["-t", f"{duration_seconds:.6f}"])
    command.extend(["-vsync", "0", frame_pattern])
    run_command(command)
    frames = sorted(frames_dir.glob("frame_*.png"))
    if not frames:
        raise SystemExit("ffmpeg 没有抽出任何帧，请检查视频。")
    return frames


def encode_video(ffmpeg_path, clean_frames_dir, source_video, output_video, fps, start_seconds=0.0, duration_seconds=None):
    output_video.parent.mkdir(parents=True, exist_ok=True)
    frame_pattern = str(clean_frames_dir / "frame_%06d.png")
    command = [
        ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-framerate",
        f"{fps:.8f}",
        "-i",
        frame_pattern,
    ]
    if start_seconds > 0:
        command.extend(["-ss", f"{start_seconds:.6f}"])
    if duration_seconds is not None:
        command.extend(["-t", f"{duration_seconds:.6f}"])
    command.extend(
        [
            "-i",
            str(source_video),
            "-map",
            "0:v:0",
            "-map",
            "1:a?",
            "-c:v",
            "libx264",
            "-preset",
            "veryfast",
            "-crf",
            "18",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            "-movflags",
            "+faststart",
            str(output_video),
        ]
    )
    run_command(command)


def level_allowed(level, min_level):
    if min_level == "high":
        return level == "high"
    return level in ("medium", "high")


def load_plans(report_path, min_level, padding, duration):
    report = json.loads(Path(report_path).read_text(encoding="utf-8"))
    source = report.get("cleanup_plan") or report.get("windows") or []
    plans = []
    for item in source:
        if not level_allowed(str(item.get("level", "")), min_level):
            continue
        start = max(0.0, float(item["start_seconds"]) - padding)
        end = min(duration, float(item["end_seconds"]) + padding) if duration > 0 else float(item["end_seconds"]) + padding
        if end <= start:
            continue
        plans.append(
            {
                "start_seconds": round(start, 3),
                "end_seconds": round(end, 3),
                "level": item.get("level"),
                "max_score": item.get("max_score"),
                "reasons": item.get("reasons", []),
                "suggested_action": item.get("suggested_action", "auto_detect_and_clean"),
                "safety_level": item.get("safety_level", "unknown"),
                "needs_review": bool(item.get("needs_review")),
            }
        )
    plans.sort(key=lambda item: (item["start_seconds"], item["end_seconds"]))
    return report, plans


def intersects_norm(bbox_norm, roi_norm=SENSITIVE_ROI_NORM):
    x1, y1, x2, y2 = bbox_norm
    rx1, ry1, rx2, ry2 = roi_norm
    return x1 < rx2 and x2 > rx1 and y1 < ry2 and y2 > ry1


def bbox_norm_from_xy(x, y, width, height, image_width, image_height):
    return [
        round(x / image_width, 4),
        round(y / image_height, 4),
        round((x + width) / image_width, 4),
        round((y + height) / image_height, 4),
    ]


def component_key(label, bbox_norm):
    x1, y1, x2, y2 = bbox_norm
    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2
    return f"{label}:{int(cx * 14):02d}:{int(cy * 14):02d}"


def dilate_mask(mask, radius):
    if radius <= 0:
        return mask
    kernel = np.ones((radius * 2 + 1, radius * 2 + 1), dtype=np.uint8)
    return cv2.dilate(mask.astype(np.uint8), kernel, iterations=1).astype(bool)


def mask_components(mask, label, image_width, image_height, min_pixels):
    num_labels, _, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    components = []
    frame_area = image_width * image_height
    for component_index in range(1, num_labels):
        x = int(stats[component_index, cv2.CC_STAT_LEFT])
        y = int(stats[component_index, cv2.CC_STAT_TOP])
        width = int(stats[component_index, cv2.CC_STAT_WIDTH])
        height = int(stats[component_index, cv2.CC_STAT_HEIGHT])
        pixels = int(stats[component_index, cv2.CC_STAT_AREA])
        if pixels < min_pixels or width <= 1 or height <= 1:
            continue
        area_ratio = pixels / frame_area
        bbox_norm = bbox_norm_from_xy(x, y, width, height, image_width, image_height)
        components.append(
            {
                "label": label,
                "x": x,
                "y": y,
                "width": width,
                "height": height,
                "pixels": pixels,
                "area_ratio": area_ratio,
                "bbox_norm": bbox_norm,
            }
        )
    components.sort(key=lambda item: item["pixels"], reverse=True)
    return components


def detect_candidates(rgb):
    height, width = rgb.shape[:2]
    frame_area = width * height
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    min_pixels = max(8, int(frame_area * 0.00006))
    masks = {
        "red": (((h < 8) | (h > 170)) & (s > 75) & (v > 70)),
        "yellow": ((h >= 15) & (h <= 38) & (s > 70) & (v > 100)),
        "green": ((h >= 42) & (h <= 85) & (s > 85) & (v > 105)),
        "cyan": ((h >= 86) & (h <= 102) & (s > 90) & (v > 115)),
        "blue": ((h >= 96) & (h <= 138) & (s > 42) & (v > 82)),
        "magenta": ((h >= 135) & (h <= 170) & (s > 75) & (v > 90)),
    }

    candidates = []
    for label, mask in masks.items():
        for component in mask_components(mask, label, width, height, min_pixels)[:16]:
            area_ratio = component["area_ratio"]
            w_ratio = component["width"] / width
            h_ratio = component["height"] / height
            fill_ratio = component["pixels"] / max(1, component["width"] * component["height"])
            x1, y1, x2, y2 = component["bbox_norm"]
            cx = (x1 + x2) / 2

            if area_ratio > 0.035 or w_ratio > 0.62 or h_ratio > 0.42:
                continue
            if label in ("green", "cyan", "blue") and area_ratio < 0.0012:
                continue
            if label in ("green", "cyan", "blue") and fill_ratio < 0.12 and (w_ratio > 0.18 or h_ratio > 0.12):
                continue
            if label == "red" and y2 < 0.48 and 0.25 <= cx <= 0.75 and area_ratio < 0.003:
                component["skip_reason"] = "likely_face_or_lip_color"
                continue

            component_mask = np.zeros((height, width), dtype=bool)
            x = component["x"]
            y = component["y"]
            w = component["width"]
            hgt = component["height"]
            component_mask[y : y + hgt, x : x + w] = mask[y : y + hgt, x : x + w]
            near_sensitive = intersects_norm(component["bbox_norm"])
            component["near_sensitive_roi"] = near_sensitive
            component["mask"] = dilate_mask(component_mask, 5 if label == "red" else 7)
            component["key"] = component_key(label, component["bbox_norm"])
            candidates.append(component)

    text_masks = {
        "white_text_line": (s < 62) & (v > 188),
        "yellow_text_line": (h >= 15) & (h <= 38) & (s > 65) & (v > 110),
        "red_text_line": (((h < 8) | (h > 170)) & (s > 70) & (v > 75)),
        "blue_text_line": ((h >= 96) & (h <= 138) & (s > 42) & (v > 82)),
    }
    for label, mask in text_masks.items():
        candidates.extend(detect_text_line_candidates(mask, label, width, height))

    bottom_band = np.zeros((height, width), dtype=bool)
    bottom_band[int(height * 0.62) :, :] = True
    white_mask = (s < 62) & (v > 188) & bottom_band
    white_components = [
        item
        for item in mask_components(white_mask, "white_subtitle", width, height, max(5, int(frame_area * 0.000035)))
        if item["y"] >= int(height * 0.70)
        and item["area_ratio"] < 0.006
        and item["width"] / width <= 0.26
        and item["height"] / height <= 0.06
        and item["x"] > int(width * 0.025)
        and item["x"] + item["width"] < int(width * 0.975)
    ]
    if len(white_components) >= 3:
        x1 = min(item["x"] for item in white_components)
        y1 = min(item["y"] for item in white_components)
        x2 = max(item["x"] + item["width"] for item in white_components)
        y2 = max(item["y"] + item["height"] for item in white_components)
        x_span = (x2 - x1) / width
        y_span = (y2 - y1) / height
        total_pixels = sum(item["pixels"] for item in white_components)
        if (
            x_span >= 0.18
            and x_span <= 0.82
            and y_span <= 0.11
            and x1 > int(width * 0.055)
            and x2 < int(width * 0.945)
            and total_pixels / frame_area >= 0.0012
        ):
            grouped_mask = np.zeros((height, width), dtype=bool)
            for item in white_components:
                x = item["x"]
                y = item["y"]
                w = item["width"]
                hgt = item["height"]
                grouped_mask[y : y + hgt, x : x + w] |= white_mask[y : y + hgt, x : x + w]
            bbox_norm = bbox_norm_from_xy(x1, y1, x2 - x1, y2 - y1, width, height)
            candidates.append(
                {
                    "label": "white_subtitle",
                    "x": x1,
                    "y": y1,
                    "width": x2 - x1,
                    "height": y2 - y1,
                    "pixels": int(total_pixels),
                    "area_ratio": total_pixels / frame_area,
                    "bbox_norm": bbox_norm,
                    "near_sensitive_roi": intersects_norm(bbox_norm),
                    "mask": dilate_mask(grouped_mask, 4),
                    "key": component_key("white_subtitle", bbox_norm),
                }
            )

    candidates.sort(key=lambda item: item["area_ratio"], reverse=True)
    return candidates


def detect_text_line_candidates(mask, label, image_width, image_height):
    frame_area = image_width * image_height
    components = mask_components(mask, label, image_width, image_height, max(5, int(frame_area * 0.000025)))
    glyphs = []
    for item in components:
        area_ratio = item["area_ratio"]
        width_ratio = item["width"] / image_width
        height_ratio = item["height"] / image_height
        fill_ratio = item["pixels"] / max(1, item["width"] * item["height"])
        if area_ratio > 0.018 or width_ratio > 0.35 or height_ratio > 0.16:
            continue
        if area_ratio < 0.000025:
            continue
        if fill_ratio < 0.08:
            continue
        # Ignore tiny facial highlights; the text-line grouping below will still catch real overlay text.
        x1, y1, x2, y2 = item["bbox_norm"]
        cx = (x1 + x2) / 2
        cy = (y1 + y2) / 2
        if 0.34 <= cx <= 0.66 and 0.18 <= cy <= 0.46 and area_ratio < 0.0012:
            continue
        glyphs.append(item)

    if not glyphs:
        return []

    bands = {}
    for item in glyphs:
        _, y1, _, y2 = item["bbox_norm"]
        cy = (y1 + y2) / 2
        key = int(cy * 28)
        bands.setdefault(key, []).append(item)

    candidates = []
    for band_key, items in bands.items():
        if len(items) < 3:
            continue
        x1 = min(item["x"] for item in items)
        y1 = min(item["y"] for item in items)
        x2 = max(item["x"] + item["width"] for item in items)
        y2 = max(item["y"] + item["height"] for item in items)
        span_ratio = (x2 - x1) / image_width
        height_ratio = (y2 - y1) / image_height
        total_pixels = sum(item["pixels"] for item in items)
        if span_ratio < 0.12 and len(items) < 5:
            continue
        if height_ratio > 0.18:
            continue
        if total_pixels / frame_area < 0.00045:
            continue
        cy = ((y1 + y2) / 2) / image_height
        touches_edge = x1 <= int(image_width * 0.015) or x2 >= int(image_width * 0.985)
        if label == "white_text_line":
            if touches_edge and cy >= 0.38:
                continue
            if 0.42 <= cy <= 0.70 and span_ratio >= 0.42:
                continue
            if cy >= 0.42 and total_pixels / frame_area > 0.012:
                continue
        if label in ("blue_text_line", "cyan_text_line") and cy >= 0.42:
            continue

        line_mask = np.zeros((image_height, image_width), dtype=bool)
        for item in items:
            gx = item["x"]
            gy = item["y"]
            gw = item["width"]
            gh = item["height"]
            line_mask[gy : gy + gh, gx : gx + gw] |= mask[gy : gy + gh, gx : gx + gw]
        # Expand enough to include dark text outlines and sticker borders, while still avoiding full bbox fill.
        line_mask = dilate_mask(line_mask, 4)
        bbox_norm = bbox_norm_from_xy(x1, y1, x2 - x1, y2 - y1, image_width, image_height)
        candidates.append(
            {
                "label": label,
                "x": x1,
                "y": y1,
                "width": x2 - x1,
                "height": y2 - y1,
                "pixels": int(total_pixels),
                "area_ratio": total_pixels / frame_area,
                "bbox_norm": bbox_norm,
                "near_sensitive_roi": intersects_norm(bbox_norm),
                "mask": line_mask,
                "key": component_key(label, bbox_norm),
                "text_band_key": band_key,
            }
        )

    candidates.sort(key=lambda item: item["area_ratio"], reverse=True)
    return candidates[:8]


def plan_for_time(plans, time_seconds):
    matches = [plan for plan in plans if plan["start_seconds"] <= time_seconds <= plan["end_seconds"]]
    if not matches:
        return None
    return max(matches, key=lambda item: item.get("max_score") or 0)


def apply_desaturate_blur(rgb, mask):
    mask = dilate_mask(mask, 2)
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    hsv[:, :, 1][mask] = (hsv[:, :, 1][mask].astype(np.float32) * 0.18).astype(np.uint8)
    desaturated = cv2.cvtColor(hsv, cv2.COLOR_HSV2RGB)
    blurred = cv2.GaussianBlur(desaturated, (0, 0), 2.0)
    out = rgb.copy()
    out[mask] = (desaturated[mask].astype(np.float32) * 0.7 + blurred[mask].astype(np.float32) * 0.3).astype(np.uint8)
    return out


def apply_blur(rgb, mask):
    mask = dilate_mask(mask, 3)
    blurred = cv2.GaussianBlur(rgb, (0, 0), 4.0)
    out = rgb.copy()
    out[mask] = blurred[mask]
    return out


def apply_inpaint(rgb, mask):
    mask_u8 = (dilate_mask(mask, 3).astype(np.uint8) * 255)
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    repaired = cv2.inpaint(bgr, mask_u8, 3, cv2.INPAINT_TELEA)
    return cv2.cvtColor(repaired, cv2.COLOR_BGR2RGB)


def apply_inpaint_then_desaturate(rgb, mask):
    expanded = dilate_mask(mask, 4)
    repaired = apply_inpaint(rgb, expanded)
    hsv = cv2.cvtColor(repaired, cv2.COLOR_RGB2HSV)
    hsv[:, :, 1][expanded] = (hsv[:, :, 1][expanded].astype(np.float32) * 0.28).astype(np.uint8)
    desaturated = cv2.cvtColor(hsv, cv2.COLOR_HSV2RGB)
    blurred = cv2.GaussianBlur(desaturated, (0, 0), 1.8)
    out = repaired.copy()
    out[expanded] = (desaturated[expanded].astype(np.float32) * 0.65 + blurred[expanded].astype(np.float32) * 0.35).astype(
        np.uint8
    )
    return out


def feather_mask(mask, radius=7):
    if not np.any(mask):
        return mask.astype(np.float32)
    alpha = mask.astype(np.float32)
    kernel_size = max(3, radius * 2 + 1)
    if kernel_size % 2 == 0:
        kernel_size += 1
    alpha = cv2.GaussianBlur(alpha, (kernel_size, kernel_size), radius / 2)
    return np.clip(alpha, 0.0, 1.0)


def blend_with_mask(rgb, replacement, mask, feather_radius=7, strength=1.0):
    alpha = feather_mask(mask, feather_radius)[:, :, None] * float(strength)
    out = rgb.astype(np.float32) * (1.0 - alpha) + replacement.astype(np.float32) * alpha
    return np.clip(out, 0, 255).astype(np.uint8)


def neutralized_blur(rgb, sigma=7.0, saturation_scale=0.08, value_shift=-4):
    blurred = cv2.GaussianBlur(rgb, (0, 0), sigma)
    hsv = cv2.cvtColor(blurred, cv2.COLOR_RGB2HSV).astype(np.float32)
    hsv[:, :, 1] *= saturation_scale
    hsv[:, :, 2] = np.clip(hsv[:, :, 2] + value_shift, 0, 255)
    return cv2.cvtColor(hsv.astype(np.uint8), cv2.COLOR_HSV2RGB)


def text_like_mask_in_bbox(candidate, rgb, pad_ratio=0.015, include_rectangles=True):
    height, width = rgb.shape[:2]
    x1, y1, x2, y2 = bbox_bounds_for_candidate(candidate, rgb.shape, pad_ratio=pad_ratio)
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    roi = np.zeros((height, width), dtype=bool)
    roi[y1:y2, x1:x2] = True
    bright_text = (s < 92) & (v > 166)
    saturated_ui = (s > 58) & (v > 82)
    warm_ui = (((h < 12) | (h > 168)) | ((h >= 14) & (h <= 42))) & (s > 46) & (v > 80)
    candidate_seed = roi & candidate["mask"]
    seed_neighborhood = dilate_mask(candidate_seed, 7)
    seed = candidate_seed | (roi & seed_neighborhood & (bright_text | saturated_ui | warm_ui))
    dark_outline = roi & (v < 118) & (s < 150) & dilate_mask(seed, 4)
    mask = seed | dark_outline
    if include_rectangles:
        white_rect = roi & (s < 82) & (v > 178)
        mask |= white_rect
    return dilate_mask(mask, 3)


def apply_masked_neutralize(
    rgb,
    mask,
    sigma=7.0,
    saturation_scale=0.08,
    feather_radius=8,
    strength=0.95,
    value_shift=-4,
):
    expanded = dilate_mask(mask, 2)
    replacement = neutralized_blur(rgb, sigma=sigma, saturation_scale=saturation_scale, value_shift=value_shift)
    return blend_with_mask(rgb, replacement, expanded, feather_radius=feather_radius, strength=strength)


def apply_bbox_neutralize(rgb, candidate, pad_ratio=0.02, sigma=9.0, saturation_scale=0.06):
    mask = bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=pad_ratio)
    return apply_masked_neutralize(
        rgb,
        mask,
        sigma=sigma,
        saturation_scale=saturation_scale,
        feather_radius=12,
        strength=0.88,
    )


def apply_inpaint_soft(rgb, mask, radius=3, feather_radius=8, strength=0.92):
    expanded = dilate_mask(mask, radius)
    repaired = apply_inpaint(rgb, expanded)
    return blend_with_mask(rgb, repaired, expanded, feather_radius=feather_radius, strength=strength)


def apply_masked_dim(rgb, mask, saturation_scale=0.12, value_scale=0.48, feather_radius=2, strength=0.92):
    expanded = dilate_mask(mask, 1)
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV).astype(np.float32)
    hsv[:, :, 1] *= saturation_scale
    hsv[:, :, 2] *= value_scale
    replacement = cv2.cvtColor(np.clip(hsv, 0, 255).astype(np.uint8), cv2.COLOR_HSV2RGB)
    return blend_with_mask(rgb, replacement, expanded, feather_radius=feather_radius, strength=strength)


def apply_connected_ring_fill(rgb, mask, min_pixels=30):
    out = rgb.copy()
    num_labels, _, stats, _ = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    height, width = rgb.shape[:2]
    for label_index in range(1, num_labels):
        x = int(stats[label_index, cv2.CC_STAT_LEFT])
        y = int(stats[label_index, cv2.CC_STAT_TOP])
        w = int(stats[label_index, cv2.CC_STAT_WIDTH])
        h = int(stats[label_index, cv2.CC_STAT_HEIGHT])
        pixels = int(stats[label_index, cv2.CC_STAT_AREA])
        if pixels < min_pixels or w < 3 or h < 3:
            continue
        pad_x = max(6, int(width * 0.025))
        pad_y = max(5, int(height * 0.012))
        x1 = max(0, x - pad_x)
        y1 = max(0, y - pad_y)
        x2 = min(width, x + w + pad_x)
        y2 = min(height, y + h + pad_y)
        ring_pad_x = max(8, int(width * 0.045))
        ring_pad_y = max(8, int(height * 0.028))
        rx1 = max(0, x1 - ring_pad_x)
        ry1 = max(0, y1 - ring_pad_y)
        rx2 = min(width, x2 + ring_pad_x)
        ry2 = min(height, y2 + ring_pad_y)
        ring = out[ry1:ry2, rx1:rx2]
        ring_mask = np.ones((ry2 - ry1, rx2 - rx1), dtype=bool)
        ring_mask[y1 - ry1 : y2 - ry1, x1 - rx1 : x2 - rx1] = False
        samples = ring[ring_mask]
        if samples.size == 0:
            continue
        fill_color = np.median(samples.reshape(-1, 3), axis=0).astype(np.uint8)
        replacement = out.copy()
        replacement[y1:y2, x1:x2] = fill_color
        bbox_mask = np.zeros((height, width), dtype=bool)
        bbox_mask[y1:y2, x1:x2] = True
        out = blend_with_mask(out, replacement, bbox_mask, feather_radius=10, strength=0.92)
    return out


def bbox_mask_for_candidate(candidate, shape, pad_ratio=0.018):
    height, width = shape[:2]
    if isinstance(pad_ratio, tuple):
        pad_x_ratio, pad_y_ratio = pad_ratio
    else:
        pad_x_ratio = pad_y_ratio = pad_ratio
    pad_x = max(4, int(width * pad_x_ratio))
    pad_y = max(4, int(height * pad_y_ratio))
    x1 = max(0, int(candidate["x"]) - pad_x)
    y1 = max(0, int(candidate["y"]) - pad_y)
    x2 = min(width, int(candidate["x"]) + int(candidate["width"]) + pad_x)
    y2 = min(height, int(candidate["y"]) + int(candidate["height"]) + pad_y)
    mask = np.zeros((height, width), dtype=bool)
    mask[y1:y2, x1:x2] = True
    return mask


def bbox_bounds_for_candidate(candidate, shape, pad_ratio=0.018):
    height, width = shape[:2]
    if isinstance(pad_ratio, tuple):
        pad_x_ratio, pad_y_ratio = pad_ratio
    else:
        pad_x_ratio = pad_y_ratio = pad_ratio
    pad_x = max(4, int(width * pad_x_ratio))
    pad_y = max(4, int(height * pad_y_ratio))
    x1 = max(0, int(candidate["x"]) - pad_x)
    y1 = max(0, int(candidate["y"]) - pad_y)
    x2 = min(width, int(candidate["x"]) + int(candidate["width"]) + pad_x)
    y2 = min(height, int(candidate["y"]) + int(candidate["height"]) + pad_y)
    return x1, y1, x2, y2


def apply_bbox_fill_from_ring(rgb, candidate, pad_ratio=0.05, ring_ratio=0.055):
    height, width = rgb.shape[:2]
    x1, y1, x2, y2 = bbox_bounds_for_candidate(candidate, rgb.shape, pad_ratio=pad_ratio)
    ring_pad_x = max(8, int(width * ring_ratio))
    ring_pad_y = max(8, int(height * ring_ratio))
    rx1 = max(0, x1 - ring_pad_x)
    ry1 = max(0, y1 - ring_pad_y)
    rx2 = min(width, x2 + ring_pad_x)
    ry2 = min(height, y2 + ring_pad_y)
    ring = rgb[ry1:ry2, rx1:rx2]
    ring_mask = np.ones((ry2 - ry1, rx2 - rx1), dtype=bool)
    ring_mask[y1 - ry1 : y2 - ry1, x1 - rx1 : x2 - rx1] = False
    samples = ring[ring_mask]
    if samples.size == 0:
        return apply_inpaint(rgb, bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=pad_ratio))
    fill_color = np.median(samples.reshape(-1, 3), axis=0).astype(np.uint8)
    out = rgb.copy()
    out[y1:y2, x1:x2] = fill_color
    blurred = cv2.GaussianBlur(out, (0, 0), 2.0)
    blend_mask = np.zeros((height, width), dtype=bool)
    blend_mask[y1:y2, x1:x2] = True
    out[blend_mask] = (out[blend_mask].astype(np.float32) * 0.55 + blurred[blend_mask].astype(np.float32) * 0.45).astype(
        np.uint8
    )
    return out


def expanded_overlay_mask(candidate, rgb, radius=8):
    base = candidate["mask"]
    expanded = dilate_mask(base, radius)
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    outline_or_text = expanded & ((v < 145) | ((s < 76) & (v > 170)) | base)
    return dilate_mask(outline_or_text, 2)


def clean_candidate(rgb, candidate):
    label = candidate["label"]
    near_sensitive = bool(candidate.get("near_sensitive_roi"))
    area_ratio = float(candidate["area_ratio"])
    mask = candidate["mask"]

    width_ratio = candidate["width"] / max(1, rgb.shape[1])
    height_ratio = candidate["height"] / max(1, rgb.shape[0])
    _, y1_norm, _, y2_norm = candidate["bbox_norm"]
    safe_upper_overlay = y2_norm <= 0.34
    likely_text_or_banner = (
        label in ("white_subtitle", "white_text_line", "yellow_text_line", "red_text_line", "blue_text_line")
        or width_ratio >= 0.12
        or area_ratio >= 0.0025
    )

    text_labels = ("white_subtitle", "white_text_line", "yellow_text_line", "red_text_line", "blue_text_line")

    if label in text_labels:
        text_mask = text_like_mask_in_bbox(
            candidate,
            rgb,
            pad_ratio=(0.012, 0.006) if near_sensitive else (0.018, 0.01),
            include_rectangles=True,
        )
        if near_sensitive and not safe_upper_overlay:
            return (
                apply_masked_neutralize(
                    rgb,
                    text_mask,
                    sigma=8.0,
                    saturation_scale=0.05,
                    feather_radius=10,
                    strength=0.96,
                ),
                "near_body_text_mask_neutralize",
                True,
            )
        if safe_upper_overlay:
            bbox_mask = bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=(0.05, 0.02))
            repaired = apply_inpaint_soft(rgb, bbox_mask | text_mask, radius=3, feather_radius=11, strength=0.9)
            return apply_masked_neutralize(repaired, text_mask, sigma=5.0, saturation_scale=0.04), "upper_text_soft_inpaint", near_sensitive
        return (
            apply_masked_neutralize(rgb, text_mask, sigma=9.0, saturation_scale=0.05, feather_radius=11),
            "background_text_mask_neutralize",
            near_sensitive,
        )
    if near_sensitive and likely_text_or_banner:
        if safe_upper_overlay:
            banner_mask = bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=(0.05, 0.025))
            return apply_inpaint_soft(rgb, banner_mask, radius=3, feather_radius=12, strength=0.9), "upper_overlay_soft_inpaint", True
        banner_mask = text_like_mask_in_bbox(candidate, rgb, pad_ratio=(0.014, 0.008), include_rectangles=True)
        return (
            apply_masked_neutralize(rgb, banner_mask, sigma=8.5, saturation_scale=0.05, feather_radius=10),
            "near_body_text_or_banner_neutralize",
            True,
        )
    if near_sensitive:
        return apply_desaturate_blur(rgb, mask), "conservative_desaturate_blur", True
    if label == "red":
        return apply_desaturate_blur(rgb, mask), "red_token_desaturate_blur", near_sensitive
    if label in ("yellow", "magenta") and not near_sensitive:
        return apply_inpaint(rgb, mask), "sticker_inpaint", False
    if not near_sensitive:
        return apply_blur(rgb, mask), "background_overlay_blur", False
    return apply_desaturate_blur(rgb, mask), "conservative_desaturate_blur", True


def candidate_cleaning_spec(rgb, candidate):
    label = candidate["label"]
    near_sensitive = bool(candidate.get("near_sensitive_roi"))
    area_ratio = float(candidate["area_ratio"])
    mask = candidate["mask"]
    width_ratio = candidate["width"] / max(1, rgb.shape[1])
    _, y1_norm, _, y2_norm = candidate["bbox_norm"]
    safe_upper_overlay = y2_norm <= 0.34
    text_labels = ("white_subtitle", "white_text_line", "yellow_text_line", "red_text_line", "blue_text_line")
    likely_text_or_banner = label in text_labels or (
        label in ("red", "yellow", "magenta") and (width_ratio >= 0.12 or area_ratio >= 0.0025)
    )

    if near_sensitive and label in ("blue", "cyan", "green") and not safe_upper_overlay:
        return np.zeros(rgb.shape[:2], dtype=bool), "near_body_blue_green_candidate_preserved", "skip", True

    if label in text_labels:
        text_mask = text_like_mask_in_bbox(
            candidate,
            rgb,
            pad_ratio=(0.012, 0.006) if near_sensitive else (0.018, 0.01),
            include_rectangles=True,
        )
        if near_sensitive and not safe_upper_overlay:
            if y1_norm < 0.68:
                return np.zeros(rgb.shape[:2], dtype=bool), "near_body_mid_text_needs_review_only", "skip", True
            return text_mask, "near_body_text_mask_dim", "dim_text", True
        if safe_upper_overlay:
            bbox_mask = bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=(0.05, 0.02))
            return bbox_mask | text_mask, "upper_text_soft_inpaint", "upper_soft_inpaint", near_sensitive
        return text_mask, "background_text_mask_neutralize", "neutralize", near_sensitive

    if near_sensitive and likely_text_or_banner:
        if safe_upper_overlay:
            banner_mask = bbox_mask_for_candidate(candidate, rgb.shape, pad_ratio=(0.05, 0.025))
            return banner_mask, "upper_overlay_soft_inpaint", "upper_soft_inpaint", True
        banner_mask = text_like_mask_in_bbox(candidate, rgb, pad_ratio=(0.014, 0.008), include_rectangles=True)
        return banner_mask, "near_body_text_or_banner_dim", "dim_text", True

    if near_sensitive:
        return mask, "conservative_desaturate_blur", "desaturate", True
    if label == "red":
        return mask, "red_token_desaturate_blur", "desaturate", False
    if label in ("yellow", "magenta"):
        return mask, "sticker_soft_inpaint", "soft_inpaint", False
    return mask, "background_overlay_blur", "blur", False


def merge_masks(mask_items):
    if not mask_items:
        return None
    merged = np.zeros_like(mask_items[0], dtype=bool)
    for mask in mask_items:
        merged |= mask
    return merged


def apply_frame_cleaning_specs(rgb, specs):
    if not specs:
        return rgb
    grouped = {}
    for spec in specs:
        grouped.setdefault(spec["group"], []).append(spec["mask"])

    out = rgb.copy()
    upper_mask = merge_masks(grouped.get("upper_soft_inpaint"))
    if upper_mask is not None and np.any(upper_mask):
        out = apply_connected_ring_fill(out, upper_mask)
        out = apply_inpaint_soft(out, upper_mask, radius=3, feather_radius=10, strength=0.82)
        out = apply_masked_neutralize(
            out,
            upper_mask,
            sigma=4.5,
            saturation_scale=0.04,
            feather_radius=7,
            strength=0.58,
            value_shift=-18,
        )

    soft_inpaint_mask = merge_masks(grouped.get("soft_inpaint"))
    if soft_inpaint_mask is not None and np.any(soft_inpaint_mask):
        out = apply_inpaint_soft(out, soft_inpaint_mask, radius=3, feather_radius=8, strength=0.86)

    dim_text_mask = merge_masks(grouped.get("dim_text"))
    if dim_text_mask is not None and np.any(dim_text_mask):
        out = apply_masked_dim(out, dim_text_mask, saturation_scale=0.08, value_scale=0.42, feather_radius=2, strength=0.94)

    neutralize_mask = merge_masks(grouped.get("neutralize"))
    if neutralize_mask is not None and np.any(neutralize_mask):
        out = apply_masked_neutralize(
            out,
            neutralize_mask,
            sigma=5.5,
            saturation_scale=0.05,
            feather_radius=4,
            strength=0.92,
            value_shift=-34,
        )

    desaturate_mask = merge_masks(grouped.get("desaturate"))
    if desaturate_mask is not None and np.any(desaturate_mask):
        out = apply_desaturate_blur(out, desaturate_mask)

    blur_mask = merge_masks(grouped.get("blur"))
    if blur_mask is not None and np.any(blur_mask):
        out = apply_blur(out, blur_mask)

    return out


def preserve_persistent_candidate(candidate):
    label = candidate["label"]
    if label.endswith("_text_line") or label == "white_subtitle":
        return False
    if float(candidate.get("area_ratio", 0.0)) >= 0.006:
        return False
    return label in ("red", "yellow", "green", "cyan", "blue", "magenta")


def make_before_after_sheet(raw_dir, clean_dir, output_path, plans, fps, frame_count, max_items, start_seconds=0.0, end_seconds=None):
    if not plans:
        return None
    font = ImageFont.load_default()
    selected = []
    for plan in plans:
        plan_start = max(float(plan["start_seconds"]), start_seconds)
        plan_end = min(float(plan["end_seconds"]), end_seconds) if end_seconds is not None else float(plan["end_seconds"])
        if plan_end < start_seconds or plan_start > (end_seconds if end_seconds is not None else plan_end):
            continue
        duration = max(0.0, plan_end - plan_start)
        if duration <= 8:
            selected.extend([plan_start, (plan_start + plan_end) / 2])
        else:
            sample_count = min(10, max(3, int(math.ceil(duration / 8.0)) + 1))
            for sample_index in range(sample_count):
                ratio = sample_index / max(1, sample_count - 1)
                selected.append(plan_start + duration * ratio)
    deduped = []
    for value in selected:
        local_seconds = max(0.0, value - start_seconds)
        frame_index = max(1, min(frame_count, int(round(local_seconds * fps)) + 1))
        if frame_index not in deduped:
            deduped.append(frame_index)
        if len(deduped) >= max_items:
            break

    tiles = []
    for frame_index in deduped:
        name = f"frame_{frame_index:06d}.png"
        before_path = raw_dir / name
        after_path = clean_dir / name
        if not before_path.exists() or not after_path.exists():
            continue
        before = Image.open(before_path).convert("RGB")
        after = Image.open(after_path).convert("RGB")
        before.thumbnail((220, 220), Image.Resampling.LANCZOS)
        after.thumbnail((220, 220), Image.Resampling.LANCZOS)
        tile_width = before.width + after.width
        tile_height = max(before.height, after.height) + 34
        tile = Image.new("RGB", (tile_width, tile_height), (18, 18, 18))
        draw = ImageDraw.Draw(tile)
        time_seconds = start_seconds + (frame_index - 1) / fps
        draw.text((6, 9), f"{time_seconds:.2f}s before | after", fill=(255, 255, 255), font=font)
        tile.paste(before, (0, 34))
        tile.paste(after, (before.width, 34))
        tiles.append(tile)

    if not tiles:
        return None

    columns = 2
    margin = 10
    tile_width = max(tile.width for tile in tiles)
    tile_height = max(tile.height for tile in tiles)
    rows = math.ceil(len(tiles) / columns)
    sheet = Image.new(
        "RGB",
        (columns * tile_width + (columns + 1) * margin, rows * tile_height + (rows + 1) * margin),
        (240, 240, 240),
    )
    for index, tile in enumerate(tiles):
        row = index // columns
        col = index % columns
        sheet.paste(tile, (margin + col * (tile_width + margin), margin + row * (tile_height + margin)))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, quality=92)
    return output_path


def main():
    args = parse_args()
    video_path = Path(args.video).resolve()
    risk_report_path = Path(args.risk_report).resolve()
    output_video = Path(args.output_video).resolve()
    output_dir = Path(args.output_dir).resolve()
    if not video_path.is_file():
        raise SystemExit(f"参考视频不存在: {video_path}")
    if not risk_report_path.is_file():
        raise SystemExit(f"risk report 不存在: {risk_report_path}")

    output_dir.mkdir(parents=True, exist_ok=True)
    ffmpeg_path = resolve_ffmpeg(args.ffmpeg)
    ffprobe_path = resolve_ffprobe(args.ffprobe)
    info = read_video_info(ffprobe_path, video_path)
    sample_start = max(0.0, float(args.start_seconds or 0.0))
    sample_end = float(args.end_seconds) if args.end_seconds is not None else float(info["duration"] or 0.0)
    if info["duration"] > 0:
        sample_end = min(sample_end, float(info["duration"]))
    if sample_end <= sample_start:
        raise SystemExit("--end-seconds 必须大于 --start-seconds")
    sample_duration = sample_end - sample_start

    report_payload, plans = load_plans(risk_report_path, args.min_level, args.window_padding, info["duration"])
    work_dir = output_dir / "work"
    raw_dir = work_dir / "frames_raw"
    clean_dir = work_dir / "frames_clean"
    ensure_empty_dir(raw_dir, output_dir)
    ensure_empty_dir(clean_dir, output_dir)

    frames = extract_frames(ffmpeg_path, video_path, raw_dir, sample_start, sample_duration)
    frame_count = len(frames)

    all_candidate_counts = {}
    for frame_path in frames:
        rgb = np.asarray(Image.open(frame_path).convert("RGB"))
        candidates = detect_candidates(rgb)
        for candidate in candidates:
            if candidate["label"] == "white_subtitle":
                continue
            key = candidate["key"]
            all_candidate_counts[key] = all_candidate_counts.get(key, 0) + 1

    persistent_min_count = max(8, math.ceil(frame_count * args.persistent_ratio))
    persistent_keys = {key for key, count in all_candidate_counts.items() if count >= persistent_min_count}

    actions = {}
    safety_counts = {"auto": 0, "conservative": 0, "needs_review": 0}
    cleaned_candidates = []
    skipped_candidates = []
    frames_touched = 0

    for frame_index, frame_path in enumerate(frames, start=1):
        time_seconds = sample_start + (frame_index - 1) / info["fps"]
        plan = plan_for_time(plans, time_seconds)
        rgb = np.asarray(Image.open(frame_path).convert("RGB"))
        out = rgb.copy()
        frame_touched = False

        if plan:
            frame_specs = []
            for candidate in detect_candidates(rgb):
                if candidate["key"] in persistent_keys and preserve_persistent_candidate(candidate):
                    skipped_candidates.append(
                        {
                            "frame_index": frame_index,
                            "time_seconds": round(time_seconds, 3),
                            "label": candidate["label"],
                            "bbox_norm": candidate["bbox_norm"],
                            "reason": "persistent_color_key_preserved",
                        }
                    )
                    continue

                mask, action, group, needs_review = candidate_cleaning_spec(rgb, candidate)
                if group == "skip":
                    skipped_candidates.append(
                        {
                            "frame_index": frame_index,
                            "time_seconds": round(time_seconds, 3),
                            "label": candidate["label"],
                            "bbox_norm": candidate["bbox_norm"],
                            "reason": action,
                        }
                    )
                    actions[action] = actions.get(action, 0) + 1
                    safety_counts["needs_review"] += 1
                    continue
                if not np.any(mask):
                    continue
                frame_specs.append({"mask": mask, "group": group, "action": action, "needs_review": needs_review})
                actions[action] = actions.get(action, 0) + 1
                if needs_review:
                    safety_counts["needs_review"] += 1
                elif candidate.get("near_sensitive_roi"):
                    safety_counts["conservative"] += 1
                else:
                    safety_counts["auto"] += 1
                cleaned_candidates.append(
                    {
                        "frame_index": frame_index,
                        "time_seconds": round(time_seconds, 3),
                        "label": candidate["label"],
                        "bbox_norm": candidate["bbox_norm"],
                        "action": action,
                        "near_sensitive_roi": bool(candidate.get("near_sensitive_roi")),
                        "plan_level": plan.get("level"),
                    }
                )
            if frame_specs:
                out = apply_frame_cleaning_specs(out, frame_specs)
                frame_touched = True

        if frame_touched:
            frames_touched += 1
        Image.fromarray(out).save(clean_dir / frame_path.name)

    encode_video(ffmpeg_path, clean_dir, video_path, output_video, info["fps"], sample_start, sample_duration)
    sheet_path = output_dir / "before-after-contact-sheet.jpg"
    make_before_after_sheet(
        raw_dir,
        clean_dir,
        sheet_path,
        plans,
        info["fps"],
        frame_count,
        args.max_sheet_items,
        sample_start,
        sample_end,
    )

    cleaning_report = {
        "input_video": str(video_path),
        "output_video": str(output_video),
        "risk_report": str(risk_report_path),
        "ffmpeg": ffmpeg_path,
        "ffprobe": ffprobe_path,
        "source_report_video": report_payload.get("video"),
        "video_info": info,
        "frame_count": frame_count,
        "processed_start_seconds": round(sample_start, 3),
        "processed_end_seconds": round(sample_end, 3),
        "processed_duration_seconds": round(sample_duration, 3),
        "min_level": args.min_level,
        "window_padding_seconds": args.window_padding,
        "windows_considered": plans,
        "persistent_ratio": args.persistent_ratio,
        "persistent_min_count": persistent_min_count,
        "persistent_keys_preserved": sorted(persistent_keys),
        "frames_touched": frames_touched,
        "actions": actions,
        "safety_counts": safety_counts,
        "cleaned_candidate_count": len(cleaned_candidates),
        "skipped_candidate_count": len(skipped_candidates),
        "cleaned_candidates_sample": cleaned_candidates[:200],
        "skipped_candidates_sample": skipped_candidates[:100],
        "before_after_contact_sheet": str(sheet_path) if sheet_path.exists() else None,
        "needs_review": any(plan.get("needs_review") for plan in plans) or safety_counts["needs_review"] > 0,
    }
    report_path = output_dir / "cleaning-report.json"
    report_path.write_text(json.dumps(cleaning_report, ensure_ascii=False, indent=2), encoding="utf-8")

    if not args.keep_work:
        shutil.rmtree(work_dir, ignore_errors=True)

    print(f"清理视频: {output_video}")
    print(f"清理报告: {report_path}")
    print(f"before/after 拼图: {sheet_path}")
    print(f"processed_range={sample_start:.3f}s-{sample_end:.3f}s")
    print(f"windows_considered={len(plans)} frames_touched={frames_touched} cleaned_candidates={len(cleaned_candidates)}")
    if cleaning_report["needs_review"]:
        print("needs_review=true")
    else:
        print("needs_review=false")


if __name__ == "__main__":
    main()
