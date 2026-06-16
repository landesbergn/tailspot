#!/usr/bin/env python3
"""
score_field_session.py — turn a Tailspot field recording into a visual-confirmation
go/no-go verdict.

The app, while recording, writes ground-truth crops to the device at
Documents/replays/frames/:
  - crop-<ts>-<icao24>.jpg   : the 640px native-res crop fed to the detector,
                               centered on the geometry-PREDICTED plane position
                               (so the crop centre ≈ where the bracket would sit
                               WITHOUT visual confirmation).
  - frames.jsonl             : one line per saved crop with the predicted
                               position, the crop rect, and the detector's
                               output boxes (buffer-pixel coords).

Pull them off the phone (udid from `xcrun devicectl list devices`):
  xcrun devicectl device copy from --device <udid> \
    --domain-type appDataContainer --domain-identifier com.landesberg.Tailspot \
    --source Documents/replays/frames --destination ./frames

Then:
  python3 tools/visual-confirmation/score_field_session.py ./frames

What it does:
  1. Draws each detector box onto its crop (top-confidence box highlighted) plus a
     crosshair at the crop centre (≈ the predicted position). You EYEBALL whether
     the box lands on the real plane — that's the honest go/no-go.
  2. Builds a single contact-sheet montage of every annotated crop.
  3. Prints quantitative stats: detection rate (recall), confidence distribution,
     and the correction magnitude (how far the chosen box sits from the predicted
     centre — i.e. how much value visual confirmation is adding over geometry alone).

No app dependency; re-runnable on the same frames as the detector improves.
"""

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("Pillow required: pip install pillow")

PREDICTED_COLOR = (120, 200, 255)   # cyan-ish — the predicted (geometry) centre
TOP_BOX_COLOR = (80, 240, 140)      # green — the box the tracker would pick (highest conf)
OTHER_BOX_COLOR = (240, 180, 80)    # amber — other candidate boxes


def _font(size):
    try:
        return ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", size)
    except OSError:
        return ImageFont.load_default()


def load_frames(frames_dir: Path):
    sidecar = frames_dir / "frames.jsonl"
    if not sidecar.exists():
        sys.exit(f"no frames.jsonl in {frames_dir} — is this the pulled replays/frames dir?")
    rows = []
    for n, raw in enumerate(sidecar.read_text().splitlines(), 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            rows.append(json.loads(raw))
        except json.JSONDecodeError:
            print(f"  warn: skipped malformed line {n}", file=sys.stderr)
    return rows


def annotate(row, frames_dir: Path, out_dir: Path):
    """Draw detection boxes + predicted crosshair onto the crop. Returns the
    correction offset (buffer px) of the top box from the crop centre, or None."""
    jpg = frames_dir / row["file"]
    if not jpg.exists():
        return None, None
    img = Image.open(jpg).convert("RGB")
    w, h = img.size
    draw = ImageDraw.Draw(img)
    font = _font(max(11, w // 32))

    crop_x, crop_y = row["cropX"], row["cropY"]
    crop_side = row.get("cropSide", w) or w
    # JPEG may not be exactly cropSide px; scale buffer-space coords into image px.
    scale = w / crop_side if crop_side else 1.0

    # Predicted ≈ crop centre (the crop is built centered on the predicted spot,
    # modulo clamping at the buffer edge).
    pcx, pcy = w / 2, h / 2
    r = max(6, w // 40)
    draw.line([(pcx - r, pcy), (pcx + r, pcy)], fill=PREDICTED_COLOR, width=2)
    draw.line([(pcx, pcy - r), (pcx, pcy + r)], fill=PREDICTED_COLOR, width=2)

    dets = row.get("detections", [])
    # Highest confidence first — that's the one VisualFixTracker would pick.
    dets = sorted(dets, key=lambda d: d.get("conf", 0), reverse=True)
    top_offset = None
    for i, d in enumerate(dets):
        lx = (d["x"] - crop_x) * scale
        ly = (d["y"] - crop_y) * scale
        lw, lh = d["w"] * scale, d["h"] * scale
        color = TOP_BOX_COLOR if i == 0 else OTHER_BOX_COLOR
        draw.rectangle([lx, ly, lx + lw, ly + lh], outline=color, width=3 if i == 0 else 2)
        label = f"{d.get('conf', 0):.2f}"
        draw.text((lx + 2, max(0, ly - font.size - 2)), label, fill=color, font=font)
        if i == 0:
            bcx, bcy = lx + lw / 2, ly + lh / 2
            draw.line([(pcx, pcy), (bcx, bcy)], fill=TOP_BOX_COLOR, width=1)
            top_offset = math.hypot(bcx - pcx, bcy - pcy) / scale  # back to buffer px

    if not dets:
        draw.text((6, 6), "NO DETECTION", fill=(240, 90, 90), font=font)

    out = out_dir / f"annotated-{row['file']}"
    img.save(out, quality=85)
    return top_offset, (w, h)


def montage(annotated_dir: Path, out_path: Path, cols=6, thumb=220):
    imgs = sorted(annotated_dir.glob("annotated-*.jpg"))
    if not imgs:
        return
    rows = math.ceil(len(imgs) / cols)
    sheet = Image.new("RGB", (cols * thumb, rows * thumb), (16, 18, 22))
    for i, p in enumerate(imgs):
        im = Image.open(p).convert("RGB")
        im.thumbnail((thumb - 6, thumb - 6))
        x = (i % cols) * thumb + 3
        y = (i // cols) * thumb + 3
        sheet.paste(im, (x, y))
    sheet.save(out_path, quality=85)


def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    k = (len(xs) - 1) * p / 100
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return xs[int(k)]
    return xs[lo] * (hi - k) + xs[hi] * (k - lo)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames_dir", type=Path, help="pulled Documents/replays/frames directory")
    ap.add_argument("--out", type=Path, default=None, help="output dir (default: <frames_dir>/scored)")
    args = ap.parse_args()

    frames_dir = args.frames_dir
    out_dir = args.out or (frames_dir / "scored")
    annotated_dir = out_dir / "annotated"
    annotated_dir.mkdir(parents=True, exist_ok=True)

    rows = load_frames(frames_dir)
    if not rows:
        sys.exit("no frames to score.")

    total = len(rows)
    with_det = 0
    top_confs = []        # top confidence per frame that HAS a detection
    offsets = []          # correction magnitude (buffer px) per detected frame
    dets_per_frame = []
    by_icao = {}

    for row in rows:
        dets = row.get("detections", [])
        dets_per_frame.append(len(dets))
        icao = row.get("icao24", "?")
        by_icao.setdefault(icao, {"frames": 0, "det": 0})
        by_icao[icao]["frames"] += 1
        offset, _ = annotate(row, frames_dir, annotated_dir)
        if dets:
            with_det += 1
            by_icao[icao]["det"] += 1
            top_confs.append(max(d.get("conf", 0) for d in dets))
            if offset is not None:
                offsets.append(offset)

    montage_path = out_dir / "montage.jpg"
    montage(annotated_dir, montage_path)

    recall = 100 * with_det / total if total else 0
    lines = []
    lines.append("=" * 60)
    lines.append("VISUAL CONFIRMATION — FIELD SESSION SCORE")
    lines.append("=" * 60)
    lines.append(f"frames recorded         : {total}")
    lines.append(f"frames with a detection : {with_det}  ({recall:.0f}% recall)")
    lines.append(f"detections / frame      : mean {statistics.mean(dets_per_frame):.2f}, max {max(dets_per_frame)}")
    if top_confs:
        lines.append("")
        lines.append("top-box confidence (detected frames):")
        lines.append(f"  min {min(top_confs):.2f}  p10 {pct(top_confs,10):.2f}  "
                     f"median {statistics.median(top_confs):.2f}  p90 {pct(top_confs,90):.2f}  max {max(top_confs):.2f}")
    if offsets:
        lines.append("")
        lines.append("correction magnitude — chosen box vs predicted centre (buffer px):")
        lines.append(f"  median {statistics.median(offsets):.0f}  p90 {pct(offsets,90):.0f}  max {max(offsets):.0f}")
        lines.append("  (small = geometry was already on target; large + box-on-plane = CV is")
        lines.append("   adding real value; large + box-off-plane = false positive to investigate)")
    lines.append("")
    lines.append("per aircraft:")
    for icao, s in sorted(by_icao.items()):
        rc = 100 * s["det"] / s["frames"] if s["frames"] else 0
        lines.append(f"  {icao:<8} {s['det']:>3}/{s['frames']:<3} frames detected ({rc:.0f}%)")
    lines.append("")
    lines.append(f"annotated crops : {annotated_dir}")
    lines.append(f"contact sheet   : {montage_path}")
    lines.append("")
    lines.append("GO/NO-GO: open the contact sheet. If the green box lands on the actual")
    lines.append("plane in most frames where one is visible, that's a GO — flip the Release")
    lines.append("flag on. If boxes miss the plane or recall is low, that's tuning work.")
    report = "\n".join(lines)
    print(report)
    (out_dir / "summary.txt").write_text(report + "\n")


if __name__ == "__main__":
    main()
