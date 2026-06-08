//
//  CameraBasisTests.swift
//  TailspotTests
//
//  Covers the 3D pinhole projection that replaces the separable tan
//  projection (spec 2026-06-08). Two layers are tested independently,
//  because they can fail independently:
//
//    (a) Basis builders — does (heading, gravity/scalar) → camera basis
//        faithfully model the real camera? Asserted against KNOWN poses,
//        not just builder-vs-builder agreement (which can be jointly
//        wrong the same way).
//    (b) Projection core — given a correct basis, is the pinhole formula
//        right? Several assertions are self-checking identities (new-x ==
//        old separable x at level; new-y == old-y / cos(dB)), so they
//        carry zero hand-arithmetic risk.
//
//  The existing GeoTests `screenPosition` cases stay untouched as the
//  common-case regression net.
//

import Testing
import CoreGraphics
import simd
@testable import Tailspot

@Suite("CameraBasis & pinhole projection")
struct CameraBasisTests {

    // MARK: helpers

    private static func rad(_ deg: Double) -> Double { deg * .pi / 180 }

    private static func approxEqual(
        _ a: SIMD3<Double>, _ b: SIMD3<Double>, tol: Double = 1e-9
    ) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol && abs(a.z - b.z) < tol
    }

    private static let screen = CGSize(width: 400, height: 800)
    private static let hfov: Double = 56
    private static let vfov: Double = 72

    // ENU cardinal directions for readability.
    private static let east  = SIMD3<Double>(1, 0, 0)
    private static let north = SIMD3<Double>(0, 1, 0)
    private static let up    = SIMD3<Double>(0, 0, 1)

    // MARK: (a) basis builder — absolute correctness vs known poses

    @Test func basisLevelNorthIsCardinal() {
        let b = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        #expect(Self.approxEqual(b.forward, Self.north))
        #expect(Self.approxEqual(b.right, Self.east))
        #expect(Self.approxEqual(b.up, Self.up))
    }

    @Test func basisLevelEastFacing() {
        // Facing east: forward=East, screen-right=South, up=Up.
        let b = Geo.cameraBasis(headingDeg: 90, cameraElevationDeg: 0, rollDeg: 0)
        #expect(Self.approxEqual(b.forward, Self.east, tol: 1e-9))
        #expect(Self.approxEqual(b.right, SIMD3(0, -1, 0), tol: 1e-9))
        #expect(Self.approxEqual(b.up, Self.up, tol: 1e-9))
    }

    @Test func basisPitchedUpTiltsForwardAndUp() {
        // Camera pitched 30° up, facing north. Forward tilts up; the
        // screen-up axis tilts back (toward the observer, -North); right
        // stays horizontal (East).
        let b = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 30, rollDeg: 0)
        #expect(Self.approxEqual(b.forward, SIMD3(0, cos(Self.rad(30)), sin(Self.rad(30))), tol: 1e-9))
        #expect(Self.approxEqual(b.up, SIMD3(0, -sin(Self.rad(30)), cos(Self.rad(30))), tol: 1e-9))
        #expect(Self.approxEqual(b.right, Self.east, tol: 1e-9))
    }

    @Test func basisIsOrthonormal() {
        // Sweep poses; forward/right/up must stay unit and mutually ⊥.
        for h in stride(from: 0.0, to: 360.0, by: 45.0) {
            for e in stride(from: -60.0, through: 60.0, by: 30.0) {
                for r in stride(from: -45.0, through: 45.0, by: 45.0) {
                    let b = Geo.cameraBasis(headingDeg: h, cameraElevationDeg: e, rollDeg: r)
                    #expect(abs(simd_length(b.forward) - 1) < 1e-9)
                    #expect(abs(simd_length(b.right) - 1) < 1e-9)
                    #expect(abs(simd_length(b.up) - 1) < 1e-9)
                    #expect(abs(simd_dot(b.forward, b.right)) < 1e-9)
                    #expect(abs(simd_dot(b.forward, b.up)) < 1e-9)
                    #expect(abs(simd_dot(b.right, b.up)) < 1e-9)
                }
            }
        }
    }

    @Test func basisRollRotatesRightAndUp() {
        // +90° roll about the bore-sight: screen-right swings to Up,
        // screen-up swings to West. Pins the roll sign/convention.
        let b = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 90)
        #expect(Self.approxEqual(b.forward, Self.north, tol: 1e-9))
        #expect(Self.approxEqual(b.right, Self.up, tol: 1e-9))
        #expect(Self.approxEqual(b.up, SIMD3(-1, 0, 0), tol: 1e-9))   // West
    }

    // MARK: (a) gravity-derived roll — physically grounded sign

    @Test func gravityUprightHasZeroRoll() {
        // Upright portrait, camera at horizon: gravity points toward the
        // device bottom (-y). No roll.
        let roll = Geo.rollDeg(gravityX: 0, gravityY: -1, gravityZ: 0)
        #expect(abs(roll) < 1e-9)
    }

    @Test func gravityRightSideDownIsPositiveRoll() {
        // Right edge of the device dips down → gravity gains a +x
        // component. Roll is +10°, and the camera-up axis tilts West
        // (up.x < 0) while camera-right tilts up (right.z > 0).
        let g = SIMD3(sin(Self.rad(10)), -cos(Self.rad(10)), 0.0)
        let roll = Geo.rollDeg(gravityX: g.x, gravityY: g.y, gravityZ: g.z)
        #expect(abs(roll - 10) < 1e-6)

        let b = Geo.cameraBasis(gravityX: g.x, gravityY: g.y, gravityZ: g.z, headingDeg: 0)
        #expect(b.up.x < 0)
        #expect(b.right.z > 0)
    }

    @Test func gravityElevationMatchesMotionManager() {
        // Camera elevation derived inside the gravity basis must match the
        // single source of truth in MotionManager.
        let g = SIMD3(0.2, -0.6, 0.5)
        let b = Geo.cameraBasis(gravityX: g.x, gravityY: g.y, gravityZ: g.z, headingDeg: 0)
        let camEl = MotionManager.cameraElevationDeg(gravityX: g.x, gravityY: g.y, gravityZ: g.z)
        // forward.z == sin(camEl)
        #expect(abs(b.forward.z - sin(Self.rad(camEl))) < 1e-9)
    }

    @Test func gravityAndScalarBuildersAgree() {
        // The gravity builder must equal the scalar builder fed gravity's
        // derived camEl + roll — guards against future divergence.
        let g = SIMD3(0.2, -0.6, 0.5)
        let heading = 120.0
        let camEl = MotionManager.cameraElevationDeg(gravityX: g.x, gravityY: g.y, gravityZ: g.z)
        let roll = Geo.rollDeg(gravityX: g.x, gravityY: g.y, gravityZ: g.z)

        let fromGravity = Geo.cameraBasis(gravityX: g.x, gravityY: g.y, gravityZ: g.z, headingDeg: heading)
        let fromScalar = Geo.cameraBasis(headingDeg: heading, cameraElevationDeg: camEl, rollDeg: roll)

        #expect(Self.approxEqual(fromGravity.forward, fromScalar.forward, tol: 1e-12))
        #expect(Self.approxEqual(fromGravity.right, fromScalar.right, tol: 1e-12))
        #expect(Self.approxEqual(fromGravity.up, fromScalar.up, tol: 1e-12))
    }

    // MARK: (b) projection core — invariants

    @Test func projectionCenteredTargetIsExactCenter() {
        let basis = Geo.cameraBasis(headingDeg: 90, cameraElevationDeg: 30, rollDeg: 0)
        let pos = Geo.screenPosition(
            targetBearingDeg: 90, targetElevationDeg: 30,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let p = try! #require(pos)
        #expect(abs(p.x - 200) < 1e-9)
        #expect(abs(p.y - 400) < 1e-9)
    }

    @Test func projectionBehindCameraIsNil() {
        // Target directly behind the camera (180° away) → nil.
        let basis = Geo.cameraBasis(headingDeg: 90, cameraElevationDeg: 0, rollDeg: 0)
        let pos = Geo.screenPosition(
            targetBearingDeg: 270, targetElevationDeg: 0,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(pos == nil)
    }

    @Test func projectionOffFrameIsNil() {
        let basis = Geo.cameraBasis(headingDeg: 90, cameraElevationDeg: 0, rollDeg: 0)
        let pos = Geo.screenPosition(
            targetBearingDeg: 180, targetElevationDeg: 0,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(pos == nil)
    }

    // MARK: (b) projection core — self-checking coupling identities

    @Test func levelCameraXMatchesSeparableModel() {
        // At a level camera the pinhole x is identical to the old
        // separable x for every bearing/elevation. Self-checking: no
        // hand-arithmetic, the expected value is the old formula.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        for dB in [-20.0, -10.0, 5.0, 15.0, 25.0] {
            for dE in [0.0, 10.0, 20.0] {
                let pos = Geo.screenPosition(
                    targetBearingDeg: dB, targetElevationDeg: dE,
                    basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
                )
                let p = try! #require(pos)
                let oldXRel = tan(Self.rad(dB)) / tan(Self.rad(Self.hfov / 2))
                let oldX = 200 + oldXRel * 200
                #expect(abs(p.x - oldX) < 1e-6)
            }
        }
    }

    @Test func levelCameraYGainsInverseCosineCoupling() {
        // At a level camera the pinhole y-offset equals the old separable
        // y-offset divided by cos(dB) — the exact coupling the old model
        // dropped. Self-checking identity.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        let dB = 20.0, dE = 20.0
        let pos = Geo.screenPosition(
            targetBearingDeg: dB, targetElevationDeg: dE,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let p = try! #require(pos)
        let newYRel = (400 - Double(p.y)) / 400
        let oldYRel = tan(Self.rad(dE)) / tan(Self.rad(Self.vfov / 2))
        #expect(abs(newYRel - oldYRel / cos(Self.rad(dB))) < 1e-9)
    }

    @Test func pitchedCameraCompressesHorizontalOffset() {
        // The headline fix: at camEl=40°, an off-axis target's horizontal
        // offset from center is markedly smaller than the separable model
        // claimed (the "~25% at 40°" error). Precise anchor + direction.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 40, rollDeg: 0)
        let pos = Geo.screenPosition(
            targetBearingDeg: 20, targetElevationDeg: 40,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let p = try! #require(pos)
        let oldX = 200 + (tan(Self.rad(20)) / tan(Self.rad(28))) * 200   // ≈ 336.9
        #expect(Double(p.x) < oldX - 20)          // fix direction
        #expect(abs(Double(p.x) - 302.16) < 0.2)  // hand-computed anchor
    }

    // MARK: (b) frustum boundary (frustum replaces the old angular box)

    @Test func frustumEdgeIsAtTanHalfFov() {
        // Level camera: xRel hits 1 at dB = hfov/2 (28°). Just inside is
        // on-screen; just outside is culled.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        let inside = Geo.screenPosition(
            targetBearingDeg: 27.9, targetElevationDeg: 0,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let outside = Geo.screenPosition(
            targetBearingDeg: 28.1, targetElevationDeg: 0,
            basis: basis, screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(inside != nil)
        #expect(outside == nil)
    }
}
