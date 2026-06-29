//
//  RarityDivergenceTests.swift
//  TailspotTests
//
//  Pins the two rarity divergences fixed on 2026-06-11:
//
//  (a) AR-overlay HUD tier: `resolveAROverlayRarity` must use the
//      typecode-first path (matching `Catch.resolvedRarity`) so the
//      pre-catch HUD tier agrees with the post-catch Hangar tier.
//      The key regression: B38M (737 MAX) must resolve to .common via
//      the typecode path even though the string classifier would say
//      .uncommon (the old tier before the 2026-06-08 re-tier).
//
//  (b) Set-entry rarity consistency: every `CardSetEntry` with a
//      `representativeTypecode` must carry a `rarity` that matches
//      `AircraftNaming.rarity(forTypecode:)`. A divergence here means
//      the Sets browser shows a different tier than the activity model —
//      future re-tiers in `generate-aircraft-types.py` will be caught
//      automatically by this test rather than silently diverging.
//

import Testing
import Foundation
@testable import Tailspot

// MARK: - (a) AR-overlay HUD rarity resolution

@Suite("AR overlay rarity — typecode-first path")
struct AROverlayRarityTests {

    // The core regression: B38M must resolve to .common via the typecode
    // even when the string classifier would return the old .uncommon tier
    // (the 737 MAX's pre-2026-06-08 curated tier).
    @Test func b38mResolves_common_viaTypecode() {
        let rarity = resolveAROverlayRarity(
            typecode: "B38M",
            manufacturer: "Boeing",
            model: "737 MAX 8",
            operatorName: "Southwest Airlines"
        )
        #expect(rarity == .common,
                "B38M typecode must resolve to .common — same as Catch.resolvedRarity")
    }

    // Typecode wins over a model string that the string classifier would
    // tier differently (Phenom 300 → uncommon via typecode; string path
    // might see "Phenom" without a typecode-driven lookup).
    @Test func e55pResolves_uncommon_viaTypecode() {
        let rarity = resolveAROverlayRarity(
            typecode: "E55P",
            manufacturer: "Embraer",
            model: "Phenom 300",
            operatorName: nil
        )
        #expect(rarity == .uncommon,
                "E55P typecode must resolve to .uncommon")
    }

    // G650 → rare via typecode (GLF6 override).
    @Test func glf6Resolves_rare_viaTypecode() {
        let rarity = resolveAROverlayRarity(
            typecode: "GLF6",
            manufacturer: "Gulfstream",
            model: "G650",
            operatorName: nil
        )
        #expect(rarity == .rare,
                "GLF6 typecode must resolve to .rare")
    }

    // Without a typecode the string classifier is the fallback.
    // A known-legendary model (SR-71) still resolves correctly via the
    // string classifier when no typecode is present.
    @Test func sr71_noTypecode_fallsBackToStringClassifier() {
        let rarity = resolveAROverlayRarity(
            typecode: nil,
            manufacturer: "Lockheed",
            model: "SR-71",
            operatorName: nil
        )
        #expect(rarity == .legendary,
                "SR-71 without typecode must fall back to string classifier → .legendary")
    }

    // No metadata at all → common (classifier's catch-all default).
    @Test func nilEverything_returnsCommon() {
        let rarity = resolveAROverlayRarity(
            typecode: nil,
            manufacturer: nil,
            model: nil,
            operatorName: nil
        )
        #expect(rarity == .common)
    }
}

// MARK: - (b) Set-entry rarity consistency vs. AircraftTypes.json

@Suite("Sets — rarity consistency with activity model")
struct SetsRarityConsistencyTests {

    /// Every `CardSetEntry` whose `representativeTypecode` is non-nil
    /// must have a `rarity` that matches `AircraftNaming.rarity(forTypecode:)`.
    /// Fails when `generate-aircraft-types.py` re-tiers a type without a
    /// corresponding update to Sets.swift.
    @Test func allEntriesWithTypecode_matchActivityTable() {
        var mismatches: [(String, String, Rarity, Rarity)] = []

        for set in CardSets.all {
            for entry in set.entries {
                guard let tc = entry.representativeTypecode else { continue }
                guard let tableRarity = AircraftNaming.rarity(forTypecode: tc) else {
                    // The typecode is present in Sets.swift but missing from
                    // the generated table — this is also a bug worth surfacing.
                    Issue.record(
                        "Sets entry '\(entry.id)': typecode '\(tc)' not found in AircraftTypes.json table"
                    )
                    continue
                }
                if entry.rarity != tableRarity {
                    mismatches.append((entry.id, tc, entry.rarity, tableRarity))
                }
            }
        }

        for (entryId, tc, setsRarity, tableRarity) in mismatches {
            Issue.record(
                "Sets entry '\(entryId)' (\(tc)): rarity=\(setsRarity.rawValue) != table=\(tableRarity.rawValue). Update Sets.swift to match AircraftTypes.json."
            )
        }
    }

    /// Spot-check a representative sample of entries as named arguments
    /// so a regression is immediately obvious (rather than just a count).
    @Test(arguments: [
        // Narrow
        ("n-737-800",  "B738", Rarity.common),
        ("n-737-max",  "B38M", Rarity.common),    // was .uncommon — key re-tier
        ("n-a320neo",  "A20N", Rarity.common),
        ("n-a220",     "BCS3", Rarity.uncommon),
        ("n-757",      "B752", Rarity.uncommon),   // 757-200 ~130 still flying
        ("n-e190",     "E190", Rarity.uncommon),   // was .common
        // Wide
        ("w-777",      "B77W", Rarity.common),     // workhorse widebody → common
        ("w-787",      "B788", Rarity.common),     // workhorse widebody → common
        ("w-a350",     "A35K", Rarity.common),     // workhorse widebody → common
        ("w-a330",     "A332", Rarity.common),     // workhorse widebody → common
        ("w-767",      "B763", Rarity.common),     // workhorse widebody → common
        ("w-747",      "B744", Rarity.rare),        // scarce-in-the-air widebody
        ("w-a380",     "A388", Rarity.rare),       // ~200 fly, hub-concentrated
        ("w-747-8",    "B748", Rarity.epic),
        // Regional
        ("r-e175",     "E75L", Rarity.common),
        ("r-crj-700",  "CRJ7", Rarity.common),
        ("r-dash-8",   "DH8D", Rarity.common),     // was .uncommon
        ("r-atr",      "AT72", Rarity.common),     // was .uncommon
        // Biz
        ("b-citation", "C525", Rarity.uncommon),   // was .common
        ("b-phenom",   "E55P", Rarity.uncommon),   // was .common
        ("b-falcon",   "F2TH", Rarity.uncommon),   // was .common
        ("b-g650",     "GLF6", Rarity.rare),        // was .uncommon
        ("b-global",   "GL7T", Rarity.rare),        // was .uncommon
        // Mil
        ("m-c130",     "C130", Rarity.rare),
        ("m-c17",      "C17",  Rarity.rare),
        ("m-kc135",    "K35E", Rarity.rare),       // KC-135 tanker → mil → rare
        ("m-b52",      "B52",  Rarity.epic),        // was .rare
        // GA
        ("ga-c172",    "C172", Rarity.common),
        ("ga-c182",    "C182", Rarity.common),
        ("ga-c152",    "C152", Rarity.common),      // was .uncommon
        ("ga-pa28",    "P28A", Rarity.common),
        ("ga-sr22",    "SR22", Rarity.common),
        ("ga-sr20",    "SR20", Rarity.common),      // was .uncommon
        ("ga-bonanza", "BE35", Rarity.common),      // was .uncommon
        ("ga-mooney",  "M20P", Rarity.common),      // was .rare
        ("ga-da40",    "DA40", Rarity.common),      // was .uncommon
        ("ga-da42",    "DA42", Rarity.common),      // was .rare
        ("ga-r44",     "R44",  Rarity.uncommon),    // was .rare
        // Heritage (typecoded)
        ("h-dc3",      "DC3",  Rarity.rare),         // vintage classic → rare
        ("h-sofia",    "B74S", Rarity.rare),         // was .legendary
    ] as [(String, String, Rarity)])
    func setEntry_rarityMatchesTable(_ entryID: String, _ typecode: String, _ expected: Rarity) {
        // Find the entry in the catalog.
        let entry = CardSets.all
            .flatMap { $0.entries }
            .first { $0.id == entryID }
        guard let entry else {
            Issue.record("CardSetEntry '\(entryID)' not found in CardSets.all")
            return
        }
        // Entry's static rarity must equal the expected (activity-model) value.
        #expect(entry.rarity == expected,
                "entry '\(entryID)': rarity=\(entry.rarity.rawValue) expected=\(expected.rawValue)")
        // And the table must agree with that expected value.
        #expect(AircraftNaming.rarity(forTypecode: typecode) == expected,
                "typecode '\(typecode)' table rarity must equal expected \(expected.rawValue)")
    }
}
