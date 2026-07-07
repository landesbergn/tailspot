//
//  CatchPhotoSnapperTests.swift
//  TailspotTests
//
//  Pins the pure snap-decision logic: the gates and the nearest-wins
//  choice rule, whose constants were calibrated against the 2026-07-05
//  offline eval of the real catch-photo corpus. The CoreML search itself
//  is exercised on-device; these tests guarantee the DECISION layer
//  can't regress silently (e.g. someone "fixing" nearest-wins back to
//  highest-confidence, which re-opens the airport wrong-plane snap).
//

import CoreGraphics
import Testing
@testable import Tailspot

@Suite("CatchPhotoSnapper gates")
struct CatchPhotoSnapperGateTests {

    private func det(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 40, h: CGFloat = 20,
                     conf: Float = 0.8) -> Detection {
        Detection(rect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h),
                  confidence: conf)
    }

    @Test func confidenceFloorRejects() {
        #expect(!CatchPhotoSnapper.passesGates(det(0, 0, conf: 0.24)))
        #expect(CatchPhotoSnapper.passesGates(det(0, 0, conf: 0.25)))
    }

    @Test func giantBoxRejected() {
        // The eval's false-positive class: boxes spanning most of the crop
        // (736x668 and 1072x926 at ~0.4 conf on real photos).
        #expect(!CatchPhotoSnapper.passesGates(det(0, 0, w: 736, h: 668, conf: 0.9)))
        // A real distant plane (80x80 was the largest verified true hit).
        #expect(CatchPhotoSnapper.passesGates(det(0, 0, w: 80, h: 80)))
    }

    @Test func sizeGateUsesLongerSide() {
        // Wide-but-flat boxes (a 300x40 fuselage smear) still exceed the cap.
        let cap = CatchPhotoSnapper.maxDetectionSide
        #expect(!CatchPhotoSnapper.passesGates(det(0, 0, w: cap + 1, h: 10)))
        #expect(CatchPhotoSnapper.passesGates(det(0, 0, w: cap, h: 10)))
    }
}

@Suite("CatchPhotoSnapper choice")
struct CatchPhotoSnapperChoiceTests {

    private func det(_ x: CGFloat, _ y: CGFloat, conf: Float = 0.8) -> Detection {
        Detection(rect: CGRect(x: x - 20, y: y - 10, width: 40, height: 20),
                  confidence: conf)
    }

    @Test func nearestWinsOverMostConfident() {
        // Airport scenario: a high-confidence parked plane further away
        // must lose to the nearer (dimmer) airborne target.
        let near = det(100, 100, conf: 0.5)
        let far = det(600, 100, conf: 0.95)
        let picked = CatchPhotoSnapper.choose(from: [far, near], predicted: CGPoint(x: 80, y: 100))
        #expect(picked == near)
    }

    @Test func outsideSnapRadiusIgnored() {
        let d = det(0, CatchPhotoSnapper.maxSnapRadiusPixels + 50)
        #expect(CatchPhotoSnapper.choose(from: [d], predicted: .zero) == nil)
    }

    @Test func emptyIsNil() {
        #expect(CatchPhotoSnapper.choose(from: [], predicted: .zero) == nil)
    }

    @Test func searchCentersCoverRingWithOverlap() {
        let p = CGPoint(x: 500, y: 900)
        let centers = CatchPhotoSnapper.searchCenters(around: p)
        #expect(centers.count == 9)
        #expect(centers.first == p)  // center tile first → early-exit favors least correction
        // 640 px tiles at ±480 px offsets: adjacent tiles overlap 160 px,
        // so no seam gap inside the ±800 px search area.
        let side = CGFloat(AirplaneDetector.inputSide)
        #expect(CatchPhotoSnapper.ringOffset < side)
        // Every ring center is exactly one stride away on each axis.
        for c in centers.dropFirst() {
            let dx = abs(c.x - p.x), dy = abs(c.y - p.y)
            #expect(dx == 0 || dx == CatchPhotoSnapper.ringOffset)
            #expect(dy == 0 || dy == CatchPhotoSnapper.ringOffset)
        }
    }
}
