import argparse
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter


def parse_args():
    parser = argparse.ArgumentParser(description="Build a true combo-2 anchor with a newly reconstructed solar rooftop scene.")
    parser.add_argument("--reference", required=True, help="Reference clean scene frame")
    parser.add_argument("--speaker", required=True, help="Speaker image on plain background")
    parser.add_argument("--output", required=True, help="Output anchor path")
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


def build_speaker_mask(speaker):
    rgb = speaker.convert("RGB")
    diff = ImageChops.difference(rgb, Image.new("RGB", rgb.size, (255, 255, 255))).convert("L")
    mask = diff.point(lambda p: 255 if p > 18 else 0)
    return mask.filter(ImageFilter.GaussianBlur(1.5))


def repeat_texture(tile, size):
    cols = size[0] // tile.width + 2
    rows = size[1] // tile.height + 2
    canvas = Image.new("RGB", (tile.width * cols, tile.height * rows))
    for row in range(rows):
        for col in range(cols):
            canvas.paste(tile, (col * tile.width, row * tile.height))
    return canvas.crop((0, 0, size[0], size[1]))


def make_panel_texture(size, base_rgb):
    width, height = size
    texture = Image.new("RGB", size, base_rgb)
    draw = ImageDraw.Draw(texture)

    # Add a gentle vertical gradient so the panel field does not look flat.
    gradient = Image.new("RGBA", size, (0, 0, 0, 0))
    gradient_draw = ImageDraw.Draw(gradient)
    for row in range(height):
        alpha = int(34 * (row / max(1, height - 1)))
        gradient_draw.line([(0, row), (width, row)], fill=(0, 18, 38, alpha))
    texture = Image.alpha_composite(texture.convert("RGBA"), gradient).convert("RGB")
    draw = ImageDraw.Draw(texture)

    cell_w = max(32, width // 12)
    cell_h = max(22, height // 9)
    for x in range(0, width, cell_w):
        draw.line([(x, 0), (x, height)], fill=(198, 214, 238), width=2)
    for y in range(0, height, cell_h):
        draw.line([(0, y), (width, y)], fill=(198, 214, 238), width=2)
    for x in range(-height, width, 44):
        draw.line([(x, 0), (x + height // 2, height)], fill=(120, 146, 190), width=1)
    return texture


def warp_texture_to_polygon(texture, canvas_size, polygon, blur_radius=0.0):
    width, height = canvas_size
    src = np.array(
        [[0, 0], [texture.width - 1, 0], [texture.width - 1, texture.height - 1], [0, texture.height - 1]],
        dtype=np.float32,
    )
    dst = np.array(polygon, dtype=np.float32)
    matrix = cv2.getPerspectiveTransform(src, dst)
    warped = cv2.warpPerspective(
        cv2.cvtColor(np.array(texture), cv2.COLOR_RGB2BGR),
        matrix,
        (width, height),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_TRANSPARENT,
    )
    warped = cv2.cvtColor(warped, cv2.COLOR_BGR2RGB)
    image = Image.fromarray(warped)

    mask = Image.new("L", canvas_size, 0)
    ImageDraw.Draw(mask).polygon(polygon, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(1.5))
    if blur_radius > 0:
        image = image.filter(ImageFilter.GaussianBlur(blur_radius))
    return image.convert("RGBA"), mask


def composite_layer(base, layer, mask):
    return Image.composite(layer, base, mask)


def build_background(reference):
    width, height = reference.size
    reference = reference.convert("RGB")

    sky_src = reference.crop((0, 0, width, int(height * 0.34)))
    sky = fit_cover(sky_src, (width, height))
    sky = sky.filter(ImageFilter.GaussianBlur(4))

    # Rebuild a cleaner sky and keep it visibly different from the original frame.
    tint = Image.new("RGBA", (width, height), (92, 145, 220, 68))
    background = Image.alpha_composite(sky.convert("RGBA"), tint)

    cloud_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    cloud_draw = ImageDraw.Draw(cloud_layer)
    cloud_draw.ellipse((20, 52, 290, 150), fill=(255, 255, 255, 48))
    cloud_draw.ellipse((180, 72, 480, 180), fill=(255, 255, 255, 42))
    cloud_draw.ellipse((250, 20, 520, 110), fill=(255, 255, 255, 26))
    cloud_layer = cloud_layer.filter(ImageFilter.GaussianBlur(26))
    background = Image.alpha_composite(background, cloud_layer)

    panel_src = reference.crop((14, int(height * 0.50), int(width * 0.22), int(height * 0.82)))
    panel_np = np.array(panel_src)
    panel_rgb = tuple(int(x) for x in panel_np.reshape(-1, 3).mean(axis=0))
    panel_texture = make_panel_texture((700, 460), panel_rgb)

    panel_poly_main = [
        (-70, int(height * 0.46)),
        (int(width * 0.82), int(height * 0.52)),
        (int(width * 0.95), int(height * 0.83)),
        (-15, int(height * 0.87)),
    ]
    main_panel, main_mask = warp_texture_to_polygon(panel_texture, (width, height), panel_poly_main, blur_radius=0.1)
    background = composite_layer(background, main_panel, main_mask)

    panel_poly_side = [
        (int(width * 0.58), int(height * 0.60)),
        (width, int(height * 0.61)),
        (width, int(height * 0.88)),
        (int(width * 0.66), int(height * 0.86)),
    ]
    side_panel, side_mask = warp_texture_to_polygon(panel_texture, (width, height), panel_poly_side, blur_radius=0.08)
    side_mask = side_mask.point(lambda p: int(p * 0.82))
    background = composite_layer(background, side_panel, side_mask)

    ridge = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ridge_draw = ImageDraw.Draw(ridge)
    ridge_draw.line(
        [(0, int(height * 0.57)), (width, int(height * 0.585))],
        fill=(185, 190, 204, 255),
        width=3,
    )
    ridge = ridge.filter(ImageFilter.GaussianBlur(0.4))
    background = Image.alpha_composite(background, ridge)

    building_src = reference.crop((int(width * 0.74), int(height * 0.35), int(width * 0.96), int(height * 0.56)))
    building_np = np.array(building_src)
    wall_rgb = tuple(int(x) for x in building_np.reshape(-1, 3).mean(axis=0))
    roof_rgb = tuple(max(0, min(255, c - 26)) for c in wall_rgb)

    building_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    building_draw = ImageDraw.Draw(building_layer)
    building_draw.rectangle(
        [int(width * 0.73), int(height * 0.40), int(width * 0.93), int(height * 0.56)],
        fill=wall_rgb + (255,),
    )
    building_draw.rectangle(
        [int(width * 0.71), int(height * 0.38), int(width * 0.95), int(height * 0.41)],
        fill=roof_rgb + (255,),
    )
    building_draw.rectangle(
        [int(width * 0.78), int(height * 0.33), int(width * 0.89), int(height * 0.40)],
        fill=wall_rgb + (235,),
    )
    building_draw.line(
        [(int(width * 0.73), int(height * 0.48)), (int(width * 0.93), int(height * 0.48))],
        fill=(120, 126, 134, 180),
        width=2,
    )
    building_layer = building_layer.filter(ImageFilter.GaussianBlur(0.6))
    background = Image.alpha_composite(background, building_layer)

    side_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    side_draw = ImageDraw.Draw(side_layer)
    side_draw.rectangle(
        [int(width * 0.56), int(height * 0.46), int(width * 0.64), int(height * 0.53)],
        fill=wall_rgb + (180,),
    )
    side_draw.rectangle(
        [int(width * 0.55), int(height * 0.445), int(width * 0.65), int(height * 0.465)],
        fill=roof_rgb + (180,),
    )
    side_layer = side_layer.filter(ImageFilter.GaussianBlur(1.1))
    background = Image.alpha_composite(background, side_layer)

    ground_src = reference.crop((int(width * 0.74), int(height * 0.77), width, height))
    ground = fit_cover(ground_src, (int(width * 0.36), int(height * 0.28)))
    floor_layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    floor_mask = Image.new("L", (width, height), 0)
    floor_poly = [
        (int(width * 0.58), int(height * 0.73)),
        (width, int(height * 0.71)),
        (width, height),
        (int(width * 0.54), height),
    ]
    floor_layer.paste(ground, (int(width * 0.64), int(height * 0.73)))
    ImageDraw.Draw(floor_mask).polygon(floor_poly, fill=255)
    floor_mask = floor_mask.filter(ImageFilter.GaussianBlur(4))
    background = composite_layer(background, floor_layer, floor_mask)

    floor_tint = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    floor_draw = ImageDraw.Draw(floor_tint)
    floor_draw.polygon(
        [
            (int(width * 0.60), int(height * 0.72)),
            (width, int(height * 0.70)),
            (width, height),
            (int(width * 0.56), height),
        ],
        fill=(98, 98, 102, 48),
    )
    floor_tint = floor_tint.filter(ImageFilter.GaussianBlur(8))
    background = Image.alpha_composite(background, floor_tint)

    glare = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    glare_draw = ImageDraw.Draw(glare)
    glare_draw.ellipse((int(width * 0.06), int(height * 0.44), int(width * 0.44), int(height * 0.78)), fill=(255, 255, 255, 28))
    glare = glare.filter(ImageFilter.GaussianBlur(22))
    background = Image.alpha_composite(background, glare)

    return background


def composite_speaker(background, speaker):
    width, height = background.size
    mask = build_speaker_mask(speaker)
    bbox = mask.getbbox()
    if not bbox:
        raise RuntimeError("Speaker mask is empty.")

    speaker_crop = speaker.crop(bbox)
    mask_crop = mask.crop(bbox)
    target = fit_contain(speaker_crop, (int(width * 0.56), int(height * 0.78)))
    target_mask = mask_crop.resize(target.size, Image.Resampling.LANCZOS)

    x = (width - target.width) // 2 + 12
    y = height - target.height - int(height * 0.03)

    shadow = Image.new("RGBA", background.size, (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.ellipse(
        [x + int(target.width * 0.18), y + target.height - 24, x + int(target.width * 0.86), y + target.height + 8],
        fill=(0, 0, 0, 88),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(12))
    composed = Image.alpha_composite(background, shadow)

    layer = Image.new("RGBA", background.size, (0, 0, 0, 0))
    layer.paste(target, (x, y), target_mask)
    return Image.alpha_composite(composed, layer)


def main():
    args = parse_args()
    reference = Image.open(args.reference).convert("RGBA")
    speaker = Image.open(args.speaker).convert("RGBA")

    background = build_background(reference)
    result = composite_speaker(background, speaker)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    result.save(output_path)


if __name__ == "__main__":
    main()
