#!/usr/bin/env python3
"""Compare two renders: compare.py a.png b.png [--max-mean 1.0] [--max-p99 4]. Exit 1 if they disagree."""
import argparse
import sys

import numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("a")
ap.add_argument("b")
ap.add_argument("--max-mean", type=float, default=1.0)
ap.add_argument("--max-p99", type=float, default=4.0)
a = ap.parse_args()
x = np.asarray(Image.open(a.a).convert("RGB")).astype(np.float32)
y = np.asarray(Image.open(a.b).convert("RGB")).astype(np.float32)
if x.shape != y.shape:
    sys.exit(f"size mismatch {x.shape} vs {y.shape}")
d = np.abs(x - y)
mean, p99, mx = d.mean(), np.percentile(d, 99), d.max()
bias = (y - x).mean(axis=(0, 1))
ok = mean <= a.max_mean and p99 <= a.max_p99
print(f"{'OK  ' if ok else 'FAIL'} {a.a} vs {a.b}: mean abs {mean:.3f}, p99 {p99:.1f}, max {mx:.0f}, bias RGB {np.round(bias, 2)}")
sys.exit(0 if ok else 1)
