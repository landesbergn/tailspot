//
//  MotionManagerTests.swift
//  TailspotTests
//
//  Covers the gravity-based camera-elevation derivation that replaced the
//  Euler `90 − pitch` formula (2026-06-02). The old formula inverted below
//  the horizon because CMAttitude.pitch gimbal-locks at the portrait hold;
//  these tests pin the anchor poses AND the property that actually broke:
//  continuity / monotonicity through the horizon.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("MotionManager camera elevation")
struct MotionManagerTests {

    private func el(_ x: Double, _ y: Double, _ z: Double) -> Double {
        MotionManager.cameraElevationDeg(gravityX: x, gravityY: y, gravityZ: z)
    }

    @Test func screenUpCameraPointsStraightDown() {
        // Device flat, screen up → gravity (0,0,-1). Rear camera faces the
        // ground → elevation -90°.
        #expect(abs(el(0, 0, -1) - (-90)) < 0.01)
    }

    @Test func screenDownCameraPointsStraightUp() {
        // Device flat, screen down → gravity (0,0,+1). Rear camera faces the
        // sky → elevation +90°.
        #expect(abs(el(0, 0, 1) - 90) < 0.01)
    }

    @Test func portraitUprightLooksAtHorizon() {
        // Upright portrait → gravity (0,-1,0). Rear camera at the horizon → 0°.
        #expect(abs(el(0, -1, 0)) < 0.01)
    }

    @Test func belowHorizonIsNegative() {
        // Camera tilted ~60° below the horizon → negative elevation. This is
        // exactly the case the Euler-pitch formula flipped to positive.
        #expect(el(0, -0.5, -0.866) < 0)
        #expect(abs(el(0, -0.5, -0.866) - (-60)) < 0.5)
    }

    @Test func continuousMonotonicThroughHorizon() {
        // The property the Euler formula violated: sweeping the camera from
        // straight-up to straight-down must yield a strictly DECREASING
        // elevation with no reflection at the portrait/horizon pose. Sweep
        // gravityZ from +1 → -1 keeping the vector unit-length in the Y-Z
        // plane.
        var last = 91.0
        var z = 1.0
        while z >= -1.0 {
            let y = -(max(0, 1 - z * z)).squareRoot()
            let e = el(0, y, z)
            #expect(e < last)   // strictly decreasing — no gimbal reflection
            last = e
            z -= 0.05
        }
    }

    @Test func rollInvariantForElevation() {
        // Camera at the horizon but the phone rolled to landscape: gravity
        // moves into X, but its Z component (hence elevation) stays ~0.
        #expect(abs(el(-1, 0, 0)) < 0.01)   // rolled 90°, still horizon
        #expect(abs(el(-0.707, -0.707, 0)) < 0.01)  // rolled 45°, still horizon
    }

    @Test func magnitudeNormalized() {
        // Non-unit gravity (transient) still yields a sane angle.
        #expect(abs(el(0, 0, -2) - (-90)) < 0.01)
    }

    @Test func zeroVectorDefaultsToHorizon() {
        #expect(el(0, 0, 0) == 0)
    }
}
