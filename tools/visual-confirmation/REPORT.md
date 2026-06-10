# Visual-confirmation spike — model conversion report

Goal of this half of the spike: produce a CoreML airplane detector from
COCO-pretrained **YOLOX-Small** and prove it runs on macOS, end-to-end, before
any iOS integration. The Swift half (decode + NMS + AR reticle lock) lands on
this same branch next.

**Bottom line:** the conversion chain works and the INT8 CoreML model detects
airplanes that occupy a meaningful fraction of frame with high confidence
(0.81-0.94). It is **not** reliable on true distant specks (the dominant
Tailspot field case), and it false-positives helicopters and some
airplane-shaped ground clutter as "airplane." **A fine-tune on small/distant
aircraft is needed before the in-app go/no-go gate** -- details under
"Honest small-aircraft assessment."

---

## 1. Artifacts + file sizes

| Artifact | Size | Notes |
|---|---|---|
| `YoloxAirplane_int8.mlpackage` | **9.20 MB** (3 files; `weight.bin` = 9.04 MB) | **committed** -- INT8 weight-quantized, the deploy candidate |
| FP16 `.mlpackage` (intermediate) | 18.11 MB | produced in `out/`, **not committed** (deleted to save disk) |
| `yolox_s.onnx` (intermediate) | 35.97 MB | validated then **deleted** |
| `yolox_s.pth` (COCO weights) | 69 MB | downloaded to `~/.cache/yolox/`, **deleted** after conversion |

INT8 vs FP16: **9.20 MB vs 18.11 MB** -- a 2.0x shrink, as expected for 8-bit
linear weight quantization. This tracks the SkySpottr precedent (YOLOX-S INT8 @
8.7 MB); our 9.2 MB is slightly larger because we kept the grid/stride decode
baked into the graph (extra constant tensors) rather than stripping it.

## 2. macOS latency

Measured in `validate.py` over the 7 test images, timing only `MLModel.predict`.

| | latency |
|---|---|
| first call (cold) | 448 ms |
| warm mean | **265 ms** |
| warm min / max | 259 / 272 ms |

**Caveat -- this number is a weak proxy for the device.** This Mac has no native
arm64 Python, so everything runs x86_64 under **Rosetta**, on **CPU only**
(`ComputeUnit.CPU_ONLY`). The GPU/ANE path is unavailable here -- coremltools'
MPS backend errors under Rosetta ("MPSGraph doesn't support padded tensors on
Intel macs"). On a real iPhone the same model runs on the Neural Engine; the
SkySpottr precedent reports **~5.6 ms** for the same architecture/quantization.
**Treat ~5-10 ms, not 265 ms, as the expected on-device latency.** The macOS run
here proves *correctness*, not device speed.

## 3. Per-image hit table

Run: `validate.py`, confidence threshold (obj x class) >= **0.30**, NMS IoU 0.45,
airplane = COCO class 4. Annotated images in `out/annotated_*.jpg`.

| Image | Scenario | Airplanes found | Top conf | Verdict |
|---|---|---|---|---|
| `01_airliner_overhead.jpg` | Airliner crossing overhead, ~70 px wide (small) | 1 | 0.81 | HIT -- tight box on the small plane |
| `02_airliner_approach.jpg` | 737 on approach, large in frame | 1 | 0.94 | HIT |
| `03_plane_in_clouds.jpg` | Jet against cloud/haze | 1 | 0.92 | HIT |
| `04_helicopter.jpg` | Daytime helicopter, airframe visible | 2 | 0.90 | **FALSE POSITIVE** -- heli called "airplane" 0.90; a streetlamp called "airplane" 0.72 |
| `05_empty_sky.jpg` | Empty sky (negative control) | 0 | -- | CORRECT (no detection) |
| `06_cessna_ga.jpg` | Cessna 172 GA, large in frame | 1 | 0.92 | HIT |
| `07_airliner_distant.jpg` | "Distant" CRJ -- actually a clear telephoto shot | 1 | 0.92 | HIT |

So 5/5 clear airplane images detected; the empty-sky control is clean; the
helicopter is misclassified as airplane (expected -- see below).

### Small-aircraft size sweep (the spike's central question)

`validate.py`'s scale probe shrinks image 01 so the plane occupies progressively
fewer pixels, and reads the best airplane confidence:

| Plane footprint (approx width) | Best airplane conf |
|---|---|
| ~70 px (full res) | 0.81 |
| ~47 px | 0.78 |
| ~29 px | 0.58 |
| ~19 px | 0.48 |
| ~12 px | 0.17  (below a 0.30 gate: **missed**) |
| ~7 px | 0.00  (**completely missed**) |

Confidence falls off smoothly with apparent size and crosses below a usable
threshold somewhere around a **~15-20 px** plane footprint in the 640-input
frame.

## 4. Output tensor spec + Swift decode procedure

### Input
- Name: `image`. Shape `(1, 3, 640, 640)`, **float32**, layout **NCHW**.
- **RGB** channel order, **raw 0-255** pixel values. **No /255, no mean/std**
  (YOLOX with `legacy=False` does no normalization). The CoreML model has no
  scale/bias baked in -- Swift must hand it raw pixel values.
- It is a plain `MLMultiArray` input (NOT an `ImageType`), so Swift does the
  letterbox + channel ordering itself and fills the array.

**Preprocessing Swift must do (mirrors `validate.py.letterbox` + `to_model_input`):**
1. Compute `r = min(640 / origH, 640 / origW)`.
2. Resize the source to `(round(origW*r), round(origH*r))`.
3. Paste it **top-left** onto a 640x640 canvas pre-filled with **114** (gray).
   Padding is bottom/right only; the top-left offset is `(0, 0)`.
4. Write into the MLMultiArray as NCHW float32, RGB, values in `[0, 255]`.

### Output
- Name: `detections`. Shape `(1, 8400, 85)`, float32.
- 8400 = 80x80 + 40x40 + 20x20 anchors (one per grid cell at strides 8/16/32 on
  a 640 input: 6400 + 1600 + 400). Anchor order in the tensor is **stride-8
  block first, then stride-16, then stride-32**.
- Per row of 85: `[cx, cy, w, h, obj, cls_0 ... cls_79]`.
  - `cx, cy, w, h` -- box center + size **in 640x640 letterbox-pixel space**.
    **The grid/stride decode is already applied inside the model**
    (`head.decode_in_inference = True`): the model emits
    `cx = (raw_x + grid_x) * stride`, `w = exp(raw_w) * stride`, etc.
    **Swift does NOT need to rebuild the grid/stride table.**
  - `obj` -- objectness, **already sigmoid-activated** (in `[0, 1]`).
  - `cls_0..cls_79` -- 80 COCO class scores, **already sigmoid-activated**.
- **Airplane = COCO class index 4**, i.e. column `5 + 4 = 9`.

**Postprocessing Swift must do (mirrors `validate.py.decode`):**
1. For each of the 8400 rows, `score = obj * cls_4` (airplane only -- we don't
   care about the other 79 classes for the gate).
2. Keep rows with `score >= threshold` (we used 0.30; tune on device).
3. Convert center `xywh -> xyxy`:
   `x1 = cx - w/2; y1 = cy - h/2; x2 = cx + w/2; y2 = cy + h/2`.
4. **Un-letterbox** back to original-image pixels: divide all four by `r`.
   (No offset subtraction -- padding was bottom/right, top-left anchored.)
5. Greedy NMS at IoU 0.45 over the surviving boxes.

That's the entire Swift port surface. `validate.py` is the reference
implementation in numpy; the math is line-for-line portable to Accelerate / a
simple Swift loop (8400 rows is trivial to scan).

> Note on an alternative: if you ever prefer to do the grid/stride decode in
> Swift instead, re-export with `model.head.decode_in_inference = False` in
> `convert.py`. The model then emits raw `cx,cy` offsets and log-space `w,h`, and
> Swift applies `(raw+grid)*stride` / `exp(raw)*stride` using the 8400-anchor
> stride table above. We chose decode-in-model for the spike: fewer Swift bugs,
> and it matches the library's own postprocess exactly so the numpy validation
> is faithful.

## 5. License chain

Clean, commercial-OK end to end:

- **Weights:** YOLOX-S COCO checkpoint via **`pixeltable-yolox` 0.4.2**, which
  redistributes the Megvii YOLOX weights under **Apache-2.0**
  (`Yolox.from_pretrained("yolox_s")`). NOT Ultralytics (AGPL), NOT YOLO-NAS
  (non-commercial). Megvii's YOLOX itself is Apache-2.0.
- **Conversion tooling:** coremltools (BSD-3), onnx (Apache-2.0), torch (BSD),
  opencv-python (Apache-2.0/BSD) -- all permissive.
- **The produced `.mlpackage`** is a derivative of the Apache-2.0 weights ->
  Apache-2.0. Recorded in the model's `license` metadata field.
- **Test images:** CC0 / CC BY / CC BY-SA (per `test-images/SOURCES.md`); used
  here for evaluation only, none baked into the shipped model.

## 6. Honest small-aircraft assessment -- does this gate on its own?

**No -- not as-is for the field case. Fine-tune first.**

What COCO-pretrained YOLOX-S does well:
- Detects aircraft that fill a real fraction of the frame (>=25-30 px footprint)
  with high, reliable confidence across liveries, lighting, and cloud/haze
  backdrops -- including a small GA Cessna and a small overhead airliner.
- Clean on a true empty-sky negative.
- Box localization (after un-letterbox) is pixel-accurate, so once a plane is
  detected, AR reticle placement will be solid.

Where it fails for Tailspot specifically:
1. **Distant specks fall off a cliff.** Tailspot's whole premise is a phone
   pointed at a plane that's often a tiny dot at altitude (Berkeley/Oakland is
   under the SFO/OAK approach corridors, but cruising traffic is still small in
   frame). The size sweep shows confidence dropping below a usable 0.30 gate at
   roughly a 15-px footprint and to zero by ~7 px. COCO has very few tiny-object
   airplane examples, so this is a training-data gap, not a tuning knob.
2. **Helicopters are misclassified as "airplane" at high confidence (0.90).**
   COCO has no helicopter class, so the model generalizes rotorcraft to its
   nearest learned class. For Tailspot this is arguably *acceptable* (a heli
   overhead is still "an aircraft the user is pointing at"), but it means the
   detector cannot be trusted to *distinguish* aircraft type -- that stays the
   job of ADS-B correlation, exactly as the geometric-ID architecture assumes.
3. **Airplane-shaped ground clutter false-positives** (a streetlamp scored 0.72).
   In the app this is mitigated because detections are only trusted when they
   agree with an ADS-B-predicted bearing/elevation, but a naive
   "is there a plane on screen" gate would fire on clutter.

**Recommendation for the in-app gate:**
- Use this model now to validate the *Swift inference + decode + reticle*
  plumbing end-to-end (that's what it's good enough for, and that's the next
  task on this branch).
- Before relying on visual confirmation as a real go/no-go signal, **fine-tune
  YOLOX-S on small/distant aircraft** (e.g. a tiny-aircraft dataset, or
  self-supervised crops harvested from field replays + ADS-B labels). Add a
  rotorcraft class if telling helicopters apart matters. The SkySpottr precedent
  did exactly this -- it trained an aircraft-specific detector rather than
  shipping raw COCO. Our results independently reproduce *why* that step is
  necessary.
- Because Tailspot already knows the ADS-B-predicted screen position, a cheaper
  near-term alternative is to **crop a tight window around the predicted
  location and upscale it** before inference, which moves a distant speck back up
  the size curve into the model's reliable range. Worth trying before committing
  to a fine-tune.

## 7. Reproduce

From `tools/visual-confirmation/` (see `requirements.txt` for the Python/torch
pinning rationale -- Python 3.9 x86_64 is forced by this machine's lack of a
native arm64 Python + torch dropping x86 macOS wheels after 2.2.2):

```
python3.9 -m venv .venv
.venv/bin/python -m pip install --upgrade pip setuptools wheel
.venv/bin/python -m pip install -r requirements.txt
python3 test-images/download.py        # fetch CC/PD test images (stdlib only)
.venv/bin/python convert.py            # weights -> ONNX -> CoreML FP16 -> INT8
.venv/bin/python validate.py           # run images, decode+NMS, annotate, time
```

`convert.py` re-downloads the 69 MB COCO `.pth` to `~/.cache/yolox/` on a fresh
run; delete it + `out/` afterward to reclaim disk.

## 8. Peak disk usage during this spike

Free space started at ~10 GB. Lowest observed free space was **~5.8 GB** (after
the full venv -- torch ~900 MB, coremltools/onnx/onnxruntime/opencv, plus the
36 MB ONNX + 18 MB FP16 + 9 MB INT8 packages in `out/`). That is a **peak
consumption of ~4.2 GB** above the starting point, never breaching the 4 GB
free-space floor. The pip cache was purged mid-run (reclaimed ~480 MB) and the
ONNX + FP16 intermediates + `.pth` were deleted at the end, returning free space
to ~24 GB. The CUDA-build trap was avoided -- macOS torch wheels are inherently
CPU-only.
