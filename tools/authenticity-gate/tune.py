#!/usr/bin/env python3
"""Tune the SkyCheck gate thresholds against a labeled image set.

Faithful port of SkyCheck.extract + verdict (same 12x12 grid sampling,
same "busy AND warm" rule). Point it at a directory of labeled images:

    <dir>/pass-*.jpg   # plane/sky shots that SHOULD be allowed
    <dir>/block-*.jpg  # interiors that SHOULD be blocked

It extracts the 4 features per image, grid-searches edgeBusy / varianceBusy
/ warmThreshold, and prints the trade-off (operating points) + the
fail-open knee. Used to calibrate Thresholds in SkyCheck.swift —
see CALIBRATION.md. Requires Pillow.

    python3 tune.py /path/to/labeled/images
"""
import sys, glob, os, itertools
from PIL import Image
GRID = 12

def features(path):
    im = Image.open(path).convert("RGB"); W, H = im.size; px = im.load()
    lum = []; sumR = sumB = sumL = 0.0
    for gy in range(GRID):
        y = (gy * H) // GRID + H // (2 * GRID)
        for gx in range(GRID):
            x = (gx * W) // GRID + W // (2 * GRID)
            R, G, B = px[x, y][:3]; r, g, b = R / 255, G / 255, B / 255
            l = 0.299 * r + 0.587 * g + 0.114 * b
            lum.append(l); sumR += r; sumB += b; sumL += l
    n = GRID * GRID; mL = sumL / n
    var = sum((v - mL) ** 2 for v in lum) / n
    es = ec = 0.0
    for gy in range(GRID):
        for gx in range(GRID):
            i = gy * GRID + gx
            if gx + 1 < GRID: es += abs(lum[i] - lum[i + 1]); ec += 1
            if gy + 1 < GRID: es += abs(lum[i] - lum[i + GRID]); ec += 1
    return dict(edge=es / ec, var=var,
                warmth=(sumR - sumB) / (sumR + sumB) if sumR + sumB else 0, lum=mL)

def blocks(ft, eB, vB, wT, lT=0.12):   # SkyCheck rule: busy AND warm
    return (ft["edge"] >= eB or ft["var"] >= vB) and (ft["lum"] >= lT and ft["warmth"] >= wT)

def main(d):
    P = [features(f) for f in glob.glob(os.path.join(d, "pass-*.jpg"))]
    B = [features(f) for f in glob.glob(os.path.join(d, "block-*.jpg"))]
    print(f"{len(P)} pass, {len(B)} block")
    def sc(p):
        pr = sum(1 for f in P if not blocks(f, *p)) / len(P)
        br = sum(1 for f in B if blocks(f, *p)) / len(B)
        return (pr + br) / 2, pr, br
    E = [round(0.03 + 0.005 * i, 3) for i in range(30)]
    V = [round(0.005 + 0.0025 * i, 4) for i in range(34)]
    W = [round(-0.20 + 0.02 * i, 2) for i in range(28)]
    configs = [(p, *sc(p)) for p in itertools.product(E, V, W)]
    print(f"searched {len(configs)} configs")
    bb = max(configs, key=lambda c: c[1])
    print(f"max balanced     bal={bb[1]:.3f} pass={bb[2]:.0%} block={bb[3]:.0%}  {bb[0]}")
    for pm in (1.0, 0.95, 0.92):
        c = max((c for c in configs if c[2] >= pm), key=lambda c: (c[3], c[2]), default=None)
        if c: print(f"max block @pass>={pm:.2f}  block={c[3]:.0%} pass={c[2]:.0%} bal={c[1]:.3f}  {c[0]}")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else ".")
