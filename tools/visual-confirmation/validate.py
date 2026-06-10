#!/usr/bin/env python3
"""
validate.py — load the INT8 CoreML model on macOS, run the test images, and
prove the decode + NMS pipeline that will live in Swift.

This is the macOS proof-of-life for the Tailspot visual-confirmation spike. The
numpy postprocessing here is a 1:1 mirror of what the Swift side must do:

  PRE  (per image):
    1. Letterbox-resize to 640x640: scale r = min(640/h, 640/w), resize, then
       paste top-left onto a 114-gray 640x640 canvas. Record r + pad offsets.
       (YOLOX pads bottom/right only — top-left anchored, offset = 0,0.)
    2. RGB, raw 0-255 float32, layout NCHW (1,3,640,640). NO /255, NO mean/std.

  MODEL: emits [1, 8400, 85]. Per row: [cx, cy, w, h, obj, cls0..cls79].
         cx,cy,w,h are in 640x640 letterbox-pixel space (grid/stride decode is
         already baked into the model). obj + class scores already sigmoid'd.

  POST (per image):
    3. score = obj * class_score; keep airplane (COCO class 4) above threshold.
       (We also surface the model's argmax class so we can see e.g. helicopters
        landing on a wrong/no class.)
    4. xywh -> xyxy (corner) in letterbox space.
    5. Un-letterbox: divide xyxy by r to map back to original-image pixels.
    6. Greedy NMS (IoU 0.45) per class.

Run:  .venv/bin/python validate.py
Outputs: annotated images in out/, a per-image hit table on stdout.
"""
from __future__ import annotations

import sys
import time
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
OUT.mkdir(exist_ok=True)
TEST_DIR = HERE / "test-images"

MLPACKAGE = HERE / "YoloxAirplane_int8.mlpackage"
INPUT_SIZE = 640
INPUT_NAME = "image"
COCO_AIRPLANE = 4
CONF_THRESHOLD = 0.30   # objectness*class; deliberately low to probe small-aircraft recall
NMS_IOU = 0.45

# COCO class names (index -> name); only a few matter for us.
COCO_NAMES = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 4: "airplane",
              5: "bus", 6: "train", 7: "truck", 8: "boat", 14: "bird", 33: "kite"}


def log(msg: str) -> None:
    print(msg, flush=True)


def letterbox(img_rgb: np.ndarray) -> tuple[np.ndarray, float]:
    """Resize keeping aspect, pad bottom/right with 114. Returns (canvas, r)."""
    h, w = img_rgb.shape[:2]
    r = min(INPUT_SIZE / h, INPUT_SIZE / w)
    nw, nh = int(round(w * r)), int(round(h * r))
    resized = cv2.resize(img_rgb, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((INPUT_SIZE, INPUT_SIZE, 3), 114, dtype=np.uint8)
    canvas[:nh, :nw] = resized  # top-left anchored; pad is bottom/right
    return canvas, r


def to_model_input(canvas_rgb: np.ndarray) -> np.ndarray:
    """HWC uint8 RGB -> NCHW float32 raw 0-255 (no normalization)."""
    chw = canvas_rgb.transpose(2, 0, 1).astype(np.float32)  # (3,640,640)
    return chw[None, ...]  # (1,3,640,640)


def iou(box: np.ndarray, boxes: np.ndarray) -> np.ndarray:
    x1 = np.maximum(box[0], boxes[:, 0]); y1 = np.maximum(box[1], boxes[:, 1])
    x2 = np.minimum(box[2], boxes[:, 2]); y2 = np.minimum(box[3], boxes[:, 3])
    inter = np.maximum(0, x2 - x1) * np.maximum(0, y2 - y1)
    area = (box[2] - box[0]) * (box[3] - box[1])
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    return inter / (area + areas - inter + 1e-9)


def nms(boxes: np.ndarray, scores: np.ndarray, iou_thr: float) -> list[int]:
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(int(i))
        if order.size == 1:
            break
        rest = order[1:]
        ious = iou(boxes[i], boxes[rest])
        order = rest[ious <= iou_thr]
    return keep


def decode(pred: np.ndarray, r: float, conf_thr: float):
    """pred: (8400,85) decoded xywh+obj+cls. Returns airplane + best-class lists."""
    boxes_xywh = pred[:, :4]
    obj = pred[:, 4]
    cls = pred[:, 5:]
    cls_id = cls.argmax(axis=1)
    cls_score = cls.max(axis=1)
    score = obj * cls_score

    # xywh (center) -> xyxy in letterbox space, then un-letterbox by /r.
    xyxy = np.empty_like(boxes_xywh)
    xyxy[:, 0] = boxes_xywh[:, 0] - boxes_xywh[:, 2] / 2
    xyxy[:, 1] = boxes_xywh[:, 1] - boxes_xywh[:, 3] / 2
    xyxy[:, 2] = boxes_xywh[:, 0] + boxes_xywh[:, 2] / 2
    xyxy[:, 3] = boxes_xywh[:, 1] + boxes_xywh[:, 3] / 2
    xyxy /= r

    # Airplane-class detections (the gate we actually care about).
    air_obj_score = obj * cls[:, COCO_AIRPLANE]  # obj * airplane-class prob
    air_mask = air_obj_score >= conf_thr
    air_boxes = xyxy[air_mask]
    air_scores = air_obj_score[air_mask]
    air_keep = nms(air_boxes, air_scores, NMS_IOU) if len(air_boxes) else []
    airplanes = [(air_boxes[i], float(air_scores[i])) for i in air_keep]

    # Top overall detection regardless of class (diagnostic: what DID it see?).
    best_mask = score >= conf_thr
    diag = []
    if best_mask.any():
        b = xyxy[best_mask]; s = score[best_mask]; c = cls_id[best_mask]
        keep = nms(b, s, NMS_IOU)
        diag = [(b[i], float(s[i]), int(c[i])) for i in keep]
        diag.sort(key=lambda t: -t[1])
    return airplanes, diag


def draw(img_bgr, dets, color, label_fn):
    for d in dets:
        box = d[0]
        x1, y1, x2, y2 = [int(v) for v in box]
        cv2.rectangle(img_bgr, (x1, y1), (x2, y2), color, 2)
        txt = label_fn(d)
        cv2.putText(img_bgr, txt, (x1, max(12, y1 - 5)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, color, 1, cv2.LINE_AA)


def main() -> int:
    import coremltools as ct

    if not MLPACKAGE.exists():
        log(f"ERROR: {MLPACKAGE} not found. Run convert.py first.")
        return 1

    log(f"loading {MLPACKAGE.name} (CPU compute units) ...")
    # Force CPU: under Rosetta the GPU/MPS backend errors ("padded tensors on
    # Intel macs"); CPU is the reliable + deterministic path for this proof.
    model = ct.models.MLModel(str(MLPACKAGE),
                              compute_units=ct.ComputeUnit.CPU_ONLY)
    out_name = list(model.output_description._fd_spec)[0].name

    images = sorted(TEST_DIR.glob("*.jpg"))
    log(f"running {len(images)} test images @ conf>={CONF_THRESHOLD}, "
        f"airplane=COCO#{COCO_AIRPLANE}\n")

    header = f"{'image':<26} {'airplanes':>9} {'top_conf':>9} {'best_class(conf)':>22} {'ms':>7}"
    log(header)
    log("-" * len(header))

    rows = []
    for path in images:
        bgr = cv2.imread(str(path))
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        canvas, r = letterbox(rgb)
        x = to_model_input(canvas)

        # Time only the model predict() call (decode/NMS timed separately is
        # negligible; this isolates the inference cost we care about).
        t0 = time.perf_counter()
        out = model.predict({INPUT_NAME: x})
        dt_ms = (time.perf_counter() - t0) * 1000.0

        pred = np.asarray(out[out_name]).reshape(-1, 85)
        airplanes, diag = decode(pred, r, CONF_THRESHOLD)

        top_conf = max((s for _, s in airplanes), default=0.0)
        if diag:
            bc = diag[0]
            best_str = f"{COCO_NAMES.get(bc[2], str(bc[2]))}({bc[1]:.2f})"
        else:
            best_str = "-"
        log(f"{path.name:<26} {len(airplanes):>9} {top_conf:>9.3f} {best_str:>22} {dt_ms:>7.1f}")
        rows.append((path.name, len(airplanes), top_conf, best_str, dt_ms))

        # Annotate: airplane dets in green, the top non-airplane diagnostic in orange.
        draw(bgr, airplanes, (0, 200, 0), lambda d: f"airplane {d[1]:.2f}")
        non_air = [d for d in diag if d[2] != COCO_AIRPLANE][:2]
        draw(bgr, non_air, (0, 140, 255),
             lambda d: f"{COCO_NAMES.get(d[2], d[2])} {d[1]:.2f}")
        cv2.imwrite(str(OUT / f"annotated_{path.name}"), bgr)

    # Latency summary (skip first image as warm-up).
    lat = [r[4] for r in rows]
    if len(lat) > 1:
        warm = lat[1:]
        log(f"\nlatency: first={lat[0]:.1f}ms  warm mean={np.mean(warm):.1f}ms  "
            f"warm min={np.min(warm):.1f}ms  warm max={np.max(warm):.1f}ms (CPU, Rosetta x86)")
    log(f"\nannotated images -> {OUT}/annotated_*.jpg")
    return 0


if __name__ == "__main__":
    sys.exit(main())
