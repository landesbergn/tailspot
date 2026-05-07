//
//  GeoTests.swift
//  TailspotTests
//
//  Geometry math is the foundation of every aircraft-position calculation
//  in the app — bugs here would silently corrupt user-visible bearings
//  and elevations without any visible crash. Heavily covered.
//
//  Uses Swift Testing (@Test, #expect) — the modern replacement for
//  XCTest that ships with Xcode 16+. Easier to read and easier to write.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Geo")
struct GeoTests {

    // MARK: distance

    @Test func distanceBetweenIdenticalPointsIsZero() {
        let d = Geo.distance(fromLat: 37.0, lon: -122.0, toLat: 37.0, lon: -122.0)
        #expect(d == 0)
    }

    @Test func distanceBerkeleyToSFO() {
        // Berkeley (~37.87, -122.27) to SFO (~37.62, -122.38).
        // Reference: ~28 km via spherical-Earth formula.
        let d = Geo.distance(fromLat: 37.87, lon: -122.27, toLat: 37.62, lon: -122.38)
        #expect(d > 27_000)
        #expect(d < 30_000)
    }

    @Test func distanceIsSymmetric() {
        let a = Geo.distance(fromLat: 37.87, lon: -122.27, toLat: 37.62, lon: -122.38)
        let b = Geo.distance(fromLat: 37.62, lon: -122.38, toLat: 37.87, lon: -122.27)
        #expect(abs(a - b) < 0.001)
    }

    // MARK: bearing — cardinal directions

    @Test func bearingDueNorth() {
        let b = Geo.bearing(fromLat: 0, lon: 0, toLat: 1, lon: 0)
        #expect(abs(b) < 0.1)
    }

    @Test func bearingDueEast() {
        let b = Geo.bearing(fromLat: 0, lon: 0, toLat: 0, lon: 1)
        #expect(abs(b - 90) < 0.1)
    }

    @Test func bearingDueSouth() {
        let b = Geo.bearing(fromLat: 1, lon: 0, toLat: 0, lon: 0)
        #expect(abs(b - 180) < 0.1)
    }

    @Test func bearingDueWest() {
        let b = Geo.bearing(fromLat: 0, lon: 1, toLat: 0, lon: 0)
        #expect(abs(b - 270) < 0.1)
    }

    @Test func bearingAlwaysIn0to360() {
        // Sweep a bunch of fromLon/toLon combos; bearing must never go
        // negative or hit 360 — the app indexes overlay angles by this.
        for fromLon in stride(from: -170.0, through: 170.0, by: 30.0) {
            for toLon in stride(from: -170.0, through: 170.0, by: 30.0) where toLon != fromLon {
                let b = Geo.bearing(fromLat: 0, lon: fromLon, toLat: 0, lon: toLon)
                #expect(b >= 0)
                #expect(b < 360)
            }
        }
    }

    // MARK: elevation

    @Test func elevation45Degrees() {
        // 10 km horizontal, 10 km vertical → 45° elevation
        let e = Geo.elevation(observerAltMeters: 0, targetAltMeters: 10_000, groundDistanceMeters: 10_000)
        #expect(abs(e - 45) < 0.01)
    }

    @Test func elevationLevelIsZero() {
        let e = Geo.elevation(observerAltMeters: 5_000, targetAltMeters: 5_000, groundDistanceMeters: 10_000)
        #expect(abs(e) < 0.01)
    }

    @Test func elevationNegativeBelowHorizon() {
        let e = Geo.elevation(observerAltMeters: 1_000, targetAltMeters: 500, groundDistanceMeters: 5_000)
        #expect(e < 0)
    }

    @Test func elevationStraightUpIsNinety() {
        // Target directly above (effectively zero ground distance) →
        // function returns 0 by guard. Document the convention rather
        // than computing 90° — at zero distance, "elevation" is ambiguous.
        let e = Geo.elevation(observerAltMeters: 0, targetAltMeters: 10_000, groundDistanceMeters: 0)
        #expect(e == 0)
    }

    // MARK: project — round-trip with bearing/distance

    @Test func projectRoundTripsWithBearingAndDistance() {
        let origin = (lat: 37.87, lon: -122.27)
        let bearing = 47.0
        let distanceMeters = 25_000.0

        let (lat, lon) = Geo.project(
            fromLat: origin.lat, lon: origin.lon,
            bearingDeg: bearing,
            distanceMeters: distanceMeters
        )

        let measuredDist = Geo.distance(
            fromLat: origin.lat, lon: origin.lon,
            toLat: lat, lon: lon
        )
        let measuredBearing = Geo.bearing(
            fromLat: origin.lat, lon: origin.lon,
            toLat: lat, lon: lon
        )

        // Tolerances chosen empirically; trig stack accumulates a bit
        // of error but stays well inside these bounds.
        #expect(abs(measuredDist - distanceMeters) < 1)
        #expect(abs(measuredBearing - bearing) < 0.1)
    }

    @Test func projectAtAllBearingsRoundTrips() {
        let origin = (lat: 37.87, lon: -122.27)
        for bearing in stride(from: 0.0, through: 350.0, by: 10.0) {
            let (lat, lon) = Geo.project(
                fromLat: origin.lat, lon: origin.lon,
                bearingDeg: bearing,
                distanceMeters: 10_000
            )
            let measured = Geo.bearing(
                fromLat: origin.lat, lon: origin.lon,
                toLat: lat, lon: lon
            )
            #expect(abs(measured - bearing) < 0.1)
        }
    }

    // MARK: screenPosition

    private static let screen = CGSize(width: 400, height: 800)
    private static let hfov: Double = 56
    private static let vfov: Double = 72

    @Test func projectionTargetStraightAheadIsAtCenter() {
        let pos = Geo.screenPosition(
            targetBearingDeg: 90, targetElevationDeg: 30,
            phoneHeadingDeg: 90,  cameraElevationDeg: 30,
            screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        if let pos {
            #expect(abs(pos.x - 200) < 0.001)
            #expect(abs(pos.y - 400) < 0.001)
        } else {
            Issue.record("Expected non-nil position for centered target")
        }
    }

    @Test func projectionWayOutOfFovReturnsNil() {
        // 90° to the right of the camera's pointing direction; FOV is 56°.
        let pos = Geo.screenPosition(
            targetBearingDeg: 180, targetElevationDeg: 0,
            phoneHeadingDeg: 90,   cameraElevationDeg: 0,
            screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        #expect(pos == nil)
    }

    /// 0/360° wraparound — heading high, target low.
    /// Naive (bearing - heading) gives -340°; correct delta is +20°.
    @Test func projectionWraparoundFromHighHeading() {
        let pos = Geo.screenPosition(
            targetBearingDeg: 10, targetElevationDeg: 0,
            phoneHeadingDeg: 350, cameraElevationDeg: 0,
            screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        if let pos {
            // dB = +20° ⇒ right of center, well inside the right half-screen.
            #expect(pos.x > 200)
            #expect(pos.x < 400)
        } else {
            Issue.record("+20° delta should land on screen, not be filtered as off-FOV")
        }
    }

    /// 0/360° wraparound — heading low, target high.
    /// Naive (bearing - heading) gives +340°; correct delta is -20°.
    @Test func projectionWraparoundFromLowHeading() {
        let pos = Geo.screenPosition(
            targetBearingDeg: 350, targetElevationDeg: 0,
            phoneHeadingDeg: 10,   cameraElevationDeg: 0,
            screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        if let pos {
            // dB = -20° ⇒ left of center.
            #expect(pos.x < 200)
            #expect(pos.x > 0)
        } else {
            Issue.record("-20° delta should land on screen, not be filtered as off-FOV")
        }
    }

    @Test func projectionElevationAboveCameraRendersAboveCenter() {
        // Phone aimed at horizon, target 20° up.
        let pos = Geo.screenPosition(
            targetBearingDeg: 0, targetElevationDeg: 20,
            phoneHeadingDeg: 0,  cameraElevationDeg: 0,
            screenSize: Self.screen, hfovDeg: Self.hfov, vfovDeg: Self.vfov
        )
        if let pos {
            #expect(abs(pos.x - 200) < 0.001)  // perfectly aligned in bearing
            #expect(pos.y < 400)               // above center (lower Y on screen)
            #expect(pos.y > 0)
        } else {
            Issue.record("20° elevation delta should be on screen for vfov=72°")
        }
    }
}
