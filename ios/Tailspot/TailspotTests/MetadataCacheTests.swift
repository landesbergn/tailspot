//
//  MetadataCacheTests.swift
//  TailspotTests
//
//  The cache is the deduplication layer in front of OpenSky's metadata
//  endpoint. Two requirements drive the design:
//
//  1. Distinguish "not yet fetched" from "fetched, no record." OpenSky
//     returns 404 for a lot of icao24s; we cache the absence as
//     `.set(icao, nil)` so subsequent taps don't re-fetch the miss.
//  2. Bound memory growth. 500 entries fits a long Berkeley session.
//     Oldest insertion evicts when full.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("MetadataCache")
struct MetadataCacheTests {

    @Test func getReturnsNotFetchedForUnknownIcao24() async {
        let cache = MetadataCache(cap: 10)
        let result = await cache.get(icao24: "abc123")
        #expect(result == .notFetched)
    }

    @Test func setThenGetReturnsStoredValue() async {
        let cache = MetadataCache(cap: 10)
        let m = AircraftMetadata(
            icao24: "abc123",
            registration: "N1",
            manufacturerName: "BOEING",
            manufacturerIcao: "BOEING",
            model: "737",
            typecode: "B737",
            operatorName: "X"
        )
        await cache.set(icao24: "abc123", value: m)
        let result = await cache.get(icao24: "abc123")
        #expect(result == .hit(m))
    }

    @Test func setNilCachesTheMiss() async {
        let cache = MetadataCache(cap: 10)
        await cache.set(icao24: "abc123", value: nil)
        let result = await cache.get(icao24: "abc123")
        #expect(result == .hit(nil))
    }

    @Test func evictsOldestAtCap() async {
        let cache = MetadataCache(cap: 3)
        await cache.set(icao24: "a", value: nil)
        await cache.set(icao24: "b", value: nil)
        await cache.set(icao24: "c", value: nil)
        await cache.set(icao24: "d", value: nil)   // evicts "a"

        #expect(await cache.get(icao24: "a") == .notFetched)
        #expect(await cache.get(icao24: "b") == .hit(nil))
        #expect(await cache.get(icao24: "c") == .hit(nil))
        #expect(await cache.get(icao24: "d") == .hit(nil))
    }
}
