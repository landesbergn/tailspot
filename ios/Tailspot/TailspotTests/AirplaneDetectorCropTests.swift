//
//  AirplaneDetectorCropTests.swift
//  TailspotTests
//
//  The crop-rect clamping rules (AirplaneDetector.cropRect) and the
//  screen↔photo round-trip on AspectFillTransform — the two pure-math
//  pieces of the visual-confirmation camera path.
//

import CoreGraphics
import Foundation
import Testing
@testable import Tailspot

@Suite("AirplaneDetector crop rect")
struct AirplaneDetectorCropTests {

    private let buffer = CGSize(width: 1080, height: 1920)

    @Test func centeredCropStaysCentered() {
        let r = AirplaneDetector.cropRect(center: CGPoint(x: 540, y: 960),
                                          side: 640, in: buffer)
        #expect(r == CGRect(x: 220, y: 640, width: 640, height: 640))
    }

    @Test func edgeCropShiftsInsteadOfShrinking() {
        // Prediction near the top-left corner: the crop slides to stay
        // inside the buffer but keeps its full 640px size (shrinking
        // would silently change the detector's effective resolution).
        let r = AirplaneDetector.cropRect(center: CGPoint(x: 50, y: 30),
                                          side: 640, in: buffer)
        #expect(r == CGRect(x: 0, y: 0, width: 640, height: 640))
    }

    @Test func bottomRightCropClampsToBufferEdge() {
        let r = AirplaneDetector.cropRect(center: CGPoint(x: 1070, y: 1900),
                                          side: 640, in: buffer)
        #expect(r.maxX == 1080)
        #expect(r.maxY == 1920)
        #expect(r.width == 640 && r.height == 640)
    }

    @Test func tinyBufferShrinksTheCrop() {
        // Buffer smaller than the crop side (shouldn't happen with real
        // camera formats, but the math must not produce negative origins).
        let r = AirplaneDetector.cropRect(center: CGPoint(x: 100, y: 100),
                                          side: 640, in: CGSize(width: 480, height: 360))
        #expect(r.width == 360 && r.height == 360)
        #expect(r.minX >= 0 && r.minY >= 0)
    }

    @Test func aspectFillRoundTripIsIdentity() {
        // screen → photo → screen must return the original point; the
        // detection pipeline relies on this pair being exact inverses.
        let t = AspectFillTransform(screenSize: CGSize(width: 390, height: 844),
                                    photoSize: CGSize(width: 1080, height: 1920))
        let original = CGPoint(x: 123.4, y: 567.8)
        let roundTrip = t.screenPoint(fromPhotoPoint: t.photoPoint(fromScreenPoint: original))
        #expect(abs(roundTrip.x - original.x) < 1e-9)
        #expect(abs(roundTrip.y - original.y) < 1e-9)
    }
}
