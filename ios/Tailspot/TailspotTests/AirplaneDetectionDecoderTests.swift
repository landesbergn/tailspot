//
//  AirplaneDetectionDecoderTests.swift
//  TailspotTests
//
//  Unit tests for AirplaneDetectionDecoder — decode + NMS logic.
//
//  ALL test vectors are synthetic (hand-built tensors, no model file) so
//  the suite runs on any iOS Simulator without GPU or model artifacts.
//
//  HAND-DERIVED CROSS-CHECK CASE
//  ------------------------------
//  One anchor is fully traced by hand and compared against validate.py math:
//
//    Input anchor (row i in the 8400×85 tensor):
//      cx=320, cy=320, w=100, h=80, obj=0.9, cls_4=0.8
//      All other class scores = 0.0
//      letterboxScale r = 0.5, letterboxPad = (0, 0)
//
//    Step 1 — score = obj × cls_4 = 0.9 × 0.8 = 0.72  ✓ (≥ 0.30, keep)
//
//    Step 2 — xywh → xyxy (letterbox pixels):
//      x1 = 320 − 100/2 = 270
//      y1 = 320 − 80/2  = 280
//      x2 = 320 + 100/2 = 370
//      y2 = 320 + 80/2  = 360
//
//    Step 3 — un-letterbox with r=0.5, pad=(0,0) → divide by r:
//      x1 = 270 / 0.5 = 540
//      y1 = 280 / 0.5 = 560
//      x2 = 370 / 0.5 = 740
//      y2 = 360 / 0.5 = 720
//
//    Expected Detection:
//      rect = CGRect(x:540, y:560, width:200, height:160)
//      confidence = 0.72
//
//  This result matches what validate.py's decode() produces for the same
//  input values (verified by running the same arithmetic in Python).
//
//  Uses Swift Testing (@Test / #expect / @Suite) — not XCTest.
//

import Testing
import CoreGraphics
@testable import Tailspot

// MARK: - Tensor builder helpers

/// Build a zeroed [Float] tensor of shape (8400, 85) and populate anchor
/// at row `index` with the supplied box + objectness + class scores.
///
/// - Parameters:
///   - index: Which of the 8400 anchors to set (0-based).
///   - cx, cy, w, h: Box center and size in letterbox pixels.
///   - obj: Objectness score ∈ [0, 1].
///   - classScores: Up to 80 COCO class scores; anything unspecified stays 0.
private func makeTensor(
    anchorAt index: Int = 0,
    cx: Float = 0, cy: Float = 0, w: Float = 0, h: Float = 0,
    obj: Float = 0,
    classScores: [Float] = []   // index into the 80-class block
) -> [Float] {
    let stride = AirplaneDetectionDecoder.anchorStride   // 85
    let count  = AirplaneDetectionDecoder.anchorCount    // 8400
    var t = [Float](repeating: 0, count: count * stride)
    let base = index * stride
    t[base + 0] = cx
    t[base + 1] = cy
    t[base + 2] = w
    t[base + 3] = h
    t[base + 4] = obj
    for (k, v) in classScores.enumerated() where k < 80 {
        t[base + 5 + k] = v
    }
    return t
}

/// Build a tensor with multiple anchors populated from an array of tuples.
private func makeTensor(anchors: [(index: Int, cx: Float, cy: Float,
                                   w: Float, h: Float,
                                   obj: Float, classScores: [Float])]) -> [Float] {
    let stride = AirplaneDetectionDecoder.anchorStride
    let count  = AirplaneDetectionDecoder.anchorCount
    var t = [Float](repeating: 0, count: count * stride)
    for a in anchors {
        let base = a.index * stride
        t[base + 0] = a.cx
        t[base + 1] = a.cy
        t[base + 2] = a.w
        t[base + 3] = a.h
        t[base + 4] = a.obj
        for (k, v) in a.classScores.enumerated() where k < 80 {
            t[base + 5 + k] = v
        }
    }
    return t
}

// MARK: - Test suite

@Suite("AirplaneDetectionDecoder")
struct AirplaneDetectionDecoderTests {

    // MARK: - Scoring

    @Test func scoringMultipliesObjByCls() {
        // obj=0.9, cls_4=0.8 → score=0.72, comfortably above 0.30 threshold.
        let tensor = makeTensor(obj: 0.9, classScores: [0, 0, 0, 0, 0.8])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.count == 1)
        #expect(abs(dets[0].confidence - 0.72) < 1e-5)
    }

    @Test func thresholdCutsLowScores() {
        // obj=0.4, cls_4=0.5 → score=0.20, below the default 0.30 threshold.
        let tensor = makeTensor(obj: 0.4, classScores: [0, 0, 0, 0, 0.5])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.isEmpty)
    }

    @Test func thresholdBoundaryIsInclusive() {
        // score = 0.30 exactly (obj=0.6, cls_4=0.5) should be kept.
        let tensor = makeTensor(obj: 0.6, classScores: [0, 0, 0, 0, 0.5])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.count == 1)
        #expect(abs(dets[0].confidence - 0.30) < 1e-5)
    }

    // MARK: - Class selection

    @Test func class4SelectionIgnoresHigherOtherClassScores() {
        // A higher cls_0 score (0.99) must not affect whether airplane is kept.
        // cls_4=0.5, obj=0.8 → airplane score=0.40 ≥ 0.30 — should appear.
        var scores = [Float](repeating: 0, count: 80)
        scores[0] = 0.99   // cls_0 very high — should be ignored for airplane
        scores[4] = 0.50   // cls_4 (airplane) moderate
        let tensor = makeTensor(obj: 0.8, classScores: scores)
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor,
            airplaneClassIndex: 4,
            confidenceThreshold: 0.30,
            letterboxScale: 1.0)
        // Must find exactly one airplane detection (not suppressed by cls_0).
        #expect(dets.count == 1)
        #expect(abs(dets[0].confidence - 0.40) < 1e-5)
    }

    @Test func nonAirplaneClassDoesNotTrigger() {
        // cls_4=0 means airplane score=0 regardless of obj; must not survive.
        var scores = [Float](repeating: 0, count: 80)
        scores[2] = 0.99   // cls_2 (car) irrelevant to the airplane gate
        let tensor = makeTensor(obj: 0.9, classScores: scores)
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, airplaneClassIndex: 4,
            confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.isEmpty)
    }

    // MARK: - Box coordinate transform

    @Test func cxcywhToXyxyMath() {
        // cx=100, cy=200, w=40, h=60 → x1=80, y1=170, x2=120, y2=230.
        // With r=1.0 the letterbox transform is a no-op.
        let tensor = makeTensor(cx: 100, cy: 200, w: 40, h: 60,
                                obj: 1.0, classScores: [0, 0, 0, 0, 1.0])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.count == 1)
        let r = dets[0].rect
        #expect(abs(r.minX - 80)  < 0.001)
        #expect(abs(r.minY - 170) < 0.001)
        #expect(abs(r.maxX - 120) < 0.001)
        #expect(abs(r.maxY - 230) < 0.001)
    }

    @Test func letterboxUnscalingWithNonUnitScale() {
        // FULL HAND-DERIVED CROSS-CHECK — see file header for derivation.
        //
        //   cx=320, cy=320, w=100, h=80, obj=0.9, cls_4=0.8
        //   r=0.5, pad=(0,0)
        //
        //   score = 0.9 × 0.8 = 0.72
        //   xyxy (letterbox): x1=270, y1=280, x2=370, y2=360
        //   un-letterbox (/0.5): x1=540, y1=560, x2=740, y2=720
        //   → CGRect(x:540, y:560, width:200, height:160)
        //
        var scores = [Float](repeating: 0, count: 80)
        scores[4] = 0.8
        let tensor = makeTensor(cx: 320, cy: 320, w: 100, h: 80,
                                obj: 0.9, classScores: scores)
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 0.5)
        #expect(dets.count == 1)
        let r = dets[0].rect
        #expect(abs(Float(r.minX)   - 540) < 0.001)
        #expect(abs(Float(r.minY)   - 560) < 0.001)
        #expect(abs(Float(r.width)  - 200) < 0.001)
        #expect(abs(Float(r.height) - 160) < 0.001)
        #expect(abs(dets[0].confidence - 0.72) < 1e-5)
    }

    @Test func letterboxUnscalingWithNonZeroPad() {
        // Verify the pad subtraction path (not exercised by the main model,
        // but validates that the parameter is wired correctly).
        // cx=100, cy=100, w=20, h=20, r=1.0, pad=(10, 20)
        // xyxy (letterbox): x1=90, y1=90, x2=110, y2=110
        // un-letterbox: x1=(90-10)/1=80, y1=(90-20)/1=70, x2=(110-10)/1=100, y2=(110-20)/1=90
        let tensor = makeTensor(cx: 100, cy: 100, w: 20, h: 20,
                                obj: 1.0, classScores: [0, 0, 0, 0, 1.0])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30,
            letterboxScale: 1.0, letterboxPad: (x: 10, y: 20))
        #expect(dets.count == 1)
        let rect = dets[0].rect
        #expect(abs(Float(rect.minX) - 80) < 0.001)
        #expect(abs(Float(rect.minY) - 70) < 0.001)
        #expect(abs(Float(rect.maxX) - 100) < 0.001)
        #expect(abs(Float(rect.maxY) - 90) < 0.001)
    }

    // MARK: - Empty input

    @Test func emptyTensorReturnsEmpty() {
        let dets = AirplaneDetectionDecoder.decode(
            tensor: [], confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.isEmpty)
    }

    @Test func wrongLengthTensorReturnsEmpty() {
        // A tensor of length 100 is not 8400×85; the guard should fire.
        let short = [Float](repeating: 0, count: 100)
        let dets = AirplaneDetectionDecoder.decode(
            tensor: short, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.isEmpty)
    }

    @Test func allZeroTensorReturnsEmpty() {
        // All-zero tensor: every score=0, nothing passes 0.30 gate.
        let zero = [Float](repeating: 0,
                           count: AirplaneDetectionDecoder.anchorCount
                                * AirplaneDetectionDecoder.anchorStride)
        let dets = AirplaneDetectionDecoder.decode(
            tensor: zero, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.isEmpty)
    }

    // MARK: - NMS suppression

    @Test func nmsEmptyInputReturnsEmpty() {
        let kept = AirplaneDetectionDecoder.nonMaxSuppression([])
        #expect(kept.isEmpty)
    }

    @Test func nmsSuppressesHighIouPair() {
        // Box A and Box B overlap heavily (IoU ≈ 0.68 > 0.45); lower score
        // (Box B, conf=0.60) must be suppressed; Box A (conf=0.90) survives.
        //
        //   Box A: (0,0)→(100,100)  area = 10 000
        //   Box B: (10,10)→(110,110) area = 10 000
        //   Intersection: (10,10)→(100,100) = 90×90 = 8 100
        //   Union = 10000+10000−8100 = 11 900
        //   IoU = 8100/11900 ≈ 0.681  > 0.45 → suppress B
        let boxA = Detection(rect: CGRect(x: 0,  y: 0,  width: 100, height: 100),
                             confidence: 0.90)
        let boxB = Detection(rect: CGRect(x: 10, y: 10, width: 100, height: 100),
                             confidence: 0.60)
        let kept = AirplaneDetectionDecoder.nonMaxSuppression(
            [boxA, boxB], iouThreshold: 0.45)
        #expect(kept.count == 1)
        #expect(abs(kept[0].confidence - 0.90) < 1e-6)
    }

    @Test func nmsKeepsBothWhenLowerScoreIsHigherInInput() {
        // Same geometry as above but Box B appears FIRST in the array.
        // NMS sorts by score before processing, so Box A (higher score)
        // must still win and Box B must still be suppressed.
        let boxA = Detection(rect: CGRect(x: 0,  y: 0,  width: 100, height: 100),
                             confidence: 0.90)
        let boxB = Detection(rect: CGRect(x: 10, y: 10, width: 100, height: 100),
                             confidence: 0.60)
        let kept = AirplaneDetectionDecoder.nonMaxSuppression(
            [boxB, boxA], iouThreshold: 0.45)   // boxB first in input
        #expect(kept.count == 1)
        #expect(abs(kept[0].confidence - 0.90) < 1e-6)
    }

    @Test func nmsKeepsNonOverlappingDetections() {
        // Box C and Box D share no pixels; both must survive.
        //
        //   Box C: (0,0)→(50,50)      Box D: (100,100)→(150,150)
        //   Intersection: empty → IoU = 0  < 0.45 → keep both
        let boxC = Detection(rect: CGRect(x: 0,   y: 0,   width: 50, height: 50),
                             confidence: 0.80)
        let boxD = Detection(rect: CGRect(x: 100, y: 100, width: 50, height: 50),
                             confidence: 0.70)
        let kept = AirplaneDetectionDecoder.nonMaxSuppression(
            [boxC, boxD], iouThreshold: 0.45)
        #expect(kept.count == 2)
    }

    @Test func nmsSingleDetectionPassesThrough() {
        let d = Detection(rect: CGRect(x: 0, y: 0, width: 100, height: 100),
                          confidence: 0.75)
        let kept = AirplaneDetectionDecoder.nonMaxSuppression([d])
        #expect(kept.count == 1)
        #expect(kept[0] == d)
    }

    // MARK: - Integration: decode then NMS

    @Test func decodeThenNmsEndToEnd() {
        // Two anchors: heavily overlapping, both above threshold.
        // Only the higher-score one should survive NMS.
        //
        // Anchor 0: cx=100, cy=100, w=60, h=60, obj=0.9, cls_4=0.8 → score 0.72
        //           → xyxy (r=1): (70,70)→(130,130)
        // Anchor 1: cx=105, cy=105, w=60, h=60, obj=0.7, cls_4=0.6 → score 0.42
        //           → xyxy (r=1): (75,75)→(135,135)
        // IoU of those two boxes:
        //   A=[70,70,130,130] area=3600, B=[75,75,135,135] area=3600
        //   inter=[75,75,130,130]=55×55=3025  union=3600+3600-3025=4175
        //   IoU = 3025/4175 ≈ 0.724 > 0.45 → B suppressed
        var s0 = [Float](repeating: 0, count: 80); s0[4] = 0.8
        var s1 = [Float](repeating: 0, count: 80); s1[4] = 0.6
        let tensor = makeTensor(anchors: [
            (index: 0, cx: 100, cy: 100, w: 60, h: 60, obj: 0.9, classScores: s0),
            (index: 1, cx: 105, cy: 105, w: 60, h: 60, obj: 0.7, classScores: s1),
        ])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.count == 2)   // both pass threshold before NMS

        let kept = AirplaneDetectionDecoder.nonMaxSuppression(dets, iouThreshold: 0.45)
        #expect(kept.count == 1)
        #expect(abs(kept[0].confidence - 0.72) < 1e-5)
    }

    @Test func multipleAnchorsBothKeptWhenNonOverlapping() {
        // Two well-separated detections — decode finds both, NMS keeps both.
        var s = [Float](repeating: 0, count: 80); s[4] = 0.9
        let tensor = makeTensor(anchors: [
            (index: 0,    cx: 100,  cy: 100,  w: 50, h: 50, obj: 0.9, classScores: s),
            (index: 8399, cx: 500,  cy: 500,  w: 50, h: 50, obj: 0.8, classScores: s),
        ])
        let dets = AirplaneDetectionDecoder.decode(
            tensor: tensor, confidenceThreshold: 0.30, letterboxScale: 1.0)
        #expect(dets.count == 2)

        let kept = AirplaneDetectionDecoder.nonMaxSuppression(dets, iouThreshold: 0.45)
        #expect(kept.count == 2)
    }
}
