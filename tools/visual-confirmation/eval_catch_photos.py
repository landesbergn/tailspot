#!/usr/bin/env python3
"""
eval_catch_photos.py — evaluate "snap the catch-photo bracket to a YOLOX
detection" against Noah's real catch photos.

Per photo:
  1. Recover the baked-in bracket center (CatchPhotoComposer draws it in
     brand cyan 0x00D4FF with a dark halo) via color matching. That center
     IS the geometric prediction at catch time.
  2. CROP pass (models the proposed fix): a 640x640 native-res crop
     centered on the bracket center, plus a 1280x1280 "wide" crop
     downscaled to 640 (r=0.5).
  3. SWEEP pass (ground-truth proxy): full-frame letterbox + native-res
     640 tiles over the whole image, global NMS. Finds the plane wherever
     it actually is, so we can measure the bracket->plane miss distance
     and whether the crop search radius would have reached it.
  4. Writes eval-out/<name>.json + annotated eval-out/<name>.jpg.

Decode/NMS mirrors tools/visual-confirmation/validate.py exactly.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

import coremltools as ct

HERE = Path(__file__).resolve().parent
PHOTO_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "catch-photos"
OUT = HERE / "eval-out"
OUT.mkdir(exist_ok=True)

MLPACKAGE = str(HERE.parents[1] / "ios/Tailspot/Tailspot/YoloxAirplane_int8.mlpackage")
INPUT_SIZE = 640
INPUT_NAME = "image"
COCO_AIRPLANE = 4
CONF_THRESHOLD = 0.30
NMS_IOU = 0.45
TILE_STRIDE = 544  # 96 px overlap between native-res tiles

# Brand cyan 0x00D4FF as drawn by CatchPhotoComposer (RGB).
BRACKET_RGB = np.array([0, 212, 255], dtype=np.float32)


def log(msg: str) -> None:
    print(msg, flush=True)


def iou(box, boxes):
    x1 = np.maximum(box[0], boxes[:, 0]); y1 = np.maximum(box[1], boxes[:, 1])
    x2 = np.minimum(box[2], boxes[:, 2]); y2 = np.minimum(box[3], boxes[:, 3])
    inter = np.maximum(0, x2 - x1) * np.maximum(0, y2 - y1)
    area = (box[2] - box[0]) * (box[3] - box[1])
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return inter / (area + areas - inter + 1e-9)


def nms(boxes, scores, iou_thr):
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        if order.size == 1:
            break
        rest = order[1:]
        order = rest[iou(boxes[i], boxes[rest]) <= iou_thr]
    return keep


def decode_airplanes(pred: np.ndarray, conf_thr: float):
    """pred: (8400,85). Returns [(xyxy_letterbox, score)] for airplane class."""
    boxes_xywh = pred[:, :4]
    obj = pred[:, 4]
    cls = pred[:, 5:]
    air_score = obj * cls[:, COCO_AIRPLANE]
    mask = air_score >= conf_thr
    if not mask.any():
        return []
    xywh = boxes_xywh[mask]
    xyxy = np.empty_like(xywh)
    xyxy[:, 0] = xywh[:, 0] - xywh[:, 2] / 2
    xyxy[:, 1] = xywh[:, 1] - xywh[:, 3] / 2
    xyxy[:, 2] = xywh[:, 0] + xywh[:, 2] / 2
    xyxy[:, 3] = xywh[:, 1] + xywh[:, 3] / 2
    scores = air_score[mask]
    keep = nms(xyxy, scores, NMS_IOU)
    return [(xyxy[i], float(scores[i])) for i in keep]


class Detector:
    def __init__(self):
        self.model = ct.models.MLModel(MLPACKAGE, compute_units=ct.ComputeUnit.CPU_ONLY)

    def predict_region(self, rgb: np.ndarray, x0: int, y0: int, side: int) -> list:
        """Run one region of the full-res image. Region (x0,y0,side,side) is
        resized to 640 if needed. Returns [(xyxy_fullres, score)]."""
        h, w = rgb.shape[:2]
        x0 = max(0, min(x0, w - 1)); y0 = max(0, min(y0, h - 1))
        x1 = min(w, x0 + side); y1 = min(h, y0 + side)
        region = rgb[y0:y1, x0:x1]
        rh, rw = region.shape[:2]
        if rh == 0 or rw == 0:
            return []
        r = min(INPUT_SIZE / rh, INPUT_SIZE / rw)
        if r < 1.0:
            region = cv2.resize(region, (int(round(rw * r)), int(round(rh * r))),
                                interpolation=cv2.INTER_LINEAR)
        else:
            r = 1.0
        canvas = np.full((INPUT_SIZE, INPUT_SIZE, 3), 114, dtype=np.uint8)
        canvas[:region.shape[0], :region.shape[1]] = region
        x = canvas.transpose(2, 0, 1).astype(np.float32)[None, ...]
        out = self.model.predict({INPUT_NAME: x})
        pred = np.asarray(next(iter(out.values()))).reshape(-1, 85)
        dets = decode_airplanes(pred, CONF_THRESHOLD)
        return [((b / r) + np.array([x0, y0, x0, y0]), s) for b, s in dets]

    def full_letterbox(self, rgb: np.ndarray) -> list:
        h, w = rgb.shape[:2]
        return self.predict_region(rgb, 0, 0, max(h, w))


def find_bracket(rgb: np.ndarray):
    """Locate the composed-in cyan bracket. Returns (center_xy, bbox, n_px)
    or None. Tight color gate: strong cyan, low red — sky is much greyer."""
    f = rgb.astype(np.float32)
    dist = np.linalg.norm(f - BRACKET_RGB, axis=2)
    # Two rendering eras, tried strict-first so the modern opaque bracket
    # isn't diluted by pale sky pixels: (1) current opaque 0x00D4FF;
    # (2) the pale June-5..13 variant blended with sky (R lifted to ~90).
    strict = (dist < 90) & (f[:, :, 0] < 110) & (f[:, :, 1] > 150) & (f[:, :, 2] > 190)
    wide = (dist < 150) & (f[:, :, 0] < 130) & (f[:, :, 1] > 170) \
        & (f[:, :, 2] > 200) & ((f[:, :, 2] - f[:, :, 0]) > 90)
    for mask in (strict, wide):
        got = _bracket_from_mask(mask)
        if got:
            return got
    return None


def _bracket_from_mask(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) < 200:  # bracket strokes are ~12 px wide at photo res; real hits are thousands
        return None
    # Percentile bbox to shrug off stray cyan-ish pixels elsewhere.
    x_lo, x_hi = np.percentile(xs, [2, 98])
    y_lo, y_hi = np.percentile(ys, [2, 98])
    # Shape gate: the real bracket is a ~315 px square (140 pt at the
    # 1080x1920 photo scale). Pre-composer photos can still produce cyan-ish
    # matches (horizon haze) but they come out as wide flat strips — reject
    # anything that isn't roughly bracket-sized and square.
    bw, bh = x_hi - x_lo, y_hi - y_lo
    if not (180 <= bw <= 520 and 180 <= bh <= 520 and 0.65 <= bw / max(bh, 1) <= 1.55):
        return None
    center = ((x_lo + x_hi) / 2.0, (y_lo + y_hi) / 2.0)
    return center, (float(x_lo), float(y_lo), float(x_hi), float(y_hi)), int(len(xs))


def merge_global(dets: list) -> list:
    if not dets:
        return []
    boxes = np.array([d[0] for d in dets]); scores = np.array([d[1] for d in dets])
    keep = nms(boxes, scores, NMS_IOU)
    out = [(boxes[i], float(scores[i])) for i in keep]
    out.sort(key=lambda t: -t[1])
    return out


def center_of(box) -> tuple:
    return (float((box[0] + box[2]) / 2), float((box[1] + box[3]) / 2))


def main() -> int:
    photos = sorted(PHOTO_DIR.glob("*.jpg")) + sorted(PHOTO_DIR.glob("*.jpeg"))
    if not photos:
        log(f"no photos in {PHOTO_DIR}")
        return 1
    det = Detector()
    log(f"{len(photos)} photos, model loaded (CPU)")

    results = []
    for path in photos:
        t0 = time.perf_counter()
        img = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
        rgb = np.asarray(img)
        h, w = rgb.shape[:2]

        bracket = find_bracket(rgb)
        rec = {"file": path.name, "size": [w, h], "bracket": None,
               "crop640": [], "crop1280": [], "sweep": []}

        # SWEEP: full-frame letterbox + native-res tiles.
        sweep = det.full_letterbox(rgb)
        for ty in range(0, max(1, h - INPUT_SIZE + TILE_STRIDE), TILE_STRIDE):
            for tx in range(0, max(1, w - INPUT_SIZE + TILE_STRIDE), TILE_STRIDE):
                sweep += det.predict_region(rgb, tx, ty, INPUT_SIZE)
        sweep = merge_global(sweep)
        rec["sweep"] = [{"box": [float(v) for v in b], "score": s} for b, s in sweep]

        if bracket:
            (bcx, bcy), bbox, npx = bracket
            rec["bracket"] = {"center": [bcx, bcy], "bbox": list(bbox), "px": npx}
            # CROP passes centered on the bracket (the proposed fix).
            c640 = merge_global(det.predict_region(rgb, int(bcx - 320), int(bcy - 320), INPUT_SIZE))
            c1280 = merge_global(det.predict_region(rgb, int(bcx - 640), int(bcy - 640), 1280))
            rec["crop640"] = [{"box": [float(v) for v in b], "score": s} for b, s in c640]
            rec["crop1280"] = [{"box": [float(v) for v in b], "score": s} for b, s in c1280]
            if sweep:
                px, py = center_of(sweep[0][0])
                rec["miss_px"] = float(np.hypot(px - bcx, py - bcy))
                # Distance to the NEAREST detection too — in airport scenes
                # the top-confidence det can be a parked plane, not the target.
                rec["miss_nearest_px"] = float(min(
                    np.hypot(center_of(b)[0] - bcx, center_of(b)[1] - bcy)
                    for b, _ in sweep
                ))

        # Annotate.
        bgr = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
        if bracket:
            (bcx, bcy), bbox, _ = bracket
            cv2.rectangle(bgr, (int(bbox[0]), int(bbox[1])), (int(bbox[2]), int(bbox[3])),
                          (0, 212, 255), 3)  # recovered bracket, cyan-ish (BGR swap ok)
            cv2.drawMarker(bgr, (int(bcx), int(bcy)), (0, 212, 255),
                           cv2.MARKER_CROSS, 60, 4)
            cv2.rectangle(bgr, (int(bcx - 320), int(bcy - 320)), (int(bcx + 320), int(bcy + 320)),
                          (255, 200, 0), 2)  # 640 crop region
        for b, s in sweep:
            x1, y1, x2, y2 = [int(v) for v in b]
            cv2.rectangle(bgr, (x1, y1), (x2, y2), (0, 220, 0), 4)
            cv2.putText(bgr, f"plane {s:.2f}", (x1, max(30, y1 - 12)),
                        cv2.FONT_HERSHEY_SIMPLEX, 1.4, (0, 220, 0), 3, cv2.LINE_AA)
        cv2.imwrite(str(OUT / f"annotated_{path.stem}.jpg"), bgr,
                    [cv2.IMWRITE_JPEG_QUALITY, 82])

        dt = time.perf_counter() - t0
        miss = rec.get("miss_px")
        log(f"{path.name:<36} bracket={'Y' if bracket else 'n'} "
            f"sweep={len(sweep)} crop640={len(rec['crop640'])} crop1280={len(rec['crop1280'])} "
            f"miss={f'{miss:.0f}px' if miss is not None else '-':>7} {dt:5.1f}s")
        results.append(rec)

    (OUT / "results.json").write_text(json.dumps(results, indent=1))
    log(f"\nwrote {OUT}/results.json + annotated images")
    return 0


if __name__ == "__main__":
    sys.exit(main())
