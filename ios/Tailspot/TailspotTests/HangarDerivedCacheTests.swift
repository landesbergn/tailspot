//
//  HangarDerivedCacheTests.swift
//  TailspotTests
//
//  Pins the Hangar memoization seam: the fingerprint must be stable for
//  unchanged data (that's what makes segment switches cache hits) and
//  must change when any derivation-relevant field changes (that's what
//  makes the cache staleness-free — a backfill fill or delete forces a
//  recompute with no counter plumbing).
//

import Testing
import Foundation
@testable import Tailspot

@MainActor
struct HangarDerivedCacheTests {

    // Unmanaged @Model instances — deliberately NO ModelContainer/insert.
    // The fingerprint only reads stored fields, and a container created
    // inside a test must be retained for the life of every context/model
    // that touches it or SwiftData traps later on a change-notification
    // timer (this crashed the whole suite run on 2026-07-19).
    private func makeCatch(icao24: String) -> Catch {
        Catch(
            icao24: icao24, callsign: "UAL1", model: "737-800", manufacturer: "Boeing",
            caughtAt: Date(timeIntervalSince1970: 1_700_000_000),
            observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 5000
        )
    }

    @Test func fingerprintStableForUnchangedData() {
        let catches = [makeCatch(icao24: "a1b2c3"), makeCatch(icao24: "d4e5f6")]
        #expect(CatchFingerprint.of(catches) == CatchFingerprint.of(catches))
    }

    @Test func fingerprintChangesOnBackfillStyleFieldEdit() {
        let c = makeCatch(icao24: "a1b2c3")
        let before = CatchFingerprint.of([c])
        c.typecode = "B738"   // what CatchBackfill fills — must bust the cache
        #expect(CatchFingerprint.of([c]) != before)
    }

    @Test func fingerprintChangesOnInsertAndOrder() {
        let a = makeCatch(icao24: "a1b2c3")
        let b = makeCatch(icao24: "d4e5f6")
        #expect(CatchFingerprint.of([a]) != CatchFingerprint.of([a, b]))
        // Order-sensitive on purpose: grouped rows are order-derived.
        #expect(CatchFingerprint.of([a, b]) != CatchFingerprint.of([b, a]))
    }

    @Test func cacheBoxRecomputesOnlyOnTokenChange() {
        let box = DerivedCacheBox<Int>()
        var computes = 0
        #expect(box.value(for: 1) { computes += 1; return 10 } == 10)
        #expect(box.value(for: 1) { computes += 1; return 99 } == 10)  // hit: stale closure ignored
        #expect(computes == 1)
        #expect(box.value(for: 2) { computes += 1; return 20 } == 20)  // miss: recompute
        #expect(computes == 2)
    }
}
