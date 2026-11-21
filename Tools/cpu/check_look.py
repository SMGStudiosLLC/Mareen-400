#!/usr/bin/env python3
"""Look regression checks, run in CI on the CPU reference renderer.

Guards the properties v2 was built for, so they cannot quietly regress:
  * grain is isotropic: no lattice, no preferred direction (the v1 "linear grain")
  * grain looks the same on a screen whatever resolution it was rendered at
  * a fixed seed develops the same frame twice

usage: python3 Tools/cpu/check_look.py
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import marenn  # noqa: E402

LW = np.array([0.2126, 0.7152, 0.0722], np.float32)
lib = marenn.load()
failures = []


def check(name, ok, detail):
    print(f"{'OK  ' if ok else 'FAIL'} {name}: {detail}")
    if not ok:
        failures.append(name)


def grain_field(w, h, level=128, seed=11):
    """Luminance grain alone: the same frame developed with and without grain."""
    img = np.full((h, w, 3), level, np.uint8)
    a, _ = marenn.develop(lib, img, seed=seed, variation=0, grain=True)
    b, _ = marenn.develop(lib, img, seed=seed, variation=0, grain=False)
    return (a.astype(np.float32) - b.astype(np.float32)) @ LW


# 1. isotropy on a 1600 px frame, where dye clouds are drawn at near-pixel size and a
#    lattice would be hardest to hide
g = grain_field(1600, 3024)[1000:1800, 400:1200]


def corr(dx, dy):
    x = g[8:-8, 8:-8]
    y = np.roll(np.roll(g, dy, 0), dx, 1)[8:-8, 8:-8]
    return float(np.corrcoef(x.ravel(), y.ravel())[0, 1])


r10, r01, r11, r1m = corr(1, 0), corr(0, 1), corr(1, 1), corr(1, -1)
check("horizontal vs vertical correlation", abs(r10 - r01) < 0.03, f"{r10:.3f} vs {r01:.3f}")
check("diagonal vs anti-diagonal correlation", abs(r11 - r1m) < 0.03, f"{r11:.3f} vs {r1m:.3f}")
# for a round gaussian correlation, rho(sqrt 2) = rho(1)^2
check("diagonal matches a round grain", abs(r11 - r10 * r10) < 0.06, f"rho(1,1) {r11:.3f}, rho(1,0)^2 {r10 * r10:.3f}")

# lattice energy: spectral power on the axes vs on the diagonals, same frequency band
F = np.abs(np.fft.fftshift(np.fft.fft2((g - g.mean()) * np.outer(np.hanning(800), np.hanning(800))))) ** 2
yy, xx = np.mgrid[-400:400, -400:400]
rad, ang = np.hypot(xx, yy), np.degrees(np.arctan2(yy, xx)) % 90
band = (rad > 60) & (rad < 300)
axis = F[band & ((ang < 5) | (ang > 85))].mean()
diag = F[band & (np.abs(ang - 45) < 5)].mean()
check("no lattice in the grain spectrum", 0.85 < axis / diag < 1.15, f"axis/diagonal power {axis / diag:.3f}")

# 2. on-screen consistency: render at two sizes, view both at a 1000 px short side
stds = []
for short in (1000, 2048):
    w = int(short * 4 / 3)
    f = grain_field(w, short)
    shown = np.asarray(Image.fromarray(f, mode="F").resize((1333, 1000), Image.BOX))
    stds.append(float(shown[250:750, 333:1000].std()))
check("grain on screen, 1000 px vs 2048 px render", abs(stds[0] / stds[1] - 1) < 0.15,
      f"{stds[0]:.2f} vs {stds[1]:.2f} levels")

# 3. determinism
img = np.asarray(Image.open(Path(__file__).resolve().parents[2] / "Examples/original-rooftop.jpg").convert("RGB"))
a, _ = marenn.develop(lib, img, seed=5)
b, _ = marenn.develop(lib, img, seed=5)
check("same seed, same frame", np.array_equal(a, b), "bit identical" if np.array_equal(a, b) else "differs")

sys.exit(1 if failures else 0)
