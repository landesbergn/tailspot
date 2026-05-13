//
//  CatchTests.swift
//  TailspotTests
//
//  Tests for the Catch SwiftData model. We use an in-memory
//  ModelContainer (configurations: .init(isStoredInMemoryOnly: true))
//  so the tests don't touch disk and don't share state between
//  invocations.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Catch model")
@MainActor
struct CatchTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Catch.self, configurations: config)
    }

    @Test func insertsAndFetchesACatch() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a3b15e",
            callsign: "UAL248",
            model: "737-800",
            manufacturer: "BOEING",
            caughtAt: Date(timeIntervalSince1970: 1_715_000_000),
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 25_400
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.icao24 == "a3b15e")
        #expect(fetched.first?.callsign == "UAL248")
        #expect(fetched.first?.model == "737-800")
    }

    @Test func storesMultipleCatchesIncludingDuplicates() throws {
        // v1 explicitly allows the same icao24 to be caught multiple
        // times — each tap is a discrete event. Dedupe is a Hangar
        // concern (PLAN.md §9 #7).
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date()
        context.insert(Catch(
            icao24: "abc", callsign: "X", model: "737", manufacturer: "BOEING",
            caughtAt: now, observerLat: 37, observerLon: -122,
            slantDistanceMeters: 1000
        ))
        context.insert(Catch(
            icao24: "abc", callsign: "X", model: "737", manufacturer: "BOEING",
            caughtAt: now.addingTimeInterval(60),
            observerLat: 37, observerLon: -122, slantDistanceMeters: 1100
        ))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>())
        #expect(fetched.count == 2)
    }

    @Test func nilOptionalFieldsAreAllowed() throws {
        // Some metadata fields aren't always available (callsign nil
        // for radar-only contacts; model/manufacturer nil if OpenSky
        // has no record).
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "xyz",
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>())
        #expect(fetched.first?.callsign == nil)
        #expect(fetched.first?.model == nil)
    }
}
