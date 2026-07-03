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
            // inject a metadata-specific source (see ADSBManagerMetadataTests).
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
        let manager = ADSBManager(source: source)

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
        let manager = ADSBManager(source: source)

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
        let manager = ADSBManager(source: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.map(\.aircraft.icao24) == ["close", "mid", "far"])
    }

    // MARK: - Error handling

    @Test func sourceErrorsLandInLastErrorWithoutCrashing() async {
        let source = FixedSource([], error: TestError())
        let manager = ADSBManager(source: source)

        await manager.refresh(around: Self.observer())

        #expect(manager.observed.isEmpty)
        #expect(manager.lastError != nil)
    }

    @Test func successfulRefreshClearsPreviousError() async {
        let source = FixedSource([
            Self.aircraftAt(bearing: 0, distanceMeters: 10_000, altitudeMeters: 5_000, icao: "x")
        ])
        let manager = ADSBManager(source: source)
        manager.lastError = "previous"

        await manager.refresh(around: Self.observer())

        #expect(manager.lastError == nil)
        #expect(manager.observed.count == 1)
    }

    @Test func updatesLastFetchedTimestampOnSuccess() async {
        let source = FixedSource([])
        let manager = ADSBManager(source: source)
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
        slantDistanceMeters: Double,
        callsign: String? = nil
    ) -> ObservedAircraft {
        let aircraft = Aircraft(
            icao24: "test", callsign: callsign, originCountry: "Test",
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
        // 5 km @ 10° — comfortably inside the ~7.1 km cap at that angle.
        let obs = Self.observed(elevationDeg: 10, slantDistanceMeters: 5_000)
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
        // 30 km @ 45° is past the FULL curve (25 km) but inside the faint
        // ceiling (35 km) — tiered visibility (2026-06-12) renders it as a
        // dimmed label rather than hiding it.
        let nearFar = Self.observed(elevationDeg: 45, slantDistanceMeters: 30_000)
        #expect(nearFar.visibilityTier == .faint)
        #expect(nearFar.isLikelyVisibleToObserver)
        // Existence ends at the faint ceiling: 36 km is hidden outright.
        let beyond = Self.observed(elevationDeg: 45, slantDistanceMeters: 36_000)
        #expect(beyond.visibilityTier == .hidden)
        #expect(!beyond.isLikelyVisibleToObserver)
    }

    @Test func visibleAtEdgeOfRange() {
        // Just inside the 13 km plateau, near-overhead — the contrail /
        // cruise-traffic case the plateau exists for.
        let obs = Self.observed(elevationDeg: 35, slantDistanceMeters: 12_000)
        #expect(obs.isLikelyVisibleToObserver)
    }

    @Test func notVisibleAtLowElevationBuffer() {
        // Planes right at the horizon are hidden behind hills / urban
        // skyline. The filter keeps a small buffer (>1° elevation, lowered
        // from 3° on 2026-06-01 after 3° was deleting visible low traffic).
        let obs = Self.observed(elevationDeg: 0.5, slantDistanceMeters: 10_000)
        #expect(!obs.isLikelyVisibleToObserver)
    }

    @Test func visibleAtLowElevationAboveBuffer() {
        // Low elevation still admits genuinely-close traffic: 4 km @ 2°
        // (short final over the bay) is inside the ~4.8 km cap there.
        let obs = Self.observed(elevationDeg: 2, slantDistanceMeters: 4_000)
        #expect(obs.isLikelyVisibleToObserver)
    }

    // MARK: - Elevation-dependent distance cap (2026-06-04 field fit)

    @Test func farLowElevationGhostIsFiltered() {
        // The 2026-06-04 field session's ghost signature: 21 km @ 3.5°
        // (N2838Q) was labeled but invisible — far + low is haze/clutter.
        // Precision band (2026-06-15): well beyond 2× the ~5.2 km curve cap
        // at 3.5°, so HIDDEN — the desired outcome for a confirmed ghost.
        let obs = Self.observed(elevationDeg: 3.5, slantDistanceMeters: 21_000)
        #expect(obs.visibilityTier == .hidden)
    }

    @Test func nightHighElevationGhostIsFiltered() {
        // 2026-06-04 night session: 20.5 km @ 11° (SKW5983) was labeled
        // but NOT visible — tap-pin ground truth. High elevation does not
        // rescue a distant airframe.
        // Precision band (2026-06-15): 20.5 km is past 2× the ~7.4 km curve
        // cap at 11°, so HIDDEN.
        let obs = Self.observed(elevationDeg: 11, slantDistanceMeters: 20_500)
        #expect(obs.visibilityTier == .hidden)
    }

    @Test func daytimeMidElevationGhostIsFiltered() {
        // 2026-06-06 daytime session: 33.3 km @ 10.8° (TZP30) was the
        // reported false positive that motivated moving the plateau off
        // the 10° edge.
        // Precision band (2026-06-15): the dense-MLAT field session showed
        // the old "demote far ghosts to a quiet faint label" doctrine
        // produced ~20 false labels per frame. This confirmed ghost (33 km
        // @ 10.8°, far past 2× the curve) is now HIDDEN. The cost asymmetry
        // flipped: against a 76-contact feed, a wall of ghost labels is
        // worse than missing the occasional clear-day far plane.
        let obs = Self.observed(elevationDeg: 10.8, slantDistanceMeters: 33_300)
        #expect(obs.visibilityTier == .hidden)
    }

    @Test func urbanCloseGhostsAreFiltered() {
        // 2026-06-06 09:08 session — Noah confirmed NONE of these were
        // visible despite all being within 13 km. Naked-eye spotting is a
        // single-digit-km activity:
        //   REH1   9.3 km @ 1.9° (381 m medevac helo, below the roofline)
        //   N21866 6.3 km @ 4.1°
        //   VJA534 8.1 km @ 12.3°
        //   SWA3042 11 km @ 17.4° (737 in daylight — still invisible)
        // Tiered visibility (2026-06-12): confirmed ghosts demote to faint
        // (quiet label) rather than hide — full labels stay reserved for
        // the confidence curve these cases sit outside of.
        #expect(Self.observed(elevationDeg: 1.9, slantDistanceMeters: 9_300).visibilityTier == .faint)
        #expect(Self.observed(elevationDeg: 4.1, slantDistanceMeters: 6_300).visibilityTier == .faint)
        #expect(Self.observed(elevationDeg: 12.3, slantDistanceMeters: 8_100).visibilityTier == .faint)
        #expect(Self.observed(elevationDeg: 17.4, slantDistanceMeters: 11_000).visibilityTier == .faint)
    }

    @Test func confirmedSightingsAreKept() {
        // Every tap-pin-confirmed real sighting across sessions:
        //   UAL8205 4.1 km @ 46° (day), DAL640 4.7 km @ 36° (day),
        //   FDX5991 5.8 km @ 16° (night), SKW5405 8.3 km @ 20.7° (day).
        #expect(Self.observed(elevationDeg: 46, slantDistanceMeters: 4_100, callsign: "UAL8205").isLikelyVisibleToObserver)
        #expect(Self.observed(elevationDeg: 36, slantDistanceMeters: 4_700, callsign: "DAL640").isLikelyVisibleToObserver)
        #expect(Self.observed(elevationDeg: 16, slantDistanceMeters: 5_800, callsign: "FDX5991").isLikelyVisibleToObserver)
        #expect(Self.observed(elevationDeg: 20.7, slantDistanceMeters: 8_300, callsign: "SKW5405").isLikelyVisibleToObserver)
    }

    @Test func smallAirframeGetsHalvedCap() {
        // N3001B, confirmed ghost at 4.8 km / 8.0° (2026-06-06 09:13
        // session): inside the airliner cap (~6.6 km at 8°) but a GA
        // single subtends a third of an airliner — the N-number heuristic
        // halves its cap to ~3.3 km. The identical geometry under an
        // airline callsign stays visible.
        // Under tiered visibility (2026-06-12) the GA half-cap shapes
        // EMPHASIS, not existence: the confirmed N3001B ghost is demoted
        // to faint (quiet) while the same geometry under an airline
        // callsign earns a full label.
        #expect(Self.observed(elevationDeg: 8, slantDistanceMeters: 4_800, callsign: "N3001B").visibilityTier == .faint)
        #expect(Self.observed(elevationDeg: 8, slantDistanceMeters: 4_800, callsign: "SKW123").visibilityTier == .full)
        // And a genuinely-close GA plane still gets the full treatment.
        #expect(Self.observed(elevationDeg: 8, slantDistanceMeters: 2_000, callsign: "N3001B").visibilityTier == .full)
    }

    @Test func smallAirframeHeuristic() {
        func ac(_ cs: String?) -> Aircraft {
            Aircraft(icao24: "x", callsign: cs, originCountry: "US",
                     longitude: 0, latitude: 0, altitudeMeters: 0,
                     velocityMps: nil, trackDeg: nil, onGround: false,
                     positionTimestamp: nil)
        }
        #expect(ac("N3001B").isLikelySmallAirframe)
        #expect(ac("N21866").isLikelySmallAirframe)
        #expect(!ac("UAL8205").isLikelySmallAirframe)   // airline ICAO prefix
        #expect(!ac("NKS123").isLikelySmallAirframe)    // Spirit (NKS) — N + letter
        #expect(!ac(nil).isLikelySmallAirframe)
        #expect(!ac("N").isLikelySmallAirframe)
    }

    @Test func distanceCapCurveShape() {
        // Floor: ~4.5 km right at the 1° elevation floor.
        #expect(abs(ObservedAircraft.maxVisibleDistance(forElevationDeg: 1) - 4_500) < 1)
        // Joint: 13 km at exactly 30° (end of the haze ramp).
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 30) == 13_000)
        // Contrail segment (2026-06-11): grows past 30°, capped 25 km ≥ 45°.
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 45) == 25_000)
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 60) == 25_000)
        // Monotonic across the whole curve, both segments and the joint.
        var last = 0.0
        for e in stride(from: 1.0, through: 60.0, by: 0.5) {
            let d = ObservedAircraft.maxVisibleDistance(forElevationDeg: e)
            #expect(d >= last)
            last = d
        }
    }

    // MARK: - Freshness (maxPositionAge)

    @Test func annotateKeepsRecentPosition() {
        // 120 s old < the 150 s default floor → annotated, not dropped.
        let now = Date()
        let ac = Self.aircraftAt(bearing: 0, distanceMeters: 10_000,
                                 altitudeMeters: 5_000, icao: "fresh",
                                 positionTimestamp: now.addingTimeInterval(-120))
        #expect(ObservedAircraft.annotate(ac, observer: Self.observer(), now: now) != nil)
    }

    @Test func annotateDropsStalePosition() {
        // 200 s old > the 150 s default floor → dropped as a ghost.
        let now = Date()
        let ac = Self.aircraftAt(bearing: 0, distanceMeters: 10_000,
                                 altitudeMeters: 5_000, icao: "stale",
                                 positionTimestamp: now.addingTimeInterval(-200))
        #expect(ObservedAircraft.annotate(ac, observer: Self.observer(), now: now) == nil)
    }

    @Test func annotateHonorsExplicitMaxPositionAge() {
        // `annotate` takes maxPositionAge as a parameter (the replay
        // analyzer passes its own) — verify a plane stale vs the default
        // floor survives under a wider explicit allowance.
        let now = Date()
        let ac = Self.aircraftAt(bearing: 0, distanceMeters: 10_000,
                                 altitudeMeters: 5_000, icao: "widened",
                                 positionTimestamp: now.addingTimeInterval(-200))
        #expect(ObservedAircraft.annotate(ac, observer: Self.observer(), now: now) == nil)
        #expect(ObservedAircraft.annotate(ac, observer: Self.observer(), now: now,
                                          maxPositionAge: 250) != nil)
    }
}

// MARK: - Contrail visibility ceiling (field datum 2026-06-11)

@Suite("Visibility contrail segment")
struct VisibilityContrailTests {

    /// The Sea Ranch observation that created the segment: ANA179 at
    /// 12.1 km altitude, slant 19.2 km, elevation 39.1°, clearly visible
    /// by contrail (photo + replay-2026-06-11T161754Z), pruned by the old
    /// 13 km plateau. The curve must now pass it.
    @Test func ana179FieldDatumPasses() {
        let allowed = ObservedAircraft.maxVisibleDistance(forElevationDeg: 39.1)
        #expect(allowed > 19_200)
    }

    @Test func contrailPlateauCapsAt25km() {
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 45) == 25_000)
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 80) == 25_000)
        // Even straight up, 30 km stays out — beyond any contrail datum.
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 80) < 30_000)
    }

    @Test func lowElevationCurveUnchangedByContrailSegment() {
        // The Berkeley ghost observations all live below 30° — that part
        // of the curve must be bit-identical to the pre-segment fit.
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 1) == 4_500)
        #expect(ObservedAircraft.maxVisibleDistance(forElevationDeg: 30) == 13_000)
        let at16 = ObservedAircraft.maxVisibleDistance(forElevationDeg: 16)
        #expect(at16 > 5_800 && at16 < 13_000)   // 5.8 km @ 16° confirmed sighting fits
        let at17 = ObservedAircraft.maxVisibleDistance(forElevationDeg: 17.4)
        #expect(at17 < 11_000)                    // 11 km @ 17.4° confirmed ghost stays out
    }

    @Test func segmentIsContinuousAtThirtyDegrees() {
        let below = ObservedAircraft.maxVisibleDistance(forElevationDeg: 29.999)
        let above = ObservedAircraft.maxVisibleDistance(forElevationDeg: 30.001)
        #expect(abs(below - above) < 50)   // no cliff at the joint
    }
}
