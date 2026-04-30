import argparse
import csv
import json
import math
import sys
from pathlib import Path


try:
    import numpy as np
    from PIL import Image, ImageDraw, ImageFont
except ImportError as exc:
    raise SystemExit(
        "缺少依赖，请先安装 pillow numpy，例如: D:\\code\\YuYan\\python\\python.exe -m pip install pillow numpy"
    ) from exc


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from analyze_reference_overlay_risk import (  # noqa: E402
    color_for_label,
    connected_components,
    resolve_ffmpeg,
    run_ffmpeg_extract,
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="扫描生成视频里的短时红点、贴纸残留、彩色小块等成片异常。"
    )
    parser.add_argument("--video", required=True, help="生成后的视频路径")
    parser.add_argument("--output-dir", required=True, help="报告输出目录")
    parser.add_argument("--ffmpeg", help="ffmpeg.exe 路径，默认优先使用 PATH 和 D:\\code\\KuangJia\\ffmpeg")
    parser.add_argument("--sample-interval", type=float, default=0.25, help="抽帧间隔秒数，默认 0.25")
    parser.add_argument("--segment-seconds", type=float, default=30.0, help="分段秒数，用于报告定位，默认 30")
    parser.add_argument(
        "--persistent-min-ratio",
        type=float,
        default=0.16,
        help="同位置颜色块出现比例超过该值时视为常驻元素，默认 0.16",
    )
    parser.add_argument("--risk-threshold", type=float, default=1.8, help="进入风险窗口的分数阈值")
    parser.add_argument("--max-sheet-frames", type=int, default=64, help="审查拼图最多放多少帧")
    return parser.parse_args()


def frame_masks(image):
    hsv = np.asarray(image.convert("HSV"), dtype=np.uint8)
    h = hsv[:, :, 0]
    s = hsv[:, :, 1]
    v = hsv[:, :, 2]
    return {
        "red": (((h < 14) | (h > 240)) & (s > 85) & (v > 80)),
        "yellow": ((h >= 18) & (h <= 52) & (s > 85) & (v > 105)),
        "green": ((h >= 58) & (h <= 118) & (s > 95) & (v > 105)),
        "cyan": ((h >= 120) & (h <= 150) & (s > 95) & (v > 115)),
        "magenta": ((h >= 200) & (h <= 238) & (s > 80) & (v > 95)),
    }


def component_key(label, bbox, width, height):
    x1, y1, x2, y2 = bbox
    cx = ((x1 + x2) / 2) / max(width, 1)
    cy = ((y1 + y2) / 2) / max(height, 1)
    return f"{label}:{int(cx * 14):02d}:{int(cy * 14):02d}"


def extract_components(frame_path):
    image = Image.open(frame_path).convert("RGB")
    width, height = image.size
    frame_area = width * height
    min_pixels = max(10, int(frame_area * 0.00008))
    max_area_ratio = 0.018
    components = []

    for label, mask in frame_masks(image).items():
        for component in connected_components(mask, min_pixels=min_pixels)[:12]:
            x1, y1, x2, y2 = component["bbox"]
            area_ratio = component["pixels"] / frame_area
            bbox_width_ratio = (x2 - x1) / width
            bbox_height_ratio = (y2 - y1) / height
            if area_ratio > max_area_ratio:
                continue
            if bbox_width_ratio > 0.32 or bbox_height_ratio > 0.28:
                continue
            if area_ratio < 0.00009:
                continue

            # Stable bottom footwear/contact shadows are common in generated talking videos.
            # Keep them in the data, but their persistent-location filter will usually drop them.
            components.append(
                {
                    "label": label,
                    "pixels": int(component["pixels"]),
                    "area_ratio": round(area_ratio, 6),
                    "bbox": [int(x1), int(y1), int(x2), int(y2)],
                    "bbox_norm": [
                        round(x1 / width, 4),
                        round(y1 / height, 4),
                        round(x2 / width, 4),
                        round(y2 / height, 4),
                    ],
                    "key": component_key(label, component["bbox"], width, height),
                }
            )

    components.sort(key=lambda item: item["area_ratio"], reverse=True)
    return image.size, components[:16]


def score_frames(frame_paths, sample_interval, persistent_min_ratio):
    raw_records = []
    key_counts = {}

    for index, frame_path in enumerate(frame_paths):
        size, components = extract_components(frame_path)
        for component in components:
            key_counts[component["key"]] = key_counts.get(component["key"], 0) + 1
        raw_records.append(
            {
                "frame": frame_path.name,
                "time_seconds": round(index * sample_interval, 3),
                "size": size,
                "components": components,
            }
        )

    persistent_min_count = max(4, math.ceil(len(raw_records) * persistent_min_ratio))
    persistent_keys = {key for key, count in key_counts.items() if count >= persistent_min_count}

    records = []
    for record in raw_records:
        transient = [item for item in record["components"] if item["key"] not in persistent_keys]
        score = 0.0
        reasons = []
        for item in transient:
            weight = {
                "red": 2.2,
                "yellow": 1.35,
                "magenta": 1.3,
                "green": 1.0,
                "cyan": 0.9,
            }.get(item["label"], 1.0)
            score += weight + min(2.0, item["area_ratio"] * 700)
        if any(item["label"] == "red" for item in transient):
            reasons.append("short_lived_red_artifact")
        if any(item["label"] in ("yellow", "magenta") for item in transient):
            reasons.append("short_lived_sticker_color")
        if any(item["label"] in ("green", "cyan") for item in transient):
            reasons.append("short_lived_ui_color")
        if len(transient) >= 2:
            reasons.append("multiple_transient_color_blobs")

        if score >= 4.2:
            level = "high"
        elif score >= 1.8:
            level = "medium"
        elif score > 0:
            level = "low"
        else:
            level = "none"

        records.append(
            {
                "frame": record["frame"],
                "time_seconds": record["time_seconds"],
                "score": round(score, 3),
                "level": level,
                "reasons": reasons,
                "components": transient[:10],
            }
        )

    return records, sorted(persistent_keys)


def group_windows(records, sample_interval, segment_seconds, risk_threshold):
    windows = []
    current = None
    max_gap = max(sample_interval * 2.2, 0.6)

    for record in records:
        if record["score"] < risk_threshold:
            continue
        if current is None or record["time_seconds"] - current["last_time"] > max_gap:
            if current:
                windows.append(finalize_window(current, sample_interval, segment_seconds))
            current = {
                "start": record["time_seconds"],
                "last_time": record["time_seconds"],
                "max_score": record["score"],
                "reasons": set(record["reasons"]),
                "frames": [record],
            }
        else:
            current["last_time"] = record["time_seconds"]
            current["max_score"] = max(current["max_score"], record["score"])
            current["reasons"].update(record["reasons"])
            current["frames"].append(record)

    if current:
        windows.append(finalize_window(current, sample_interval, segment_seconds))

    windows.sort(key=lambda item: (-item["max_score"], item["start_seconds"]))
    return windows


def finalize_window(window, sample_interval, segment_seconds):
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
        "level": "high" if window["max_score"] >= 4.2 else "medium",
        "reasons": sorted(window["reasons"]),
        "max_frame": max_frame["frame"],
        "frame_count": len(window["frames"]),
    }


def make_contact_sheet(records, frames_dir, output_path, max_frames):
    selected = [record for record in records if record["score"] >= 1.8]
    selected = sorted(selected, key=lambda item: (-item["score"], item["time_seconds"]))[:max_frames]
    selected.sort(key=lambda item: item["time_seconds"])
    if not selected:
        return None

    thumb_width = 220
    label_height = 34
    margin = 10
    columns = 4
    font = ImageFont.load_default()
    tiles = []

    for record in selected:
        image = Image.open(frames_dir / record["frame"]).convert("RGB")
        image.thumbnail((thumb_width, 220), Image.Resampling.LANCZOS)
        tile = Image.new("RGB", (thumb_width, image.height + label_height), (18, 18, 18))
        tile.paste(image, (0, label_height))
        draw = ImageDraw.Draw(tile)
        header = (170, 42, 42) if record["level"] == "high" else (150, 120, 30)
        draw.rectangle([0, 0, thumb_width, label_height], fill=header)
        draw.text(
            (6, 8),
            f"{record['time_seconds']:.2f}s score={record['score']:.1f}",
            fill=(255, 255, 255),
            font=font,
        )

        scale_x = image.width
        scale_y = image.height
        for component in record["components"][:6]:
            x1, y1, x2, y2 = component["bbox_norm"]
            box = [
                int(x1 * scale_x),
                label_height + int(y1 * scale_y),
                int(x2 * scale_x),
                label_height + int(y2 * scale_y),
            ]
            draw.rectangle(box, outline=color_for_label(component["label"]), width=2)
        tiles.append(tile)

    rows = math.ceil(len(tiles) / columns)
    tile_height = max(tile.height for tile in tiles)
    sheet = Image.new(
        "RGB",
        (columns * thumb_width + (columns + 1) * margin, rows * tile_height + (rows + 1) * margin),
        (245, 245, 245),
    )
    for index, tile in enumerate(tiles):
        row = index // columns
        col = index % columns
        sheet.paste(tile, (margin + col * (thumb_width + margin), margin + row * (tile_height + margin)))
    sheet.save(output_path, quality=92)
    return output_path


def write_csv(records, path):
    with path.open("w", encoding="utf-8-sig", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["time_seconds", "score", "level", "reasons", "components", "frame"])
        for record in records:
            components = ";".join(
                f"{item['label']}:{item['area_ratio']}:{item['bbox_norm']}" for item in record["components"]
            )
            writer.writerow(
                [
                    record["time_seconds"],
                    record["score"],
                    record["level"],
                    "|".join(record["reasons"]),
                    components,
                    record["frame"],
                ]
            )


def write_markdown(report, path):
    lines = [
        "# 生成视频异常彩色块报告",
        "",
        f"- 视频: `{report['video']}`",
        f"- 抽帧间隔: `{report['sample_interval_seconds']}s`",
        f"- 抽帧数量: `{report['frames_sampled']}`",
        f"- 风险窗口数量: `{len(report['windows'])}`",
        "",
        "## 风险窗口",
        "",
    ]
    if report["windows"]:
        for window in report["windows"]:
            reason_text = ", ".join(window["reasons"])
            if window.get("segment_start_index") != window.get("segment_end_index"):
                segment_text = (
                    f"segments `{window['segment_start_index']}-{window['segment_end_index']}` "
                    f"local start `{window['segment_local_start_seconds']:.2f}s`, "
                    f"local end `{window['segment_local_end_seconds']:.2f}s`"
                )
            else:
                segment_text = (
                    f"segment `{window['segment_index']}` local "
                    f"`{window['segment_local_start_seconds']:.2f}s-{window['segment_local_end_seconds']:.2f}s`"
                )
            lines.append(
                f"- `{window['start_seconds']:.2f}s-{window['end_seconds']:.2f}s` "
                f"{segment_text}: "
                f"`{window['level']}` score `{window['max_score']}`; {reason_text}; max frame `{window['max_frame']}`"
            )
    else:
        lines.append("- 无明显短时彩色块异常。")

    lines.extend(
        [
            "",
            "## 判断口径",
            "",
            "- 该脚本先排除同位置反复出现的常驻颜色块，再抓短时出现的红/黄/绿/青/紫小块。",
            "- 它用于自动生成复查清单，不替代人工验片；嘴唇、鞋子、衣服、正常道具可能成为候选，需要看拼图确认。",
            "- 出现孤立小点时优先做成片局部后修；出现手部/脸部/身体结构异常时回到参考视频清洗并重跑对应分段。",
        ]
    )
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
    records, persistent_keys = score_frames(frames, args.sample_interval, args.persistent_min_ratio)
    windows = group_windows(records, args.sample_interval, args.segment_seconds, args.risk_threshold)

    report = {
        "video": str(video_path),
        "ffmpeg": ffmpeg_path,
        "sample_interval_seconds": args.sample_interval,
        "segment_seconds": args.segment_seconds,
        "persistent_min_ratio": args.persistent_min_ratio,
        "risk_threshold": args.risk_threshold,
        "frames_sampled": len(records),
        "persistent_keys": persistent_keys,
        "windows": windows,
        "frames": records,
    }

    report_path = output_dir / "generated-artifact-report.json"
    csv_path = output_dir / "generated-artifact-frames.csv"
    markdown_path = output_dir / "generated-artifact-summary.md"
    sheet_path = output_dir / "generated-artifact-contact-sheet.jpg"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    write_csv(records, csv_path)
    write_markdown(report, markdown_path)
    make_contact_sheet(records, frames_dir, sheet_path, args.max_sheet_frames)

    print(f"报告: {report_path}")
    print(f"汇总: {markdown_path}")
    print(f"拼图: {sheet_path}")
    if windows:
        print("风险窗口:")
        for window in windows[:12]:
            if window.get("segment_start_index") != window.get("segment_end_index"):
                segment_text = (
                    f"segments {window['segment_start_index']}-{window['segment_end_index']} "
                    f"local {window['segment_local_start_seconds']:.2f}s->{window['segment_local_end_seconds']:.2f}s"
                )
            else:
                segment_text = (
                    f"segment {window['segment_index']} local "
                    f"{window['segment_local_start_seconds']:.2f}s-{window['segment_local_end_seconds']:.2f}s"
                )
            print(
                f"- {window['start_seconds']:.2f}s-{window['end_seconds']:.2f}s "
                f"{segment_text} "
                f"{window['level']} score={window['max_score']}"
            )
    else:
        print("未发现明显短时彩色块异常。")


if __name__ == "__main__":
    main()
