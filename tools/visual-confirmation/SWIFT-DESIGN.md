# Visual Confirmation — Swift Integration Design (Stage 2a, second half)

**Status:** design committed before implementation. Model + decode are done:
`YoloxAirplane_int8.mlpackage` (9.2 MB, see REPORT.md) and
`AirplaneDetectionDecoder.swift` (pure decode + NMS, 18 tests).

## The core idea: detect in a crop, not the frame

REPORT.md's size sweep shows COCO-pretrained YOLOX-S loses distant aircraft
below a ~15–20 px footprint. Downscaling a full 4032-px-wide frame to 640×640
costs ~6.3× of apparent size — a 60 px plane on the sensor becomes an
undetectable 9 px. But Tailspot never needs full-frame search: ADS-B +
geometry already predict where the plane should be. So the detector runs on a
**640×640 native-resolution crop centered on the predicted position**,
preserving the sensor's full resolution exactly where it matters. The same
plane stays 60 px and detects at ~0.8 confidence. The crop window only has to
cover the *error* of the prediction (compass wobble), not the sky.

Crop-size math (portrait, baseHfovDeg 56° across the short side ≈ 1170 px of
a 3024×4032 frame at 1×): 1° of bearing ≈ 21 px native. A 640 px crop covers
±15° of compass error at 1× zoom — matching the observed ±10–20° urban wobble.
At higher zoom the same crop covers proportionally less angle but the plane is
proportionally bigger; if tuning shows clipping at 1×, fall back to a 960 px
crop downscaled to 640 (1.5× size cost, ±23° coverage).

## Components

1. **Frame tap.** `CameraPreview`'s `AVCaptureSession` gains an
   `AVCaptureVideoDataOutput` on the existing dedicated session queue,
   delivering BGRA `CVPixelBuffer`s. Frames are throttled to ~8 fps and only
   consumed while at least one aircraft is a detection candidate (lock-engine
   target or pinned plane first; ambient candidates later if cheap).
2. **Screen→sensor mapping.** Reuse `AspectFillTransform`
   (CatchPhotoComposer.swift) to map the predicted *screen* position into
   *camera-pixel* coordinates — it already encodes the `.resizeAspectFill`
   relationship and is unit-tested.
3. **`AirplaneDetector`** (new, `nonisolated` final class, owned off-main):
   direct `MLModel` (not `VNCoreMLRequest` — Vision hides letterboxing and
   resampling choices; we need exact control to match the decoder's
   assumptions). Pipeline: crop CVPixelBuffer (vImage/CoreImage) → 640×640 →
   MLMultiArray → `AirplaneDetectionDecoder.decode` (letterboxScale = crop
   scale, pad zero) → NMS → map rects back to sensor coords → back to screen
   coords via the inverse aspect-fill transform.
4. **Association + smoothing** (pure, testable): among detections in the
   crop, accept the highest-confidence one within a gate radius of the
   predicted position (gate ≈ the crop half-width; tighter after first
   acquisition). Maintain per-icao24 state: EMA-smoothed screen offset
   (predicted→visual), confidence, missed-frame counter. N consecutive misses
   (≈8 ≈ 1 s) → expire and fall back to predicted position. Multiple
   candidate aircraft in one crop: nearest-prediction wins, one detection
   feeds one aircraft (no double-claim).
5. **Rendering.** The lock bracket reads the corrected position when a live
   visual fix exists (full-opacity treatment) and the predicted position
   otherwise (current treatment becomes the lower-confidence style per
   PLAN §1.1a). Feature-flagged: debug-overlay toggle, default ON in Debug,
   OFF in Release until the field gate passes.
6. **Ground truth for the gate.** `ReplayRecorder` tick gains optional
   fields: `visualFix` (detected screen xy + confidence + crop rect) per
   aircraft. Additionally, while recording, save the crop JPEG at 1 Hz to
   `Documents/replays/frames/<session>/` so the go/no-go can be re-scored
   offline as the detector/tuning evolves (schemaVersion bump not needed —
   fields are additive-optional; analyzer treats nil as "no detector ran").

## The go/no-go gate (unchanged from the program spec)

One field session under the SFO/OAK corridor with recording on: for every
tap-pinned (user-confirmed-visible) aircraft, compare bracket-to-plane error
with and without visual fix across the recorded frames. PASS = the visual fix
reduces median screen error meaningfully (target ≥2×) on confirmed-visible
airliners within ~10 km, with zero fixes snapping to the wrong object in a
two-plane frame. FAIL → feature flag stays off for beta; fine-tuning path
(REPORT.md) becomes a post-beta work package.

## Out of scope for this stage

Fine-tuning on airborne imagery (post-gate decision), multi-crop scheduling
for many simultaneous candidates (start with lock target + pin only),
ANE-vs-GPU performance tuning beyond a working 8 fps budget.
