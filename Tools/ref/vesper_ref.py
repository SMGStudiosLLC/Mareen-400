#!/usr/bin/env python3
"""Run the filter on any machine, without Metal.

    python3 Tools/ref/vesper_ref.py in.jpg out.png [--stock vesper800|marenn400]
        [--seed N] [--nograin] [--date "'98 8 24"|auto|none] [--leak 0.35]
        [--flash 0|1] [--stats] [--nohalf] [--dump DIR] [--compare ref.jpg]

The heavy lifting happens in build/ref_<stock>, a C++ binary that runs the
real Metal kernels through the metal_stdlib shim. This script decodes the
input (honoring EXIF orientation), hands the binary raw RGBA8, and encodes the
result. `--compare` reports how far the render is from a reference image after
a small blur (which removes grain-seed differences), useful for regression
checks against the shipped example renders.
"""
import argparse
import os
import struct
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"


def ensure_built():
    if not (BUILD / "ref_marenn400").exists() and not (BUILD / "ref_vesper800").exists():
        subprocess.check_call([str(HERE / "build.sh")])


def load_rgba(path: Path) -> np.ndarray:
    im = Image.open(path)
    im = ImageOps.exif_transpose(im)
    if im.mode in ("RGBA", "LA", "P"):
        # Flatten onto white so alpha inputs are deterministic.
        im = im.convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        im = Image.alpha_composite(bg, im)
    im = im.convert("RGB")
    arr = np.asarray(im, dtype=np.uint8)
    rgba = np.dstack([arr, np.full(arr.shape[:2], 255, dtype=np.uint8)])
    return rgba


def write_raw(path: Path, rgba: np.ndarray):
    h, w = rgba.shape[:2]
    with open(path, "wb") as f:
        f.write(struct.pack("<II", w, h))
        f.write(np.ascontiguousarray(rgba).tobytes())


def read_raw(path: Path) -> np.ndarray:
    with open(path, "rb") as f:
        w, h = struct.unpack("<II", f.read(8))
        data = np.frombuffer(f.read(), dtype=np.uint8)
    return data.reshape(h, w, 4)


def exif_date(path: Path):
    try:
        im = Image.open(path)
        exif = im.getexif()
        raw = exif.get(36867) or exif.get(306)
        if raw:
            dt = datetime.strptime(str(raw)[:19], "%Y:%m:%d %H:%M:%S")
            return dt
    except Exception:
        pass
    return None


def stamp_text(option: str, in_path: Path) -> str:
    if option in (None, "", "none"):
        return ""
    if option == "auto":
        dt = exif_date(in_path) or datetime.fromtimestamp(in_path.stat().st_mtime)
        return "'%02d %d %d" % (dt.year % 100, dt.month, dt.day)
    return option


def compare(out_rgb: np.ndarray, ref_path: Path):
    from scipy.ndimage import gaussian_filter

    ref = np.asarray(ImageOps.exif_transpose(Image.open(ref_path)).convert("RGB"), dtype=np.float32)
    out = out_rgb.astype(np.float32)
    if ref.shape != out.shape:
        print(f"compare: size mismatch {out.shape} vs {ref.shape}")
        return
    a = np.stack([gaussian_filter(out[..., c], 2.0) for c in range(3)], axis=-1)
    b = np.stack([gaussian_filter(ref[..., c], 2.0) for c in range(3)], axis=-1)
    diff = a - b
    rms = float(np.sqrt(np.mean(diff ** 2)))
    mean_shift = diff.reshape(-1, 3).mean(axis=0)
    p99 = float(np.percentile(np.abs(diff), 99))
    raw_rms = float(np.sqrt(np.mean((out - ref) ** 2)))
    print(f"compare: blurred RMS {rms:.2f}/255, raw RMS {raw_rms:.2f}/255, mean shift RGB "
          f"({mean_shift[0]:+.2f}, {mean_shift[1]:+.2f}, {mean_shift[2]:+.2f}), 99th pct |diff| {p99:.1f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--stock", default="vesper800", choices=["vesper800", "marenn400"])
    ap.add_argument("--seed", type=float, default=None)
    ap.add_argument("--nograin", action="store_true")
    ap.add_argument("--date", default="none")
    ap.add_argument("--leak", type=float, default=0.0)
    ap.add_argument("--flash", type=int, default=None)
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--nohalf", action="store_true", help="use float32 intermediates instead of emulating rgba16Float")
    ap.add_argument("--dump", default=None, help="directory for intermediate texture dumps")
    ap.add_argument("--compare", default=None, help="reference image to compare against")
    ap.add_argument("--timing", action="store_true")
    ap.add_argument("--quality", type=int, default=92)
    args = ap.parse_args()

    ensure_built()
    binary = BUILD / f"ref_{args.stock}"
    if not binary.exists():
        sys.exit(f"{binary} is not built; the Swift file may not carry that stock yet")

    in_path = Path(args.input)
    out_path = Path(args.output)
    rgba = load_rgba(in_path)
    tmp_in = out_path.with_suffix(".in.rgba")
    tmp_out = out_path.with_suffix(".out.rgba")
    write_raw(tmp_in, rgba)

    cmd = [str(binary), str(tmp_in), str(tmp_out)]
    if args.seed is not None:
        cmd += ["--seed", str(args.seed)]
    if args.nograin:
        cmd.append("--nograin")
    if args.nohalf:
        cmd.append("--nohalf")
    if args.stats:
        cmd.append("--stats")
    if args.timing:
        cmd.append("--timing")
    if args.dump:
        os.makedirs(args.dump, exist_ok=True)
        cmd += ["--dump", args.dump]
    text = stamp_text(args.date, in_path)
    if text:
        cmd += ["--date", text]
    if args.leak:
        cmd += ["--leak", str(args.leak)]
    if args.flash is not None:
        cmd += ["--flash", str(args.flash)]
    try:
        subprocess.check_call(cmd)
    finally:
        tmp_in.unlink(missing_ok=True)

    out = read_raw(tmp_out)
    tmp_out.unlink(missing_ok=True)
    rgb = out[..., :3]
    im = Image.fromarray(rgb, "RGB")
    if out_path.suffix.lower() in (".jpg", ".jpeg"):
        im.save(out_path, quality=args.quality, subsampling=0)
    else:
        im.save(out_path)
    if args.compare:
        compare(rgb, Path(args.compare))


if __name__ == "__main__":
    main()
