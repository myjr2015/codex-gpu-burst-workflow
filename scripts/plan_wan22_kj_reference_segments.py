import argparse
import json
import math
import shutil
import subprocess
from pathlib import Path


REPO_FFPROBE_CANDIDATES = (
    Path(r"D:\code\KuangJia\ffmpeg\ffprobe.exe"),
    Path(r"D:\code\KuangJia\ffmpeg\bin\ffprobe.exe"),
)


def parse_args():
    parser = argparse.ArgumentParser(
        description="根据参考视频污染风险报告，为 KJ 长视频生成 seam-aware 分段计划。"
    )
    parser.add_argument("--risk-report", required=True, help="analyze_reference_overlay_risk.py 输出的 overlay-risk-report.json")
    parser.add_argument("--output-dir", required=True, help="segment-plan.json / .md 输出目录")
    parser.add_argument("--video", help="参考视频路径；未传时使用 risk report 里的 video")
    parser.add_argument("--ffprobe", help="ffprobe.exe 路径")
    parser.add_argument("--duration", type=float, help="显式指定视频时长秒数")
    parser.add_argument("--max-segment-seconds", type=float, default=30.0, help="单段最大时长，KJ 当前默认 30s")
    parser.add_argument("--target-segment-seconds", type=float, default=30.0, help="理想分段时长")
    parser.add_argument("--min-segment-seconds", type=float, default=8.0, help="非尾段最短时长")
    parser.add_argument("--min-final-seconds", type=float, default=2.0, help="尾段最短时长")
    parser.add_argument("--candidate-step", type=float, default=0.5, help="候选切点步长秒数")
    parser.add_argument("--seam-buffer", type=float, default=2.0, help="切点前后风险窗口秒数")
    parser.add_argument("--medium-threshold", type=float, default=3.0)
    parser.add_argument("--high-threshold", type=float, default=5.0)
    parser.add_argument("--segment-penalty", type=float, default=2.5, help="每多一段的成本惩罚")
    parser.add_argument("--high-seam-penalty", type=float, default=8.0, help="切点落在高风险区的额外惩罚")
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
    return None


def read_duration(ffprobe_path, video_path):
    if not ffprobe_path or not video_path:
        return None
    command = [
        ffprobe_path,
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(video_path),
    ]
    try:
        value = subprocess.check_output(command, text=True, encoding="utf-8").strip()
        return float(value)
    except Exception:
        return None


def round_time(value):
    return round(float(value) + 1e-9, 3)


def frame_score(record):
    return float(record.get("score") or 0.0)


def frame_reasons(record):
    return set(record.get("reasons") or [])


def records_in_window(records, start, end):
    return [record for record in records if start <= float(record.get("time_seconds", 0.0)) <= end]


def summarize_window(records, start, end):
    selected = records_in_window(records, start, end)
    if not selected:
        return {
            "max_score": 0.0,
            "level": "none",
            "reasons": [],
            "frame_count": 0,
        }
    max_score = max(frame_score(record) for record in selected)
    reasons = sorted(set().union(*(frame_reasons(record) for record in selected)))
    if max_score >= 5.0:
        level = "high"
    elif max_score >= 3.0:
        level = "medium"
    elif max_score > 0:
        level = "low"
    else:
        level = "none"
    return {
        "max_score": round(max_score, 3),
        "level": level,
        "reasons": reasons,
        "frame_count": len(selected),
    }


def seam_risk(records, cut_time, seam_buffer, high_threshold, high_seam_penalty):
    start = max(0.0, cut_time - seam_buffer)
    end = cut_time + seam_buffer
    summary = summarize_window(records, start, end)
    score = float(summary["max_score"])
    reasons = set(summary["reasons"])
    penalty = score
    if score >= high_threshold:
        penalty += high_seam_penalty + (score - high_threshold) * 2.5
    if "overlay_near_body_area" in reasons:
        penalty += 2.0
    if "bottom_subtitle_or_text" in reasons:
        penalty += 1.0
    if {"red_icon_or_pin", "yellow_magenta_sticker", "green_cyan_sticker"} & reasons:
        penalty += 1.0
    return {
        "cut_seconds": round_time(cut_time),
        "risk_window": [round_time(start), round_time(end)],
        "risk_score": round(score, 3),
        "risk_level": summary["level"],
        "penalty": round(penalty, 3),
        "reasons": summary["reasons"],
    }


def build_candidate_times(duration, step):
    count = int(math.floor(duration / step))
    times = [round_time(index * step) for index in range(count + 1)]
    if not times or abs(times[-1] - duration) > 1e-6:
        times.append(round_time(duration))
    return sorted(set(times))


def find_plan(records, duration, args):
    times = build_candidate_times(duration, args.candidate_step)
    end_time = round_time(duration)
    time_to_index = {time: index for index, time in enumerate(times)}
    seam_cache = {}

    def get_seam(cut_time):
        if cut_time not in seam_cache:
            seam_cache[cut_time] = seam_risk(
                records,
                cut_time,
                args.seam_buffer,
                args.high_threshold,
                args.high_seam_penalty,
            )
        return seam_cache[cut_time]

    inf = 1e18
    dp = [inf] * len(times)
    prev = [None] * len(times)
    dp[time_to_index[0.0]] = 0.0

    for index, current in enumerate(times):
        if dp[index] >= inf:
            continue
        for next_index in range(index + 1, len(times)):
            next_time = times[next_index]
            duration_seconds = next_time - current
            if duration_seconds <= 0:
                continue
            if duration_seconds > args.max_segment_seconds + 1e-6:
                break

            is_final = abs(next_time - end_time) <= 1e-6
            if not is_final and duration_seconds < args.min_segment_seconds - 1e-6:
                continue
            if is_final and current > 0 and duration_seconds < args.min_final_seconds - 1e-6:
                continue

            length_penalty = abs(duration_seconds - min(args.target_segment_seconds, args.max_segment_seconds)) * 0.04
            cut_penalty = 0.0 if is_final else get_seam(next_time)["penalty"]
            candidate_cost = dp[index] + args.segment_penalty + length_penalty + cut_penalty
            if candidate_cost < dp[next_index]:
                dp[next_index] = candidate_cost
                prev[next_index] = index

    end_index = time_to_index[end_time]
    if dp[end_index] >= inf:
        raise SystemExit("无法生成合法分段计划，请检查最大/最小时长参数。")

    cuts = []
    cursor = end_index
    while cursor is not None:
        cuts.append(times[cursor])
        cursor = prev[cursor]
    cuts.reverse()

    segments = []
    for index in range(1, len(cuts)):
        start = cuts[index - 1]
        end = cuts[index]
        segment_summary = summarize_window(records, start, max(start, end - 1e-6))
        segments.append(
            {
                "id": f"{index:02d}",
                "index": index,
                "start_seconds": round_time(start),
                "end_seconds": round_time(end),
                "duration_seconds": round_time(end - start),
                "risk_max_score": segment_summary["max_score"],
                "risk_level": segment_summary["level"],
                "risk_reasons": segment_summary["reasons"],
            }
        )

    seams = [get_seam(cut) for cut in cuts[1:-1]]
    return segments, seams, dp[end_index]


def fixed_cut_risks(records, duration, args):
    risks = []
    cut = args.max_segment_seconds
    while cut < duration - 1e-6:
        risks.append(seam_risk(records, cut, args.seam_buffer, args.high_threshold, args.high_seam_penalty))
        cut += args.max_segment_seconds
    return risks


def write_markdown(plan, path):
    lines = [
        "# KJ 参考视频分段计划",
        "",
        f"- 视频: `{plan['video']}`",
        f"- 时长: `{plan['duration_seconds']}` 秒",
        f"- 单段上限: `{plan['max_segment_seconds']}` 秒",
        f"- 推荐段数: `{len(plan['segments'])}`",
        f"- 状态: `{plan['status']}`",
        "",
        "## 推荐切段",
        "",
        "| 段 | 起点 | 终点 | 时长 | 段内最高风险 |",
        "|---|---:|---:|---:|---:|",
    ]
    for segment in plan["segments"]:
        lines.append(
            f"| {segment['id']} | {segment['start_seconds']} | {segment['end_seconds']} | "
            f"{segment['duration_seconds']} | {segment['risk_level']} {segment['risk_max_score']} |"
        )

    lines.extend(["", "## 推荐切点风险", ""])
    if plan["seams"]:
        for seam in plan["seams"]:
            lines.append(
                f"- `{seam['cut_seconds']}s`: `{seam['risk_level']}` score `{seam['risk_score']}`, "
                f"window `{seam['risk_window'][0]}s-{seam['risk_window'][1]}s`, reasons: {', '.join(seam['reasons'])}"
            )
    else:
        lines.append("- 无切点。")

    lines.extend(["", "## 固定 30s 切点风险", ""])
    if plan["fixed_cut_risks"]:
        for seam in plan["fixed_cut_risks"]:
            lines.append(
                f"- `{seam['cut_seconds']}s`: `{seam['risk_level']}` score `{seam['risk_score']}`, "
                f"reasons: {', '.join(seam['reasons'])}"
            )
    else:
        lines.append("- 无。")

    lines.extend(["", "## 自动建议", ""])
    for action in plan["recommended_actions"]:
        lines.append(f"- {action}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main():
    args = parse_args()
    if args.max_segment_seconds <= 0 or args.candidate_step <= 0 or args.seam_buffer < 0:
        raise SystemExit("分段参数非法。")

    report_path = Path(args.risk_report).resolve()
    report = json.loads(report_path.read_text(encoding="utf-8"))
    video_path = Path(args.video or report.get("video") or "").resolve()
    ffprobe_path = resolve_ffprobe(args.ffprobe)
    duration = args.duration or read_duration(ffprobe_path, video_path)
    records = sorted(report.get("frames") or [], key=lambda item: float(item.get("time_seconds", 0.0)))
    if not records:
        raise SystemExit("风险报告里没有 frames，无法做切点评分。")
    if not duration:
        duration = max(float(item.get("time_seconds", 0.0)) for item in records) + float(report.get("sample_interval_seconds") or 0.5)

    segments, seams, cost = find_plan(records, duration, args)
    fixed_risks = fixed_cut_risks(records, duration, args)
    highest_segment_score = max(float(segment["risk_max_score"]) for segment in segments) if segments else 0.0
    highest_planned_seam_score = max((float(seam["risk_score"]) for seam in seams), default=0.0)
    highest_fixed_seam_score = max((float(seam["risk_score"]) for seam in fixed_risks), default=0.0)

    recommended_actions = []
    status = "pass_with_review"
    if highest_fixed_seam_score >= args.high_threshold:
        recommended_actions.append("固定 30s 切点处于高风险区，不建议继续死切 30s。")
    if len(segments) > math.ceil(duration / args.max_segment_seconds):
        recommended_actions.append("为了避开高风险接缝，允许增加一个短尾段；这会增加一次推理，但比硬切更稳。")
    if highest_segment_score >= args.high_threshold:
        status = "needs_reference_cleanup_or_manual_review"
        recommended_actions.append("段内仍存在高风险覆盖，尤其靠近身体/手部时，应先清理参考视频或准备重跑对应分段。")
    if highest_planned_seam_score >= args.high_threshold:
        status = "needs_reference_cleanup_or_manual_review"
        recommended_actions.append("推荐切点仍有高风险，智能切段只能降低接缝风险，不能替代参考视频清理。")
    if not recommended_actions:
        recommended_actions.append("可以按推荐切段进入 KJ 分段生成；生成后仍需跑成片质检。")

    plan = {
        "schema_version": 1,
        "source": "plan_wan22_kj_reference_segments.py",
        "risk_report": str(report_path),
        "video": str(video_path),
        "duration_seconds": round_time(duration),
        "max_segment_seconds": args.max_segment_seconds,
        "target_segment_seconds": args.target_segment_seconds,
        "candidate_step_seconds": args.candidate_step,
        "seam_buffer_seconds": args.seam_buffer,
        "status": status,
        "cost": round(cost, 3),
        "segments": segments,
        "seams": seams,
        "fixed_cut_risks": fixed_risks,
        "recommended_actions": recommended_actions,
    }

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    plan_path = output_dir / "segment-plan.json"
    markdown_path = output_dir / "segment-plan-summary.md"
    plan_path.write_text(json.dumps(plan, ensure_ascii=False, indent=2), encoding="utf-8")
    write_markdown(plan, markdown_path)

    print(f"分段计划: {plan_path}")
    print(f"分段汇总: {markdown_path}")
    print(f"status={status}")
    for segment in segments:
        print(
            f"segment_{segment['id']}: start={segment['start_seconds']}s "
            f"duration={segment['duration_seconds']}s risk={segment['risk_level']} {segment['risk_max_score']}"
        )
    for action in recommended_actions:
        print(f"action={action}")


if __name__ == "__main__":
    main()
