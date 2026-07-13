//
//  GroundedEasterEggTests.swift
//  TailspotTests
//
//  The grounded easter egg (game-layer PR5): on-ground aircraft are
//  annotated into a HIDDEN tier (`ObservedAircraft.grounded`) instead of
//  dropped, so a tap near one can answer "that one's still parked" — but
//  they must NEVER become visible, catchable, or tap-to-revealable. These
//  tests are the permanent floor for that invariant, plus coverage for the
//  pieces around it: the empty-tap classifier that routes the toast, the
//  generic TrophyEventStore, and the "Ground Stop" secret badge.
//
//  The field-tuned visibility curve itself is untouched — grounded planes
//  are pinned hidden BEFORE any elevation/distance math — so the
//  FieldReplays floor assertions stay structurally identical.
//

import Testing
import Foundation
import CoreGraphics
import CoreLocation
@testable import Tailspot

@Suite("Grounded easter egg")
@MainActor
struct GroundedEasterEggTests {

    // MARK: - Fixtures

    private static let observerCoord = (lat: 37.87, lon: -122.27)

    private static func observer() -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: observerCoord.lat,
                                               longitude: observerCoord.lon),
            altitude: 0,
            horizontalAccuracy: 1, verticalAccuracy: 1,
            timestamp: Date()
        )
    }

    /// An Aircraft at a bearing/distance/altitude from the fixed observer —
    /// geometry deliberately WELL INSIDE the visibility curve (5 km slant at
    /// a healthy elevation), so that if the `grounded` guard ever regressed,
    /// the plane would pass the filter and these tests would go red.
    private static func aircraft(
        icao: String, onGround: Bool,
        distanceMeters: Double = 5_000, altitudeMeters: Double = 1_000
    ) -> Aircraft {
        let (lat, lon) = Geo.project(
            fromLat: observerCoord.lat, lon: observerCoord.lon,
            bearingDeg: 90, distanceMeters: distanceMeters
        )
        return Aircraft(
            icao24: icao,
            callsign: "UAL\(icao.prefix(3))",   // non-N callsign: no GA half-cap
            originCountry: "Test",
            longitude: lon, latitude: lat,
            altitudeMeters: altitudeMeters,
            velocityMps: nil, trackDeg: nil,
            onGround: onGround,
            positionTimestamp: nil
        )
    }

    /// A hand-built ObservedAircraft for the projection-based helpers
    /// (`icaosInZone`), mirroring CatchZoneTests' builder + a grounded flag.
    private func obs(
        icao: String, bearingDeg: Double, grounded: Bool = false
    ) -> ObservedAircraft {
        let aircraft = Aircraft(
            icao24: icao, callsign: nil, originCountry: "X",
            longitude: 0, latitude: 0, altitudeMeters: 100,
            velocityMps: nil, trackDeg: nil, onGround: grounded,
            positionTimestamp: nil
        )
        return ObservedAircraft(
            aircraft: aircraft,
            bearingDeg: bearingDeg, elevationDeg: 5.0,
            groundDistanceMeters: 5_000, slantDistanceMeters: 5_100,
            grounded: grounded
        )
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.groundedegg.\(UUID().uuidString)")!
    }

    // MARK: - Never visible

    @Test func groundedAnnotatesIntoHiddenTierWhereAirborneTwinIsVisible() {
        let now = Date()
        let parked = ObservedAircraft.annotate(
            Self.aircraft(icao: "park01", onGround: true),
            observer: Self.observer(), now: now
        )
        let airborne = ObservedAircraft.annotate(
            Self.aircraft(icao: "fly001", onGround: false),
            observer: Self.observer(), now: now
        )

        // The twin proves the geometry PASSES the curve — only the grounded
        // guard hides the parked one.
        #expect(airborne?.isLikelyVisibleToObserver == true)

        #expect(parked != nil, "grounded aircraft must be annotated, not dropped")
        #expect(parked?.grounded == true)
        #expect(parked?.visibilityTier == .hidden)
        #expect(parked?.isLikelyVisibleToObserver == false)
    }

    @Test func hysteresisCannotResurrectAGroundedPlane() {
        var parked = ObservedAircraft.annotate(
            Self.aircraft(icao: "park01", onGround: true),
            observer: Self.observer(), now: Date()
        )!
        // Even with the stay-shown stamp forced on, the tier stays hidden.
        parked.wasShownLastFrame = true
        #expect(parked.visibilityTier == .hidden)

        // And the shared hysteresis helper never admits it to the shown set,
        // even when the previous frame (impossibly) claimed to show it.
        var frame = [parked]
        let shown = applyVisibilityHysteresis(
            &frame, previouslyShown: [parked.aircraft.icao24]
        )
        #expect(shown.isEmpty)
        #expect(frame[0].isLikelyVisibleToObserver == false)
    }

    // MARK: - Never catchable

    @Test func groundedPlaneAtScreenCenterIsNotInCatchZone() {
        // Dead-center grounded plane + an airborne one 5° off: the catch
        // zone must contain only the airborne plane.
        let planes = [
            obs(icao: "PARKED", bearingDeg: 0, grounded: true),
            obs(icao: "FLYING", bearingDeg: 5),
        ]
        let zone = icaosInZone(
            in: planes, phoneHeadingDeg: 0, cameraElevationDeg: 0,
            screenSize: CGSize(width: 393, height: 852), zoneRadius: 180
        )
        #expect(zone == ["FLYING"])
    }

    // MARK: - Never revealable (the empty-tap classifier routes to the toast)

    @Test func classifierRoutesGroundedToToastNotReveal() {
        // A grounded plane is ALSO tier-hidden; "grounded" must win over
        // "filtered" or the tap-reveal path would surface a parked plane.
        let reason = classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: true, tier: .hidden, onScreen: false,
            plausiblyRevealable: false
        )
        #expect(reason == "grounded")
    }

    @Test func classifierKeepsTapRevealForAirborneFilteredPlanes() {
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, tier: .hidden, onScreen: false,
            plausiblyRevealable: true
        ) == "filtered")
    }

    @Test func classifierIgnoresGroundedPlaneOutsideTapRadius() {
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: emptySkyTapMaxOffsetDeg + 1,
            grounded: true, tier: .hidden, onScreen: false,
            plausiblyRevealable: false
        ) == "nothing-nearby")
    }

    @Test func classifierPreservesLegacyReasons() {
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, tier: .full, onScreen: false,
            plausiblyRevealable: true
        ) == "off-frame")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, tier: .full, onScreen: true,
            plausiblyRevealable: true
        ) == "on-screen")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 41, grounded: false, tier: .full, onScreen: true,
            plausiblyRevealable: true
        ) == "nothing-nearby")
    }

    @Test func tapRevealFiresForFilteredAndOffFrame() {
        // The explicit-intent escape hatch surfaces a real plane the ambient
        // filter/frame hid: a precision-band-FILTERED plane (FDX1268) and —
        // 2026-07-11 — a visible plane pushed OFF-FRAME by compass error (the
        // DAL972 field miss: pointed right at it, label projected off-screen).
        #expect(shouldTapReveal(reason: "filtered"))
        #expect(shouldTapReveal(reason: "off-frame"))
    }

    @Test func tapRevealNeverFiresForGroundedOrHits() {
        // Grounded is routed to the toast BEFORE this gate (belt-and-suspenders
        // here too); on-screen / nothing-nearby are ordinary misses. None reveal.
        #expect(!shouldTapReveal(reason: "grounded"))
        #expect(!shouldTapReveal(reason: "on-screen"))
        #expect(!shouldTapReveal(reason: "nothing-nearby"))
    }

    // MARK: - TrophyEventStore

    @Test func eventStoreRecordsAndPersistsAcrossInstances() {
        let defaults = freshDefaults()
        let store = TrophyEventStore(defaults: defaults)
        #expect(store.hasOccurred(.groundedCatchAttempt) == false)
        #expect(store.count(of: .groundedCatchAttempt) == 0)

        store.record(.groundedCatchAttempt)
        #expect(store.hasOccurred(.groundedCatchAttempt))
        #expect(store.count(of: .groundedCatchAttempt) == 1)

        // A separate instance over the same defaults sees the record —
        // persistence, not instance state.
        let revived = TrophyEventStore(defaults: defaults)
        #expect(revived.hasOccurred(.groundedCatchAttempt))
    }

    @Test func eventStoreOccurrenceIsIdempotentAcrossRepeats() {
        let store = TrophyEventStore(defaults: freshDefaults())
        store.record(.groundedCatchAttempt)
        store.record(.groundedCatchAttempt)
        store.record(.groundedCatchAttempt)
        // The boolean view the 1-of-1 badge consumes never flaps; the raw
        // count keeps the honest tally for future threshold badges.
        #expect(store.hasOccurred(.groundedCatchAttempt))
        #expect(store.count(of: .groundedCatchAttempt) == 3)
    }

    // MARK: - "Ground Stop" badge

    private var groundStop: Achievement {
        Trophies.roster.first { $0.id == "groundstop" }!
    }

    @Test func groundStopIsASecretOneShot() {
        #expect(groundStop.secret)
        #expect(groundStop.tiers.count == 1)
        #expect(groundStop.threshold == 1)
        // Roster stays integral with the addition (unique ids, all binary).
        let ids = Trophies.roster.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func groundStopEarnsOnlyFromTheEventInput() {
        #expect(groundStop.isEarned(inputs: .zero) == false)
        let tried = TrophyProgressInputs(
            totalCatches: 0, uniqueAirframes: 0,
            wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0,
            triedGroundedCatch: true
        )
        #expect(groundStop.isEarned(inputs: tried))
    }

    @Test func inputsAggregatorReadsTheEventStore() {
        let defaults = freshDefaults()
        let store = TrophyEventStore(defaults: defaults)

        #expect(Trophies.inputs(from: [], events: store).triedGroundedCatch == false)
        store.record(.groundedCatchAttempt)
        #expect(Trophies.inputs(from: [], events: store).triedGroundedCatch == true)
    }

    /// End-to-end wiring: recording the event between two unlock scans
    /// queues the Ground Stop moment (this is exactly the toast path —
    /// `presentGroundedTapToast` records, then calls `enqueueNewUnlocks`).
    @Test func recordingTheEventQueuesTheGroundStopUnlockMoment() {
        let defaults = freshDefaults()
        let ledger = UserDefaultsTrophyLedger(defaults: defaults)
        let events = TrophyEventStore(defaults: defaults)
        let center = TrophyUnlockCenter(ledger: ledger, events: events)

        center.enqueueNewUnlocks(from: [])   // seeds; event not yet recorded
        #expect(center.pendingEvents.isEmpty)

        events.record(.groundedCatchAttempt)
        center.enqueueNewUnlocks(from: [])
        #expect(center.pendingEvents.contains { $0.achievementID == "groundstop" })
    }

    // MARK: - Telemetry shape

    @Test func groundedAttemptCarriesIcaoOnly() {
        let props = CatchTelemetry.groundedAttemptProperties(icao24: "a1b2c3")
        #expect(props.count == 1)
        guard case .string(let icao)? = props["icao24"] else {
            Issue.record("icao24 missing or not a string"); return
        }
        #expect(icao == "a1b2c3")
        #expect(CatchTelemetry.groundedAttemptEvent == "grounded_catch_attempt")
    }
}
