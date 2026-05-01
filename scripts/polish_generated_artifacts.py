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
        "缺少依赖，请先安装 opencv-python pillow numpy，例如: "
        "D:\\code\\YuYan\\python\\python.exe -m pip install opencv-python pillow numpy"
    ) from exc


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from analyze_reference_overlay_risk import resolve_ffmpeg  # noqa: E402


FFPROBE_CANDIDATES = (
    Path(r"D:\code\KuangJia\ffmpeg\ffprobe.exe"),
    Path(r"D:\code\KuangJia\ffmpeg\bin\ffprobe.exe"),
    Path("node_modules/ffprobe-static/bin/win32/x64/ffprobe.exe"),
)


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "生成后成片一条龙精修：风险检测 -> 小红点/小色块局部修复 -> 重新复检。"
        )
    )
    parser.add_argument("--video", required=True, help="待精修的生成视频")
    parser.add_argument("--output-video", required=True, help="精修后输出 mp4")
    parser.add_argument("--output-dir", required=True, help="报告、拼图、临时结果目录")
    parser.add_argument("--ffmpeg", help="ffmpeg.exe 路径")
    parser.add_argument("--ffprobe", help="ffprobe.exe 路径")
    parser.add_argument("--sample-interval", type=float, default=0.25, help="风险检测抽帧间隔")
    parser.add_argument("--segment-seconds", type=float, default=30.0, help="报告里的分段秒数")
    parser.add_argument("--min-window-score", type=float, default=1.8, help="参与修复的最低窗口分数")
    parser.add_argument("--window-padding", type=float, default=0.18, help="修复窗口前后补偿秒数")
    parser.add_argument(
        "--persistent-ratio",
        type=float,
        default=0.055,
        help="同位置红色块出现比例超过该值时视为鞋/唇等常驻元素并保留",
    )
    parser.add_argument("--max-repair-windows", type=int, default=20, help="最多修复多少个窗口")
    parser.add_argument(
        "--repair-all-window-red",
        action="store_true",
        help="实验选项：修复窗口内所有非持久红色组件。默认只修检测报告里的红色候选框。",
    )
    parser.add_argument(
        "--max-skin-overlap",
        type=float,
        default=0.55,
        help="红色组件本身被判为皮肤的比例超过该值时跳过，避免误修手、脸、嘴唇。",
    )
    parser.add_argument(
        "--target-frame-padding",
        type=int,
        default=2,
        help="每个检测目标前后额外补修的帧数，用于覆盖不足 1 秒的短时红点边缘漏帧。",
    )
    parser.add_argument("--keep-work", action="store_true", help="保留抽帧临时目录")
    return parser.parse_args()


def resolve_ffprobe(explicit_path):
    candidates = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    which = shutil.which("ffprobe")
    if which:
        candidates.append(Path(which))
    candidates.extend(FFPROBE_CANDIDATES)
    for candidate in candidates:
        if candidate and candidate.is_file():
            return str(candidate.resolve())
    raise SystemExit("找不到 ffprobe.exe，请用 --ffprobe 指定。")


def run_command(command):
    subprocess.run(command, check=True)


def read_video_info(ffprobe_path, video_path):
    payload = json.loads(
        subprocess.check_output(
            [
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
            ],
            text=True,
            encoding="utf-8",
        )
    )
    stream = payload["streams"][0]
    rate = stream.get("avg_frame_rate") or stream.get("r_frame_rate") or "16/1"
    numerator, denominator = rate.split("/")
    fps = float(numerator) / float(denominator or 1)
    duration = float(payload.get("format", {}).get("duration") or 0)
    nb_frames = stream.get("nb_frames")
    return {
        "width": int(stream["width"]),
        "height": int(stream["height"]),
        "fps": fps,
        "duration": duration,
        "nb_frames": int(nb_frames) if str(nb_frames).isdigit() else None,
    }


def ensure_empty_dir(path, allowed_root):
    path = path.resolve()
    allowed_root = allowed_root.resolve()
    if path == allowed_root or allowed_root not in path.parents:
        raise SystemExit(f"拒绝清理非工作目录: {path}")
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def run_detector(video_path, output_dir, ffmpeg_path, sample_interval, segment_seconds):
    analyzer = SCRIPT_DIR / "analyze_generated_artifact_risk.py"
    command = [
        sys.executable,
        str(analyzer),
        "--video",
        str(video_path),
        "--output-dir",
        str(output_dir),
        "--ffmpeg",
        str(ffmpeg_path),
        "--sample-interval",
        f"{sample_interval:.6f}",
        "--segment-seconds",
        f"{segment_seconds:.6f}",
    ]
    run_command(command)
    report_path = output_dir / "generated-artifact-report.json"
    if not report_path.is_file():
        raise SystemExit(f"检测报告不存在: {report_path}")
    return json.loads(report_path.read_text(encoding="utf-8"))


def extract_frames(ffmpeg_path, video_path, frames_dir):
    pattern = str(frames_dir / "frame_%06d.png")
    run_command(
        [
            ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(video_path),
            "-vsync",
            "0",
            pattern,
        ]
    )
    frames = sorted(frames_dir.glob("frame_*.png"))
    if not frames:
        raise SystemExit("ffmpeg 没有抽出任何帧。")
    return frames


def encode_with_audio(ffmpeg_path, frames_dir, source_video, output_video, fps):
    output_video.parent.mkdir(parents=True, exist_ok=True)
    run_command(
        [
            ffmpeg_path,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-framerate",
            f"{fps:.8f}",
            "-i",
            str(frames_dir / "frame_%06d.png"),
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
            "copy",
            "-shortest",
            "-movflags",
            "+faststart",
            str(output_video),
        ]
    )


def level_rank(level):
    return {"none": 0, "low": 1, "medium": 2, "high": 3}.get(str(level), 0)


def select_windows(report, min_score, padding, duration, max_windows):
    selected = []
    for window in report.get("windows", []):
        if float(window.get("max_score", 0.0)) < min_score:
            continue
        reasons = set(window.get("reasons", []))
        if not any("red" in reason or "ui_color" in reason for reason in reasons):
            continue
        start = max(0.0, float(window["start_seconds"]) - padding)
        end = min(duration, float(window["end_seconds"]) + padding) if duration else float(window["end_seconds"]) + padding
        if end <= start:
            continue
        selected.append(
            {
                "start_seconds": round(start, 3),
                "end_seconds": round(end, 3),
                "max_score": float(window.get("max_score", 0.0)),
                "level": window.get("level", "medium"),
                "reasons": window.get("reasons", []),
                "max_frame": window.get("max_frame"),
            }
        )
    selected.sort(key=lambda item: (-item["max_score"], item["start_seconds"]))
    return selected[:max_windows]


def active_window(windows, time_seconds):
    matches = [item for item in windows if item["start_seconds"] <= time_seconds <= item["end_seconds"]]
    if not matches:
        return None
    return max(matches, key=lambda item: item["max_score"])


def bbox_iou(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    ix1 = max(ax1, bx1)
    iy1 = max(ay1, by1)
    ix2 = min(ax2, bx2)
    iy2 = min(ay2, by2)
    if ix2 <= ix1 or iy2 <= iy1:
        return 0.0
    intersection = (ix2 - ix1) * (iy2 - iy1)
    area_a = max(0.0, (ax2 - ax1) * (ay2 - ay1))
    area_b = max(0.0, (bx2 - bx1) * (by2 - by1))
    return intersection / max(area_a + area_b - intersection, 1e-9)


def center_distance(a, b):
    ax1, ay1, ax2, ay2 = a
    bx1, by1, bx2, by2 = b
    acx = (ax1 + ax2) / 2
    acy = (ay1 + ay2) / 2
    bcx = (bx1 + bx2) / 2
    bcy = (by1 + by2) / 2
    return math.hypot(acx - bcx, acy - bcy)


def bbox_center(bbox_norm):
    x1, y1, x2, y2 = bbox_norm
    return (x1 + x2) / 2, (y1 + y2) / 2


def component_is_safe_repair_candidate(component):
    bbox_norm = component.get("bbox_norm") or []
    if len(bbox_norm) != 4:
        return False
    x1, y1, x2, y2 = bbox_norm
    cx, cy = bbox_center(bbox_norm)
    area_ratio = float(component.get("area_ratio", 0.0))
    width_ratio = x2 - x1
    height_ratio = y2 - y1

    if area_ratio < 0.00008 or area_ratio > 0.012:
        return False
    if width_ratio > 0.22 or height_ratio > 0.20:
        return False
    if 0.33 <= cx <= 0.68 and 0.16 <= cy <= 0.45 and area_ratio < 0.006:
        return False
    if cy >= 0.86:
        return False
    return True


def build_frame_targets(report, selected_windows, fps, sample_interval, min_score, target_frame_padding):
    selected_ranges = [(item["start_seconds"], item["end_seconds"]) for item in selected_windows]
    targets_by_frame = {}
    targets = []

    def in_selected_window(time_seconds):
        return any(start <= time_seconds <= end for start, end in selected_ranges)

    for record in report.get("frames", []):
        time_seconds = float(record.get("time_seconds", 0.0))
        if float(record.get("score", 0.0)) < min_score:
            continue
        if selected_windows and not in_selected_window(time_seconds):
            continue
        for component in record.get("components", []):
            if component.get("label") != "red":
                continue
            if not component_is_safe_repair_candidate(component):
                continue
            frame_start = max(
                1,
                int(math.floor((time_seconds - sample_interval * 0.7) * fps)) + 1 - target_frame_padding,
            )
            frame_end = max(
                frame_start,
                int(math.ceil((time_seconds + sample_interval * 0.7) * fps)) + 1 + target_frame_padding,
            )
            target = {
                "time_seconds": round(time_seconds, 3),
                "frame_start": frame_start,
                "frame_end": frame_end,
                "bbox_norm": component["bbox_norm"],
                "area_ratio": component.get("area_ratio"),
                "source_frame": record.get("frame"),
                "score": record.get("score"),
            }
            targets.append(target)
            for frame_index in range(frame_start, frame_end + 1):
                targets_by_frame.setdefault(frame_index, []).append(target)
    return targets_by_frame, targets


def matches_target(component, targets):
    if not targets:
        return False
    bbox_norm = component.get("bbox_norm")
    for target in targets:
        target_bbox = target["bbox_norm"]
        if bbox_iou(bbox_norm, target_bbox) >= 0.05:
            return True
        if center_distance(bbox_norm, target_bbox) <= 0.055:
            return True
    return False


def red_mask(rgb):
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    return (((h <= 8) | (h >= 170)) & (s > 70) & (v > 70))


def component_key(component, width, height):
    x, y, w, h = component["bbox"]
    cx = (x + w / 2) / max(width, 1)
    cy = (y + h / 2) / max(height, 1)
    return f"red:{int(cx * 18):02d}:{int(cy * 18):02d}"


def red_components(rgb):
    height, width = rgb.shape[:2]
    frame_area = height * width
    mask = red_mask(rgb).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((2, 2), dtype=np.uint8))
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    components = []
    min_pixels = max(10, int(frame_area * 0.000035))
    max_pixels = int(frame_area * 0.016)
    for index in range(1, count):
        x = int(stats[index, cv2.CC_STAT_LEFT])
        y = int(stats[index, cv2.CC_STAT_TOP])
        w = int(stats[index, cv2.CC_STAT_WIDTH])
        h = int(stats[index, cv2.CC_STAT_HEIGHT])
        pixels = int(stats[index, cv2.CC_STAT_AREA])
        if pixels < min_pixels or pixels > max_pixels:
            continue
        if w / width > 0.24 or h / height > 0.22:
            continue
        component_mask = labels == index
        component = {
            "bbox": [x, y, w, h],
            "pixels": pixels,
            "area_ratio": pixels / frame_area,
            "bbox_norm": [
                round(x / width, 4),
                round(y / height, 4),
                round((x + w) / width, 4),
                round((y + h) / height, 4),
            ],
            "mask": component_mask,
        }
        component["key"] = component_key(component, width, height)
        components.append(component)
    components.sort(key=lambda item: item["pixels"], reverse=True)
    return components


def skin_mask(rgb):
    hsv = cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    ycrcb = cv2.cvtColor(rgb, cv2.COLOR_RGB2YCrCb)
    y = ycrcb[:, :, 0]
    cr = ycrcb[:, :, 1]
    cb = ycrcb[:, :, 2]
    r = rgb[:, :, 0]
    g = rgb[:, :, 1]
    b = rgb[:, :, 2]

    color_range = (
        (r > 80)
        & (g > 40)
        & (b > 25)
        & ((r.astype(np.int16) - g.astype(np.int16)) > 5)
        & (r > b)
        & (
            (
                np.maximum.reduce([r, g, b]).astype(np.int16)
                - np.minimum.reduce([r, g, b]).astype(np.int16)
            )
            > 15
        )
    )
    ycrcb_skin = (cr >= 132) & (cr <= 185) & (cb >= 75) & (cb <= 145) & (y > 45)
    hsv_skin = ((h <= 24) | (h >= 165)) & (s >= 20) & (s <= 180) & (v >= 70)
    return (color_range & ycrcb_skin) | (color_range & hsv_skin)


def component_skin_overlap(rgb, component):
    x, y, w, h = component["bbox"]
    if w <= 0 or h <= 0:
        return 0.0
    component_area = component["mask"][y : y + h, x : x + w]
    if not component_area.any():
        return 0.0
    skin_area = skin_mask(rgb)[y : y + h, x : x + w]
    return float((skin_area & component_area).sum()) / float(component_area.sum())


def preserve_component(rgb, component, persistent_keys, max_skin_overlap):
    x1, y1, x2, y2 = component["bbox_norm"]
    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2

    if component["key"] in persistent_keys:
        return "persistent_red_element"
    if component_skin_overlap(rgb, component) > max_skin_overlap:
        return "skin_like_red_region"
    if 0.33 <= cx <= 0.68 and 0.16 <= cy <= 0.45 and component["area_ratio"] < 0.006:
        return "face_or_lip_region"
    if cy >= 0.86:
        return "bottom_footwear_region"
    return None


def dilate(mask, radius):
    if radius <= 0:
        return mask
    kernel = np.ones((radius * 2 + 1, radius * 2 + 1), dtype=np.uint8)
    return cv2.dilate(mask.astype(np.uint8), kernel, iterations=1).astype(bool)


def repair_red_component(rgb, component):
    mask = dilate(component["mask"], 5)
    mask_u8 = mask.astype(np.uint8) * 255
    bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    repaired = cv2.inpaint(bgr, mask_u8, 3, cv2.INPAINT_TELEA)
    repaired = cv2.cvtColor(repaired, cv2.COLOR_BGR2RGB)

    # Feather the repaired patch to avoid a hard edge.
    alpha = cv2.GaussianBlur(mask_u8, (0, 0), 2.0).astype(np.float32) / 255.0
    alpha = np.clip(alpha[:, :, None], 0.0, 1.0)
    return (rgb.astype(np.float32) * (1.0 - alpha) + repaired.astype(np.float32) * alpha).astype(np.uint8)


def build_persistent_red_keys(frames, ratio):
    counts = {}
    for frame_path in frames:
        rgb = np.asarray(Image.open(frame_path).convert("RGB"))
        seen = set()
        for component in red_components(rgb):
            seen.add(component["key"])
        for key in seen:
            counts[key] = counts.get(key, 0) + 1
    min_count = max(6, math.ceil(len(frames) * ratio))
    return {key for key, count in counts.items() if count >= min_count}, counts, min_count


def make_before_after_sheet(records, raw_dir, clean_dir, output_path, max_items=24):
    if not records:
        return None
    font = ImageFont.load_default()
    selected = records[:max_items]
    tiles = []
    for record in selected:
        before = Image.open(raw_dir / record["frame"]).convert("RGB")
        after = Image.open(clean_dir / record["frame"]).convert("RGB")
        before.thumbnail((220, 220), Image.Resampling.LANCZOS)
        after.thumbnail((220, 220), Image.Resampling.LANCZOS)
        tile = Image.new("RGB", (before.width + after.width, max(before.height, after.height) + 34), (18, 18, 18))
        draw = ImageDraw.Draw(tile)
        draw.text((6, 9), f"{record['time_seconds']:.2f}s before | after", fill=(255, 255, 255), font=font)
        tile.paste(before, (0, 34))
        tile.paste(after, (before.width, 34))
        tiles.append(tile)

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


def write_summary(report, output_path):
    lines = [
        "# 成片自动精修报告",
        "",
        f"- 输入视频: `{report['input_video']}`",
        f"- 输出视频: `{report['output_video']}`",
        f"- 修复窗口: `{len(report['repair_windows'])}`",
        f"- 修复目标: `{report['repair_target_count']}`",
        f"- 触达帧数: `{report['frames_touched']}`",
        f"- 修复红色组件: `{report['repaired_component_count']}`",
        f"- 跳过组件: `{report['skipped_component_count']}`",
        f"- 前检风险窗口: `{report['before_risk_window_count']}`",
        f"- 后检风险窗口: `{report['after_risk_window_count']}`",
        "",
        "## 判断",
        "",
        report["decision"],
        "",
    ]
    if report["skip_reason_counts"]:
        lines.extend(["## 跳过原因", ""])
        for reason, count in sorted(report["skip_reason_counts"].items()):
            lines.append(f"- `{reason}`: `{count}`")
        lines.append("")
    if report["repair_windows"]:
        lines.extend(["## 修复窗口", ""])
        for window in report["repair_windows"]:
            lines.append(
                f"- `{window['start_seconds']:.2f}s-{window['end_seconds']:.2f}s` "
                f"score `{window['max_score']}` reasons `{','.join(window['reasons'])}`"
            )
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    video_path = Path(args.video).resolve()
    output_video = Path(args.output_video).resolve()
    output_dir = Path(args.output_dir).resolve()
    if not video_path.is_file():
        raise SystemExit(f"视频不存在: {video_path}")
    output_dir.mkdir(parents=True, exist_ok=True)

    ffmpeg_path = resolve_ffmpeg(args.ffmpeg)
    ffprobe_path = resolve_ffprobe(args.ffprobe)
    info = read_video_info(ffprobe_path, video_path)

    risk_before_dir = output_dir / "risk_before"
    risk_after_dir = output_dir / "risk_after"
    work_dir = output_dir / "work"
    raw_dir = work_dir / "frames_raw"
    clean_dir = work_dir / "frames_clean"
    ensure_empty_dir(raw_dir, output_dir)
    ensure_empty_dir(clean_dir, output_dir)

    before_report = run_detector(
        video_path,
        risk_before_dir,
        ffmpeg_path,
        args.sample_interval,
        args.segment_seconds,
    )
    repair_windows = select_windows(
        before_report,
        args.min_window_score,
        args.window_padding,
        info["duration"],
        args.max_repair_windows,
    )
    targets_by_frame, repair_targets = build_frame_targets(
        before_report,
        repair_windows,
        info["fps"],
        args.sample_interval,
        args.min_window_score,
        max(0, args.target_frame_padding),
    )

    frames = extract_frames(ffmpeg_path, video_path, raw_dir)
    persistent_keys, persistent_counts, persistent_min_count = build_persistent_red_keys(frames, args.persistent_ratio)

    repaired = []
    skipped = []
    frames_touched = 0
    for frame_index, frame_path in enumerate(frames, start=1):
        time_seconds = (frame_index - 1) / info["fps"]
        window = active_window(repair_windows, time_seconds)
        frame_targets = targets_by_frame.get(frame_index, [])
        rgb = np.asarray(Image.open(frame_path).convert("RGB"))
        out = rgb.copy()
        touched = False

        if window and (frame_targets or args.repair_all_window_red):
            for component in red_components(rgb):
                if not args.repair_all_window_red and not matches_target(component, frame_targets):
                    continue
                reason = preserve_component(rgb, component, persistent_keys, args.max_skin_overlap)
                record = {
                    "frame": frame_path.name,
                    "frame_index": frame_index,
                    "time_seconds": round(time_seconds, 3),
                    "bbox_norm": component["bbox_norm"],
                    "pixels": component["pixels"],
                    "area_ratio": round(component["area_ratio"], 6),
                    "key": component["key"],
                }
                if reason:
                    record["reason"] = reason
                    skipped.append(record)
                    continue
                out = repair_red_component(out, component)
                touched = True
                repaired.append(record)

        if touched:
            frames_touched += 1
        Image.fromarray(out).save(clean_dir / frame_path.name)

    encode_with_audio(ffmpeg_path, clean_dir, video_path, output_video, info["fps"])
    after_report = run_detector(
        output_video,
        risk_after_dir,
        ffmpeg_path,
        args.sample_interval,
        args.segment_seconds,
    )

    sheet_path = output_dir / "before-after-contact-sheet.jpg"
    make_before_after_sheet(repaired, raw_dir, clean_dir, sheet_path)
    skip_reason_counts = {}
    for record in skipped:
        reason = record.get("reason", "unknown")
        skip_reason_counts[reason] = skip_reason_counts.get(reason, 0) + 1

    decision = "未发现可自动修复的小红点/小色块，输出视频仅重新封装。"
    if repaired:
        decision = (
            "已执行本地小红点/小色块精修。请人工复查 before/after 拼图；"
            "若仍有手、脸、身体结构问题，不能本地硬修，应清理参考视频并重跑对应 30s 分段。"
        )

    polish_report = {
        "input_video": str(video_path),
        "output_video": str(output_video),
        "ffmpeg": ffmpeg_path,
        "ffprobe": ffprobe_path,
        "video_info": info,
        "risk_before_dir": str(risk_before_dir),
        "risk_after_dir": str(risk_after_dir),
        "repair_windows": repair_windows,
        "repair_target_count": len(repair_targets),
        "repair_targets_sample": repair_targets[:200],
        "repair_all_window_red": bool(args.repair_all_window_red),
        "persistent_ratio": args.persistent_ratio,
        "max_skin_overlap": args.max_skin_overlap,
        "target_frame_padding": max(0, args.target_frame_padding),
        "persistent_min_count": persistent_min_count,
        "persistent_red_keys": sorted(persistent_keys),
        "frames_touched": frames_touched,
        "repaired_component_count": len(repaired),
        "skipped_component_count": len(skipped),
        "skip_reason_counts": skip_reason_counts,
        "repaired_components_sample": repaired[:200],
        "skipped_components_sample": skipped[:120],
        "before_risk_window_count": len(before_report.get("windows", [])),
        "after_risk_window_count": len(after_report.get("windows", [])),
        "before_after_contact_sheet": str(sheet_path) if sheet_path.is_file() else None,
        "decision": decision,
    }
    report_path = output_dir / "polish-report.json"
    summary_path = output_dir / "polish-summary.md"
    report_path.write_text(json.dumps(polish_report, ensure_ascii=False, indent=2), encoding="utf-8")
    write_summary(polish_report, summary_path)

    if not args.keep_work:
        shutil.rmtree(work_dir, ignore_errors=True)

    print(f"精修输出: {output_video}")
    print(f"精修报告: {report_path}")
    print(f"精修汇总: {summary_path}")
    print(f"before/after: {sheet_path}")
    print(
        f"windows={len(repair_windows)} frames_touched={frames_touched} "
        f"targets={len(repair_targets)} repaired_components={len(repaired)} skipped_components={len(skipped)}"
    )


if __name__ == "__main__":
    main()
