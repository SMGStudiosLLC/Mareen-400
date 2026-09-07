#!/usr/bin/env python3
"""Tuning lab: contact sheets, crops, charts and color statistics.

    python3 Tools/ref/lab.py sheet out.jpg a.jpg b.jpg [c.jpg ...] [--labels A,B,C] [--crop x,y,w,h] [--width 2000]
    python3 Tools/ref/lab.py charts outdir           # synthetic test charts
    python3 Tools/ref/lab.py stats image.png          # OKLab summary of an image
    python3 Tools/ref/lab.py ramp image.png           # neutral ramp trace (for chart renders)

The sheet command lays images side by side at a common height and, with
--crop, adds a second row of 100% crops so grain and halation can be judged
at pixel scale. Sheets are capped at --width pixels so they stay viewable.
"""
import argparse
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageOps


def load(path):
    return ImageOps.exif_transpose(Image.open(path)).convert("RGB")


# ------------------------------------------------------------------ color math

def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.0031308, 12.92 * c, 1.055 * np.power(np.maximum(c, 0), 1 / 2.4) - 0.055)


M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])


def rgb_to_oklab(rgb01):
    lin = srgb_to_linear(rgb01)
    lms = lin @ M1.T
    lms = np.cbrt(lms)
    return lms @ M2.T


def oklch(lab):
    L = lab[..., 0]
    C = np.hypot(lab[..., 1], lab[..., 2])
    h = (np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) + 360.0) % 360.0
    return L, C, h


def delta_e_ok(a, b):
    """Euclidean distance in OKLab scaled by 100 (roughly comparable to dE2000 for small differences)."""
    return np.linalg.norm(rgb_to_oklab(a) - rgb_to_oklab(b), axis=-1) * 100.0


# ------------------------------------------------------------------ sheets

def sheet(args):
    images = [load(p) for p in args.images]
    labels = args.labels.split(",") if args.labels else [Path(p).stem for p in args.images]
    n = len(images)
    width = args.width
    gap = 6
    tile_w = (width - gap * (n - 1)) // n
    rows = []
    # Row 1: fit each image to tile width.
    scaled = []
    for im in images:
        s = tile_w / im.width
        scaled.append(im.resize((tile_w, max(1, int(im.height * s))), Image.LANCZOS))
    row_h = max(im.height for im in scaled)
    row = Image.new("RGB", (width, row_h + 22), (24, 24, 24))
    d = ImageDraw.Draw(row)
    for i, im in enumerate(scaled):
        row.paste(im, (i * (tile_w + gap), 22))
        d.text((i * (tile_w + gap) + 6, 4), labels[i] if i < len(labels) else "", fill=(230, 230, 230))
    rows.append(row)
    # Row 2: 100% crops.
    if args.crop:
        x, y, w, h = [int(v) for v in args.crop.split(",")]
        cw = min(w, tile_w)
        ch = int(h * cw / w) if w > tile_w else h
        crop_row = Image.new("RGB", (width, ch + 22), (24, 24, 24))
        d2 = ImageDraw.Draw(crop_row)
        for i, im in enumerate(images):
            c = im.crop((x, y, x + w, y + h))
            if w > tile_w:
                c = c.resize((cw, ch), Image.LANCZOS)
            crop_row.paste(c, (i * (tile_w + gap), 22))
            d2.text((i * (tile_w + gap) + 6, 4), f"crop {x},{y} {w}x{h}", fill=(230, 230, 230))
        rows.append(crop_row)
    total_h = sum(r.height for r in rows) + gap * (len(rows) - 1)
    out = Image.new("RGB", (width, total_h), (24, 24, 24))
    yy = 0
    for r in rows:
        out.paste(r, (0, yy))
        yy += r.height + gap
    out.save(args.out, quality=92)
    print(f"wrote {args.out} {out.size}")


# ------------------------------------------------------------------ charts

def charts(args):
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    # Neutral ramp: 1024 x 256, encoded values 0..1 left to right, with a
    # lower band of 33 discrete steps for banding checks.
    w, h = 1024, 256
    ramp = np.linspace(0, 1, w)[None, :].repeat(h, 0)
    steps = np.floor(ramp * 32) / 32
    img = np.where(np.arange(h)[:, None] < h // 2, ramp, steps)
    rgb = np.stack([img] * 3, axis=-1)
    Image.fromarray((rgb * 255 + 0.5).astype(np.uint8)).save(outdir / "ramp.png")
    # Hue wheels at three lightness levels in OKLCh, chroma rising toward the rim.
    size = 512
    yy, xx = np.mgrid[0:size, 0:size]
    cx = cy = size / 2
    r = np.hypot(xx - cx, yy - cy) / (size / 2)
    hue = (np.degrees(np.arctan2(yy - cy, xx - cx)) + 360) % 360
    for L in (0.35, 0.6, 0.85):
        C = np.clip(r, 0, 1) * 0.28
        a = C * np.cos(np.radians(hue))
        b = C * np.sin(np.radians(hue))
        lab = np.stack([np.full_like(a, L), a, b], axis=-1)
        rgb = oklab_to_rgb(lab)
        rgb[r > 1] = 0.2
        Image.fromarray((np.clip(rgb, 0, 1) * 255 + 0.5).astype(np.uint8)).save(outdir / f"wheel_L{int(L * 100)}.png")
    # Patches: saturated primaries, skin, sky, foliage, neutrals.
    patches = {
        "red": (230, 30, 30), "green": (30, 200, 40), "blue": (30, 60, 230), "cyan": (30, 220, 230),
        "magenta": (225, 40, 220), "yellow": (240, 225, 30), "orange": (245, 140, 30), "purple": (130, 50, 200),
        "skin_light": (232, 190, 165), "skin_mid": (198, 140, 105), "skin_deep": (120, 75, 50), "skin_dark": (75, 45, 30),
        "sky_deep": (55, 105, 200), "sky_pale": (150, 190, 235), "sky_cyan": (110, 190, 220), "sunset": (250, 150, 90),
        "foliage": (70, 120, 40), "grass": (120, 170, 60), "olive": (110, 110, 50), "sea": (40, 120, 130),
        "white": (255, 255, 255), "gray80": (204, 204, 204), "gray50": (128, 128, 128), "gray20": (51, 51, 51),
        "black": (0, 0, 0), "warm_white": (255, 245, 225), "neon_pink": (255, 20, 147), "neon_green": (57, 255, 20),
    }
    cols = 7
    ps = 96
    rows_n = math.ceil(len(patches) / cols)
    grid = np.zeros((rows_n * ps, cols * ps, 3), dtype=np.uint8)
    for i, (name, c) in enumerate(patches.items()):
        r0, c0 = divmod(i, cols)
        grid[r0 * ps:(r0 + 1) * ps, c0 * ps:(c0 + 1) * ps] = c
    Image.fromarray(grid).save(outdir / "patches.png")
    (outdir / "patches.txt").write_text("\n".join(f"{i} {n} {c}" for i, (n, c) in enumerate(patches.items())))
    # Star chart with fine lines and dots for CA and defocus, on mid gray.
    star = np.full((768, 1024, 3), 118, dtype=np.uint8)
    im = Image.fromarray(star)
    d = ImageDraw.Draw(im)
    for ang in range(0, 360, 10):
        a = math.radians(ang)
        d.line([(512, 384), (512 + 500 * math.cos(a), 384 + 500 * math.sin(a))], fill=(255, 255, 255), width=1)
    for x in range(40, 1024, 64):
        for y in range(40, 768, 64):
            d.ellipse([x - 2, y - 2, x + 2, y + 2], fill=(255, 255, 255))
    for x in range(8, 1024, 96):
        d.rectangle([x, 8, x + 12, 40], fill=(0, 0, 0))
    im.save(outdir / "star.png")
    # A field of small bright light sources on a dark scene for halation.
    night = np.full((768, 1024, 3), 18, dtype=np.uint8)
    im = Image.fromarray(night)
    d = ImageDraw.Draw(im)
    rng = np.random.default_rng(7)
    for _ in range(40):
        x, y = rng.integers(20, 1004), rng.integers(20, 748)
        rad = int(rng.integers(1, 9))
        col = (255, int(rng.integers(200, 256)), int(rng.integers(120, 256)))
        d.ellipse([x - rad, y - rad, x + rad, y + rad], fill=col)
    d.rectangle([700, 500, 1000, 740], fill=(250, 250, 250))
    im.save(outdir / "lights.png")
    print(f"charts written to {outdir}")


def oklab_to_rgb(lab):
    l_ = lab[..., 0] + 0.3963377774 * lab[..., 1] + 0.2158037573 * lab[..., 2]
    m_ = lab[..., 0] - 0.1055613458 * lab[..., 1] - 0.0638541728 * lab[..., 2]
    s_ = lab[..., 0] - 0.0894841775 * lab[..., 1] - 1.2914855480 * lab[..., 2]
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return linear_to_srgb(np.clip(np.stack([r, g, b], axis=-1), 0, 1))


# ------------------------------------------------------------------ stats

def stats(args):
    im = np.asarray(load(args.image), dtype=np.float64) / 255.0
    lab = rgb_to_oklab(im)
    L, C, h = oklch(lab)
    print(f"{args.image}: L mean {L.mean():.3f} p1 {np.percentile(L, 1):.3f} p99 {np.percentile(L, 99):.3f}, "
          f"chroma mean {C.mean():.4f} p95 {np.percentile(C, 95):.4f}")
    # Skin corridor: OKLab hue 20..70 with some chroma.
    skin = (h > 20) & (h < 70) & (C > 0.03) & (L > 0.3) & (L < 0.9)
    if skin.any():
        print(f"  skin-like pixels {skin.mean() * 100:.1f}%: hue mean {h[skin].mean():.1f} std {h[skin].std():.1f}, "
              f"chroma mean {C[skin].mean():.4f}, L mean {L[skin].mean():.3f}")
    sky = (h > 225) & (h < 285) & (C > 0.03)
    if sky.any():
        print(f"  sky-like pixels {sky.mean() * 100:.1f}%: hue mean {h[sky].mean():.1f}, chroma mean {C[sky].mean():.4f}, L mean {L[sky].mean():.3f}")
    print(f"  channel means RGB {im.reshape(-1, 3).mean(axis=0) * 255}")
    print(f"  min {im.min() * 255:.1f} max {im.max() * 255:.1f}")


def ramp(args):
    im = np.asarray(load(args.image), dtype=np.float64) / 255.0
    h = im.shape[0]
    row = im[h // 4]  # inside the continuous band
    lab = rgb_to_oklab(row)
    xs = np.linspace(0, 1, row.shape[0])
    print("x_in   L      a       b       R    G    B")
    for i in range(0, row.shape[0], row.shape[0] // 16):
        print(f"{xs[i]:.3f}  {lab[i, 0]:.3f}  {lab[i, 1]:+.4f} {lab[i, 2]:+.4f}   {row[i, 0] * 255:5.1f} {row[i, 1] * 255:5.1f} {row[i, 2] * 255:5.1f}")
    Lr = lab[:, 0]
    mono = np.all(np.diff(Lr[::8]) >= -1e-3)
    print(f"monotonic L: {mono}, L range {Lr.min():.3f}..{Lr.max():.3f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sheet")
    s.add_argument("out")
    s.add_argument("images", nargs="+")
    s.add_argument("--labels", default=None)
    s.add_argument("--crop", default=None)
    s.add_argument("--width", type=int, default=2000)
    s.set_defaults(fn=sheet)
    c = sub.add_parser("charts")
    c.add_argument("outdir")
    c.set_defaults(fn=charts)
    st = sub.add_parser("stats")
    st.add_argument("image")
    st.set_defaults(fn=stats)
    rp = sub.add_parser("ramp")
    rp.add_argument("image")
    rp.set_defaults(fn=ramp)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
