#!/usr/bin/env python3
"""
convert.py — YOLOX-Small (COCO) → ONNX → CoreML .mlpackage → INT8.

Tailspot "visual confirmation" spike. Produces a CoreML airplane detector and
proves the conversion chain end-to-end on macOS. Reproducible: weights are
pulled from the Apache-2.0 Pixeltable YOLOX fork (`pixeltable-yolox`), exported
to ONNX, converted to CoreML, and INT8 weight-quantized.

Design decisions (see REPORT.md for the full rationale):

  * Model: YOLOX-S, COCO-pretrained, Apache-2.0 weights via
    `pixeltable_yolox`'s `Yolox.from_pretrained("yolox_s")`.
    NOT Ultralytics (AGPL) and NOT YOLO-NAS (non-commercial).

  * NMS is NOT baked into the model. Decode + NMS live in Swift (and in
    validate.py's numpy mirror). The exported model emits the raw decoded
    detection tensor only.

  * GRID/STRIDE DECODE *IS* baked in (head.decode_in_inference = True, the
    library default). So the model output is already in letterbox-pixel xywh
    space — Swift does NOT need to rebuild the 8400-anchor grid/stride table.
    The full anchor layout is still documented in REPORT.md for verification.

  * Input: 1x3x640x640, RGB, raw 0-255 pixel values (NCHW). YOLOX with
    legacy=False applies NO /255 and NO mean/std normalization, so the CoreML
    model takes raw pixel values directly. Letterbox (pad-to-square with 114)
    happens BEFORE the model, on the Swift/numpy side.

  * Output: [1, 8400, 85] float. Per anchor: [cx, cy, w, h, obj, cls0..cls79].
    cx,cy,w,h are in 640x640 letterbox-pixel space. obj and the 80 class
    scores are already sigmoid-activated. Airplane = COCO class index 4.

  * coremltools ML-program format, minimum_deployment_target = iOS 16.
    INT8 weight quantization via
    coremltools.optimize.coreml.linear_quantize_weights.

Disk hygiene: the ONNX intermediate and the FP16 .mlpackage are kept in out/
(gitignored) for validate.py to compare sizes; the cached .pth weights live in
weights/ (gitignored). Delete out/ and weights/ to reclaim space after the
committed INT8 .mlpackage exists.

Run:  .venv/bin/python convert.py
"""
from __future__ import annotations

import os
import shutil
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")

import numpy as np
import torch

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
WEIGHTS = HERE / "weights"
OUT.mkdir(exist_ok=True)
WEIGHTS.mkdir(exist_ok=True)

# Best-effort: route any torch/HF cache into our gitignored weights/. NOTE:
# pixeltable-yolox's from_pretrained actually caches the .pth in ~/.cache/yolox/
# (it ignores these), so the downloaded weights land OUTSIDE the repo. Either
# way nothing weight-sized is committed. Delete ~/.cache/yolox + out/ to reclaim
# disk after the INT8 .mlpackage exists.
os.environ.setdefault("TORCH_HOME", str(WEIGHTS))
os.environ.setdefault("HF_HOME", str(WEIGHTS))
os.environ.setdefault("XDG_CACHE_HOME", str(WEIGHTS / "cache"))

INPUT_SIZE = 640
ONNX_PATH = OUT / "yolox_s.onnx"
MLPACKAGE_FP16 = OUT / "YoloxAirplane_fp16.mlpackage"
MLPACKAGE_INT8 = HERE / "YoloxAirplane_int8.mlpackage"  # committed artifact
INPUT_NAME = "image"
OUTPUT_NAME = "detections"


def log(msg: str) -> None:
    print(f"[convert] {msg}", flush=True)


def load_model() -> torch.nn.Module:
    """Load YOLOX-S COCO weights from the Apache-2.0 Pixeltable fork."""
    from yolox.models import Yolox

    log("loading YOLOX-S (COCO) from pixeltable-yolox 'yolox_s' ...")
    # from_pretrained returns a thin Yolox wrapper (.module = the nn.Module,
    # .processor = pre/post helpers). We export the underlying nn.Module.
    wrapper = Yolox.from_pretrained("yolox_s", device="cpu")
    model = wrapper.module
    model.eval()

    # Keep grid/stride decode baked in (library default). NMS is NOT here.
    # head.decode_in_inference stays True so the forward emits decoded xywh.
    head = model.head
    assert getattr(head, "decode_in_inference", True), \
        "expected decode_in_inference=True so output is in pixel space"
    log("model loaded; decode_in_inference=True (grid/stride decode baked in)")
    return model


def export_onnx(model: torch.nn.Module) -> None:
    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE, dtype=torch.float32)
    with torch.no_grad():
        out = model(dummy)
    log(f"torch forward output shape: {tuple(out.shape)} (expect [1, 8400, 85])")

    log(f"exporting ONNX -> {ONNX_PATH.name} (opset 13) ...")
    with torch.no_grad():
        torch.onnx.export(
            model,
            dummy,
            str(ONNX_PATH),
            input_names=[INPUT_NAME],
            output_names=[OUTPUT_NAME],
            opset_version=13,
            do_constant_folding=True,
            dynamic_axes=None,  # fixed 1x3x640x640 — simplest for CoreML
        )
    size_mb = ONNX_PATH.stat().st_size / 1e6
    log(f"ONNX written: {size_mb:.1f} MB")


def validate_onnx() -> None:
    """Structural check on the ONNX intermediate (documented deliverable)."""
    import onnx

    log("checking ONNX intermediate validity ...")
    model = onnx.load(str(ONNX_PATH))
    onnx.checker.check_model(model)
    out = model.graph.output[0]
    dims = [d.dim_value for d in out.type.tensor_type.shape.dim]
    log(f"ONNX OK; graph output '{out.name}' dims {dims}")


def convert_coreml(model: torch.nn.Module) -> "object":
    import coremltools as ct

    # coremltools 7+ removed the ONNX frontend, so we convert from a traced
    # TorchScript graph (the well-supported path). The ONNX file is still
    # produced + validated as a documented intermediate, but the CoreML graph
    # comes straight from torch. Same weights either way.
    log("tracing TorchScript graph for CoreML conversion ...")
    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE, dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    log("converting TorchScript -> CoreML ML-program (iOS16 target) ...")
    # The model takes raw 0-255 RGB NCHW; no scale/bias because YOLOX
    # legacy=False does no normalization. We use a plain TensorType input (NOT
    # ImageType): the Swift side does the letterbox + RGB ordering and hands the
    # model a raw MLMultiArray. This keeps the spike's preprocessing explicit
    # and matched to validate.py's numpy mirror.
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
        inputs=[
            ct.TensorType(
                name=INPUT_NAME,
                shape=(1, 3, INPUT_SIZE, INPUT_SIZE),
                dtype=np.float32,
            )
        ],
        outputs=[ct.TensorType(name=OUTPUT_NAME, dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = (
        "YOLOX-S COCO airplane detector (Tailspot spike). Input 1x3x640x640 "
        "RGB raw 0-255 NCHW. Output [1,8400,85] decoded xywh+obj+80cls "
        "(letterbox-pixel space, sigmoid applied). NMS in Swift. Airplane=cls4."
    )
    mlmodel.author = "Tailspot visual-confirmation spike"
    mlmodel.license = "Apache-2.0 (weights: pixeltable-yolox YOLOX-S COCO)"

    if MLPACKAGE_FP16.exists():
        shutil.rmtree(MLPACKAGE_FP16)
    mlmodel.save(str(MLPACKAGE_FP16))
    log(f"FP16 CoreML saved: {MLPACKAGE_FP16.name}")
    return mlmodel


def quantize_int8(mlmodel: "object") -> None:
    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    log("INT8 weight quantization (linear, per-channel) ...")
    op_cfg = OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
    cfg = OptimizationConfig(global_config=op_cfg)
    quant = linear_quantize_weights(mlmodel, config=cfg)

    if MLPACKAGE_INT8.exists():
        shutil.rmtree(MLPACKAGE_INT8)
    quant.save(str(MLPACKAGE_INT8))
    log(f"INT8 CoreML saved: {MLPACKAGE_INT8.name}")


def dir_size_mb(path: Path) -> float:
    total = 0
    for p in path.rglob("*"):
        if p.is_file():
            total += p.stat().st_size
    return total / 1e6


def main() -> int:
    model = load_model()
    export_onnx(model)
    validate_onnx()
    mlmodel = convert_coreml(model)
    del model  # free torch graph before quantization
    quantize_int8(mlmodel)

    log("--- artifact sizes ---")
    if MLPACKAGE_FP16.exists():
        log(f"  FP16 .mlpackage: {dir_size_mb(MLPACKAGE_FP16):.2f} MB")
    if MLPACKAGE_INT8.exists():
        log(f"  INT8 .mlpackage: {dir_size_mb(MLPACKAGE_INT8):.2f} MB")
    if ONNX_PATH.exists():
        log(f"  ONNX intermediate: {ONNX_PATH.stat().st_size / 1e6:.2f} MB "
            f"(safe to delete: rm {ONNX_PATH})")

    log("done. Run validate.py next, then delete out/ and weights/ "
        "to reclaim disk.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
