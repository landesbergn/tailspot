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

    private(set) var callCounts: [String: Int] = [:]

    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
        callCounts[icao24, default: 0] += 1
        if errors.contains(icao24) {
            throw ADSBSourceError.rateLimited
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
}
