//
//  ClosestTargetTests.swift
//  TailspotTests
//
//  Pure-function tests for `closestTargetIcao24(in:at:...)`. The
//  helper drives both the center-driven lock (default `at: nil`) and
//  the tap-to-ID behavior (`at: tapPoint`); narrow FOV exercises the
//  zoom-aware projection path.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("closestTargetIcao24")
@MainActor
struct ClosestTargetTests {

    /// iPhone-16-portrait-ish dimensions, used throughout so the
    /// pixel-distance numbers in the assertions correspond to a
    /// realistic screen.
    private let screenSize = CGSize(width: 393, height: 852)

    /// Build a synthetic ObservedAircraft at the given bearing /
    /// elevation. Slant distance is well below the 30 km visibility
    /// cap so all fixtures pass `isLikelyVisibleToObserver`. The
    /// underlying Aircraft's lat/lon don't matter — projection reads
    /// bearing/elevation directly off the ObservedAircraft.
    private func obs(icao: String, bearingDeg: Double, elevationDeg: Double = 1.0) -> ObservedAircraft {
        let aircraft = Aircraft(
            icao24: icao, callsign: nil,
            originCountry: "X",
            longitude: 0, latitude: 0,
            altitudeMeters: 100,
            velocityMps: nil, trackDeg: nil,
            onGround: false,
            positionTimestamp: nil
        )
        return ObservedAircraft(
            aircraft: aircraft,
            bearingDeg: bearingDeg,
            elevationDeg: elevationDeg,
            groundDistanceMeters: 5_000,
            slantDistanceMeters: 5_100
        )
    }

    // MARK: - Center-driven (default)

    @Test func centerDefaultPicksPlaneNearestCenter() {
        // Phone aimed north (0°), camera horizontal. Plane A is
        // dead-ahead, B and C are 5° off to either side. Default
        // `at:` is nil → uses screen center.
        let icao = closestTargetIcao24(
            in: [
                obs(icao: "A", bearingDeg: 0),
                obs(icao: "B", bearingDeg: 5),
                obs(icao: "C", bearingDeg: -5),
            ],
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize
        )
        #expect(icao == "A")
    }

    @Test func centerReturnsNilWhenAllPlanesAreOutsideLockZone() {
        // All planes 20° off forward → projected ~140 px right of
        // center, well past the 80 px lock zone.
        let icao = closestTargetIcao24(
            in: [
                obs(icao: "A", bearingDeg: 20),
                obs(icao: "B", bearingDeg: 25),
            ],
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize
        )
        #expect(icao == nil)
    }

    // MARK: - Tap-driven

    @Test func tapAtPointPicksPlaneNearestThatPoint() {
        // Plane A is dead-ahead at center; Plane B is 5° right
        // (≈ 35 px). A tap right of center should pick B, not A.
        let approxBPosition = CGPoint(x: screenSize.width / 2 + 35, y: screenSize.height / 2)
        let icao = closestTargetIcao24(
            in: [
                obs(icao: "A", bearingDeg: 0),
                obs(icao: "B", bearingDeg: 5),
            ],
            at: approxBPosition,
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize
        )
        #expect(icao == "B")
    }

    @Test func tapInEmptySkyReturnsNil() {
        // Tap top-left corner — no plane is anywhere near.
        let icao = closestTargetIcao24(
            in: [obs(icao: "A", bearingDeg: 0)],
            at: CGPoint(x: 10, y: 10),
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize
        )
        #expect(icao == nil)
    }

    // MARK: - FOV / zoom

    @Test func narrowingFOVPushesOffAxisPlanesOutOfLockZone() {
        // At 1× FOV (56°/72°), a plane 5° off bearing projects ~35 px
        // off center — well inside the 80 px lock zone. At 4× zoom
        // (FOV/4 → 14°/18°), the same 5° projects ~140 px off —
        // outside the lock zone, so no target qualifies.
        let baseHfov: Double = 56
        let baseVfov: Double = 72
        let zoom: Double = 4

        let inZone = closestTargetIcao24(
            in: [obs(icao: "A", bearingDeg: 5)],
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize,
            hfovDeg: baseHfov,
            vfovDeg: baseVfov
        )
        #expect(inZone == "A")

        let outOfZone = closestTargetIcao24(
            in: [obs(icao: "A", bearingDeg: 5)],
            phoneHeadingDeg: 0,
            cameraElevationDeg: 0,
            screenSize: screenSize,
            hfovDeg: baseHfov / zoom,
            vfovDeg: baseVfov / zoom
        )
        #expect(outOfZone == nil)
    }
}
