//
//  OffscreenIndicatorTests.swift
//  TailspotTests
//
//  Edge-of-frame indicator math. The load-bearing property is the GAP-FREE
//  BOUNDARY: a plane is shown by a PlaneLabel (Geo.screenPosition != nil) XOR
//  by a chevron (OffscreenIndicators.indicator != nil), never neither and
//  never both. Several tests pin that explicitly by sweeping bearings across
//  the frame edge and asserting the two are exact complements.
//
//  Uses Swift Testing (@Test, #expect).
//

import Testing
import CoreGraphics
import simd
@testable import Tailspot

@Suite("OffscreenIndicator edge math")
struct OffscreenIndicatorTests {

    // A tall portrait screen, like the iPhone in the field.
    static let screen = CGSize(width: 400, height: 800)
    static let hfov: Double = 56
    static let vfov: Double = 72
    // Default usable rect: the whole screen (no reserved zones) unless a test
    // overrides it.
    static let fullRect = CGRect(x: 0, y: 0, width: 400, height: 800)

    /// Build a camera-frame vector for a target at (bearing, elevation) given a
    /// camera looking north, level, no roll — the simplest pose to reason about.
    /// Forward = +North, right = +East, up = +Up.
    static func frame(
        bearingDeg: Double,
        elevationDeg: Double,
        headingDeg: Double = 0,
        cameraElevationDeg: Double = 0,
        rollDeg: Double = 0
    ) -> Geo.CameraFrameVector {
        let basis = Geo.cameraBasis(
            headingDeg: headingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg
        )
        return Geo.cameraFrameVector(
            targetBearingDeg: bearingDeg,
            targetElevationDeg: elevationDeg,
            basis: basis
        )
    }

    // MARK: - On-screen planes produce NO chevron

    @Test func straightAheadIsOnScreenSoNoChevron() {
        // Plane dead ahead (bearing 0, elevation 0) with camera facing north,
        // level → projects to screen center → on-screen → no indicator.
        let f = Self.frame(bearingDeg: 0, elevationDeg: 0)
        let ind = OffscreenIndicators.indicator(
            icao24: "abc", label: "TEST", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(ind == nil)
    }

    // MARK: - Straight-ahead-but-right → right edge, rightward arrow

    @Test func planeToTheRightPinsToRightEdgePointingRight() {
        // hfov 56 → half-FOV 28°. A plane at bearing 40° (well past the right
        // edge) but elevation 0 → off the right side, vertically centered.
        let f = Self.frame(bearingDeg: 40, elevationDeg: 0)
        let ind = OffscreenIndicators.indicator(
            icao24: "abc", label: "GTI9648", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let ind2 = try! #require(ind)
        // Right edge: x at (or near) the right inset, y near vertical center.
        #expect(ind2.point.x > Self.screen.width - OffscreenIndicators.defaultEdgeInset - 1)
        #expect(abs(ind2.point.y - Self.screen.height / 2) < 60)
        // Arrow points right → angleDeg ≈ 0.
        #expect(abs(ind2.angleDeg) < 15)
    }

    @Test func planeToTheLeftPinsToLeftEdgePointingLeft() {
        let f = Self.frame(bearingDeg: -40, elevationDeg: 0)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        #expect(ind.point.x < OffscreenIndicators.defaultEdgeInset + 1)
        // Arrow points left → angleDeg ≈ 180 (or −180).
        #expect(abs(abs(ind.angleDeg) - 180) < 15)
    }

    // MARK: - Above-FOV → top edge, upward arrow

    @Test func planeAboveFovPinsToTopEdgePointingUp() {
        // vfov 72 → half-FOV 36°. Elevation 50° is above the top edge,
        // azimuth centered.
        let f = Self.frame(bearingDeg: 0, elevationDeg: 50)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        // Top edge: y near the top inset, x near horizontal center.
        #expect(ind.point.y < OffscreenIndicators.defaultEdgeInset + 1)
        #expect(abs(ind.point.x - Self.screen.width / 2) < 60)
        // Arrow points up → angleDeg ≈ −90 (screen y is down).
        #expect(abs(ind.angleDeg - (-90)) < 15)
    }

    @Test func planeBelowFovPinsToBottomEdgePointingDown() {
        let f = Self.frame(bearingDeg: 0, elevationDeg: -50)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        #expect(ind.point.y > Self.screen.height - OffscreenIndicators.defaultEdgeInset - 1)
        // Arrow points down → angleDeg ≈ +90.
        #expect(abs(ind.angleDeg - 90) < 15)
    }

    // MARK: - Behind the user → side edge, shorter-way direction

    @Test func planeDirectlyBehindAndToTheRightClampsToRightEdge() {
        // Camera faces north (heading 0). A plane at bearing 135° is behind
        // and to the RIGHT (east-ish). z < 0 (behind), x > 0 (right). The
        // chevron must clamp to a SIDE edge and point right — the shorter way
        // to turn to face it is clockwise (to the right).
        let f = Self.frame(bearingDeg: 135, elevationDeg: 0)
        #expect(f.z < 0)   // confirm it's actually behind the camera
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        // Right side edge.
        #expect(ind.point.x > Self.screen.width - OffscreenIndicators.defaultEdgeInset - 1)
        // Points rightward.
        #expect(abs(ind.angleDeg) < 60)
        // Axis angle > 90 (genuinely behind).
        #expect(ind.axisAngleDeg > 90)
    }

    @Test func planeDirectlyBehindAndToTheLeftClampsToLeftEdge() {
        // Bearing 225° (= -135°) is behind and to the LEFT. z < 0, x < 0.
        let f = Self.frame(bearingDeg: 225, elevationDeg: 0)
        #expect(f.z < 0)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        // Left side edge — the shorter way is counter-clockwise (to the left).
        #expect(ind.point.x < OffscreenIndicators.defaultEdgeInset + 1)
        #expect(abs(abs(ind.angleDeg) - 180) < 60)
        #expect(ind.axisAngleDeg > 90)
    }

    @Test func planeDirectlyBehindCenteredDefaultsToASideEdgeNotNil() {
        // Bearing 180°, elevation 0: directly behind, no lateral component in
        // the limit. x is ~0. Must still produce an indicator (not nil) and
        // clamp to a side edge — never collapse to an undefined direction.
        let f = Self.frame(bearingDeg: 180, elevationDeg: 0)
        #expect(f.z < 0)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        // Anchor is finite and inside the usable rect.
        #expect(ind.point.x.isFinite && ind.point.y.isFinite)
        #expect(Self.fullRect.contains(ind.point) || Self.onBoundary(ind.point, Self.fullRect))
        #expect(ind.axisAngleDeg > 170)   // nearly straight behind
    }

    static func onBoundary(_ p: CGPoint, _ r: CGRect) -> Bool {
        abs(p.x - r.minX) < 1 || abs(p.x - r.maxX) < 1 ||
        abs(p.y - r.minY) < 1 || abs(p.y - r.maxY) < 1
    }

    // MARK: - GAP-FREE BOUNDARY: on-screen XOR chevron, never neither/both

    @Test func everyPlaneIsEitherOnScreenOrHasAChevronNeverNeitherNeverBoth() {
        // Sweep a dense grid of bearings × elevations spanning on-screen,
        // just-off-screen, far-off, and behind. For each, the projection's
        // on-screen verdict and the chevron's presence must be exact
        // complements: screenPosition != nil  ⇔  indicator == nil.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        var checked = 0
        for bearing in stride(from: -180.0, through: 180.0, by: 2.5) {
            for elev in stride(from: -85.0, through: 85.0, by: 2.5) {
                let onScreen = Geo.screenPosition(
                    targetBearingDeg: bearing, targetElevationDeg: elev,
                    basis: basis, screenSize: Self.screen,
                    hfovDeg: Self.hfov, vfovDeg: Self.vfov
                ) != nil
                let f = Geo.cameraFrameVector(
                    targetBearingDeg: bearing, targetElevationDeg: elev, basis: basis
                )
                let ind = OffscreenIndicators.indicator(
                    icao24: "x", label: "x", frame: f,
                    screenSize: Self.screen, usableRect: Self.fullRect,
                    hfovDeg: Self.hfov, vfovDeg: Self.vfov
                )
                // Exact complement: exactly one of the two is present.
                #expect(onScreen == (ind == nil),
                        "bearing=\(bearing) elev=\(elev) onScreen=\(onScreen) hasChevron=\(ind != nil)")
                checked += 1
            }
        }
        #expect(checked > 1000)
    }

    @Test func boundaryHoldsAtZoomedFov() {
        // The whole feature exists because of high zoom. Re-run the complement
        // check at the 5× zoomed FOV (≈11.2° h, ≈14.4° v) — the GTI9648 case.
        let zoom = 5.0
        let hfov = Self.hfov / zoom
        let vfov = Self.vfov / zoom
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        for bearing in stride(from: -30.0, through: 30.0, by: 0.5) {
            for elev in stride(from: -30.0, through: 30.0, by: 0.5) {
                let onScreen = Geo.screenPosition(
                    targetBearingDeg: bearing, targetElevationDeg: elev,
                    basis: basis, screenSize: Self.screen,
                    hfovDeg: hfov, vfovDeg: vfov
                ) != nil
                let f = Geo.cameraFrameVector(
                    targetBearingDeg: bearing, targetElevationDeg: elev, basis: basis
                )
                let ind = OffscreenIndicators.indicator(
                    icao24: "x", label: "x", frame: f,
                    screenSize: Self.screen, usableRect: Self.fullRect,
                    hfovDeg: hfov, vfovDeg: vfov
                )
                #expect(onScreen == (ind == nil),
                        "zoom bearing=\(bearing) elev=\(elev)")
            }
        }
    }

    @Test func reproducesGTI9648OffByAFewDegrees() {
        // The actual field geometry: zoomed to 5×, the plane is ~14° off-axis
        // in bearing — outside the ≈11° FOV. Must NOT be on-screen, and MUST
        // get a chevron pointing right (it's to the right of bore-sight).
        let hfov = Self.hfov / 5.0
        let vfov = Self.vfov / 5.0
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        let onScreen = Geo.screenPosition(
            targetBearingDeg: 14, targetElevationDeg: 0,
            basis: basis, screenSize: Self.screen, hfovDeg: hfov, vfovDeg: vfov
        )
        #expect(onScreen == nil)   // this is the bug: it was invisible
        let f = Geo.cameraFrameVector(
            targetBearingDeg: 14, targetElevationDeg: 0, basis: basis
        )
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "a0f1bc", label: "GTI9648", frame: f,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: hfov, vfovDeg: vfov
        ))
        // Points to the right; the user pans right and the plane comes in.
        #expect(abs(ind.angleDeg) < 30)
        #expect(ind.point.x > Self.screen.width - OffscreenIndicators.defaultEdgeInset - 1)
    }

    // MARK: - Cap-at-3 prefers closest-to-axis

    @Test func capKeepsThreeClosestToAxis() {
        // Five off-screen planes at increasing azimuth offsets. Cap=3 keeps the
        // three SMALLEST offsets (closest to coming on-screen).
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        // bearings chosen all off-screen (> 28° half-FOV) but increasingly far.
        let planes: [(String, Double)] = [
            ("near1", 35), ("near2", 40), ("near3", 50), ("far1", 90), ("far2", 160),
        ]
        let candidates = planes.map { (icao, bearing) in
            (icao24: icao, label: icao,
             frame: Geo.cameraFrameVector(
                targetBearingDeg: bearing, targetElevationDeg: 0, basis: basis))
        }
        let result = OffscreenIndicators.indicators(
            candidates: candidates, screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(result.count == 3)
        let ids = Set(result.map(\.icao24))
        #expect(ids == ["near1", "near2", "near3"])
        #expect(!ids.contains("far1"))
        #expect(!ids.contains("far2"))
    }

    @Test func onScreenPlanesAreExcludedFromIndicatorSet() {
        // A mix: two on-screen (should be dropped) + two off-screen.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        let planes: [(String, Double)] = [
            ("onA", 0), ("onB", 10), ("offA", 40), ("offB", 50),
        ]
        let candidates = planes.map { (icao, bearing) in
            (icao24: icao, label: icao,
             frame: Geo.cameraFrameVector(
                targetBearingDeg: bearing, targetElevationDeg: 0, basis: basis))
        }
        let result = OffscreenIndicators.indicators(
            candidates: candidates, screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        let ids = Set(result.map(\.icao24))
        #expect(ids == ["offA", "offB"])
    }

    @Test func renderOrderIsStableByIdNotByAxisAngle() {
        // Two off-screen planes; whichever is closer to axis, the OUTPUT order
        // must be by icao24 so SwiftUI identity doesn't churn when they trade
        // ranks. "aaa" is FARTHER off-axis than "zzz" but must still sort first.
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        let candidates = [
            (icao24: "zzz", label: "zzz",
             frame: Geo.cameraFrameVector(targetBearingDeg: 35, targetElevationDeg: 0, basis: basis)),
            (icao24: "aaa", label: "aaa",
             frame: Geo.cameraFrameVector(targetBearingDeg: 60, targetElevationDeg: 0, basis: basis)),
        ]
        let result = OffscreenIndicators.indicators(
            candidates: candidates, screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(result.map(\.icao24) == ["aaa", "zzz"])
    }

    // MARK: - Usable-rect clamping respects reserved zones

    @Test func chevronStaysOutOfReservedTopAndBottomZones() {
        // Reserve 120pt top (sensor panel) and 140pt bottom (capture bar).
        let reserved = CGRect(x: 0, y: 120, width: 400, height: 800 - 120 - 140)
        // A plane off the RIGHT edge but also high — without clamping its y
        // could land in the reserved top zone. With the usable rect it can't.
        let f = Self.frame(bearingDeg: 45, elevationDeg: 30)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: reserved,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        // y must stay within the reserved rect (inset by edgeInset).
        #expect(ind.point.y >= reserved.minY + OffscreenIndicators.defaultEdgeInset - 1)
        #expect(ind.point.y <= reserved.maxY - OffscreenIndicators.defaultEdgeInset + 1)
    }

    @Test func chevronAnchorAlwaysInsideUsableRect() {
        // Property: across a sweep of off-screen directions, the anchor is
        // always within the inset usable rect (never past the literal edge,
        // never in a reserved zone).
        let reserved = CGRect(x: 0, y: 100, width: 400, height: 560)
        let inset = OffscreenIndicators.defaultEdgeInset
        let basis = Geo.cameraBasis(headingDeg: 0, cameraElevationDeg: 0, rollDeg: 0)
        for bearing in stride(from: -180.0, through: 180.0, by: 7.0) {
            for elev in stride(from: -80.0, through: 80.0, by: 7.0) {
                let f = Geo.cameraFrameVector(
                    targetBearingDeg: bearing, targetElevationDeg: elev, basis: basis)
                guard let ind = OffscreenIndicators.indicator(
                    icao24: "x", label: "x", frame: f,
                    screenSize: Self.screen, usableRect: reserved,
                    hfovDeg: Self.hfov, vfovDeg: Self.vfov
                ) else { continue }
                #expect(ind.point.x >= reserved.minX + inset - 0.5)
                #expect(ind.point.x <= reserved.maxX - inset + 0.5)
                #expect(ind.point.y >= reserved.minY + inset - 0.5)
                #expect(ind.point.y <= reserved.maxY - inset + 0.5)
            }
        }
    }

    @Test func degenerateUsableRectDoesNotProduceNaN() {
        // Reserved zones larger than the screen (pathological) must not NaN.
        let tiny = CGRect(x: 190, y: 390, width: 20, height: 20)
        let f = Self.frame(bearingDeg: 45, elevationDeg: 0)
        let ind = try! #require(OffscreenIndicators.indicator(
            icao24: "abc", label: "X", frame: f,
            screenSize: Self.screen, usableRect: tiny,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov
        ))
        #expect(ind.point.x.isFinite && ind.point.y.isFinite)
    }

    // MARK: - Roll is honored (chevron rotates with the device)

    @Test func rolledCameraRotatesTheEdgeDirection() {
        // With 90° roll, a plane that was off the right edge moves (in screen
        // space) toward what is now a different edge. We don't pin the exact
        // edge here (depends on sign convention); we assert the angle CHANGED
        // materially from the un-rolled case, proving roll feeds through.
        let fLevel = Self.frame(bearingDeg: 40, elevationDeg: 0, rollDeg: 0)
        let fRolled = Self.frame(bearingDeg: 40, elevationDeg: 0, rollDeg: 90)
        let level = try! #require(OffscreenIndicators.indicator(
            icao24: "a", label: "a", frame: fLevel,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov))
        let rolled = try! #require(OffscreenIndicators.indicator(
            icao24: "a", label: "a", frame: fRolled,
            screenSize: Self.screen, usableRect: Self.fullRect,
            hfovDeg: Self.hfov, vfovDeg: Self.vfov))
        #expect(abs(level.angleDeg - rolled.angleDeg) > 30)
    }
}
