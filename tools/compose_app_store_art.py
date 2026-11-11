"""Draws the App Store header and search result artwork: piles of framed prints on linen.

Usage: python3 tools/compose_app_store_art.py marketing/app-store/promo
Everything is drawn here at the target size, so no stock photos are involved. No text: the
App Store shows the app's name and subtitle itself.
"""
import math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter

BG =(227, 219, 204)
PAPER = (250, 248, 242)
FILM = (20, 19, 18)

# (sky stops top to bottom, ridge colours back to front, sun position or None, stars)
SCENES = {
    "sunset": ([(58, 44, 98), (214, 92, 74), (250, 176, 84)], [(120, 62, 84), (72, 40, 70), (28, 22, 40)], (0.55, 0.60), False),
    "night": ([(5, 8, 42), (12, 22, 84), (40, 44, 110)], [(120, 74, 36), (176, 110, 44), (40, 24, 16)], None, True),
    "dawn": ([(92, 150, 226), (170, 204, 236), (246, 214, 186)], [(120, 150, 186), (78, 106, 142), (38, 58, 82)], (0.3, 0.62), False),
    "teal": ([(112, 196, 204), (190, 226, 216), (244, 232, 196)], [(76, 150, 150), (40, 104, 110), (18, 62, 70)], None, False),
    "forest": ([(66, 134, 190), (150, 204, 214), (226, 232, 190)], [(70, 122, 88), (42, 92, 58), (20, 58, 36)], None, False),
    "mono": ([(70, 70, 70), (168, 168, 166), (226, 226, 222)], [(120, 120, 118), (72, 72, 70), (28, 28, 28)], None, False),
    "dusk": ([(126, 104, 204), (200, 130, 150), (255, 152, 40)], [(110, 76, 130), (70, 48, 96), (34, 24, 56)], (0.7, 0.66), False),
}
SEA = {"sunset", "mono"}
ROLLING = {"forest", "teal"}


def lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def sky(w, h, stops):
    """A vertical gradient through the stops."""
    col = Image.new("RGB", (1, 512))
    n = len(stops) - 1
    for y in range(512):
        t = y / 511 * n
        i = min(int(t), n - 1)
        col.putpixel((0, y), lerp(stops[i], stops[i + 1], t - i))
    return col.resize((w, h), Image.Resampling.BICUBIC)


def photo(name, w, h, seed):
    stops, ridges, sun, stars = SCENES[name]
    img = sky(w, h, stops)
    rnd = random.Random(seed)
    if stars:
        d = ImageDraw.Draw(img)
        for _ in range(500):
            x, y = rnd.randrange(w), rnd.randrange(round(h * 0.7))
            r = rnd.choice([1, 1, 1, 2]) * max(1, w // 900)
            v = rnd.randrange(150, 255)
            d.ellipse([x, y, x + r, y + r], fill=(v, v, min(255, v + 20)))
    if sun:
        glow = Image.new("L", (w, h), 0)
        cx, cy, r = sun[0] * w, sun[1] * h, w * 0.05
        ImageDraw.Draw(glow).ellipse([cx - r * 2.2, cy - r * 2.2, cx + r * 2.2, cy + r * 2.2], fill=150)
        glow = glow.filter(ImageFilter.GaussianBlur(w * 0.04))
        ImageDraw.Draw(glow).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
        img.paste((255, 236, 190), (0, 0), glow)
    d = ImageDraw.Draw(img)
    if name in SEA:
        # Open water with a headland, not mountains.
        horizon = round(h * 0.64)
        water = sky(w, h - horizon, [lerp(stops[-1], ridges[0], 0.55), ridges[-1]])
        img.paste(water, (0, horizon))
        d = ImageDraw.Draw(img)
        for _ in range(140):
            x, y, L = rnd.randrange(w), rnd.randrange(horizon, h), rnd.randrange(w // 30, w // 7)
            d.line([(x, y), (x + L, y)], fill=lerp(stops[-1], ridges[-1], rnd.uniform(0.1, 0.6)), width=max(1, h // 300))
        d.polygon([(0, horizon), (w * 0.05, h * 0.5), (w * 0.17, h * 0.53), (w * 0.27, h * 0.6), (w * 0.4, horizon)], fill=ridges[-1])
        return img
    for i, colour in enumerate(ridges):
        base = h * (0.56 + 0.15 * i)
        amp = h * (0.13 - 0.025 * i)
        waves = [(rnd.uniform(1.0, 2.2), rnd.uniform(0, 6.3), 1.0), (rnd.uniform(3, 6), rnd.uniform(0, 6.3), 0.42),
                 (rnd.uniform(9, 17), rnd.uniform(0, 6.3), 0.14), (rnd.uniform(26, 48), rnd.uniform(0, 6.3), 0.05)]
        if name in ROLLING:
            waves = waves[:2]
            amp *= 0.6
        points = [(0, h)]
        for x in range(0, w + 8, 8):
            t = x / w * 2 * math.pi
            points.append((x, base - amp * sum(a * math.sin(f * t + p) for f, p, a in waves)))
        points.append((w, h))
        d.polygon(points, fill=colour)
    return img


def print_card(name, w, frame, seed):
    """A framed photo, w wide (photo aspect 4:3 landscape), as RGBA."""
    pw, ph = w, round(w * 0.72)
    img = photo(name, pw, ph, seed)
    if frame == "film":
        band, hole_w, hole_h = round(w * 0.075), round(w * 0.024), round(w * 0.034)
        card = Image.new("RGB", (w + round(w * 0.03), ph + 2 * band), FILM)
        card.paste(img, (round(w * 0.015), band))
        d = ImageDraw.Draw(card)
        step = round(hole_w * 2.1)
        for x in range(round(step * 0.3), card.width - hole_w, step):
            for y in (round((band - hole_h) / 2), card.height - band + round((band - hole_h) / 2)):
                d.rounded_rectangle([x, y, x + hole_w, y + hole_h], hole_w // 5, fill=(236, 232, 224))
    else:
        side = round(w * 0.045)
        bottom = round(w * 0.17) if frame == "instant" else side
        card = Image.new("RGB", (w + 2 * side, ph + side + bottom), PAPER)
        card.paste(img, (side, side))
    return card.convert("RGBA")


def place(canvas, card, cx, cy, angle, shadow_px):
    rot = card.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)
    # Blur a small copy: blurring at full size is slow and looks no different.
    pad = shadow_px * 3
    small = Image.new("L", ((rot.width + 2 * pad) // 4, (rot.height + 2 * pad) // 4), 0)
    small.paste(rot.getchannel("A").resize((rot.width // 4, rot.height // 4)), (pad // 4, pad // 4))
    small = small.filter(ImageFilter.GaussianBlur(shadow_px / 4)).point(lambda v: round(v * 0.42))
    shadow = small.resize((small.width * 4, small.height * 4), Image.Resampling.BICUBIC)
    x, y = round(cx - rot.width / 2), round(cy - rot.height / 2)
    canvas.paste((30, 24, 16), (x - pad, y - pad + shadow_px // 2), shadow)
    canvas.paste(rot, (x, y), rot)


def linen(w, h):
    img = Image.new("RGB", (w, h), BG)
    over = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(over)
    rnd = random.Random(7)
    k = max(1, round(w / 1320))
    for _ in range(round(w * h / 1e6 * 240)):
        x, y, L = rnd.randrange(w), rnd.randrange(h), rnd.randrange(30, 220) * k
        end = (x + L, y) if rnd.random() < 0.5 else (x, y + L)
        d.line([(x, y), end], fill=(0, 0, 0, rnd.randrange(4, 10)), width=rnd.choice([1, 2]) * max(1, k // 2))
    img.paste(over, (0, 0), over)
    return img


PILE = [(-0.30, -0.30, -7), (0.34, -0.10, 6), (-0.26, 0.30, 4), (0.0, 0.0, -2)]
SCATTER = [(-0.42, -0.14, -6), (0.42, -0.22, 8), (0.05, 0.28, -3)]


def pile(canvas, cx, cy, width, scenes, frame, seed, layout=PILE):
    """Prints from back to front; offsets in layout are fractions of width."""
    shadow = round(width * 0.035)
    for i, (dx, dy, angle) in enumerate(layout):
        size = width if i == len(layout) - 1 or layout is SCATTER else round(width * 0.82)
        if layout is SCATTER:
            size = round(width * (0.72, 0.62, 0.8)[i])
        card = print_card(scenes[i % len(scenes)], size, frame, seed + i)
        place(canvas, card, cx + dx * width, cy + dy * width, angle, shadow)


def wide(w, h, unit):
    """Three piles across, the biggest in the middle. unit is the middle print's width."""
    c = linen(w, h).convert("RGB")
    pile(c, w * 0.5 - unit * 1.5, h * 0.5, round(unit * 0.72), ["teal", "mono", "forest", "dawn"], "plain", 11)
    pile(c, w * 0.5 + unit * 1.5, h * 0.5, round(unit * 0.8), ["mono", "teal", "forest"], "film", 41, SCATTER)
    pile(c, w * 0.5, h * 0.5, unit, ["forest", "dawn", "dusk", "sunset"], "plain", 23)
    return c


def single(w, h):
    """One big pile, for the search result slot."""
    c = linen(w, h).convert("RGB")
    pile(c, w * 0.5, h * 0.5, round(h * 0.58), ["teal", "dawn", "night", "dusk"], "plain", 23)
    return c


if __name__ == "__main__":
    OUT = sys.argv[1]
    os.makedirs(OUT, exist_ok=True)
    wide(3840, 1646, 840).save(f"{OUT}/header-3840x1646.png")
    big = single(3840, 2560)
    big.save(f"{OUT}/search-3840x2560.png")
    big.resize((1920, 1280), Image.Resampling.LANCZOS).save(f"{OUT}/search-1920x1280.png")
    single(5244, 2950).save(f"{OUT}/header-or-search-5244x2950.png")  # both slots take this size
    print("done")
