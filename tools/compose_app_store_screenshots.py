"""Composes App Store screenshots (6.9" iPhone, 1320x2868) from simulator captures.

Usage: python3 tools/compose_app_store_screenshots.py <captures dir> marketing/app-store
Captures are full-screen simulator PNGs named 1-desk, 2-batch, 3-friends, 4-group, 5-share."""
import random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SHOTS, OUT = sys.argv[1], sys.argv[2]
W, H = 1320, 2868
SERIF = "/System/Library/Fonts/NewYork.ttf"
SANS = "/System/Library/Fonts/SFNS.ttf"

LIGHT = dict(bg=(227, 219, 204), ink=(29, 27, 23), sub=(98, 92, 82), line=(0, 0, 0))
DARK = dict(bg=(38, 36, 31), ink=(242, 236, 225), sub=(176, 168, 154), line=(255, 255, 255))

SCREENS = [
    ("1-desk", "Your photos,\nin batches", "Every day, trip and night out on one desk.", LIGHT),
    ("2-batch", "Full frame.\nNever cropped.", "White borders, instant film, mats and film strips.", LIGHT),
    ("3-friends", "See what your\nfriends share", "Follow people and get their new batches.", LIGHT),
    ("4-group", "Everyone's shots,\none batch", "Let friends add their photos to yours.", DARK),
    ("5-share", "You decide\nwho sees it", "Every batch starts private.", LIGHT),
]


def linen(color, line, seed):
    """A faint woven texture like the app's desk."""
    img = Image.new("RGB", (W, H), color)
    over = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    rnd = random.Random(seed)
    for _ in range(900):
        if rnd.random() < 0.5:
            y = rnd.randrange(H); x = rnd.randrange(W); L = rnd.randrange(30, 220)
            d.line([(x, y), (x + L, y)], fill=line + (rnd.randrange(6, 16),), width=rnd.choice([1, 2]))
        else:
            x = rnd.randrange(W); y = rnd.randrange(H); L = rnd.randrange(30, 220)
            d.line([(x, y), (x, y + L)], fill=line + (rnd.randrange(6, 16),), width=rnd.choice([1, 2]))
    img.paste(over, (0, 0), over)
    return img


def rounded(img, r):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], r, fill=255)
    out = img.convert("RGBA"); out.putalpha(mask)
    return out


def compose(name, title, sub, theme, i):
    canvas = linen(theme["bg"], theme["line"], i).convert("RGBA")
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
    canvas.convert("RGB").save(f"{OUT}/{i + 1:02d}-{name.split('-', 1)[1]}.png", optimize=True)


for i, s in enumerate(SCREENS):
    compose(*s, i)
print("done")
