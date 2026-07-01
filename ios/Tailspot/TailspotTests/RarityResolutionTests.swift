//
//  RarityResolutionTests.swift
//  TailspotTests
//
//  Pins the activity-based rarity model (spec 2026-06-08): rarity
//  resolves from the ICAO typecode via the generated AircraftTypes.json,
//  exactly like `type`. Tiers reflect sky presence — how many of a type
//  are airborne at any moment — not curated interest. The headline cases:
//  the 737 MAX is COMMON (newest 737, but ~1,500+ fly daily), workhorse
//  widebodies are COMMON, and the Phenom 300 is UNCOMMON.
//
//  Also pins the deliberate frozen-moment exception: resolvedRarity
//  derives live and ignores the stored snapshot, so re-tiering corrects
//  prior catches on read.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("RarityResolution — typecode path")
@MainActor
struct RarityResolutionTests {

    // MARK: Typecode → tier (one representative per bucket)

    @Test(arguments: [
        ("B38M", Rarity.common),     // 737 MAX 8 — newest 737, but one of the most-seen jets
        ("C172", .common),           // Cessna 172 — GA piston long tail
        ("E55P", .uncommon),         // Embraer Phenom 300 — bizjet, parked most days
        ("A333", .common),           // A330-300 — workhorse widebody → common
        ("B763", .common),           // 767-300 — workhorse widebody → common
        ("B789", .common),           // 787-9 — workhorse widebody → common
        ("EC35", .uncommon),         // Airbus H135 — rotorcraft
        ("B744", .rare),             // 747-400 — scarce-in-the-air widebody
        ("GLF6", .rare),             // Gulfstream G650 — heavy bizjet
        ("C17",  .epic),             // C-17 — military workhorse → epic
        ("A388", .rare),             // A380 — ~200 fly, hub-concentrated
        ("B2",   .legendary),        // B-2 Spirit — icon
    ])
    func rarityFromTypecode(_ code: String, _ expected: Rarity) {
        #expect(AircraftNaming.rarity(forTypecode: code) == expected)
    }

    // Bizjets newly exposed to the activity model by the 2026-06-09 type
    // fix: biz default → uncommon (they were wrongly common as narrow/ga);
    // flagship ULR Gulfstreams overridden → rare (consistent with G650).
    @Test(arguments: [
        ("FA50", Rarity.uncommon),   // Dassault Falcon 50
        ("C650", .uncommon),         // Cessna Citation VII
        ("LJ25", .uncommon),         // Learjet 25
        ("GA6C", .rare),             // Gulfstream G600
        ("GA7C", .rare),             // Gulfstream G700
        ("GA8C", .rare),             // Gulfstream G800
    ])
    func bizjetRarityAfterTypeFix(_ code: String, _ expected: Rarity) {
        #expect(AircraftNaming.rarity(forTypecode: code) == expected)
    }

    @Test func unknownTypecode_returnsNil() {
        // Unknown / nil typecode falls through to nil; callers then resolve
        // to the conservative `.common` default (the single-source rule —
        // the string classifier's rarity ladder is no longer a fallback).
        #expect(AircraftNaming.rarity(forTypecode: "ZZZZ") == nil)
        #expect(AircraftNaming.rarity(forTypecode: nil) == nil)
    }

    // MARK: resolvedRarity corrects prior data on read

    @Test func resolvedRarity_typecodeOverridesStaleSnapshot() throws {
        // A Catch carrying a stale stored rarity (.uncommon — the MAX's
        // old tier) but a known typecode must resolve to the NEW tier via
        // the typecode path. This proves re-tiering corrects prior catches
        // and the frozen snapshot no longer wins (the deliberate exception
        // to the frozen-moment rule, spec 2026-06-08).
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: modelConfig)
        let context = ModelContext(container)

        let c = Catch(
            icao24: "ab38m1",
            callsign: "SWA100",
            model: "737 MAX 8",
            manufacturer: "Boeing",
            caughtAt: Date(),
            observerLat: 37.8,
            observerLon: -122.2,
            slantDistanceMeters: 3000,
            typecode: "B38M",
            rarity: .uncommon   // stale snapshot from the old interest-based table
        )
        context.insert(c)

        #expect(c.rarity == Rarity.uncommon.rawValue)   // stored audit value unchanged
        #expect(c.resolvedRarity == .common,            // …but resolution derives → common
                "B38M typecode must resolve to .common, not the stale .uncommon snapshot")
    }
}
