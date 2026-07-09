#!/usr/bin/env python3
"""Simulate the CatchPhotoSnapper FINE pass over every bracketed catch
photo: 640 native crops (center + 8-ring at ±480), conf ≥ 0.25 (the
shipped floor, retuned 2026-07-07 on the labeled corpus), box side
≤ 213, nearest-to-prediction within 700 px, center early-exit at 340 px.
Reports per-photo outcome + summary.

NOTE: with full-res capture the on-device snapper also runs a COARSE
1080-equivalent pass + native refine for >1080 px photos; this script
models the 1080-px reference behavior, exact for the pre-2026-07-09
corpus."""
from __future__ import annotations
import json, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).parent))
from eval_catch_photos import Detector, find_bracket, decode_airplanes, INPUT_SIZE  # noqa

CONF = 0.25
MAX_SIDE = INPUT_SIZE / 3
MAX_SNAP = 700.0
CENTER_ACCEPT = 340.0
RING = 480

det = Detector()
outcomes = []
dirs = [Path(sys.argv[1]), Path(sys.argv[2])] if len(sys.argv) > 2 else [Path(sys.argv[1])]
photos = sorted(p for d in dirs for p in d.glob("*.jpg"))
for path in photos:
    rgb = np.asarray(ImageOps.exif_transpose(Image.open(path)).convert("RGB"))
    b = find_bracket(rgb)
    if not b:
        continue
    (bx, by), _, _ = b
    centers = [(bx, by)] + [(bx + dx, by + dy) for dx in (-RING, 0, RING)
               for dy in (-RING, 0, RING) if not (dx == 0 and dy == 0)]
    hits = []
    outcome = None
    for i, (cx, cy) in enumerate(centers):
        dets = det.predict_region(rgb, int(cx - 320), int(cy - 320), INPUT_SIZE)
        for box, score in dets:
            w, h = box[2] - box[0], box[3] - box[1]
            if score >= CONF and max(w, h) <= MAX_SIDE:
                c = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
                d = float(np.hypot(c[0] - bx, c[1] - by))
                if d <= MAX_SNAP:
                    hits.append((d, score, w, h))
        if i == 0 and hits and min(hits)[0] <= CENTER_ACCEPT:
            outcome = ("snap", *min(hits))
            break
    if outcome is None and hits:
        outcome = ("snap", *min(hits))
    if outcome is None:
        outcome = ("fallback",)
    outcomes.append((path.name, outcome))
    o = outcome
    print(f"{path.name:<32} {o[0]:<9}" + (f" dist={o[1]:.0f}px conf={o[2]:.2f} box={o[3]:.0f}x{o[4]:.0f}" if o[0] == "snap" else ""))

snaps = [o for _, o in outcomes if o[0] == "snap"]
dists = sorted(o[1] for o in snaps)
print(f"\n{len(outcomes)} bracketed photos: {len(snaps)} snap, {len(outcomes)-len(snaps)} fallback")
if dists:
    print(f"snap distances px: median={np.median(dists):.0f} p90={np.percentile(dists,90):.0f} max={max(dists):.0f}")
