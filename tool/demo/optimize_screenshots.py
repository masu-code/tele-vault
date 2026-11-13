"""Optimises the raw emulator screenshots for the README and landing page.

    python tool/demo/optimize_screenshots.py [raw_dir] [out_dir]

Defaults: build/screenshots_raw -> docs/screenshots. Needs Pillow. Each PNG is
kept at 1080x2400 when a 256-colour palette fits the byte budget, and is scaled
down in steps (keeping the aspect ratio) only when it does not.
"""
import os
import sys

from PIL import Image, ImageChops, ImageStat

BUDGET = 420 * 1024  # bytes per PNG (about 400 KB)
# (width, palette colours), tried in order until one fits the budget
ATTEMPTS = [(1080, 256), (990, 256), (900, 256), (810, 256), (720, 256)]


def encode(img: Image.Image, width: int, colors: int, path: str) -> int:
    """Saves the 256-colour version of [img] with the lower error of two
    quantizers: fewest badly-off channel values first (a small saturated UI detail
    such as a red icon lost to the photo's palette), then the lowest overall
    error (median cut keeps photos smooth)."""
    if width != img.width:
        h = round(img.height * width / img.width)
        img = img.resize((width, h), Image.LANCZOS)
    best, best_err = None, None
    for method in (Image.Quantize.MEDIANCUT, Image.Quantize.FASTOCTREE):
        pal = img.quantize(colors=colors, method=method, dither=Image.Dither.FLOYDSTEINBERG)
        diff = ImageChops.difference(img, pal.convert("RGB"))
        # channel values that are badly off (a lost red icon) weigh more than
        # the smooth overall error
        gross = sum(ImageStat.Stat(diff.point(lambda v: 255 if v > 48 else 0)).sum) / 255
        err = (gross, sum(ImageStat.Stat(diff).sum2))
        if best is None or err < best_err:
            best, best_err = pal, err
    best.save(path, optimize=True)
    return os.path.getsize(path)


def main() -> None:
    raw = sys.argv[1] if len(sys.argv) > 1 else os.path.join("build", "screenshots_raw")
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join("docs", "screenshots")
    os.makedirs(out, exist_ok=True)
    for name in sorted(os.listdir(raw)):
        if not name.endswith(".png"):
            continue
        img = Image.open(os.path.join(raw, name)).convert("RGB")
        dest = os.path.join(out, name)
        for width, colors in ATTEMPTS:
            size = encode(img, width, colors, dest)
            if size <= BUDGET:
                break
        print(f"{name}: {img.width}x{img.height} -> {width}px wide, {size // 1024} KB")


if __name__ == "__main__":
    main()
