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
import UIKit
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

    @Test func explicitRadiusOverridesReferenceRadius() {
        // A detection past the 700 px reference radius must be reachable
        // when the caller passes a scaled radius (the fine pass at 12 MP).
        let d = det(0, 1500)
        #expect(CatchPhotoSnapper.choose(from: [d], predicted: .zero) == nil)
        #expect(CatchPhotoSnapper.choose(from: [d], predicted: .zero,
                                         snapRadius: 1960) == d)
    }
}

@Suite("CatchPhotoSnapper resolution adaptation")
struct CatchPhotoSnapperResolutionTests {

    @Test func referenceAndLegacyPhotosKeepScaleOne() {
        // The eval corpus width and anything narrower stay at 1×: shipped
        // 1080-px behavior is exactly preserved.
        #expect(CatchPhotoSnapper.resolutionScale(photoWidth: 1080) == 1)
        #expect(CatchPhotoSnapper.resolutionScale(photoWidth: 640) == 1)
    }

    @Test func fullResPhotosScaleByWidthRatio() {
        let s = CatchPhotoSnapper.resolutionScale(photoWidth: 3024)
        #expect(abs(s - 2.8) < 0.001)
        // The scaled snap radius stays proportionate to the frame: 700 px
        // of a 1080 frame ≈ 1960 px of a 3024 frame.
        #expect(abs(s * CatchPhotoSnapper.maxSnapRadiusPixels - 1960) < 1)
    }

    @Test func legacyWidthsSkipTheCoarsePass() {
        // Coarse pass exists to restore angular coverage lost at native
        // resolution; at ≤1.3× there is nothing to restore.
        #expect(CatchPhotoSnapper.resolutionScale(photoWidth: 1080)
                < CatchPhotoSnapper.coarsePassMinScale)
        #expect(CatchPhotoSnapper.resolutionScale(photoWidth: 3024)
                >= CatchPhotoSnapper.coarsePassMinScale)
    }

    @Test func uprightNormalizesEXIFRotatedImages() {
        // Simulate a sensor-landscape capture (240×120) tagged .right —
        // the shape AVFoundation actually hands us. The upright image
        // must come out portrait (120×240): searching the raw cgImage
        // instead would rotate the whole coordinate space 90°.
        let landscape = solidCGImage(width: 240, height: 120)
        let tagged = UIImage(cgImage: landscape, scale: 1, orientation: .right)
        let upright = CatchPhotoSnapper.uprightCGImage(from: tagged)
        #expect(upright?.width == 120)
        #expect(upright?.height == 240)
    }

    @Test func uprightPassesThroughAlreadyUprightImages() {
        // Legacy composed photos are orientation .up — no re-render.
        let img = solidCGImage(width: 120, height: 240)
        let upright = CatchPhotoSnapper.uprightCGImage(from: UIImage(cgImage: img))
        #expect(upright?.width == 120)
        #expect(upright?.height == 240)
    }

    @Test func downscalePreservesAspectAndSkipsNarrowImages() {
        let big = solidCGImage(width: 3024, height: 4032)
        let small = CatchPhotoSnapper.downscaled(big, toWidth: 1080)
        #expect(small?.width == 1080)
        #expect(small?.height == 1440)
        // Already at/below the target width: returned untouched.
        let narrow = solidCGImage(width: 1080, height: 1920)
        #expect(CatchPhotoSnapper.downscaled(narrow, toWidth: 1080)?.width == 1080)
    }

    private func solidCGImage(width: Int, height: Int) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
}
