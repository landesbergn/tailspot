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

    @Test func countryDefaultsToNilWhenOmitted() throws {
        // `country` was added 2026-06 for the Mr. Worldwide trophy. Existing
        // call sites omit it (default nil); pre-field rows decode as nil under
        // SwiftData lightweight migration. Pin the default so a future
        // signature change can't break the migration shape.
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
        #expect(fetched.first?.country == nil)
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
        // New rows still snapshot rarity + type from the classifier at
        // insert time (stored as audit values). Post-2026-06-08
        // resolvedRarity DERIVES live, and under the single-source rule
        // (U3) a row with NO typecode resolves to the conservative .common
        // default — so the stored audit rarity (classifier verdict: 787 →
        // .uncommon) and the resolved rarity deliberately DIVERGE here.
        // resolvedType still falls out of the classifier (787 → .wide).
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
        #expect(fetched.rarity == Rarity.uncommon.rawValue)   // stored audit = classifier verdict
        #expect(fetched.aircraftType == AircraftType.wide.rawValue)
        #expect(fetched.resolvedRarity == .common)            // no typecode → conservative default
        #expect(fetched.resolvedType == .wide)
    }

    @Test func resolvedTypeBackfillsFromClassifierWhenNil_rarityDefaultsCommon() {
        // Legacy rows written before the rarity/type fields existed come
        // back with nil. resolvedType still reproduces the classifier's
        // verdict so the Hangar / Detail views don't render them all as one
        // type. resolvedRarity, under the single-source rule (U3), no longer
        // reads the classifier ladder: with NO typecode it resolves to the
        // conservative .common default. (A typecoded legacy row would still
        // re-tier correctly via the authoritative table.)
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
        #expect(c.resolvedRarity == .common)   // no typecode → conservative default
        #expect(c.resolvedType == .wide)       // type still backfills from the classifier
    }

    @Test func explicitRarityStoredButResolvedRarityDerives() {
        // The init still accepts explicit rarity / aircraftType params,
        // stored as as-caught audit values. aircraftType still flows
        // through resolvedType (typecode → stored → classifier), but
        // post-2026-06-08 resolvedRarity DERIVES from the typecode/
        // classifier and ignores the stored rarity snapshot — the
        // deliberate exception that lets re-tiering correct prior catches.
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
        // Explicit rarity is still stored (audit), but no longer drives
        // resolution — a 737-800 with no typecode resolves to .common.
        #expect(c.rarity == Rarity.legendary.rawValue)
        #expect(c.resolvedRarity == .common)
        // aircraftType explicit value still wins via resolvedType.
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

    @Test func routePersistsWhenSet() throws {
        // Route (origin → destination) is a frozen catch-moment fact, stored
        // when the live feed carried one. Round-trips through SwiftData.
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL901",
            model: "787-9", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            originIcao: "KSFO",
            destIcao: "EGLL"
        )
        context.insert(c)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.originIcao == "KSFO")
        #expect(fetched?.destIcao == "EGLL")
    }

    @Test func routeDefaultsToNilWhenOmitted() throws {
        // `originIcao`/`destIcao` were added 2026-06. Existing call sites omit
        // them (default nil); pre-field rows decode as nil under SwiftData
        // lightweight migration. Most catches (routeless GA/military) are nil
        // here too. Pin the default + migration shape.
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

        let fetched = try context.fetch(FetchDescriptor<Catch>()).first
        #expect(fetched?.originIcao == nil)
        #expect(fetched?.destIcao == nil)
    }

    // MARK: - CardPlane from a stored Catch

    @Test func cardPlaneFormatsStoredAltAndSpeed() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 8_300,
            altitudeMeters: 152.4,   // exactly 500 ft
            velocityMps: 102.889     // exactly 200 kt
        )
        let plane = CardPlane(catchRecord: c)
        #expect(plane.altText == "500 ft")
        #expect(plane.speedText == "200 kt")
    }

    @Test func cardPlaneShowsNilStatsForLegacyRows() {
        let c = Catch(
            icao24: "a1b2c3", callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
        let plane = CardPlane(catchRecord: c)
        #expect(plane.altText == nil)   // card renders "—"
        #expect(plane.speedText == nil)
    }

    @Test func cardPlaneUsesCanonicalModelName() {
        let c = Catch(
            icao24: "a1b2c3", callsign: "UAL248",
            model: "777-322ER", manufacturer: "BOEING",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: "B77W"
        )
        #expect(CardPlane(catchRecord: c).model == "Boeing 777-300ER")
    }

    // MARK: - Live-feed airframe field preference (U3)

    @Test func preferredAirframeFieldPrefersFeedThenMetadata() {
        // Feed wins when present.
        #expect(Catch.preferredAirframeField(feed: "A359", metadata: "A320") == "A359")
        // Falls back to the metadata endpoint when the feed lacks it.
        #expect(Catch.preferredAirframeField(feed: nil, metadata: "A320") == "A320")
        // A blank feed value is treated as absent → falls back to metadata.
        #expect(Catch.preferredAirframeField(feed: "   ", metadata: "A320") == "A320")
        // Both blank/absent → nil, so the fill-only-if-nil Hangar backfill can
        // still heal the field later.
        #expect(Catch.preferredAirframeField(feed: "  ", metadata: "") == nil)
        #expect(Catch.preferredAirframeField(feed: nil, metadata: nil) == nil)
        // The chosen value is trimmed.
        #expect(Catch.preferredAirframeField(feed: " 9V-SMH ", metadata: nil) == "9V-SMH")
    }

    @Test func foreignTypecodeAloneResolvesCardWithoutMetadata() {
        // The SIA248 case: a foreign airframe the FAA-only /v1/metadata endpoint
        // can't resolve, so model/manufacturer are nil — but the feed supplied
        // the typecode. Storing it alone must produce a real name + correct
        // type: no "Unknown aircraft", no GA-default fallback (the .wide type and
        // the resolved model prove it). The airline (callsign-derived) keeps
        // showing as before.
        let c = Catch(
            icao24: "76cdb5", callsign: "SIA248",
            model: nil, manufacturer: nil,
            operatorName: "Singapore Airlines",
            caughtAt: Date(), observerLat: 0, observerLon: 0,
            slantDistanceMeters: 38_600,
            typecode: "A359"
        )
        let plane = CardPlane(catchRecord: c)
        #expect(plane.model == "Airbus A350-900")
        #expect(plane.model != "Unknown aircraft")
        #expect(plane.type == .wide)            // not the .ga unknown-airframe default
        #expect(c.resolvedRarity == .common)    // A350 is a workhorse widebody → common
        #expect(plane.carrier == "Singapore Airlines")
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
        let narrow = CardSets.all.first { $0.id == "narrow" }!
        let entry737 = narrow.entries.first { $0.id == "n-737-800" }!
        let entryMax = narrow.entries.first { $0.id == "n-737-max" }!

        #expect(CardSets.matches(catch: raw, entry: entry737))   // union keeps raw matching
        #expect(CardSets.matches(catch: canon, entry: entryMax)) // union adds canonical matching
    }
}
