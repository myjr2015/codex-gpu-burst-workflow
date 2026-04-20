import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


def parse_args():
    parser = argparse.ArgumentParser(description="Build combo-2 anchor from scene structure and a clean speaker image.")
    parser.add_argument("--reference", required=True, help="Reference clean scene frame")
    parser.add_argument("--speaker", required=True, help="Speaker image on plain background")
    parser.add_argument("--output", required=True, help="Output composite anchor path")
    return parser.parse_args()


def fit_cover(image, size):
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = max(dst_w / src_w, dst_h / src_h)
    resized = image.resize((int(src_w * scale), int(src_h * scale)), Image.Resampling.LANCZOS)
    left = max(0, (resized.width - dst_w) // 2)
    top = max(0, (resized.height - dst_h) // 2)
    return resized.crop((left, top, left + dst_w, top + dst_h))


def fit_contain(image, size):
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = min(dst_w / src_w, dst_h / src_h)
    resized = image.resize((max(1, int(src_w * scale)), max(1, int(src_h * scale))), Image.Resampling.LANCZOS)
    return resized


def build_background(reference):
    return reference.convert("RGBA")


def build_speaker_mask(speaker):
    rgb = speaker.convert("RGB")
    white_bg = Image.new("RGB", rgb.size, (255, 255, 255))
    diff = ImageChops.difference(rgb, white_bg).convert("L")
    mask = diff.point(lambda p: 255 if p > 18 else 0)
    mask = mask.filter(ImageFilter.GaussianBlur(1.6))
    return mask


def prepare_speaker_layer(size, speaker):
    width, height = size
    speaker_rgba = speaker.convert("RGBA")
    mask = build_speaker_mask(speaker_rgba)
    bbox = mask.getbbox()
    if not bbox:
        raise RuntimeError("Speaker mask is empty.")

    speaker_crop = speaker_rgba.crop(bbox)
    mask_crop = mask.crop(bbox)

    target = fit_contain(speaker_crop, (int(width * 0.62), int(height * 0.90)))
    target_mask = mask_crop.resize(target.size, Image.Resampling.LANCZOS)

    x = (width - target.width) // 2 + 18
    y = height - target.height - 2

    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    layer.paste(target, (x, y), target_mask)
    return layer, (x, y, target.width, target.height)


def composite_speaker(background, speaker_layer, speaker_bounds):
    width, height = background.size
    x, y, target_width, target_height = speaker_bounds

    shadow = Image.new("RGBA", background.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        [x + int(target_width * 0.18), y + target_height - 34, x + int(target_width * 0.82), y + target_height - 1],
        fill=(0, 0, 0, 72)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(12))

    composed = Image.alpha_composite(background, shadow)
    return Image.alpha_composite(composed, speaker_layer)


def cleanup_ground_artifacts(image):
    width, height = image.size
    patch = image.crop((int(width * 0.83), int(height * 0.70), width, int(height * 0.90)))
    patch = patch.resize((int(width * 0.25), int(height * 0.30)), Image.Resampling.LANCZOS)

    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    layer.paste(patch, (int(width * 0.75), int(height * 0.70)))

    mask = Image.new("L", image.size, 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon(
        [
            (int(width * 0.78), int(height * 0.84)),
            (width, int(height * 0.82)),
            (width, height),
            (int(width * 0.67), height),
            (int(width * 0.72), int(height * 0.92)),
        ],
        fill=255,
    )
    mask = mask.filter(ImageFilter.GaussianBlur(6))
    return Image.composite(layer, image, mask)


def main():
    args = parse_args()
    reference = Image.open(args.reference).convert("RGBA")
    speaker = Image.open(args.speaker).convert("RGBA")

    speaker_layer, speaker_bounds = prepare_speaker_layer(reference.size, speaker)
    background = build_background(reference)
    result = composite_speaker(background, speaker_layer, speaker_bounds)
    result = cleanup_ground_artifacts(result)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path)


if __name__ == "__main__":
    main()
