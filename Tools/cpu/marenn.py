#!/usr/bin/env python3
"""Develop photos with the CPU reference renderer (no Mac needed).

    python3 Tools/cpu/marenn.py in.jpg out.png [--seed N] [--nograin] [--stamp 2026-11-21]
                                [--leak 0.6] [--variation 0] [--set field=value ...]

Builds Tools/cpu/build/libmarenn.so on first use. Needs numpy, Pillow and clang.
"""
import argparse
import ctypes
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

HERE = Path(__file__).resolve().parent


def load(build_dir=None):
    build = Path(build_dir) if build_dir else HERE / "build"
    lib_path = build / "libmarenn.so"
    swift = HERE.parent.parent / "MarennFilter.swift"
    stale = not lib_path.exists() or any(
        f.stat().st_mtime > lib_path.stat().st_mtime
        for f in [swift, HERE / "marenn_cpu.cpp", HERE / "metal_stdlib", HERE / "msl2cpp.py"])
    if stale:
        subprocess.run([str(HERE / "build.sh"), str(build)], check=True, stdout=subprocess.DEVNULL)
    lib = ctypes.CDLL(str(lib_path))
    lib.marenn_process.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32,
                                   ctypes.c_float, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_int, ctypes.c_float, ctypes.c_char_p, ctypes.c_void_p]
    return lib


def develop(lib, rgb, seed=3, variation=1.0, grain=True, stamp=None, leak=0.0, overrides=""):
    """rgb: HxWx3 uint8 sRGB array. Returns (HxWx3 uint8, info dict)."""
    h, w = rgb.shape[:2]
    rgba = np.empty((h, w, 4), np.uint8)
    rgba[..., :3] = rgb
    rgba[..., 3] = 255
    out = np.empty_like(rgba)
    info = np.zeros(4, np.float32)
    yy, mm, dd = stamp if stamp else (0, 0, 0)
    lib.marenn_process(rgba.ctypes.data, w, h, out.ctypes.data, seed & 0xFFFFFFFF, variation, int(grain),
                       int(stamp is not None), yy, mm, dd, leak, overrides.encode(), info.ctypes.data)
    return out[..., :3].copy(), {"gain": float(info[0]), "p50": float(info[1]), "push": float(info[2])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--seed", type=int, default=3)
    ap.add_argument("--nograin", action="store_true")
    ap.add_argument("--stamp", help="YYYY-MM-DD date imprint")
    ap.add_argument("--leak", type=float, default=0.0)
    ap.add_argument("--variation", type=float, default=1.0)
    ap.add_argument("--set", action="append", default=[], help="override a MarennParams field, e.g. grainAmount=0.06")
    a = ap.parse_args()
    lib = load()
    img = ImageOps.exif_transpose(Image.open(a.input)).convert("RGB")
    stamp = tuple(int(x) for x in a.stamp.split("-")) if a.stamp else None
    out, info = develop(lib, np.asarray(img), a.seed, a.variation, not a.nograin, stamp, a.leak, ";".join(a.set))
    Image.fromarray(out).save(a.output, quality=94)
    print(f"{a.input} -> {a.output}  {img.width}x{img.height}  gain={info['gain']:.3f} p50={info['p50']:.3f}")


if __name__ == "__main__":
    sys.exit(main())
