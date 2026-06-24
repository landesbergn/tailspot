# Bundled detector — license & attribution

The app bundles a CoreML object detector for visual confirmation:
`ios/Tailspot/Tailspot/YoloxAirplane_int8.mlpackage`.

## Provenance

- **Architecture / weights:** YOLOX-S, COCO-pretrained, obtained via the
  **`pixeltable-yolox`** fork's `Yolox.from_pretrained("yolox_s")`
  (`tools/visual-confirmation/convert.py`). Stock COCO weights — **not**
  fine-tuned (a small/distant-aircraft fine-tune is a future step per
  `REPORT.md`).
- **Conversion:** PyTorch → ONNX → CoreML ML-program → INT8 weight
  quantization (coremltools). Reproducible via `convert.py`.
- The CoreML model's own `license` metadata field is set to
  `"Apache-2.0 (weights: pixeltable-yolox YOLOX-S COCO)"`.

## License

- **YOLOX** (Megvii) is **Apache-2.0**. The `pixeltable-yolox` fork is
  Apache-2.0. COCO-pretrained weights distributed under the same.
- Apache-2.0 is **permissive and safe for closed-source App Store
  distribution** — this was a deliberate choice in `convert.py`:
  - **Not** Ultralytics YOLO (AGPL-3.0 — copyleft, would require a
    commercial license to ship in a closed app).
  - **Not** YOLO-NAS (non-commercial license).

## Compliance checklist (before wider App Store distribution)

Apache-2.0 requires preserving the license and attributing the work:

- [ ] Commit the full **Apache-2.0 license text** + any upstream
      `NOTICE` alongside the model (this file records the obligation; add
      `LICENSE-YOLOX` here, fetched from the `pixeltable-yolox` repo).
- [ ] Add **YOLOX (Megvii, Apache-2.0)** to the app's Attributions page
      (`tailspot.app/attributions.html`, linked from Settings → About).
- [ ] If the model is later fine-tuned, record the **training-data
      provenance + license** here before shipping the fine-tuned weights.

_Note (separate from this model): Settings → About still lists
"OpenSky Network" as the data source; ADS-B now comes from adsb.lol via
the Tailspot backend, so that attribution string is stale and should be
corrected on the same Attributions pass._
