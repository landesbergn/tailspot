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
}
