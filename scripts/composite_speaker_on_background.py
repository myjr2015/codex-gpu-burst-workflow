import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter


def parse_args():
    parser = argparse.ArgumentParser(description="Composite a white-background speaker image onto a target background.")
    parser.add_argument("--background", required=True, help="Background image path")
    parser.add_argument("--speaker", required=True, help="Speaker image path on plain white background")
    parser.add_argument("--output", required=True, help="Output file path")
    parser.add_argument("--speaker-width-ratio", type=float, default=0.56, help="Max speaker width ratio")
    parser.add_argument("--speaker-height-ratio", type=float, default=0.80, help="Max speaker height ratio")
    parser.add_argument("--offset-x", type=int, default=0, help="Speaker x offset in pixels")
    parser.add_argument("--offset-y", type=int, default=0, help="Speaker y offset in pixels")
    parser.add_argument("--crop-top-ratio", type=float, default=0.0, help="Crop top portion after mask bbox, 0-1")
    parser.add_argument("--crop-bottom-ratio", type=float, default=1.0, help="Crop bottom portion after mask bbox, 0-1")
    return parser.parse_args()


def fit_cover(image, size):
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = max(dst_w / src_w, dst_h / src_h)
    resized = image.resize((max(1, int(src_w * scale)), max(1, int(src_h * scale))), Image.Resampling.LANCZOS)
    left = max(0, (resized.width - dst_w) // 2)
    top = max(0, (resized.height - dst_h) // 2)
    return resized.crop((left, top, left + dst_w, top + dst_h))


def fit_contain(image, size):
    src_w, src_h = image.size
    dst_w, dst_h = size
    scale = min(dst_w / src_w, dst_h / src_h)
    return image.resize((max(1, int(src_w * scale)), max(1, int(src_h * scale))), Image.Resampling.LANCZOS)


def border_connected_white_background(img):
    near_white = np.all(img > 246, axis=2) & ((img.max(axis=2) - img.min(axis=2)) < 18)
    component_count, labels = cv2.connectedComponents(near_white.astype(np.uint8), connectivity=8)
    if component_count <= 1:
        return near_white

    border_labels = np.unique(
        np.concatenate([labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]])
    )
    return np.isin(labels, border_labels) & near_white


def keep_largest_component(mask):
    component_count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    if component_count <= 1:
        return mask

    component_areas = stats[1:, cv2.CC_STAT_AREA]
    keep_label = 1 + int(np.argmax(component_areas))
    return np.where(labels == keep_label, 255, 0).astype(np.uint8)


def fill_mask_holes(mask):
    height, width = mask.shape[:2]
    flood = mask.copy()
    flood_fill_mask = np.zeros((height + 2, width + 2), np.uint8)
    cv2.floodFill(flood, flood_fill_mask, (0, 0), 255)
    holes = cv2.bitwise_not(flood)
    return cv2.bitwise_or(mask, holes)


def build_speaker_mask(speaker):
    rgb = speaker.convert("RGB")
    img = np.array(rgb)
    height, width = img.shape[:2]

    gc_mask = np.full((height, width), cv2.GC_PR_BGD, dtype=np.uint8)
    margin = max(6, min(width, height) // 30)
    gc_mask[:margin, :] = cv2.GC_BGD
    gc_mask[-margin:, :] = cv2.GC_BGD
    gc_mask[:, :margin] = cv2.GC_BGD
    gc_mask[:, -margin:] = cv2.GC_BGD

    border_background = border_connected_white_background(img)
    gc_mask[border_background] = cv2.GC_BGD

    strong_foreground = (img.min(axis=2) < 220) | ((img.max(axis=2) - img.min(axis=2)) > 22)
    gc_mask[strong_foreground & ~border_background] = cv2.GC_PR_FGD

    center_x1 = width // 5
    center_x2 = width - center_x1
    center_y1 = height // 8
    center_y2 = height - height // 12
    gc_mask[center_y1:center_y2, center_x1:center_x2] = np.where(
        border_background[center_y1:center_y2, center_x1:center_x2],
        gc_mask[center_y1:center_y2, center_x1:center_x2],
        cv2.GC_PR_FGD,
    )

    bg_model = np.zeros((1, 65), np.float64)
    fg_model = np.zeros((1, 65), np.float64)
    cv2.grabCut(img, gc_mask, None, bg_model, fg_model, 5, cv2.GC_INIT_WITH_MASK)

    mask = np.where((gc_mask == cv2.GC_FGD) | (gc_mask == cv2.GC_PR_FGD), 255, 0).astype(np.uint8)
    if mask.sum() < width * height * 8:
        diff = ImageChops.difference(rgb, Image.new("RGB", rgb.size, (255, 255, 255))).convert("L")
        return diff.point(lambda p: 255 if p > 18 else 0).filter(ImageFilter.GaussianBlur(1.6))

    mask = keep_largest_component(mask)
    close_kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (25, 25))
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, close_kernel)
    mask = fill_mask_holes(mask)

    mask_image = Image.fromarray(mask, mode="L")
    return mask_image.filter(ImageFilter.GaussianBlur(1.4))


def main():
    args = parse_args()
    background = Image.open(args.background).convert("RGBA")
    speaker = Image.open(args.speaker).convert("RGBA")

    width, height = background.size
    mask = build_speaker_mask(speaker)
    bbox = mask.getbbox()
    if not bbox:
        raise RuntimeError("Speaker mask is empty.")

    speaker_crop = speaker.crop(bbox)
    mask_crop = mask.crop(bbox)
    crop_top = max(0.0, min(1.0, args.crop_top_ratio))
    crop_bottom = max(crop_top + 0.05, min(1.0, args.crop_bottom_ratio))
    crop_y1 = int(mask_crop.height * crop_top)
    crop_y2 = max(crop_y1 + 1, int(mask_crop.height * crop_bottom))
    speaker_crop = speaker_crop.crop((0, crop_y1, speaker_crop.width, crop_y2))
    mask_crop = mask_crop.crop((0, crop_y1, mask_crop.width, crop_y2))
    target = fit_contain(
        speaker_crop,
        (int(width * args.speaker_width_ratio), int(height * args.speaker_height_ratio)),
    )
    target_mask = mask_crop.resize(target.size, Image.Resampling.LANCZOS)

    x = (width - target.width) // 2 + args.offset_x
    y = height - target.height - int(height * 0.03) + args.offset_y

    shadow = Image.new("RGBA", background.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        [x + int(target.width * 0.18), y + target.height - 24, x + int(target.width * 0.82), y + target.height + 8],
        fill=(0, 0, 0, 72),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    composed = Image.alpha_composite(background, shadow)

    layer = Image.new("RGBA", background.size, (0, 0, 0, 0))
    layer.paste(target, (x, y), target_mask)
    result = Image.alpha_composite(composed, layer)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path)


if __name__ == "__main__":
    main()
