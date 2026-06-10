//
//  AirplaneDetectionDecoder.swift
//  Tailspot
//
//  Pure-math decode + NMS for the YOLOX-Small CoreML output tensor.
//  NO Vision, NO CoreML, NO UIKit — only Foundation and CoreGraphics so
//  the logic is unit-testable without a model file and callable from any
//  actor context.
//
//  WHY pure-math / nonisolated
//  ---------------------------
//  The decoder operates entirely on a [Float] array extracted from the
//  MLMultiArray the model emits.  Keeping it here — rather than inlined
//  inside a Vision/CoreML wrapper — means:
//    • The unit-test suite can exercise decode + NMS with hand-built tensors,
//      no model file, no simulator GPU, no 3-minute cold-boot.
//    • The math is reviewed in isolation; the CoreML plumbing (which is
//      boilerplate) stays in a separate file.
//    • Swapping to a different model architecture later requires touching
//      only the decoder, not the inference pipeline.
//
//  Xcode 26 defaults every type to @MainActor isolation.  This decoder is
//  pure math — no @Published, no UI state — so it is explicitly nonisolated
//  (same pattern as Geo.swift and Aircraft.swift in this repo).
//
//  OUTPUT TENSOR SPEC (from tools/visual-confirmation/REPORT.md §4)
//  ----------------------------------------------------------------
//  Name:  "detections"
//  Shape: (1, 8400, 85)  float32
//  8400 anchors = 80×80 (stride 8) + 40×40 (stride 16) + 20×20 (stride 32)
//  Per row: [cx, cy, w, h, obj, cls_0 … cls_79]
//    - cx, cy, w, h  in 640×640 letterbox-pixel space (grid/stride decode
//      is already baked into the model graph; Swift does NOT re-apply it).
//    - obj   — objectness, already sigmoid-activated ∈ [0, 1].
//    - cls_k — COCO class k score, already sigmoid-activated ∈ [0, 1].
//  Airplane = COCO class 4 → column index 5 + 4 = 9.
//
//  POSTPROCESS PIPELINE (mirrors validate.py exactly)
//  ---------------------------------------------------
//  1. score = obj × cls_4.
//  2. Drop rows where score < confidenceThreshold (default 0.30).
//  3. cx cy w h → x1 y1 x2 y2 (corner form, still letterbox pixels).
//  4. Un-letterbox: x = (x − padX) / scale, y = (y − padY) / scale.
//     Padding is bottom/right (top-left anchored); padX=padY=0 for this
//     model's letterbox, so the formula simplifies to coord / scale.
//     The (letterboxPad) parameter keeps the function general for
//     letterbox variants where the top-left offset is non-zero.
//  5. Greedy NMS at iouThreshold (default 0.45), score-descending.
//

import Foundation
import CoreGraphics

// MARK: - Detection

/// A single airplane detection in the original image's pixel coordinate space.
///
/// `rect` is axis-aligned: `origin` is the top-left corner, measured in the
/// same pixel units as the image fed into the CoreML model (NOT letterbox
/// pixels).  `confidence` is objectness × airplane-class score ∈ (0, 1].
nonisolated struct Detection: Equatable {
    /// Bounding box in original-image pixel coordinates (top-left origin, y-down).
    let rect: CGRect
    /// Detection confidence: objectness × COCO airplane-class score.
    let confidence: Float
}

// MARK: - Decoder

/// Stateless postprocessor for the YOLOX-Small `detections` output tensor.
///
/// Call `decode(tensor:...)` to filter + convert the raw model output, then
/// `nonMaxSuppression(_:...)` to remove duplicates.  Both functions are pure
/// and can be called on any thread.
nonisolated enum AirplaneDetectionDecoder {

    // MARK: Constants

    /// Total per-anchor values: 4 (box) + 1 (objectness) + 80 (COCO classes).
    static let anchorStride: Int = 85
    /// Total number of anchors emitted by the model (80² + 40² + 20²).
    static let anchorCount: Int = 8_400
    /// COCO class index for "airplane" (0-based); column 5 + 4 = 9.
    static let airplaneClassIndex: Int = 4
    /// Input canvas side length the model was trained on (pixels).
    static let inputSize: Float = 640

    // MARK: - Decode

    /// Filter, score, and un-letterbox the raw model output into `Detection`
    /// values in original-image pixel coordinates.
    ///
    /// - Parameters:
    ///   - tensor: Flat `[Float]` from the `(1, 8400, 85)` output tensor,
    ///     row-major.  Length must be `anchorCount × anchorStride` = 714 000.
    ///     Elements are already sigmoid-activated and grid/stride-decoded
    ///     (Swift does NOT reapply strides).
    ///   - airplaneClassIndex: COCO class index to score against; default is
    ///     `4` (airplane).  Override for testing or future fine-tuned models.
    ///   - confidenceThreshold: Minimum `obj × cls` score to keep a candidate.
    ///     Validate.py used 0.30; tune downward for higher recall on distant
    ///     specks once a fine-tuned model is available.
    ///   - letterboxScale: The `r` value from the letterbox step:
    ///     `r = min(640 / origH, 640 / origW)`.  Coordinates are divided by
    ///     this to map from letterbox pixels back to original-image pixels.
    ///   - letterboxPad: `(dx, dy)` top-left offset in letterbox pixels.
    ///     For this model the letterbox is top-left anchored (pad bottom/right),
    ///     so `letterboxPad = (0, 0)` — but the parameter is here for
    ///     correctness if the preprocessing ever uses a centered letterbox.
    /// - Returns: Unsorted `Detection` array (call `nonMaxSuppression` next).
    static func decode(
        tensor: [Float],
        airplaneClassIndex: Int = AirplaneDetectionDecoder.airplaneClassIndex,
        confidenceThreshold: Float = 0.30,
        letterboxScale: Float,
        letterboxPad: (x: Float, y: Float) = (0, 0)
    ) -> [Detection] {
        // Sanity-check: a truncated tensor produces nonsense silently in a
        // tight loop; surface the mismatch as an empty result instead.
        guard tensor.count == anchorCount * anchorStride else { return [] }

        var results: [Detection] = []
        let clsCol = 5 + airplaneClassIndex   // column index of the target class

        for i in 0 ..< anchorCount {
            let base = i * anchorStride

            // Step 1: score = objectness × airplane-class probability.
            let obj = tensor[base + 4]
            let cls = tensor[base + clsCol]
            let score = obj * cls
            guard score >= confidenceThreshold else { continue }

            // Step 2: center xywh → corner xyxy (still letterbox pixels).
            let cx = tensor[base + 0]
            let cy = tensor[base + 1]
            let w  = tensor[base + 2]
            let h  = tensor[base + 3]

            let x1lb = cx - w * 0.5
            let y1lb = cy - h * 0.5
            let x2lb = cx + w * 0.5
            let y2lb = cy + h * 0.5

            // Step 3: un-letterbox — subtract top-left pad, divide by scale.
            // For this model's top-left-anchored letterbox pad=(0,0), so the
            // operation reduces to a simple division by r.
            let x1 = (x1lb - letterboxPad.x) / letterboxScale
            let y1 = (y1lb - letterboxPad.y) / letterboxScale
            let x2 = (x2lb - letterboxPad.x) / letterboxScale
            let y2 = (y2lb - letterboxPad.y) / letterboxScale

            let rect = CGRect(
                x: CGFloat(x1),
                y: CGFloat(y1),
                width: CGFloat(x2 - x1),
                height: CGFloat(y2 - y1)
            )
            results.append(Detection(rect: rect, confidence: score))
        }
        return results
    }

    // MARK: - NMS

    /// Greedy, score-descending non-maximum suppression.
    ///
    /// Iterates through `detections` in descending confidence order.  For
    /// each candidate, compute its IoU against every already-kept box; if
    /// IoU > `iouThreshold` the candidate is suppressed (it overlaps a
    /// higher-scoring detection of the same object).  Mirrors the `nms`
    /// function in validate.py.
    ///
    /// - Parameters:
    ///   - detections: Candidates from `decode(tensor:...)`.
    ///   - iouThreshold: Overlap threshold above which the lower-score box is
    ///     suppressed.  Validate.py used 0.45.
    /// - Returns: Surviving detections, still in descending confidence order.
    static func nonMaxSuppression(
        _ detections: [Detection],
        iouThreshold: Float = 0.45
    ) -> [Detection] {
        guard !detections.isEmpty else { return [] }

        // Sort once, descending; the greedy loop then keeps only the first
        // occurrence of each distinct object region.
        let sorted = detections.sorted { $0.confidence > $1.confidence }

        var kept: [Detection] = []
        kept.reserveCapacity(sorted.count)

        for candidate in sorted {
            // Suppress the candidate if it overlaps any already-kept box.
            let suppressed = kept.contains { existing in
                iou(candidate.rect, existing.rect) > iouThreshold
            }
            if !suppressed {
                kept.append(candidate)
            }
        }
        return kept
    }

    // MARK: - IoU (internal helper)

    /// Intersection over Union for two axis-aligned rectangles.
    ///
    /// Returns 0 for non-overlapping boxes; 1 for identical boxes.
    /// A small epsilon (1e-6) in the denominator prevents division by zero
    /// for zero-area degenerate boxes.  Mirrors validate.py's `iou` function.
    static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        // Intersection rectangle.
        let ix1 = max(a.minX, b.minX)
        let iy1 = max(a.minY, b.minY)
        let ix2 = min(a.maxX, b.maxX)
        let iy2 = min(a.maxY, b.maxY)

        let interW = max(0, ix2 - ix1)
        let interH = max(0, iy2 - iy1)
        let inter = Float(interW * interH)

        let areaA = Float(a.width * a.height)
        let areaB = Float(b.width * b.height)
        let union = areaA + areaB - inter

        return inter / (union + 1e-6)
    }
}
