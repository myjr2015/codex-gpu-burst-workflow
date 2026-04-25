from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_TARGET_SECONDS = 10.0
DEFAULT_MIN_SECONDS = 8.0
DEFAULT_MAX_SECONDS = 12.0
DEFAULT_OVERLAP_SECONDS = 0.0
DEFAULT_PAUSE_THRESHOLD_SECONDS = 0.35
EPSILON = 1e-6

STRONG_PUNCTUATION = ("。", "！", "？", "!", "?", ";", "；", ".")
WEAK_PUNCTUATION = ("，", ",", "、", "：", ":")
ELLIPSIS_TOKENS = ("...", "……")
TRAILING_CLOSERS = "\"'”’)]}）】》」"
SPACE_NORMALIZER = re.compile(r"\s+")


@dataclass(frozen=True)
class TranscriptSegment:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class Boundary:
    end_seconds: float
    has_strong_punctuation: bool
    has_weak_punctuation: bool
    has_pause: bool

    def rank(self) -> tuple[int, int, int]:
        return (
            int(self.has_strong_punctuation),
            int(self.has_pause),
            int(self.has_weak_punctuation),
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Plan speech-aware audio chunks from a faster-whisper style transcript JSON."
    )
    parser.add_argument("--transcript-path", required=True, help="Path to transcript JSON.")
    parser.add_argument(
        "--output-path",
        help="Optional output JSON path. If omitted, the plan is written to stdout only.",
    )
    parser.add_argument(
        "--target-seconds",
        type=float,
        default=DEFAULT_TARGET_SECONDS,
        help=f"Preferred chunk duration in seconds. Default: {DEFAULT_TARGET_SECONDS}",
    )
    parser.add_argument(
        "--min-seconds",
        type=float,
        default=DEFAULT_MIN_SECONDS,
        help=f"Soft minimum chunk duration in seconds. Default: {DEFAULT_MIN_SECONDS}",
    )
    parser.add_argument(
        "--max-seconds",
        type=float,
        default=DEFAULT_MAX_SECONDS,
        help=f"Soft maximum chunk duration in seconds. Default: {DEFAULT_MAX_SECONDS}",
    )
    parser.add_argument(
        "--overlap-seconds",
        type=float,
        default=DEFAULT_OVERLAP_SECONDS,
        help=f"Overlap to keep between adjacent chunks. Default: {DEFAULT_OVERLAP_SECONDS}",
    )
    parser.add_argument(
        "--pause-threshold-seconds",
        type=float,
        default=DEFAULT_PAUSE_THRESHOLD_SECONDS,
        help=(
            "Gap threshold used to treat a transcript boundary as a pause boundary. "
            f"Default: {DEFAULT_PAUSE_THRESHOLD_SECONDS}"
        ),
    )
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> None:
    if args.target_seconds <= 0:
        raise ValueError("--target-seconds must be greater than 0.")
    if args.min_seconds <= 0:
        raise ValueError("--min-seconds must be greater than 0.")
    if args.max_seconds <= 0:
        raise ValueError("--max-seconds must be greater than 0.")
    if args.min_seconds > args.target_seconds:
        raise ValueError("--min-seconds cannot be greater than --target-seconds.")
    if args.target_seconds > args.max_seconds:
        raise ValueError("--target-seconds cannot be greater than --max-seconds.")
    if args.overlap_seconds < 0:
        raise ValueError("--overlap-seconds cannot be negative.")
    if args.overlap_seconds >= args.min_seconds:
        raise ValueError("--overlap-seconds must be smaller than --min-seconds.")
    if args.pause_threshold_seconds < 0:
        raise ValueError("--pause-threshold-seconds cannot be negative.")


def _to_float(value: Any) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _round_seconds(value: float) -> float:
    return round(value + 0.0, 3)


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _strip_boundary_trailing(text: str) -> str:
    return text.rstrip().rstrip(TRAILING_CLOSERS)


def _is_strong_boundary(text: str) -> bool:
    normalized = _strip_boundary_trailing(text)
    if not normalized:
        return False
    if normalized.endswith(ELLIPSIS_TOKENS):
        return True
    return normalized.endswith(STRONG_PUNCTUATION)


def _is_weak_boundary(text: str) -> bool:
    normalized = _strip_boundary_trailing(text)
    if not normalized:
        return False
    return normalized.endswith(WEAK_PUNCTUATION)


def load_transcript(path: Path) -> tuple[list[TranscriptSegment], float]:
    data = _read_json(path)
    raw_segments = data.get("segments")
    if not isinstance(raw_segments, list):
        raise ValueError("Transcript JSON must contain a list field named 'segments'.")

    segments: list[TranscriptSegment] = []
    for item in raw_segments:
        if not isinstance(item, dict):
            continue
        start = _to_float(item.get("start"))
        end = _to_float(item.get("end"))
        if start is None or end is None or end < start:
            continue
        text = str(item.get("text") or "").strip()
        segments.append(TranscriptSegment(start=start, end=end, text=text))

    segments.sort(key=lambda segment: (segment.start, segment.end))
    if not segments:
        raise ValueError("Transcript contains no valid segments.")

    duration_candidates = [
        _to_float(data.get("duration_seconds")),
        _to_float(data.get("source_duration_seconds")),
        _to_float(data.get("audio_duration_seconds")),
        _to_float(data.get("duration")),
        segments[-1].end,
    ]
    source_duration = max(
        candidate for candidate in duration_candidates if candidate is not None and candidate >= 0
    )
    return segments, source_duration


def merge_boundary(existing: Boundary | None, candidate: Boundary) -> Boundary:
    if existing is None:
        return candidate
    return Boundary(
        end_seconds=candidate.end_seconds,
        has_strong_punctuation=existing.has_strong_punctuation or candidate.has_strong_punctuation,
        has_weak_punctuation=existing.has_weak_punctuation or candidate.has_weak_punctuation,
        has_pause=existing.has_pause or candidate.has_pause,
    )


def build_boundaries(
    segments: list[TranscriptSegment],
    source_duration: float,
    pause_threshold_seconds: float,
) -> list[Boundary]:
    boundary_by_time: dict[float, Boundary] = {}
    for index, segment in enumerate(segments):
        next_start = source_duration if index == len(segments) - 1 else segments[index + 1].start
        gap_seconds = max(0.0, next_start - segment.end)
        candidate = Boundary(
            end_seconds=segment.end,
            has_strong_punctuation=_is_strong_boundary(segment.text),
            has_weak_punctuation=_is_weak_boundary(segment.text),
            has_pause=gap_seconds >= pause_threshold_seconds,
        )
        key = round(segment.end, 6)
        boundary_by_time[key] = merge_boundary(boundary_by_time.get(key), candidate)

    final_key = round(source_duration, 6)
    boundary_by_time[final_key] = merge_boundary(
        boundary_by_time.get(final_key),
        Boundary(
            end_seconds=source_duration,
            has_strong_punctuation=True,
            has_weak_punctuation=False,
            has_pause=False,
        ),
    )

    return sorted(boundary_by_time.values(), key=lambda boundary: boundary.end_seconds)


def _is_ascii_word_char(char: str) -> bool:
    return char.isascii() and char.isalnum()


def _needs_space(left: str, right: str) -> bool:
    if not left or not right:
        return False

    left_char = left[-1]
    right_char = right[0]
    if left_char.isspace() or right_char.isspace():
        return False

    if _is_ascii_word_char(left_char) and _is_ascii_word_char(right_char):
        return True
    if left_char in {".", ",", "!", "?", ";", ":"} and _is_ascii_word_char(right_char):
        return True
    return False


def join_texts(texts: list[str]) -> str:
    merged = ""
    for raw_text in texts:
        text = SPACE_NORMALIZER.sub(" ", raw_text.strip())
        if not text:
            continue
        if not merged:
            merged = text
            continue
        if _needs_space(merged, text):
            merged += " " + text
        else:
            merged += text
    return merged.strip()


def collect_window_text(
    segments: list[TranscriptSegment],
    start_seconds: float,
    end_seconds: float,
) -> str:
    texts = [
        segment.text
        for segment in segments
        if segment.text and segment.end > start_seconds + EPSILON and segment.start < end_seconds - EPSILON
    ]
    return join_texts(texts)


def score_boundary(
    boundary: Boundary,
    current_start_seconds: float,
    source_duration: float,
    target_seconds: float,
    min_seconds: float,
    max_seconds: float,
    overlap_seconds: float,
) -> float:
    duration_seconds = boundary.end_seconds - current_start_seconds
    if duration_seconds <= EPSILON:
        return float("-inf")

    boundary_bonus = 0.0
    if boundary.has_strong_punctuation:
        boundary_bonus += 3.0
    if boundary.has_pause:
        boundary_bonus += 1.75
    if boundary.has_weak_punctuation:
        boundary_bonus += 1.0
    if math.isclose(boundary.end_seconds, source_duration, abs_tol=EPSILON):
        boundary_bonus += 0.5

    duration_penalty = abs(duration_seconds - target_seconds) * 0.8
    range_penalty = 0.0
    if duration_seconds < min_seconds:
        range_penalty += (min_seconds - duration_seconds) * 5.0
    elif duration_seconds > max_seconds:
        range_penalty += (duration_seconds - max_seconds) * 6.0

    tail_bonus = 0.0
    tail_penalty = 0.0
    if boundary.end_seconds < source_duration - EPSILON:
        next_start_seconds = max(0.0, boundary.end_seconds - overlap_seconds)
        next_remaining_seconds = source_duration - next_start_seconds
        if min_seconds <= next_remaining_seconds <= max_seconds:
            tail_bonus += 1.5
        elif next_remaining_seconds < min_seconds:
            tail_penalty += (min_seconds - next_remaining_seconds) * 4.0

    return boundary_bonus + tail_bonus - duration_penalty - range_penalty - tail_penalty


def choose_next_boundary(
    boundaries: list[Boundary],
    current_start_seconds: float,
    source_duration: float,
    target_seconds: float,
    min_seconds: float,
    max_seconds: float,
    overlap_seconds: float,
) -> Boundary:
    remaining_seconds = source_duration - current_start_seconds
    if remaining_seconds <= max_seconds + EPSILON:
        return Boundary(
            end_seconds=source_duration,
            has_strong_punctuation=True,
            has_weak_punctuation=False,
            has_pause=False,
        )

    candidates = [
        boundary for boundary in boundaries if boundary.end_seconds > current_start_seconds + EPSILON
    ]
    if not candidates:
        return Boundary(
            end_seconds=source_duration,
            has_strong_punctuation=True,
            has_weak_punctuation=False,
            has_pause=False,
        )

    best_boundary = candidates[0]
    best_score = float("-inf")
    best_tiebreak = (-1, -1, -1, float("-inf"), float("-inf"))

    for boundary in candidates:
        duration_seconds = boundary.end_seconds - current_start_seconds
        score = score_boundary(
            boundary=boundary,
            current_start_seconds=current_start_seconds,
            source_duration=source_duration,
            target_seconds=target_seconds,
            min_seconds=min_seconds,
            max_seconds=max_seconds,
            overlap_seconds=overlap_seconds,
        )
        tiebreak = (
            *boundary.rank(),
            -abs(duration_seconds - target_seconds),
            -boundary.end_seconds,
        )
        if score > best_score + EPSILON or (
            math.isclose(score, best_score, abs_tol=EPSILON) and tiebreak > best_tiebreak
        ):
            best_boundary = boundary
            best_score = score
            best_tiebreak = tiebreak

    return best_boundary


def plan_segments(
    segments: list[TranscriptSegment],
    source_duration: float,
    target_seconds: float,
    min_seconds: float,
    max_seconds: float,
    overlap_seconds: float,
    pause_threshold_seconds: float,
) -> dict[str, Any]:
    boundaries = build_boundaries(
        segments=segments,
        source_duration=source_duration,
        pause_threshold_seconds=pause_threshold_seconds,
    )

    planned_segments: list[dict[str, Any]] = []
    current_start_seconds = 0.0
    segment_index = 1

    while current_start_seconds < source_duration - EPSILON:
        boundary = choose_next_boundary(
            boundaries=boundaries,
            current_start_seconds=current_start_seconds,
            source_duration=source_duration,
            target_seconds=target_seconds,
            min_seconds=min_seconds,
            max_seconds=max_seconds,
            overlap_seconds=overlap_seconds,
        )
        end_seconds = min(boundary.end_seconds, source_duration)
        if end_seconds <= current_start_seconds + EPSILON:
            raise ValueError("Failed to make forward progress while planning segments.")

        text = collect_window_text(
            segments=segments,
            start_seconds=current_start_seconds,
            end_seconds=end_seconds,
        )
        planned_segments.append(
            {
                "index": segment_index,
                "start_seconds": _round_seconds(current_start_seconds),
                "end_seconds": _round_seconds(end_seconds),
                "duration_seconds": _round_seconds(end_seconds - current_start_seconds),
                "text": text,
            }
        )

        if end_seconds >= source_duration - EPSILON:
            break

        next_start_seconds = max(0.0, end_seconds - overlap_seconds)
        if next_start_seconds <= current_start_seconds + EPSILON:
            raise ValueError(
                "The chosen overlap does not leave enough room for the next chunk. "
                "Use a smaller --overlap-seconds value."
            )

        current_start_seconds = next_start_seconds
        segment_index += 1

    return {
        "source_duration_seconds": _round_seconds(source_duration),
        "segment_count": len(planned_segments),
        "segments": planned_segments,
    }


def write_output(plan: dict[str, Any], output_path: Path | None) -> None:
    text = json.dumps(plan, ensure_ascii=False, indent=2) + "\n"
    if output_path is not None:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(text, encoding="utf-8")

    try:
        sys.stdout.write(text)
    except UnicodeEncodeError:
        encoding = sys.stdout.encoding or "utf-8"
        safe_text = text.encode(encoding, errors="replace").decode(encoding, errors="replace")
        sys.stdout.write(safe_text)


def main() -> int:
    args = parse_args()
    validate_args(args)

    transcript_path = Path(args.transcript_path)
    segments, source_duration = load_transcript(transcript_path)
    plan = plan_segments(
        segments=segments,
        source_duration=source_duration,
        target_seconds=args.target_seconds,
        min_seconds=args.min_seconds,
        max_seconds=args.max_seconds,
        overlap_seconds=args.overlap_seconds,
        pause_threshold_seconds=args.pause_threshold_seconds,
    )
    write_output(plan, Path(args.output_path) if args.output_path else None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
