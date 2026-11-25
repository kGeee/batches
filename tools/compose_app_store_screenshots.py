"""Composes App Store screenshots (6.9" iPhone, 1320x2868) from simulator captures.

Usage: python3 tools/compose_app_store_screenshots.py <captures dir> marketing/app-store
Captures are full-screen 6.9" simulator PNGs named 1-desk, 2-batch, 3-friends, 4-photo, 5-group,
6-share. Writes one folder per App Store Connect slot, named for its slot and pixel size."""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS, OUT = sys.argv[1], sys.argv[2]
W, H = 1320, 2868
SERIF = "/System/Library/Fonts/NewYork.ttf"
SANS = "/System/Library/Fonts/SFNS.ttf"

# App Store Connect slot -> pixel size. A slot rejects any size it doesn't list.
SIZES = [("6.9in", (1320, 2868)), ("6.9in", (1290, 2796)), ("6.5in", (1284, 2778)), ("6.5in", (1242, 2688)),
         ("6.3in", (1206, 2622)), ("6.1in", (1179, 2556))]

# The app's fog: a flat grey-green by day, a deep one at night.
LIGHT = dict(bg=(227, 229, 224), ink=(43, 46, 44), sub=(112, 118, 113))
DARK = dict(bg=(27, 29, 28), ink=(236, 238, 234), sub=(160, 166, 160))

SCREENS = [
    ("1-desk", "Your photos,\nin batches", "Every day, trip and night out on one desk.", LIGHT),
    ("2-batch", "Full frame.\nNever cropped.", "White borders, instant film, mats and film strips.", LIGHT),
    ("3-friends", "See what your\nfriends share", "Follow people and get their new batches.", LIGHT),
    ("4-photo", "Double-tap\nto like", "Comments from the people who were there.", LIGHT),
    ("5-group", "Everyone's shots,\none batch", "Let friends add their photos to yours.", DARK),
    ("6-share", "You decide\nwho sees it", "Every batch starts private.", LIGHT),
]


def rounded(img, r):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], r, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out


def compose(name, title, sub, theme, i):
    canvas = Image.new("RGBA", (W, H), theme["bg"] + (255,))
    d = ImageDraw.Draw(canvas)
    tfont = ImageFont.truetype(SERIF, 124)
    try:
        tfont.set_variation_by_name("Bold")
    except Exception:
        pass
    sfont = ImageFont.truetype(SANS, 50)
    d.multiline_text((W / 2, 190), title, font=tfont, fill=theme["ink"], anchor="ma", align="center", spacing=18)
    tb = d.multiline_textbbox((W / 2, 190), title, font=tfont, anchor="ma", align="center", spacing=18)
    d.text((W / 2, tb[3] + 48), sub, font=sfont, fill=theme["sub"], anchor="ma")

    # Phone: the capture inside a thin dark bezel, bleeding off the bottom edge.
    shot = Image.open(f"{SHOTS}/{name}.png").convert("RGB")
    sw = 1040
    sh = round(shot.height * sw / shot.width)
    screen = rounded(shot.resize((sw, sh), Image.Resampling.LANCZOS), 118)
    bez = 22
    phone = Image.new("RGBA", (sw + 2 * bez, sh + 2 * bez), (0, 0, 0, 0))
    ImageDraw.Draw(phone).rounded_rectangle([0, 0, phone.width - 1, phone.height - 1], 118 + bez, fill=(18, 18, 18, 255))
    phone.paste(screen, (bez, bez), screen)
    top = tb[3] + 170
    x = (W - phone.width) // 2

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([x + 10, top + 40, x + phone.width - 10, top + phone.height], 140, fill=(0, 0, 0, 110))
    shadow = shadow.filter(ImageFilter.GaussianBlur(50))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.paste(phone, (x, top), phone)
    art = canvas.convert("RGB")
    for slot, (w, h) in SIZES:
        # Scale to cover, then trim the few pixels the slightly different shapes leave over.
        s = max(w / W, h / H)
        out = art.resize((round(W * s), round(H * s)), Image.Resampling.LANCZOS)
        x, y = (out.width - w) // 2, (out.height - h) // 2
        folder = f"{OUT}/{slot}-{w}x{h}"
        os.makedirs(folder, exist_ok=True)
        out.crop((x, y, x + w, y + h)).save(f"{folder}/{i + 1:02d}-{name.split('-', 1)[1]}.png", optimize=True)


for i, s in enumerate(SCREENS):
    compose(*s, i)
print("done")
