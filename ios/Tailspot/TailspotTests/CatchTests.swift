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
            operatorName: "United Airlines",
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
        #expect(fetched.first?.operatorName == "United Airlines")
    }

    @Test func operatorNameDefaultsToNilWhenOmitted() throws {
        // operatorName was added after v0; existing call sites pass
        // it via the default parameter. This pins that default so a
        // future signature change can't silently re-introduce the
        // "Hangar always shows Unknown airline" regression.
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a3b15e",
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>())
        #expect(fetched.first?.operatorName == nil)
    }

    @Test func duplicateInsertIsRejected() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        let ctx = ModelContext(container)

        let icao = "abc123"

        // First insert succeeds.
        ctx.insert(Catch(
            icao24: icao,
            callsign: "UAL248",
            model: "737-800",
            manufacturer: "BOEING",
            operatorName: "United",
            caughtAt: Date(),
            observerLat: 37.871, observerLon: -122.272,
            slantDistanceMeters: 12_400
        ))
        try ctx.save()

        // Sanity: the row is there.
        let before = try ctx.fetch(FetchDescriptor<Catch>())
        #expect(before.count == 1)

        // The Catch model itself enforces nothing — uniqueness is gated at
        // the insertion site (ContentView.performCatch). What we test here
        // is the static helper that those sites use.
        #expect(Catch.exists(icao24: icao, in: ctx) == true)
        #expect(Catch.exists(icao24: "deadbeef", in: ctx) == false)
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

    // MARK: - Rarity / Type snapshotting

    @Test func insertRunsClassifierAndSnapshotsRarityAndType() throws {
        // New rows pick up rarity + type from the classifier at insert
        // time so the catch is a frozen moment — re-classifying later
        // can't retroactively change what tier the user "earned."
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a3b15e",
            callsign: "UAL248",
            model: "787-9",
            manufacturer: "BOEING",
            operatorName: "United Airlines",
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        context.insert(c)
        try context.save()

        let fetched = try #require(try context.fetch(FetchDescriptor<Catch>()).first)
        #expect(fetched.rarity == Rarity.rare.rawValue)
        #expect(fetched.aircraftType == AircraftType.wide.rawValue)
        #expect(fetched.resolvedRarity == .rare)
        #expect(fetched.resolvedType == .wide)
    }

    @Test func resolvedRarityBackfillsFromClassifierWhenNil() {
        // Legacy rows written before the rarity/type fields existed
        // come back with nil. resolvedRarity must reproduce the
        // classifier's verdict so the Hangar / Detail views don't
        // render them all as Common.
        let c = Catch(
            icao24: "x",
            callsign: nil,
            model: "A380-800",
            manufacturer: "AIRBUS",
            operatorName: "British Airways",
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        // Simulate the "pre-existing row" state by nilling the fields
        // the migration would have left empty.
        c.rarity = nil
        c.aircraftType = nil
        #expect(c.resolvedRarity == .epic)
        #expect(c.resolvedType == .wide)
    }

    @Test func explicitRarityOverridesClassifier() {
        // The init takes optional rarity / aircraftType params so a
        // caller can lock in a specific tier (e.g., the multi-catch
        // mechanic or a future curated override). Verify the explicit
        // value beats the classifier.
        let c = Catch(
            icao24: "x",
            callsign: nil,
            model: "737-800",
            manufacturer: "BOEING",
            operatorName: nil,
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
            rarity: .legendary,
            aircraftType: .heritage
        )
        #expect(c.resolvedRarity == .legendary)
        #expect(c.resolvedType == .heritage)
    }

    @Test func newSnapshotFieldsRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a1b2c3",
            callsign: "UAL248",
            model: "777-322ER",
            manufacturer: "BOEING",
            operatorName: "United Airlines",
            caughtAt: Date(timeIntervalSince1970: 1_750_000_000),
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 8_300,
            registration: "N779UA",
            typecode: "B77W",
            altitudeMeters: 11_277.6,
            velocityMps: 245.0,
            placeName: "Berkeley, CA"
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.registration == "N779UA")
        #expect(fetched?.typecode == "B77W")
        #expect(fetched?.altitudeMeters == 11_277.6)
        #expect(fetched?.velocityMps == 245.0)
        #expect(fetched?.placeName == "Berkeley, CA")
    }

    @Test func newSnapshotFieldsDefaultToNil() throws {
        // Pre-existing call sites omit the new params; lightweight
        // migration gives old rows nil. Pin the defaults.
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a1b2c3",
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(),
            observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.registration == nil)
        #expect(fetched?.typecode == nil)
        #expect(fetched?.altitudeMeters == nil)
        #expect(fetched?.velocityMps == nil)
        #expect(fetched?.placeName == nil)
    }

    // MARK: - PokePlane from a stored Catch

    @Test func pokePlaneFormatsStoredAltAndSpeed() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 8_300,
            altitudeMeters: 152.4,   // exactly 500 ft
            velocityMps: 102.889     // exactly 200 kt
        )
        let plane = PokePlane(catchRecord: c)
        #expect(plane.altText == "500 ft")
        #expect(plane.speedText == "200 kt")
    }

    @Test func pokePlaneShowsNilStatsForLegacyRows() {
        let c = Catch(
            icao24: "a1b2c3", callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
        let plane = PokePlane(catchRecord: c)
        #expect(plane.altText == nil)   // card renders "—"
        #expect(plane.speedText == nil)
    }

    @Test func pokePlaneUsesCanonicalModelName() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: "B77W"
        )
        #expect(PokePlane(catchRecord: c).model == "Boeing 777-300ER")
    }

    // MARK: - Set matcher: canonical + raw union

    @Test func setMatcherSeesCanonicalAndRawNames() {
        // Raw-only: model string carries the token (pre-typecode row).
        let raw = Catch(
            icao24: "r1", callsign: nil, model: "737-8H4", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0, slantDistanceMeters: 0
        )
        // Canonical-only: nil model, typecode resolves to "Boeing 737 MAX 8".
        let canon = Catch(
            icao24: "c1", callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
            typecode: "B38M"
        )
        let narrow = PokeSets.all.first { $0.id == "narrow" }!
        let entry737 = narrow.entries.first { $0.id == "n-737-800" }!
        let entryMax = narrow.entries.first { $0.id == "n-737-max" }!

        #expect(PokeSets.matches(catch: raw, entry: entry737))   // union keeps raw matching
        #expect(PokeSets.matches(catch: canon, entry: entryMax)) // union adds canonical matching
    }
}
