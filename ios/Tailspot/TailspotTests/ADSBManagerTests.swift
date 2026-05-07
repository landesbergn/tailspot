//
//  ADSBManagerTests.swift
//  TailspotTests
//
//  ADSBManager is the integration point for the source/geometry/UI
//  pipeline. Most user-visible regressions (wrong bearings, missing
//  filtering, broken sort order) would land here.
//
//  We inject a `FixedSource` test fixture in place of the live
//  OpenSky client so the tests are fast, deterministic, and don't
//  require the network.
//
//  ADSBManager is @MainActor (so its @Published mutations are main-
//  thread-safe by construction). That means every method we exercise
//  has to run on the main actor. Marking the whole @Suite struct
//  @MainActor handles that — every @Test inside inherits it.
//

import Testing
import Foundation
import CoreLocation
@testable import Tailspot

@Suite("ADSBManager")
@MainActor
struct ADSBManagerTests {

    // MARK: - Fixture

    /// A minimal ADSBSource that returns a fixed list of aircraft, or
    /// throws a fixed error. Sendable so it can be passed through the
    /// MainActor → URLSession pool → MainActor flow that the manager
    /// uses internally.
    private final class FixedSource: ADSBSource, Sendable {
        let aircraft: [Aircraft]
        let error: (any Error)?

        init(_ aircraft: [Aircraft] = [], error: (any Error)? = nil) {
            self.aircraft = aircraft
            self.error = error
        }

        func aircraftInBbox(
            lamin: Double, lomin: Double, lamax: Double, lomax: Double
        ) async throws -> [Aircraft] {
            if let error { throw error }
            return aircraft
        }
    }

    private struct TestError: Error {}

    private static let observerCoord = (lat: 37.87, lon: -122.27)

    private static func observer(altitude: Double = 0) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: observerCoord.lat,
                                               longitude: observerCoord.lon),
            altitude: altitude,
            horizontalAccuracy: 1, verticalAccuracy: 1,
            timestamp: Date()
        )
    }

    /// Build an Aircraft at a known angular position from the fixed
    /// observer coordinate. The test then checks that the manager
    /// computes the SAME bearing/distance/altitude back when annotating.
    private static func aircraftAt(
        bearing: Double,
        distanceMeters: Double,
        altitudeMeters: Double,
        icao: String,
        onGround: Bool = false
    ) -> Aircraft {
        let (lat, lon) = Geo.project(
            fromLat: observerCoord.lat, lon: observerCoord.lon,
            bearingDeg: bearing, distanceMeters: distanceMeters
        )
        return Aircraft(
            icao24: icao,
            callsign: "T_\(icao)",
            originCountry: "Test",
            longitude: lon,
            latitude: lat,
            altitudeMeters: altitudeMeters,
            velocityMps: nil,
            trackDeg: nil,
            onGround: onGround
        )
    }

    // MARK: - Annotation

    @Test func annotatesBearingDistanceAndElevation() async {
        let target = Self.aircraftAt(
            bearing: 90, distanceMeters: 10_000, altitudeMeters: 10_000, icao: "abc"
        )
        let source = FixedSource([target])
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.count == 1)
        let obs = manager.observed[0]
        #expect(abs(obs.bearingDeg - 90) < 0.1)
        #expect(abs(obs.elevationDeg - 45) < 0.5)   // 10 km / 10 km = 45°
        #expect(abs(obs.groundDistanceMeters - 10_000) < 1)
    }

    // MARK: - Filtering

    @Test func filtersOutOnGroundAircraft() async {
        let onGround = Self.aircraftAt(
            bearing: 90, distanceMeters: 5_000, altitudeMeters: 0,
            icao: "taxi", onGround: true
        )
        let inAir = Self.aircraftAt(
            bearing: 270, distanceMeters: 5_000, altitudeMeters: 1_000,
            icao: "fly"
        )
        let source = FixedSource([onGround, inAir])
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.count == 1)
        #expect(manager.observed[0].aircraft.icao24 == "fly")
    }

    // MARK: - Ordering

    @Test func sortsBySlantDistanceAscending() async {
        let close = Self.aircraftAt(
            bearing: 0, distanceMeters: 5_000, altitudeMeters: 1_000, icao: "close"
        )
        let far = Self.aircraftAt(
            bearing: 90, distanceMeters: 50_000, altitudeMeters: 5_000, icao: "far"
        )
        let mid = Self.aircraftAt(
            bearing: 180, distanceMeters: 20_000, altitudeMeters: 3_000, icao: "mid"
        )
        // Pass them in unsorted order — manager must sort.
        let source = FixedSource([far, close, mid])
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.map(\.aircraft.icao24) == ["close", "mid", "far"])
    }

    // MARK: - Error handling

    @Test func sourceErrorsLandInLastErrorWithoutCrashing() async {
        let source = FixedSource([], error: TestError())
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.isEmpty)
        #expect(manager.lastError != nil)
    }

    @Test func successfulRefreshClearsPreviousError() async {
        let source = FixedSource([
            Self.aircraftAt(bearing: 0, distanceMeters: 10_000, altitudeMeters: 5_000, icao: "x")
        ])
        let manager = ADSBManager(liveSource: source, mockSource: source)
        manager.lastError = "previous"

        await manager.refresh(around: Self.observer())

        #expect(manager.lastError == nil)
        #expect(manager.observed.count == 1)
    }

    @Test func updatesLastFetchedTimestampOnSuccess() async {
        let source = FixedSource([])
        let manager = ADSBManager(liveSource: source, mockSource: source)
        #expect(manager.lastFetched == nil)

        let before = Date()
        await manager.refresh(around: Self.observer())
        let after = Date()

        if let t = manager.lastFetched {
            #expect(t >= before)
            #expect(t <= after)
        } else {
            Issue.record("lastFetched should be set after a successful refresh")
        }
    }

    // MARK: - Live/mock toggle integration

    @Test func mockSourceIntegrationProducesFiveAircraft() async {
        // Default ADSBManager uses real OpenSkyClient + MockADSBSource.
        // Flipping useMock and refreshing should hit MockADSBSource,
        // which has 5 hand-picked templates.
        let manager = ADSBManager()
        manager.useMock = true

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.count == 5)
        // All mock templates have positive elevation when observer is
        // at sea level — sanity-check the projection math agrees.
        for obs in manager.observed {
            #expect(obs.elevationDeg > 0)
        }
    }
}
