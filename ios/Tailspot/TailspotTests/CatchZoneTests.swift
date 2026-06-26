//
//  CatchZoneTests.swift
//  TailspotTests
//
//  Lever 1 — aim, don't spray. The capture button derives its targets from a
//  TIGHT central zone via `icaosInZone`, not the whole frame. These pin the
//  zone helper's tightening behaviour: a plane off to the side that the old
//  wide (180 px) zone would have swept up is excluded by the 100 px catch
//  zone, so you have to point at a plane to catch it.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Catch zone (Lever 1)")
@MainActor
struct CatchZoneTests {

    /// iPhone-portrait dimensions so the pixel numbers correspond to a real
    /// screen (mirrors ClosestTargetTests).
    private let screenSize = CGSize(width: 393, height: 852)

    private func obs(icao: String, bearingDeg: Double, elevationDeg: Double = 5.0) -> ObservedAircraft {
        let aircraft = Aircraft(
            icao24: icao, callsign: nil, originCountry: "X",
            longitude: 0, latitude: 0, altitudeMeters: 100,
            velocityMps: nil, trackDeg: nil, onGround: false,
            positionTimestamp: nil
        )
        return ObservedAircraft(
            aircraft: aircraft,
            bearingDeg: bearingDeg, elevationDeg: elevationDeg,
            groundDistanceMeters: 5_000, slantDistanceMeters: 5_100
        )
    }

    @Test func tightZoneExcludesOffCenterPlaneTheWideZoneCatches() {
        // Phone aimed north, level. CENTER is dead-ahead; OFF is 20° to the
        // side → projects ~134 px off center at 1× FOV. The legacy 180 px
        // multi-zone sweeps OFF up; the 100 px catch zone does not.
        let planes = [obs(icao: "CENTER", bearingDeg: 0), obs(icao: "OFF", bearingDeg: 20)]

        let wide = icaosInZone(
            in: planes, phoneHeadingDeg: 0, cameraElevationDeg: 0,
            screenSize: screenSize, zoneRadius: 180
        )
        let tight = icaosInZone(
            in: planes, phoneHeadingDeg: 0, cameraElevationDeg: 0,
            screenSize: screenSize, zoneRadius: 100
        )

        #expect(wide.contains("OFF"))                  // old behaviour: swept up
        #expect(tight.contains("OFF") == false)        // new behaviour: must aim
        #expect(tight == ["CENTER"])
    }

    @Test func centeredPlaneStaysCatchable() {
        // The honest case — a plane you're pointing at — is unaffected.
        let tight = icaosInZone(
            in: [obs(icao: "A", bearingDeg: 0)],
            phoneHeadingDeg: 0, cameraElevationDeg: 0,
            screenSize: screenSize, zoneRadius: 100
        )
        #expect(tight == ["A"])
    }

    @Test func tightClusterOfTwoNearCenterIsStillMulti() {
        // Two planes both near the reticle (±5° ≈ 35 px) stay catchable
        // together — a real formation / approach pair isn't broken by L1.
        let tight = icaosInZone(
            in: [obs(icao: "L", bearingDeg: -5), obs(icao: "R", bearingDeg: 5)],
            phoneHeadingDeg: 0, cameraElevationDeg: 0,
            screenSize: screenSize, zoneRadius: 100
        )
        #expect(Set(tight) == ["L", "R"])
    }
}
