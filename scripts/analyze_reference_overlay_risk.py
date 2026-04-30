import argparse
import csv
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path


try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
except ImportError as exc:
    raise SystemExit(
        "缺少依赖，请先安装 pillow numpy，例如: D:\\code\\YuYan\\python\\python.exe -m pip install pillow numpy"
    ) from exc


REPO_FFMPEG_CANDIDATES = (
    r"D:\code\KuangJia\ffmpeg\ffmpeg.exe",
    r"D:\code\KuangJia\ffmpeg\bin\ffmpeg.exe",
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="扫描 KJ 参考视频里的字幕、贴纸、红点、定位气泡等视觉污染风险。"
    )
    parser.add_argument("--video", required=True, help="参考视频路径")
    parser.add_argument("--output-dir", required=True, help="报告输出目录")
    parser.add_argument("--ffmpeg", help="ffmpeg.exe 路径，默认优先使用 PATH 和 D:\\code\\KuangJia\\ffmpeg")
    parser.add_argument("--sample-interval", type=float, default=0.5, help="抽帧间隔秒数，默认 0.5")
    parser.add_argument("--segment-seconds", type=float, default=30.0, help="分段秒数，用于报告定位，默认 30")
    parser.add_argument("--risk-threshold", type=float, default=3.0, help="进入风险窗口的分数阈值")
    parser.add_argument("--high-threshold", type=float, default=5.0, help="高风险窗口阈值")
    parser.add_argument("--max-sheet-frames", type=int, default=48, help="审查拼图最多放多少帧")
    return parser.parse_args()


def resolve_ffmpeg(explicit_path):
    candidates = []
    if explicit_path:
        candidates.append(explicit_path)
    which = shutil.which("ffmpeg")
    if which:
        candidates.append(which)
    candidates.extend(REPO_FFMPEG_CANDIDATES)

    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return str(Path(candidate))
    raise SystemExit("找不到 ffmpeg.exe，请用 --ffmpeg 指定路径。")


def run_ffmpeg_extract(ffmpeg_path, video_path, frames_dir, sample_interval):
    frames_dir.mkdir(parents=True, exist_ok=True)
    for old_frame in frames_dir.glob("frame_*.jpg"):
        old_frame.unlink()

    sample_fps = 1.0 / sample_interval
    frame_pattern = str(frames_dir / "frame_%06d.jpg")
    command = [
        ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(video_path),
        "-vf",
        f"fps={sample_fps:.6f}",
        "-q:v",
        "2",
        frame_pattern,
    ]
    subprocess.run(command, check=True)
    frames = sorted(frames_dir.glob("frame_*.jpg"))
    if not frames:
        raise SystemExit("ffmpeg 没有抽出任何帧，请检查视频路径。")
    return frames


def load_analysis_image(path, max_width=720):
    image = Image.open(path).convert("RGB")
    if image.width > max_width:
        height = max(1, round(image.height * max_width / image.width))
        image = image.resize((max_width, height), Image.Resampling.LANCZOS)
    return image


def connected_components(mask, min_pixels):
    height, width = mask.shape
    visited = np.zeros(mask.shape, dtype=bool)
    components = []

    for y in range(height):
        for x in range(width):
            if visited[y, x] or not mask[y, x]:
                continue

            stack = [(x, y)]
            visited[y, x] = True
            count = 0
            min_x = max_x = x
            min_y = max_y = y

            while stack:
                cx, cy = stack.pop()
                count += 1
                min_x = min(min_x, cx)
                max_x = max(max_x, cx)
                min_y = min(min_y, cy)
                max_y = max(max_y, cy)

                for nx, ny in (
                    (cx - 1, cy),
                    (cx + 1, cy),
                    (cx, cy - 1),
                    (cx, cy + 1),
                ):
                    if nx < 0 or ny < 0 or nx >= width or ny >= height:
                        continue
                    if visited[ny, nx] or not mask[ny, nx]:
                        continue
                    visited[ny, nx] = True
                    stack.append((nx, ny))

            if count >= min_pixels:
                components.append(
                    {
                        "pixels": int(count),
                        "bbox": [int(min_x), int(min_y), int(max_x + 1), int(max_y + 1)],
                    }
                )

    components.sort(key=lambda item: item["pixels"], reverse=True)
    return components


def intersects_roi(bbox, roi):
    x1, y1, x2, y2 = bbox
    rx1, ry1, rx2, ry2 = roi
    return x1 < rx2 and x2 > rx1 and y1 < ry2 and y2 > ry1


def bbox_to_norm(bbox, width, height):
    x1, y1, x2, y2 = bbox
    return [
        round(x1 / width, 4),
        round(y1 / height, 4),
        round(x2 / width, 4),
        round(y2 / height, 4),
    ]


def classify_cleanup_candidate(component):
    label = component["label"]
    near_body = bool(component["near_body_roi"])
    x1, y1, x2, y2 = component["bbox_norm"]
    width = x2 - x1
    height = y2 - y1
    area_ratio = component["area_ratio"]
    is_large = area_ratio >= 0.006 or width >= 0.22 or height >= 0.16

    if near_body and is_large:
        safety_level = "needs_review"
        action = "conservative_desaturate_or_manual_review"
    elif near_body:
        safety_level = "conservative"
        action = "desaturate_blur"
    elif label == "red":
        safety_level = "auto"
        action = "desaturate_blur"
    elif label in ("yellow", "magenta"):
        safety_level = "auto"
        action = "local_blur_or_fill"
    else:
        safety_level = "auto"
        action = "local_blur_if_ui_like"

    return {
        "label": label,
        "bbox_norm": component["bbox_norm"],
        "area_ratio": area_ratio,
        "near_body_roi": near_body,
        "safety_level": safety_level,
        "suggested_action": action,
    }


def analyze_frame(frame_path, time_seconds):
    image = load_analysis_image(frame_path)
    width, height = image.size
    hsv = np.asarray(image.convert("HSV"), dtype=np.uint8)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]

    # 蓝色光伏板和天空通常是合法背景，所以这里默认只抓更像贴纸/图标的颜色族。
    masks = {
        "red": (((h < 14) | (h > 240)) & (s > 80) & (v > 85)),
        "yellow": ((h >= 18) & (h <= 52) & (s > 75) & (v > 105)),
        "green": ((h >= 58) & (h <= 118) & (s > 85) & (v > 115)),
        "cyan": ((h >= 120) & (h <= 150) & (s > 90) & (v > 125)),
        "magenta": ((h >= 200) & (h <= 238) & (s > 80) & (v > 95)),
    }

    yy, xx = np.indices((height, width))
    x_norm = xx / max(width - 1, 1)
    y_norm = yy / max(height - 1, 1)
    body_roi_norm = (0.18, 0.18, 0.82, 0.96)
    bottom_subject_band = (
        (x_norm >= body_roi_norm[0])
        & (x_norm <= body_roi_norm[2])
        & (y_norm >= 0.54)
        & (y_norm <= 0.96)
    )

    white_text_mask = (s < 42) & (v > 205)
    white_bottom_ratio = float(np.count_nonzero(white_text_mask & bottom_subject_band) / (width * height))

    frame_area = width * height
    min_pixels = max(8, int(frame_area * 0.00008))
    components = []
    color_ratios = {}
    max_area_by_label = {}
    body_roi_px = (
        int(body_roi_norm[0] * width),
        int(body_roi_norm[1] * height),
        int(body_roi_norm[2] * width),
        int(body_roi_norm[3] * height),
    )

    for label, mask in masks.items():
        color_ratios[label] = float(np.count_nonzero(mask) / frame_area)
        label_components = connected_components(mask, min_pixels=min_pixels)[:8]
        max_area_by_label[label] = 0.0
        for component in label_components:
            area_ratio = component["pixels"] / frame_area
            bbox = component["bbox"]
            x1, y1, x2, y2 = bbox
            bbox_width_ratio = (x2 - x1) / width
            bbox_height_ratio = (y2 - y1) / height
            is_sky_or_background_blob = (
                area_ratio > 0.035
                or bbox_width_ratio > 0.58
                or bbox_height_ratio > 0.42
            )
            is_tiny_static_corner = (
                area_ratio < 0.00018
                and (x2 < width * 0.12 or x1 > width * 0.88 or y2 < height * 0.08 or y1 > height * 0.92)
            )
            if is_sky_or_background_blob or is_tiny_static_corner:
                continue

            max_area_by_label[label] = max(max_area_by_label[label], area_ratio)
            components.append(
                {
                    "label": label,
                    "area_ratio": round(area_ratio, 6),
                    "bbox_norm": bbox_to_norm(bbox, width, height),
                    "near_body_roi": intersects_roi(bbox, body_roi_px),
                }
            )

    components.sort(key=lambda item: item["area_ratio"], reverse=True)
    top_components = components[:10]

    score = 0.0
    reasons = []

    red_max = max_area_by_label.get("red", 0.0)
    warm_max = max(max_area_by_label.get("yellow", 0.0), max_area_by_label.get("magenta", 0.0))
    green_max = max(max_area_by_label.get("green", 0.0), max_area_by_label.get("cyan", 0.0))

    if red_max >= 0.00028:
        score += 2.2 + min(2.4, red_max * 450)
        reasons.append("red_icon_or_pin")
    if warm_max >= 0.0005:
        score += 1.3 + min(1.8, warm_max * 260)
        reasons.append("yellow_magenta_sticker")
    if green_max >= 0.0009:
        score += 0.8 + min(1.2, green_max * 180)
        reasons.append("green_cyan_sticker")
    if any(item["near_body_roi"] and item["area_ratio"] >= 0.00035 for item in top_components):
        score += 1.2
        reasons.append("overlay_near_body_area")
    if white_bottom_ratio >= 0.009:
        score += 0.55 + min(0.9, white_bottom_ratio * 35)
        reasons.append("bottom_subtitle_or_text")
    if len(top_components) >= 4 and score > 0:
        score += 0.5
        reasons.append("multiple_overlay_candidates")

    if score >= 5.0:
        level = "high"
    elif score >= 3.0:
        level = "medium"
    elif score > 0:
        level = "low"
    else:
        level = "none"

    cleanup_candidates = []
    for component in top_components:
        if component["area_ratio"] < 0.00028:
            continue
        cleanup_candidates.append(classify_cleanup_candidate(component))

    if white_bottom_ratio >= 0.009:
        cleanup_candidates.append(
            {
                "label": "white_subtitle",
                "bbox_norm": [0.12, 0.72, 0.88, 0.98],
                "area_ratio": round(white_bottom_ratio, 6),
                "near_body_roi": True,
                "safety_level": "conservative",
                "suggested_action": "bottom_subtitle_masked_blur_or_fill",
            }
        )

    return {
        "frame": frame_path.name,
        "time_seconds": round(time_seconds, 3),
        "score": round(score, 3),
        "level": level,
        "reasons": reasons,
        "metrics": {
            "color_ratios": {key: round(value, 6) for key, value in color_ratios.items()},
            "max_component_area_by_label": {
                key: round(value, 6) for key, value in max_area_by_label.items()
            },
            "white_bottom_ratio": round(white_bottom_ratio, 6),
        },
        "components": top_components,
        "cleanup_candidates": cleanup_candidates,
    }


def group_windows(frame_records, sample_interval, segment_seconds, risk_threshold, high_threshold):
    risky = [record for record in frame_records if record["score"] >= risk_threshold]
    windows = []
    current = None
    max_gap = max(sample_interval * 1.6, 0.8)

    for record in risky:
        if current is None or record["time_seconds"] - current["last_time"] > max_gap:
            if current:
                windows.append(finalize_window(current, sample_interval, segment_seconds, high_threshold))
            current = {
                "start": record["time_seconds"],
                "last_time": record["time_seconds"],
                "max_score": record["score"],
                "levels": {record["level"]},
                "reasons": set(record["reasons"]),
                "frames": [record],
            }
        else:
            current["last_time"] = record["time_seconds"]
            current["max_score"] = max(current["max_score"], record["score"])
            current["levels"].add(record["level"])
            current["reasons"].update(record["reasons"])
            current["frames"].append(record)

    if current:
        windows.append(finalize_window(current, sample_interval, segment_seconds, high_threshold))

    windows.sort(key=lambda item: (-item["max_score"], item["start_seconds"]))
    return windows


def finalize_window(window, sample_interval, segment_seconds, high_threshold):
    start = max(0.0, window["start"] - sample_interval / 2)
    end = window["last_time"] + sample_interval / 2
    segment_index = int(math.floor(start / segment_seconds)) + 1 if segment_seconds > 0 else 1
    segment_end_index = int(math.floor(max(end - 0.001, 0) / segment_seconds)) + 1 if segment_seconds > 0 else 1
    local_start = start - (segment_index - 1) * segment_seconds
    local_end = end - (segment_end_index - 1) * segment_seconds
    max_frame = max(window["frames"], key=lambda item: item["score"])
    return {
        "start_seconds": round(start, 3),
        "end_seconds": round(end, 3),
        "segment_index": segment_index,
        "segment_start_index": segment_index,
        "segment_end_index": segment_end_index,
        "segment_local_start_seconds": round(local_start, 3),
        "segment_local_end_seconds": round(local_end, 3),
        "max_score": round(window["max_score"], 3),
        "level": "high" if window["max_score"] >= high_threshold else "medium",
        "reasons": sorted(window["reasons"]),
        "max_frame": max_frame["frame"],
        "frame_count": len(window["frames"]),
    }


def color_for_label(label):
    return {
        "red": (255, 40, 40),
        "yellow": (245, 190, 20),
        "green": (40, 220, 80),
        "cyan": (30, 210, 230),
        "magenta": (230, 50, 230),
    }.get(label, (255, 255, 255))


def candidate_key(candidate):
    x1, y1, x2, y2 = candidate["bbox_norm"]
    cx = (x1 + x2) / 2
    cy = (y1 + y2) / 2
    return f"{candidate['label']}:{int(cx * 10):02d}:{int(cy * 10):02d}"


def build_cleanup_plan(windows, frame_records, max_boxes_per_window=12):
    plans = []
    for window in windows:
        candidates_by_key = {}
        for record in frame_records:
            if record["time_seconds"] < window["start_seconds"] or record["time_seconds"] > window["end_seconds"]:
                continue
            for candidate in record.get("cleanup_candidates", []):
                key = candidate_key(candidate)
                existing = candidates_by_key.get(key)
                if existing is None or candidate["area_ratio"] > existing["area_ratio"]:
                    candidates_by_key[key] = candidate

        mask_boxes = sorted(
            candidates_by_key.values(),
            key=lambda item: (
                item["safety_level"] == "needs_review",
                item["safety_level"] == "conservative",
                item["area_ratio"],
            ),
            reverse=True,
        )[:max_boxes_per_window]

        safety_order = {"auto": 0, "conservative": 1, "needs_review": 2}
        safety_level = "auto"
        if mask_boxes:
            safety_level = max(mask_boxes, key=lambda item: safety_order.get(item["safety_level"], 0))[
                "safety_level"
            ]
        if "overlay_near_body_area" in window["reasons"] and safety_level == "auto":
            safety_level = "conservative"

        if safety_level == "needs_review":
            action = "review_before_aggressive_cleanup"
        elif any(item["label"] == "white_subtitle" for item in mask_boxes):
            action = "bottom_subtitle_masked_cleanup"
        elif any(item["suggested_action"] == "local_blur_or_fill" for item in mask_boxes):
            action = "local_blur_or_fill"
        elif mask_boxes:
            action = "desaturate_blur"
        else:
            action = "review_only"

        plans.append(
            {
                "start_seconds": window["start_seconds"],
                "end_seconds": window["end_seconds"],
                "segment_index": window["segment_index"],
                "segment_start_index": window.get("segment_start_index", window["segment_index"]),
                "segment_end_index": window.get("segment_end_index", window["segment_index"]),
                "segment_local_start_seconds": window["segment_local_start_seconds"],
                "segment_local_end_seconds": window["segment_local_end_seconds"],
                "level": window["level"],
                "max_score": window["max_score"],
                "reasons": window["reasons"],
                "suggested_action": action,
                "safety_level": safety_level,
                "mask_boxes_norm": mask_boxes,
                "needs_review": safety_level == "needs_review",
            }
        )
    return plans


def make_contact_sheet(frame_records, frames_dir, output_path, max_frames):
    selected = [record for record in frame_records if record["score"] >= 3.0]
    if not selected:
        selected = sorted(frame_records, key=lambda item: item["score"], reverse=True)[:max_frames]
    else:
        selected = sorted(selected, key=lambda item: (-item["score"], item["time_seconds"]))[:max_frames]
        selected.sort(key=lambda item: item["time_seconds"])

    thumb_width = 260
    label_height = 34
    margin = 10
    columns = 4
    thumbs = []
    font = ImageFont.load_default()

    for record in selected:
        image = Image.open(frames_dir / record["frame"]).convert("RGB")
        image.thumbnail((thumb_width, 220), Image.Resampling.LANCZOS)
        tile = Image.new("RGB", (thumb_width, image.height + label_height), (18, 18, 18))
        tile.paste(image, (0, label_height))
        draw = ImageDraw.Draw(tile)

        header_color = (170, 42, 42) if record["level"] == "high" else (150, 120, 30)
        if record["level"] == "low":
            header_color = (80, 80, 80)
        draw.rectangle([0, 0, thumb_width, label_height], fill=header_color)
        draw.text(
            (6, 8),
            f"{record['time_seconds']:.1f}s score={record['score']:.1f} {record['level']}",
            fill=(255, 255, 255),
            font=font,
        )

        scale_x = image.width
        scale_y = image.height
        for component in record["components"][:5]:
            x1, y1, x2, y2 = component["bbox_norm"]
            box = [
                int(x1 * scale_x),
                label_height + int(y1 * scale_y),
                int(x2 * scale_x),
                label_height + int(y2 * scale_y),
            ]
            draw.rectangle(box, outline=color_for_label(component["label"]), width=2)

        thumbs.append(tile)

    if not thumbs:
        return None

    rows = math.ceil(len(thumbs) / columns)
    tile_height = max(tile.height for tile in thumbs)
    sheet = Image.new(
        "RGB",
        (columns * thumb_width + (columns + 1) * margin, rows * tile_height + (rows + 1) * margin),
        (245, 245, 245),
    )
    for index, tile in enumerate(thumbs):
        row = index // columns
        col = index % columns
        x = margin + col * (thumb_width + margin)
        y = margin + row * (tile_height + margin)
        sheet.paste(tile, (x, y))

    sheet.save(output_path, quality=92)
    return output_path


def write_csv(frame_records, path):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            [
                "time_seconds",
                "score",
                "level",
                "reasons",
                "red_max_component",
                "yellow_max_component",
                "green_max_component",
                "white_bottom_ratio",
                "frame",
            ]
        )
        for record in frame_records:
            max_area = record["metrics"]["max_component_area_by_label"]
            writer.writerow(
                [
                    record["time_seconds"],
                    record["score"],
                    record["level"],
                    "|".join(record["reasons"]),
                    max_area.get("red", 0),
                    max_area.get("yellow", 0),
                    max_area.get("green", 0),
                    record["metrics"]["white_bottom_ratio"],
                    record["frame"],
                ]
            )


def write_markdown(report, path):
    lines = [
        "# 参考视频污染风险报告",
        "",
        f"- 视频: `{report['video']}`",
        f"- 抽帧间隔: `{report['sample_interval_seconds']}s`",
        f"- 抽帧数量: `{report['frames_sampled']}`",
        f"- 风险窗口数量: `{len(report['windows'])}`",
        "",
        "## 处理建议",
        "",
    ]

    high_windows = [window for window in report["windows"] if window["level"] == "high"]
    if high_windows:
        lines.append("- 先清洗高风险窗口，再切段上 Vast；这类窗口最容易把贴纸/字幕/红点带进动作条件。")
    elif report["windows"]:
        lines.append("- 存在中风险窗口；可以先人工看拼图，确认是否靠近身体、手、脸、道具边缘。")
    else:
        lines.append("- 未发现明显贴纸/字幕/红点风险；仍需保留生成后抽帧验收。")

    lines.extend(
        [
            "- 如果最终成片只出现孤立小红点，优先做成片局部后修；如果出现多手、手漂移、双头、身体变形，优先清洗参考视频后重跑对应 30s 分段。",
            "",
            "## 风险窗口",
            "",
        ]
    )

    if report["windows"]:
        for window in report["windows"]:
            reason_text = ", ".join(window["reasons"])
            if window.get("segment_start_index") != window.get("segment_end_index"):
                segment_text = (
                    f"segments `{window['segment_start_index']}-{window['segment_end_index']}` "
                    f"local start `{window['segment_local_start_seconds']:.1f}s`, "
                    f"local end `{window['segment_local_end_seconds']:.1f}s`"
                )
            else:
                segment_text = (
                    f"segment `{window['segment_index']}` local "
                    f"`{window['segment_local_start_seconds']:.1f}s-{window['segment_local_end_seconds']:.1f}s`"
                )
            lines.append(
                f"- `{window['start_seconds']:.1f}s-{window['end_seconds']:.1f}s` "
                f"{segment_text}: "
                f"`{window['level']}` score `{window['max_score']}`; {reason_text}; max frame `{window['max_frame']}`"
            )
    else:
        lines.append("- 无")

    lines.append("")
    lines.append("## 规则说明")
    lines.append("")
    lines.append("- `red_icon_or_pin`: 红色对勾、定位点、红色贴纸等。")
    lines.append("- `bottom_subtitle_or_text`: 底部字幕、白字黑边、贴片文字。")
    lines.append("- `overlay_near_body_area`: 候选贴图靠近人物主体区域。")
    lines.append("- 这是自动候选检测，不等于最终判定；最终仍以审查拼图和成片抽帧为准。")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    video_path = Path(args.video).resolve()
    if not video_path.is_file():
        raise SystemExit(f"视频不存在: {video_path}")
    if args.sample_interval <= 0:
        raise SystemExit("--sample-interval 必须大于 0")

    output_dir = Path(args.output_dir).resolve()
    frames_dir = output_dir / "sampled_frames"
    output_dir.mkdir(parents=True, exist_ok=True)
    ffmpeg_path = resolve_ffmpeg(args.ffmpeg)

    frames = run_ffmpeg_extract(ffmpeg_path, video_path, frames_dir, args.sample_interval)
    frame_records = []
    for index, frame_path in enumerate(frames):
        frame_records.append(analyze_frame(frame_path, index * args.sample_interval))

    windows = group_windows(
        frame_records,
        args.sample_interval,
        args.segment_seconds,
        args.risk_threshold,
        args.high_threshold,
    )

    report = {
        "video": str(video_path),
        "ffmpeg": ffmpeg_path,
        "sample_interval_seconds": args.sample_interval,
        "segment_seconds": args.segment_seconds,
        "risk_threshold": args.risk_threshold,
        "high_threshold": args.high_threshold,
        "frames_sampled": len(frame_records),
        "windows": windows,
        "cleanup_plan": build_cleanup_plan(windows, frame_records),
        "frames": frame_records,
    }

    report_path = output_dir / "overlay-risk-report.json"
    csv_path = output_dir / "overlay-risk-frames.csv"
    markdown_path = output_dir / "overlay-risk-summary.md"
    sheet_path = output_dir / "overlay-risk-contact-sheet.jpg"

    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(frame_records, csv_path)
    write_markdown(report, markdown_path)
    make_contact_sheet(frame_records, frames_dir, sheet_path, args.max_sheet_frames)

    print(f"报告: {report_path}")
    print(f"汇总: {markdown_path}")
    print(f"拼图: {sheet_path}")
    if windows:
        print("风险窗口:")
        for window in windows[:12]:
            if window.get("segment_start_index") != window.get("segment_end_index"):
                segment_text = (
                    f"segments {window['segment_start_index']}-{window['segment_end_index']} "
                    f"local {window['segment_local_start_seconds']:.1f}s->{window['segment_local_end_seconds']:.1f}s"
                )
            else:
                segment_text = (
                    f"segment {window['segment_index']} local "
                    f"{window['segment_local_start_seconds']:.1f}s-{window['segment_local_end_seconds']:.1f}s"
                )
            print(
                f"- {window['start_seconds']:.1f}s-{window['end_seconds']:.1f}s "
                f"{segment_text} "
                f"{window['level']} score={window['max_score']}"
            )
    else:
        print("未发现明显风险窗口。")


if __name__ == "__main__":
    main()
