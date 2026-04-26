import argparse
import json
from faster_whisper import WhisperModel


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio-path", required=True)
    parser.add_argument("--output-path")
    parser.add_argument("--language", default="zh")
    parser.add_argument("--model", default="small")
    parser.add_argument("--device", default="auto")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--beam-size", type=int, default=5)
    return parser.parse_args()


def normalize_segment(segment):
    return {
        "id": getattr(segment, "id", None),
        "start": float(segment.start),
        "end": float(segment.end),
        "text": segment.text.strip(),
    }


def main():
    args = parse_args()
    model = WhisperModel(args.model, device=args.device, compute_type=args.compute_type)
    segments, info = model.transcribe(
        args.audio_path,
        language=args.language or None,
        vad_filter=True,
        beam_size=args.beam_size,
    )

    normalized_segments = [normalize_segment(segment) for segment in segments]
    text = "".join(segment["text"] for segment in normalized_segments).strip()

    payload = {
        "text": text,
        "segments": normalized_segments,
        "language": getattr(info, "language", None),
        "languageProbability": getattr(info, "language_probability", None),
    }

    rendered = json.dumps(payload, ensure_ascii=False)

    if args.output_path:
        with open(args.output_path, "w", encoding="utf-8") as handle:
            handle.write(rendered + "\n")

    print(
        rendered
    )


if __name__ == "__main__":
    main()
