"""Makes the images on batches.space: the hero prints, app screens, icons and social preview.

Usage: python3 tools/make_site_images.py   (from the repo root)
App screens are cropped from the 6.9" App Store screenshots, without the status bar.
"""
import os, sys
from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
from compose_app_store_art import photo

SITE = "site"
LANCZOS = Image.Resampling.LANCZOS
os.makedirs(f"{SITE}/img", exist_ok=True)

# Hero prints, each in its true shape: landscape, portrait and panorama.
for name, w, h, seed in [("sunset", 900, 620, 3), ("dawn", 620, 800, 5), ("mono", 900, 600, 8),
                         ("forest", 620, 800, 13), ("night", 900, 600, 21), ("teal", 1200, 480, 34)]:
    photo(name, w, h, seed).save(f"{SITE}/img/print-{name}.jpg", quality=84, optimize=True, progressive=True)

# App screens: find where the phone's bezel starts, then crop inside it.
SHOTS = "marketing/app-store/6.9in-1320x2868"
for shot in ["02-batch", "04-group", "05-share"]:
    im = Image.open(f"{SHOTS}/{shot}.png").convert("RGB")
    top = next(y for y in range(500, 1400) if max(im.getpixel((400, y))) < 26)
    crop = im.crop((140, top + 150, 1180, top + 150 + 1400))
    crop.resize((760, round(760 * 1400 / 1040)), LANCZOS).save(
        f"{SITE}/img/{shot.split('-')[1]}.jpg", quality=84, optimize=True, progressive=True)

icon = Image.open("Strewn/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").convert("RGB")
icon.resize((180, 180), LANCZOS).save(f"{SITE}/apple-touch-icon.png", optimize=True)
icon.resize((64, 64), LANCZOS).save(f"{SITE}/favicon.png", optimize=True)
icon.resize((128, 128), LANCZOS).save(f"{SITE}/img/icon.png", optimize=True)

# 1200x630 social preview, from the middle of the App Store header art.
art = Image.open("marketing/app-store/promo/header-3840x1646.png").convert("RGB")
art.resize((1470, 630), LANCZOS).crop((135, 0, 1335, 630)).save(f"{SITE}/img/og.jpg", quality=84, optimize=True)
print("done")
