#!/usr/bin/env python3
"""Score the snap policy against Noah's ground-truth labels.

For each labeled photo with a recoverable bracket, collect ALL detections
(conf >= 0.05, size-gated) from the shipped search geometry (640 center +
8-ring around the bracket). Then for each candidate confidence floor,
replay the policy (nearest gated detection within 700 px) and classify:

  correct-snap — chosen detection lands within MATCH px of Noah's label
  wrong-snap   — chosen detection is somewhere else (worse than shipping!)
  fallback     — nothing chosen; bracket stays geometric (today's behavior)

'none'-labeled photos: any chosen detection is a false snap.
Pre-composer photos (no bracket): pure recall — best conf near the label
with a perfectly-centered crop (upper bound on detector ability).
"""
from __future__ import annotations
import json, sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageOps

sys.path.insert(0, str(Path(__file__).parent))
import eval_catch_photos as E

E.CONF_THRESHOLD = 0.05  # collect low; floors applied downstream

MATCH = 120.0       # detection-center-to-label distance that counts as "the plane"
MAX_SIDE = E.INPUT_SIZE / 3
MAX_SNAP = 700.0
RING = 480
FLOORS = [0.45, 0.40, 0.35, 0.30, 0.25, 0.20]

HERE = Path(__file__).resolve().parent
labels = json.loads((HERE / "labels.json").read_text())
det = E.Detector()

bracketed, pre_recall = [], []
for name, lab in sorted(labels.items()):
    path = HERE / "all-photos" / name
    rgb = np.asarray(ImageOps.exif_transpose(Image.open(path)).convert("RGB"))
    b = E.find_bracket(rgb)
    if b:
        (bx, by), _, _ = b
        centers = [(bx, by)] + [(bx + dx, by + dy) for dx in (-RING, 0, RING)
                   for dy in (-RING, 0, RING) if not (dx == 0 and dy == 0)]
        dets = []
        for cx, cy in centers:
            for box, score in det.predict_region(rgb, int(cx - 320), int(cy - 320), E.INPUT_SIZE):
                w, h = box[2] - box[0], box[3] - box[1]
                if max(w, h) <= MAX_SIDE:
                    c = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
                    dets.append({"c": c, "conf": float(score),
                                 "dist_pred": float(np.hypot(c[0] - bx, c[1] - by))})
        rec = {"file": name, "status": lab["status"], "dets": dets}
        if lab["status"] == "plane":
            rec["label"] = (lab["x"], lab["y"])
            rec["label_dist_pred"] = float(np.hypot(lab["x"] - bx, lab["y"] - by))
        bracketed.append(rec)
    elif lab["status"] == "plane":
        lx, ly = lab["x"], lab["y"]
        best = 0.0
        for box, score in det.predict_region(rgb, int(lx - 320), int(ly - 320), E.INPUT_SIZE):
            c = ((box[0] + box[2]) / 2, (box[1] + box[3]) / 2)
            if np.hypot(c[0] - lx, c[1] - ly) <= MATCH and max(box[2]-box[0], box[3]-box[1]) <= MAX_SIDE:
                best = max(best, float(score))
        pre_recall.append({"file": name, "best_conf": best})
    print(".", end="", flush=True)
print()

print(f"\n=== Bracketed labeled photos: {len(bracketed)} "
      f"(plane={sum(1 for r in bracketed if r['status']=='plane')}, "
      f"none={sum(1 for r in bracketed if r['status']=='none')}, "
      f"unsure={sum(1 for r in bracketed if r['status']=='unsure')}) ===")

unreach = [r for r in bracketed if r["status"] == "plane" and r["label_dist_pred"] > MAX_SNAP]
print(f"labeled planes beyond the 700 px snap radius (unreachable at ANY floor): {len(unreach)}")
for r in unreach:
    print(f"   {r['file']}  plane is {r['label_dist_pred']:.0f} px from the bracket")

print(f"\n{'floor':>6} {'correct':>8} {'wrong':>6} {'fallback':>9} {'false-snap(none)':>17} {'false(unsure)':>14}")
for floor in FLOORS:
    correct = wrong = fb = fp_none = fp_unsure = 0
    wrong_files, fp_files = [], []
    for r in bracketed:
        cands = [d for d in r["dets"] if d["conf"] >= floor and d["dist_pred"] <= MAX_SNAP]
        chosen = min(cands, key=lambda d: d["dist_pred"]) if cands else None
        if r["status"] == "plane":
            if chosen is None:
                fb += 1
            elif np.hypot(chosen["c"][0] - r["label"][0], chosen["c"][1] - r["label"][1]) <= MATCH:
                correct += 1
            else:
                wrong += 1
                wrong_files.append((r["file"], floor))
        elif chosen is not None:
            if r["status"] == "none":
                fp_none += 1
            else:
                fp_unsure += 1
            fp_files.append((r["file"], r["status"], round(chosen["conf"], 2)))
    print(f"{floor:>6} {correct:>8} {wrong:>6} {fb:>9} {fp_none:>17} {fp_unsure:>14}"
          + ("   " + "; ".join(f"{f}@{fl}" for f, fl in wrong_files) if wrong_files else "")
          + ("   FP: " + "; ".join(f"{f}({s},{c})" for f, s, c in fp_files) if fp_files else ""))

print("\n=== Per-plane best conf near the label (bracketed, reachable) ===")
rows = []
for r in bracketed:
    if r["status"] != "plane" or r["label_dist_pred"] > MAX_SNAP:
        continue
    near = [d["conf"] for d in r["dets"]
            if np.hypot(d["c"][0] - r["label"][0], d["c"][1] - r["label"][1]) <= MATCH]
    rows.append((max(near) if near else 0.0, r["file"], r["label_dist_pred"]))
for conf, f, d in sorted(rows, reverse=True):
    print(f"  {conf:.2f}  {f}  (plane {d:.0f} px from bracket)")

print(f"\n=== Pre-composer recall (perfectly-centered crop on the label): {len(pre_recall)} planes ===")
for band in [(0.45, 1.1), (0.30, 0.45), (0.20, 0.30), (0.05, 0.20), (0.0, 0.05)]:
    n = sum(1 for r in pre_recall if band[0] <= r["best_conf"] < band[1])
    print(f"  conf {band[0]:.2f}–{band[1]:.2f}: {n}")

json.dump({"bracketed": bracketed, "pre_recall": pre_recall},
          open(HERE / "label-analysis.json", "w"), default=float)
print("\nwrote label-analysis.json")
