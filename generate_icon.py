#!/usr/bin/env python3
"""Generate a macOS app icon for Crate Digr.
Style: Glossy aqua macOS icon with vinyl record, download arrow on center label.
No YouTube play button. No text on vinyl.
"""

from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math
import os

SIZE = 1024
PAD = 40
CENTER = SIZE // 2


def create_icon():
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # === 1. ROUNDED SQUARE BACKGROUND ===
    corner_radius = int(SIZE * 0.22)
    sq = [PAD, PAD, SIZE - PAD, SIZE - PAD]

    # Base dark fill
    draw.rounded_rectangle(sq, radius=corner_radius, fill=(18, 18, 24, 255))

    # Gradient overlay: top slightly lighter, bottom darker
    grad = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(PAD, SIZE - PAD):
        t = (y - PAD) / (SIZE - 2 * PAD)
        r = int(42 - 24 * t)
        g = int(42 - 24 * t)
        b = int(52 - 28 * t)
        gd.line([(PAD, y), (SIZE - PAD, y)], fill=(r, g, b, 255))
    mask = Image.new('L', (SIZE, SIZE), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle(sq, radius=corner_radius, fill=255)
    grad.putalpha(mask)
    img = Image.alpha_composite(img, grad)
    draw = ImageDraw.Draw(img)

    # === 2. VINYL RECORD ===
    vinyl_cx = CENTER
    vinyl_cy = CENTER + 20
    vinyl_r = 340  # Large vinyl filling most of the icon

    # Outer rim glow
    for r in range(vinyl_r + 8, vinyl_r, -1):
        alpha = 40 + (vinyl_r + 8 - r) * 20
        draw.ellipse(
            [vinyl_cx - r, vinyl_cy - r, vinyl_cx + r, vinyl_cy + r],
            outline=(60, 60, 70, min(255, alpha)), width=1
        )

    # Main vinyl body (near black)
    draw.ellipse(
        [vinyl_cx - vinyl_r, vinyl_cy - vinyl_r,
         vinyl_cx + vinyl_r, vinyl_cy + vinyl_r],
        fill=(10, 10, 14, 255)
    )

    # Grooves - concentric circles with subtle brightness variation
    label_outer = 100  # Where the label ends and grooves begin
    for i in range(label_outer + 5, vinyl_r - 15, 3):
        brightness = 28 + (i % 9) * 3
        draw.ellipse(
            [vinyl_cx - i, vinyl_cy - i, vinyl_cx + i, vinyl_cy + i],
            outline=(brightness, brightness, brightness + 4, 65), width=1
        )

    # Vinyl light reflection (subtle arc shine on lower-left)
    ref = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ref)
    for angle in range(200, 320):
        rad = math.radians(angle)
        for r_off in range(vinyl_r - 120, vinyl_r - 30):
            x = int(vinyl_cx + r_off * math.cos(rad))
            y = int(vinyl_cy + r_off * math.sin(rad))
            if 0 <= x < SIZE and 0 <= y < SIZE:
                dist = abs(angle - 260) / 60.0
                a = int(18 * max(0, 1 - dist))
                if a > 0:
                    rd.point((x, y), fill=(140, 160, 200, a))
    img = Image.alpha_composite(img, ref)
    draw = ImageDraw.Draw(img)

    # Second reflection (upper-right, subtle)
    ref2 = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    rd2 = ImageDraw.Draw(ref2)
    for angle in range(30, 100):
        rad = math.radians(angle)
        for r_off in range(vinyl_r - 160, vinyl_r - 60):
            x = int(vinyl_cx + r_off * math.cos(rad))
            y = int(vinyl_cy + r_off * math.sin(rad))
            if 0 <= x < SIZE and 0 <= y < SIZE:
                dist = abs(angle - 65) / 35.0
                a = int(12 * max(0, 1 - dist))
                if a > 0:
                    rd2.point((x, y), fill=(180, 200, 240, a))
    img = Image.alpha_composite(img, ref2)
    draw = ImageDraw.Draw(img)

    # === 3. RED CENTER LABEL ===
    label_r = 100
    # Gradient red label
    for r in range(label_r, 0, -1):
        ratio = r / label_r
        # Rich red with slight gradient
        red = int(190 + 65 * (1 - ratio))
        green = int(20 + 20 * (1 - ratio))
        blue = int(20 + 15 * (1 - ratio))
        draw.ellipse(
            [vinyl_cx - r, vinyl_cy - r, vinyl_cx + r, vinyl_cy + r],
            fill=(red, green, blue, 255)
        )

    # Label highlight (top arc shine)
    for r in range(label_r - 8, label_r - 35, -1):
        a = int(30 * (r - (label_r - 35)) / 27)
        draw.arc(
            [vinyl_cx - r, vinyl_cy - r, vinyl_cx + r, vinyl_cy + r],
            start=200, end=340,
            fill=(255, 255, 255, max(0, a)), width=1
        )

    # === 4. DOWNLOAD ARROW ON THE LABEL (centered) ===
    # Arrow stem
    stem_w = 14
    stem_top = vinyl_cy - 52
    stem_bottom = vinyl_cy + 12
    draw.rectangle(
        [vinyl_cx - stem_w, stem_top, vinyl_cx + stem_w, stem_bottom],
        fill=(255, 255, 255, 240)
    )

    # Arrow head (downward pointing triangle)
    arrow_head_w = 42
    arrow_head_h = 36
    draw.polygon([
        (vinyl_cx - arrow_head_w, stem_bottom - 2),
        (vinyl_cx + arrow_head_w, stem_bottom - 2),
        (vinyl_cx, stem_bottom + arrow_head_h)
    ], fill=(255, 255, 255, 240))

    # Horizontal base line under the arrow
    line_y = stem_bottom + arrow_head_h + 10
    line_hw = 38
    line_h = 7
    draw.rectangle(
        [vinyl_cx - line_hw, line_y, vinyl_cx + line_hw, line_y + line_h],
        fill=(255, 255, 255, 240)
    )

    # Center spindle hole (small dot)
    # Skipping spindle hole since the download arrow covers the center

    # === 5. AQUA GLOSS (top half shine on the rounded square) ===
    gloss = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(gloss)
    for y in range(PAD, CENTER - 60):
        t = (y - PAD) / (CENTER - 60 - PAD)
        a = int(22 * (1 - t * t))
        gd.line([(PAD + 30, y), (SIZE - PAD - 30, y)], fill=(255, 255, 255, a))
    gloss_mask = Image.new('L', (SIZE, SIZE), 0)
    gmd = ImageDraw.Draw(gloss_mask)
    gmd.rounded_rectangle(sq, radius=corner_radius, fill=255)
    gloss.putalpha(ImageChops.darker(gloss.split()[3], gloss_mask))
    img = Image.alpha_composite(img, gloss)

    # === 6. EDGE HIGHLIGHT ===
    edge = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    ed = ImageDraw.Draw(edge)
    ed.rounded_rectangle(sq, radius=corner_radius, outline=(255, 255, 255, 30), width=2)
    img = Image.alpha_composite(img, edge)

    return img


def create_iconset(img, output_dir):
    iconset_dir = os.path.join(output_dir, "AppIcon.iconset")
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png"),
    ]

    for size, filename in sizes:
        resized = img.resize((size, size), Image.LANCZOS)
        resized.save(os.path.join(iconset_dir, filename))

    return iconset_dir


if __name__ == "__main__":
    print("Generating Crate Digr icon v3...")
    icon = create_icon()

    output_dir = "/Users/gustavolima/Desktop/YoutubeWav"
    preview_path = os.path.join(output_dir, "icon_preview.png")
    icon.save(preview_path)
    print(f"Preview saved: {preview_path}")

    # Also save to xcassets
    xcassets_dir = os.path.join(output_dir, "CrateDigr", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    if os.path.isdir(xcassets_dir):
        sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for size, filename in sizes:
            resized = icon.resize((size, size), Image.LANCZOS)
            resized.save(os.path.join(xcassets_dir, filename))
        print(f"Updated xcassets icons in {xcassets_dir}")

    # Generate .icns
    iconset_dir = create_iconset(icon, output_dir)
    icns_path = os.path.join(output_dir, "CrateDigr", "Resources", "AppIcon.icns")
    os.system(f'iconutil -c icns "{iconset_dir}" -o "{icns_path}"')
    print(f"Generated .icns: {icns_path}")

    import shutil
    shutil.rmtree(iconset_dir)
    print("Done!")
