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

        func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
            // Test fixture: just return nil. Tests that exercise metadata
            // will use MockADSBSource or inject test-specific metadata.
            return nil
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
        onGround: Bool = false,
        positionTimestamp: Date? = nil
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
            onGround: onGround,
            positionTimestamp: positionTimestamp
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

    @Test func rateLimitedErrorIsSurfacedAsTransientBackoffMessage() async {
        // OpenSkyClient.ClientError.rateLimited is the typed signal that
        // ADSBManager catches specifically to apply backoff. Verify the
        // user-facing lastError message mentions the backoff and flags
        // the error as transient so UI surfaces can render it softly
        // (the system auto-recovers; no user action required).
        let source = FixedSource([], error: OpenSkyClient.ClientError.rateLimited)
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        let msg = manager.lastError ?? ""
        #expect(msg.localizedCaseInsensitiveContains("limit"))
        #expect(msg.localizedCaseInsensitiveContains("retry"))
        #expect(manager.lastErrorIsTransient)
    }

    @Test func nonTransientErrorClearsTransientFlag() async {
        // A plain transport error is NOT auto-recovering — verify the
        // transient flag stays false so UI surfaces treat it as a real
        // alert.
        let source = FixedSource([], error: TestError())
        let manager = ADSBManager(liveSource: source, mockSource: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.lastError != nil)
        #expect(!manager.lastErrorIsTransient)
    }

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

    // MARK: - Forward-extrapolation

    @Test func extrapolationMovesAircraftAlongTrack() {
        // Aircraft at (37, 0), heading due east at 100 m/s, position 10s old.
        let now = Date()
        let aircraft = Aircraft(
            icao24: "abc", callsign: "TEST", originCountry: "Test",
            longitude: 0, latitude: 37,
            altitudeMeters: 5_000,
            velocityMps: 100, trackDeg: 90,    // due east
            onGround: false,
            positionTimestamp: now.addingTimeInterval(-10)
        )

        let pos = aircraft.extrapolatedPosition(at: now)

        // 100 m/s × 10s = 1 km east. At lat 37, 1° lon ≈ 89 km, so
        // 1 km ≈ 0.0113°. Latitude unchanged.
        #expect(abs(pos.lat - 37) < 0.001)
        #expect(pos.lon > 0.005)
        #expect(pos.lon < 0.02)
    }

    @Test func extrapolationFallsBackWhenTimestampMissing() {
        let aircraft = Self.aircraftAt(
            bearing: 0, distanceMeters: 10_000, altitudeMeters: 5_000,
            icao: "noTime"
        )  // positionTimestamp defaults to nil
        let pos = aircraft.extrapolatedPosition(at: Date())
        #expect(pos.lat == aircraft.latitude)
        #expect(pos.lon == aircraft.longitude)
    }

    @Test func extrapolationFallsBackWhenVelocityMissing() {
        let aircraft = Aircraft(
            icao24: "x", callsign: nil, originCountry: "T",
            longitude: 0, latitude: 37,
            altitudeMeters: 5_000,
            velocityMps: nil, trackDeg: 90,
            onGround: false,
            positionTimestamp: Date().addingTimeInterval(-10)
        )
        let pos = aircraft.extrapolatedPosition(at: Date())
        #expect(pos.lat == 37)
        #expect(pos.lon == 0)
    }

    @Test func extrapolationFallsBackWhenAgeTooLarge() {
        // 10 minutes old — well past the 120 s sanity cap.
        let aircraft = Aircraft(
            icao24: "x", callsign: nil, originCountry: "T",
            longitude: 0, latitude: 37,
            altitudeMeters: 5_000,
            velocityMps: 250, trackDeg: 90,
            onGround: false,
            positionTimestamp: Date().addingTimeInterval(-600)
        )
        let pos = aircraft.extrapolatedPosition(at: Date())
        #expect(pos.lat == 37)
        #expect(pos.lon == 0)
    }

    // MARK: - Visibility filter

    /// Construct a minimal ObservedAircraft for visibility-predicate testing.
    /// Only the four geometric fields matter; the inner Aircraft is a stub.
    private static func observed(
        bearingDeg: Double = 0,
        elevationDeg: Double,
        groundDistanceMeters: Double = 0,
        slantDistanceMeters: Double
    ) -> ObservedAircraft {
        let aircraft = Aircraft(
            icao24: "test", callsign: nil, originCountry: "Test",
            longitude: 0, latitude: 0,
            altitudeMeters: 0,
            velocityMps: nil, trackDeg: nil,
            onGround: false,
            positionTimestamp: nil
        )
        return ObservedAircraft(
            aircraft: aircraft,
            bearingDeg: bearingDeg,
            elevationDeg: elevationDeg,
            groundDistanceMeters: groundDistanceMeters,
            slantDistanceMeters: slantDistanceMeters
        )
    }

    @Test func visibleWhenAboveHorizonAndClose() {
        let obs = Self.observed(elevationDeg: 10, slantDistanceMeters: 20_000)
        #expect(obs.isLikelyVisibleToObserver)
    }

    @Test func notVisibleWhenBelowHorizon() {
        let obs = Self.observed(elevationDeg: -5, slantDistanceMeters: 5_000)
        #expect(!obs.isLikelyVisibleToObserver)
    }

    @Test func notVisibleAtExactlyHorizon() {
        // elevation == 0 is the geometric horizon — strictly below the
        // visible threshold, so should NOT pass.
        let obs = Self.observed(elevationDeg: 0, slantDistanceMeters: 5_000)
        #expect(!obs.isLikelyVisibleToObserver)
    }

    @Test func notVisibleWhenTooFar() {
        // Just past the 30 km cap.
        let obs = Self.observed(elevationDeg: 5, slantDistanceMeters: 35_000)
        #expect(!obs.isLikelyVisibleToObserver)
    }

    @Test func visibleAtEdgeOfRange() {
        // Just inside the 30 km cap — should pass.
        let obs = Self.observed(elevationDeg: 5, slantDistanceMeters: 29_000)
        #expect(obs.isLikelyVisibleToObserver)
    }

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
