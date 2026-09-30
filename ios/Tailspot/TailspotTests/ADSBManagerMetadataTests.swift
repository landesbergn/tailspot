//
//  ADSBManagerMetadataTests.swift
//  TailspotTests
//
//  Tests for ADSBManager.metadata(for:): cache consultation, source
//  fall-through, dedupe of repeated requests, error handling.
//

import Testing
import Foundation
@testable import Tailspot

// A minimal ADSBSource fixture that counts metadata calls and returns
// configurable results, so tests can assert dedupe + error behavior.
private final class CountingMetadataSource: ADSBSource, @unchecked Sendable {

    // Empty aircraft list for the bbox call — we only care about
    // metadata in these tests.
    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft] { [] }

    // Configurable per-icao24 result. Throws if the icao24 is in
    // `errors`; otherwise returns the value in `results`.
    var results: [String: AircraftMetadata?] = [:]
    var errors: Set<String> = []
    /// icao24s the source answers with a 429 (the backend caps
    /// GET /v1/metadata at 300/min/IP). A test clears the entry to simulate
    /// the bucket refilling and assert the retry succeeds.
    var rateLimited: Set<String> = []

    private(set) var callCounts: [String: Int] = [:]

    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
        callCounts[icao24, default: 0] += 1
        if rateLimited.contains(icao24) {
            throw ADSBSourceError.rateLimited
        }
        if errors.contains(icao24) {
            throw ADSBSourceError.http(status: 503)
        }
        if let result = results[icao24] {
            return result
        }
        return nil
    }
}

private func makeMetadata(icao24: String, model: String) -> AircraftMetadata {
    AircraftMetadata(
        icao24: icao24,
        registration: nil,
        manufacturerName: nil,
        manufacturerIcao: nil,
        model: model,
        typecode: nil,
        operatorName: nil
    )
}

@Suite("ADSBManager metadata lookups")
@MainActor
struct ADSBManagerMetadataTests {

    @Test func cacheMissTriggersSourceCall() async {
        let src = CountingMetadataSource()
        let expected = makeMetadata(icao24: "abc", model: "737-800")
        src.results["abc"] = expected

        let mgr = ADSBManager(source: src)
        let got = await mgr.metadata(for: "abc")

        #expect(got == expected)
        #expect(src.callCounts["abc"] == 1)
    }

    @Test func repeatedCallsHitCacheOnly() async {
        let src = CountingMetadataSource()
        src.results["abc"] = makeMetadata(icao24: "abc", model: "737")

        let mgr = ADSBManager(source: src)
        _ = await mgr.metadata(for: "abc")
        _ = await mgr.metadata(for: "abc")
        _ = await mgr.metadata(for: "abc")

        #expect(src.callCounts["abc"] == 1)
    }

    @Test func unknownIcao24CachesAsMiss() async {
        let src = CountingMetadataSource()
        // No entry in src.results -> returns nil from source.

        let mgr = ADSBManager(source: src)
        let first = await mgr.metadata(for: "xyz")
        let second = await mgr.metadata(for: "xyz")

        #expect(first == nil)
        #expect(second == nil)
        // Cached as miss -> source called exactly once.
        #expect(src.callCounts["xyz"] == 1)
    }

    @Test func sourceErrorDoesNotPoisonCache() async {
        let src = CountingMetadataSource()
        src.errors.insert("err")

        let mgr = ADSBManager(source: src)
        // First call hits the error path; we should get nil back.
        let firstResult = await mgr.metadata(for: "err")
        #expect(firstResult == nil)

        // Now make the source succeed and retry.
        src.errors.remove("err")
        src.results["err"] = makeMetadata(icao24: "err", model: "A320")
        let second = await mgr.metadata(for: "err")

        #expect(second?.model == "A320")
        #expect(src.callCounts["err"] == 2)   // error did not cache
    }

    @Test func sourceErrorRaisesTheStatusPill() async {
        // The baseline the 429 case below is measured against: a REAL
        // transport failure still puts the red pill up.
        let src = CountingMetadataSource()
        src.errors.insert("err")

        let mgr = ADSBManager(source: src)
        _ = await mgr.metadata(for: "err")

        #expect(mgr.lastErrorUserMessage != nil)
    }

    // ── 429: a silent retry, not an error ────────────────────────────────
    // GET /v1/metadata is capped at 300/min/IP (backend API hardening,
    // 2026-09-06). Being told to slow down is not "Tailspot unreachable" —
    // it must not raise the pill, and it must not poison the cache.

    @Test func rateLimitedReturnsNilWithoutRaisingThePill() async {
        let src = CountingMetadataSource()
        src.rateLimited.insert("busy")

        let mgr = ADSBManager(source: src)
        let got = await mgr.metadata(for: "busy")

        #expect(got == nil)
        #expect(mgr.lastErrorUserMessage == nil)
        #expect(mgr.lastError == nil)
    }

    @Test func rateLimitedDoesNotCacheSoALaterLookupRetries() async {
        let src = CountingMetadataSource()
        src.rateLimited.insert("busy")

        let mgr = ADSBManager(source: src)
        #expect(await mgr.metadata(for: "busy") == nil)

        // Bucket refilled — the next lookup must reach the source again.
        src.rateLimited.remove("busy")
        src.results["busy"] = makeMetadata(icao24: "busy", model: "A350")
        let second = await mgr.metadata(for: "busy")

        #expect(second?.model == "A350")
        #expect(src.callCounts["busy"] == 2)   // 429 did not cache
    }
}
