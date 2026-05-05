import argparse
import json
import math
import urllib.request
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from composite_speaker_on_background import build_speaker_mask, fit_contain


DEFAULT_BACKGROUND_PROMPT = (
    "bright daytime rooftop photovoltaic installation, vertical short-video framing, "
    "large diagonal blue solar panel field behind the speaker, clean blue sky with soft white clouds, "
    "small beige rooftop utility room in the far right background, realistic rooftop concrete terrace, "
    "bright natural daylight, clean commercial solar power scene, no readable signs, no subtitles, "
    "no stickers, no logos, no extra people"
)

DEFAULT_ACTION_PROMPT = (
    "A single Chinese woman speaks naturally to the camera in a clean rooftop photovoltaic scene. "
    "Use the input RGB anchor for identity, clothing, seated body placement, and background. "
    "Follow only the body pose rhythm, head timing, and hand gesture timing from the clean matte reference video. "
    "Natural lip sync, stable face identity, realistic hands, one person only, no subtitles, no captions, no on-screen text."
)

MEDIAPIPE_SELFIE_SEGMENTER_URL = (
    "https://storage.googleapis.com/mediapipe-models/image_segmenter/"
    "selfie_segmenter/float16/latest/selfie_segmenter.tflite"
)


def parse_args():
    parser = argparse.ArgumentParser(
        description=(
            "Build local LTX2.3 action-mimic assets: a person-matted clean reference video, "
            "a prompt-only background description, and a clean RGB anchor image."
        )
    )
    parser.add_argument("--job-name", required=True)
    parser.add_argument("--source-video", required=True)
    parser.add_argument("--speaker-image", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--start-seconds", type=float, default=0.0)
    parser.add_argument("--duration-seconds", type=float, default=10.0)
    parser.add_argument("--fps", type=float, default=24.0)
    parser.add_argument("--output-width", type=int, default=512)
    parser.add_argument("--output-height", type=int, default=896)
    parser.add_argument(
        "--matte-color",
        default="142,142,142",
        help="RGB matte background for the clean reference video, default neutral gray.",
    )
    parser.add_argument(
        "--mask-threshold",
        type=float,
        default=0.45,
        help="Foreground threshold for person segmentation.",
    )
    parser.add_argument(
        "--segmentation-backend",
        choices=["auto", "mediapipe_tasks", "mediapipe_solutions", "fallback_center_mask"],
        default="auto",
        help="Person segmentation backend. auto requires a real backend unless --allow-fallback is set.",
    )
    parser.add_argument(
        "--model-cache-dir",
        default="",
        help="Optional cache directory for downloaded segmentation models.",
    )
    parser.add_argument(
        "--allow-fallback",
        action="store_true",
        help="Allow the rough center-mask fallback. Production prepare does not enable this.",
    )
    parser.add_argument(
        "--background-prompt",
        default="",
        help="Optional full background prompt override. If omitted, a photovoltaic prompt is written.",
    )
    return parser.parse_args()


def parse_rgb(value):
    parts = [int(part.strip()) for part in value.split(",")]
    if len(parts) != 3 or any(part < 0 or part > 255 for part in parts):
        raise ValueError("--matte-color must be formatted as R,G,B with values 0-255")
    return tuple(parts)


def open_capture(path):
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"Cannot open video: {path}")
    return cap


def read_frame_at(cap, timestamp_seconds):
    cap.set(cv2.CAP_PROP_POS_MSEC, max(0.0, timestamp_seconds) * 1000.0)
    ok, frame = cap.read()
    if not ok or frame is None:
        return None
    return frame


def fit_cover_bgr(frame, size):
    dst_w, dst_h = size
    src_h, src_w = frame.shape[:2]
    scale = max(dst_w / max(1, src_w), dst_h / max(1, src_h))
    resized = cv2.resize(
        frame,
        (max(1, round(src_w * scale)), max(1, round(src_h * scale))),
        interpolation=cv2.INTER_AREA if scale < 1 else cv2.INTER_CUBIC,
    )
    y1 = max(0, (resized.shape[0] - dst_h) // 2)
    x1 = max(0, (resized.shape[1] - dst_w) // 2)
    return resized[y1 : y1 + dst_h, x1 : x1 + dst_w]


def keep_largest_component(mask):
    binary = (mask > 0).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(binary, connectivity=8)
    if count <= 1:
        return mask
    areas = stats[1:, cv2.CC_STAT_AREA]
    keep = 1 + int(np.argmax(areas))
    return np.where(labels == keep, mask, 0).astype(np.uint8)


def build_fallback_center_mask(frame):
    height, width = frame.shape[:2]
    mask = np.zeros((height, width), dtype=np.uint8)
    center = (width // 2, int(height * 0.56))
    axes = (int(width * 0.28), int(height * 0.38))
    cv2.ellipse(mask, center, axes, 0, 0, 360, 255, -1)
    return cv2.GaussianBlur(mask, (31, 31), 0)


def default_model_cache_dir(output_dir):
    if output_dir.parent.name == "_matte_action_assets":
        return output_dir.parent.parent / "_model_cache"
    return output_dir / "_model_cache"


def download_if_missing(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and destination.stat().st_size > 0:
        return False

    tmp_path = destination.with_name(destination.name + ".part")
    if tmp_path.exists():
        tmp_path.unlink()
    urllib.request.urlretrieve(url, tmp_path)
    if not tmp_path.exists() or tmp_path.stat().st_size <= 0:
        raise RuntimeError(f"Downloaded model is empty: {url}")
    tmp_path.replace(destination)
    return True


class MediaPipeTasksSegmenter:
    method_label = "mediapipe_tasks_selfie_segmenter"
    real_backend = True

    def __init__(self, model_path, model_url):
        import mediapipe as mp
        from mediapipe.tasks.python import vision
        from mediapipe.tasks.python.core.base_options import BaseOptions

        self.mp = mp
        self.model_path = Path(model_path)
        self.model_url = model_url
        options = vision.ImageSegmenterOptions(
            base_options=BaseOptions(model_asset_path=str(self.model_path)),
            running_mode=vision.RunningMode.VIDEO,
            output_confidence_masks=True,
        )
        self.segmenter = vision.ImageSegmenter.create_from_options(options)

    def predict(self, frame_bgr, timestamp_ms):
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        image = self.mp.Image(image_format=self.mp.ImageFormat.SRGB, data=rgb)
        result = self.segmenter.segment_for_video(image, int(timestamp_ms))
        if not result.confidence_masks:
            raise RuntimeError("MediaPipe Tasks segmenter returned no confidence masks.")
        raw = result.confidence_masks[0].numpy_view()
        return np.asarray(raw, dtype=np.float32).squeeze()

    def close(self):
        self.segmenter.close()

    def metadata(self):
        return {
            "backend": self.method_label,
            "model_url": self.model_url,
            "model_path": str(self.model_path),
        }


class MediaPipeSolutionsSegmenter:
    method_label = "mediapipe_solutions_selfie_segmentation"
    real_backend = True

    def __init__(self):
        import mediapipe as mp

        try:
            self.segmenter = mp.solutions.selfie_segmentation.SelfieSegmentation(model_selection=1)
        except AttributeError:
            from mediapipe.python.solutions import selfie_segmentation

            self.segmenter = selfie_segmentation.SelfieSegmentation(model_selection=1)

    def predict(self, frame_bgr, timestamp_ms):
        rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
        result = self.segmenter.process(rgb)
        return np.asarray(result.segmentation_mask, dtype=np.float32)

    def close(self):
        self.segmenter.close()

    def metadata(self):
        return {
            "backend": self.method_label,
            "model_url": None,
            "model_path": None,
        }


class FallbackCenterSegmenter:
    method_label = "fallback_center_mask"
    real_backend = False

    def predict(self, frame_bgr, timestamp_ms):
        return build_fallback_center_mask(frame_bgr).astype(np.float32) / 255.0

    def close(self):
        return None

    def metadata(self):
        return {
            "backend": self.method_label,
            "model_url": None,
            "model_path": None,
        }


def create_segmenter(args, output_dir):
    errors = []
    backend = args.segmentation_backend
    model_cache_dir = Path(args.model_cache_dir).resolve() if args.model_cache_dir else default_model_cache_dir(output_dir)

    if backend in ("auto", "mediapipe_tasks"):
        try:
            model_path = model_cache_dir / "selfie_segmenter.tflite"
            download_if_missing(MEDIAPIPE_SELFIE_SEGMENTER_URL, model_path)
            return MediaPipeTasksSegmenter(model_path, MEDIAPIPE_SELFIE_SEGMENTER_URL), errors
        except Exception as exc:
            errors.append(f"mediapipe_tasks: {exc}")
            if backend == "mediapipe_tasks":
                raise

    if backend in ("auto", "mediapipe_solutions"):
        try:
            return MediaPipeSolutionsSegmenter(), errors
        except Exception as exc:
            errors.append(f"mediapipe_solutions: {exc}")
            if backend == "mediapipe_solutions":
                raise

    if backend == "fallback_center_mask" or args.allow_fallback:
        return FallbackCenterSegmenter(), errors

    raise RuntimeError(
        "No real person segmentation backend is available. "
        "Install/repair MediaPipe Tasks or pass --allow-fallback only for debugging. "
        + " | ".join(errors)
    )


def segment_person(segmenter, frame_bgr, threshold, timestamp_ms, previous_mask=None):
    raw = segmenter.predict(frame_bgr, timestamp_ms)
    raw = np.clip(raw, 0.0, 1.0)
    if previous_mask is not None and previous_mask.shape == raw.shape:
        raw = raw * 0.72 + (previous_mask.astype(np.float32) / 255.0) * 0.28

    mask = np.where(raw >= threshold, 255, 0).astype(np.uint8)
    mask = keep_largest_component(mask)
    close_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, close_kernel)
    mask = cv2.GaussianBlur(mask, (17, 17), 0)
    return mask


def make_video_writer(path, width, height, fps):
    path.parent.mkdir(parents=True, exist_ok=True)
    fourcc = cv2.VideoWriter_fourcc(*"mp4v")
    writer = cv2.VideoWriter(str(path), fourcc, fps, (width, height))
    if not writer.isOpened():
        raise RuntimeError(f"Cannot create video writer: {path}")
    return writer


def build_contact_sheet(frames, output_path, columns=4):
    if not frames:
        return
    thumbs = []
    for index, frame_bgr in frames:
        image = Image.fromarray(cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB))
        image.thumbnail((220, 390), Image.Resampling.LANCZOS)
        canvas = Image.new("RGB", (220, 420), (24, 24, 24))
        canvas.paste(image, ((220 - image.width) // 2, 0))
        draw = ImageDraw.Draw(canvas)
        draw.text((8, 394), f"{index:.1f}s", fill=(255, 255, 255))
        thumbs.append(canvas)

    rows = math.ceil(len(thumbs) / columns)
    sheet = Image.new("RGB", (columns * 220, rows * 420), (18, 18, 18))
    for i, thumb in enumerate(thumbs):
        sheet.paste(thumb, ((i % columns) * 220, (i // columns) * 420))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output_path, quality=92)


def draw_panel_grid(draw, polygon, line_color):
    xs = [point[0] for point in polygon]
    ys = [point[1] for point in polygon]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    for x in range(min_x, max_x + 1, 46):
        draw.line([(x, min_y), (x + 110, max_y)], fill=line_color, width=1)
    for y in range(min_y, max_y + 1, 36):
        draw.line([(min_x, y), (max_x, y + 18)], fill=line_color, width=1)


def build_photovoltaic_background(size):
    width, height = size
    bg = Image.new("RGB", size, (110, 164, 224))
    overlay = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)

    for y in range(height):
        alpha = int(70 * y / max(1, height - 1))
        draw.line([(0, y), (width, y)], fill=(255, 255, 255, max(0, 54 - alpha // 2)))
    draw.ellipse((-60, 54, 270, 154), fill=(255, 255, 255, 52))
    draw.ellipse((160, 38, 520, 142), fill=(255, 255, 255, 40))
    overlay = overlay.filter(ImageFilter.GaussianBlur(12))
    bg = Image.alpha_composite(bg.convert("RGBA"), overlay)

    draw = ImageDraw.Draw(bg)
    main_panel = [(-80, 390), (420, 435), (492, 750), (-40, 790)]
    side_panel = [(330, 520), (536, 530), (536, 792), (365, 774)]
    draw.polygon(main_panel, fill=(39, 83, 135, 255))
    draw.polygon(side_panel, fill=(42, 86, 136, 240))
    draw_panel_grid(draw, main_panel, (158, 184, 218, 210))
    draw_panel_grid(draw, side_panel, (158, 184, 218, 190))

    draw.rectangle((373, 340, 482, 483), fill=(203, 194, 176, 255))
    draw.rectangle((360, 322, 494, 346), fill=(165, 159, 148, 255))
    draw.rectangle((404, 288, 458, 342), fill=(196, 188, 171, 235))
    draw.line((373, 412, 482, 412), fill=(128, 124, 116, 180), width=2)

    terrace = [(305, 665), (width, 632), (width, height), (280, height)]
    draw.polygon(terrace, fill=(128, 126, 121, 245))
    draw.line((300, 666, width, 633), fill=(190, 190, 184, 180), width=2)
    return bg


def paste_speaker(background, speaker_path):
    speaker = Image.open(speaker_path).convert("RGBA")
    mask = build_speaker_mask(speaker)
    bbox = mask.getbbox()
    if not bbox:
        raise RuntimeError(f"Speaker mask is empty: {speaker_path}")

    speaker_crop = speaker.crop(bbox)
    mask_crop = mask.crop(bbox)
    width, height = background.size
    fitted = fit_contain(speaker_crop, (int(width * 0.70), int(height * 0.86)))
    fitted_mask = mask_crop.resize(fitted.size, Image.Resampling.LANCZOS)

    x = (width - fitted.width) // 2
    y = height - fitted.height - int(height * 0.018)

    shadow = Image.new("RGBA", background.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        (x + int(fitted.width * 0.16), y + fitted.height - 22, x + int(fitted.width * 0.86), y + fitted.height + 12),
        fill=(0, 0, 0, 84),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(13))
    composed = Image.alpha_composite(background.convert("RGBA"), shadow)

    layer = Image.new("RGBA", background.size, (0, 0, 0, 0))
    layer.paste(fitted, (x, y), fitted_mask)
    return Image.alpha_composite(composed, layer).convert("RGB")


def write_text(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text.strip() + "\n", encoding="utf-8")


def main():
    args = parse_args()
    source_video = Path(args.source_video).resolve()
    speaker_image = Path(args.speaker_image).resolve()
    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    matte_rgb = parse_rgb(args.matte_color)
    width = args.output_width
    height = args.output_height
    frame_count = max(9, math.floor((args.duration_seconds * args.fps) / 8) * 8 + 1)

    cap = open_capture(source_video)
    source_fps = cap.get(cv2.CAP_PROP_FPS) or 0
    source_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    source_width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH) or 0)
    source_height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT) or 0)

    segmenter, segmenter_errors = create_segmenter(args, output_dir)
    method_label = segmenter.method_label
    reference_video = output_dir / "reference_matte_gray.mp4"
    writer = make_video_writer(reference_video, width, height, args.fps)
    sample_frames = []
    previous_mask = None
    last_source_frame = None
    duplicated_tail_frames = 0
    background = np.full((height, width, 3), matte_rgb[::-1], dtype=np.uint8)

    for index in range(frame_count):
        timestamp = args.start_seconds + index / args.fps
        frame = read_frame_at(cap, timestamp)
        if frame is None:
            if last_source_frame is None:
                break
            duplicated_tail_frames += 1
            if duplicated_tail_frames > 2:
                raise RuntimeError(
                    f"Source video ended too early for requested duration; missing frame at {timestamp:.3f}s"
                )
            frame = last_source_frame.copy()
        else:
            last_source_frame = frame.copy()
        frame = fit_cover_bgr(frame, (width, height))
        timestamp_ms = round(index * 1000.0 / args.fps)
        mask = segment_person(segmenter, frame, args.mask_threshold, timestamp_ms, previous_mask)
        previous_mask = mask
        alpha = (mask.astype(np.float32) / 255.0)[:, :, None]
        composed = (frame.astype(np.float32) * alpha + background.astype(np.float32) * (1.0 - alpha)).astype(np.uint8)
        writer.write(composed)
        if index % max(1, round(args.fps)) == 0:
            sample_frames.append((index / args.fps, composed.copy()))

    writer.release()
    cap.release()
    segmenter.close()

    contact_sheet = output_dir / "reference_matte_gray_contact.jpg"
    build_contact_sheet(sample_frames, contact_sheet)

    background_prompt = args.background_prompt.strip() or DEFAULT_BACKGROUND_PROMPT
    prompt_path = output_dir / "background_prompt.txt"
    write_text(prompt_path, background_prompt)

    positive_prompt = (
        DEFAULT_ACTION_PROMPT
        + " Background / scene: "
        + background_prompt
        + ". The clean matte reference video is used only for pose and gesture timing, not for background, text, logos, or identity."
    )
    positive_prompt_path = output_dir / "ltx23_positive_prompt.txt"
    write_text(positive_prompt_path, positive_prompt)

    anchor_background = build_photovoltaic_background((width, height))
    anchor = paste_speaker(anchor_background, speaker_image)
    anchor_png = output_dir / "speaker_rgb_anchor.png"
    anchor_jpg = output_dir / "speaker_rgb_anchor_preview.jpg"
    anchor.save(anchor_png)
    anchor.save(anchor_jpg, quality=92)

    manifest = {
        "job_name": args.job_name,
        "source_video": str(source_video),
        "speaker_image": str(speaker_image),
        "method": method_label,
        "segmentation": {
            **segmenter.metadata(),
            "requested_backend": args.segmentation_backend,
            "real_backend": bool(segmenter.real_backend),
            "mask_threshold": args.mask_threshold,
            "allow_fallback": bool(args.allow_fallback),
            "backend_errors": segmenter_errors,
        },
        "source": {
            "width": source_width,
            "height": source_height,
            "fps": source_fps,
            "frames": source_frames,
            "start_seconds": args.start_seconds,
        },
        "output": {
            "width": width,
            "height": height,
            "fps": args.fps,
            "frame_count": frame_count,
            "expected_video_seconds": frame_count / args.fps,
            "duration_seconds_requested": args.duration_seconds,
            "matte_color_rgb": list(matte_rgb),
            "duplicated_tail_frames": duplicated_tail_frames,
        },
        "artifacts": {
            "reference_video": str(reference_video),
            "reference_contact_sheet": str(contact_sheet),
            "anchor_png": str(anchor_png),
            "anchor_preview": str(anchor_jpg),
            "background_prompt": str(prompt_path),
            "positive_prompt": str(positive_prompt_path),
        },
        "background_prompt": background_prompt,
        "positive_prompt": positive_prompt,
        "notes": [
            "The matte reference is only for action/pose timing.",
            "The final scene should come from the RGB anchor and prompt, not the original video background.",
            "This avoids subtitle/sticker/logo contamination from the source video motion condition.",
        ],
    }
    manifest_path = output_dir / "matte_action_assets_manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
