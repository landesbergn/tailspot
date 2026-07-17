//
//  FamilySetsTests.swift
//  TailspotTests
//
//  Covers the make/model FAMILY lens added 2026-06-15 (Sets redesign):
//
//   (a) Rarity consistency — every family entry's rarity must match
//       AircraftTypes.json for its typecode (same contract as the type
//       sets in RarityDivergenceTests, so a re-tier can't silently
//       diverge the Family browser).
//   (b) Precise variant matching — a catch fills EXACTLY its variant
//       slot via the typecode path, with no bleed between look-alike
//       variants (A320 vs A320neo, 777-300 vs 777-300ER).
//   (c) Lens + identity invariants the browser/navigation rely on.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Family sets")
struct FamilySetsTests {

    private func mk(typecode: String?, model: String? = nil) -> Catch {
        Catch(icao24: "test\(typecode ?? model ?? "x")",
              callsign: nil, model: model, manufacturer: nil,
              caughtAt: Date(), observerLat: 0, observerLon: 0,
              slantDistanceMeters: 0, typecode: typecode)
    }

    private func family(_ id: String) -> CardSet {
        CardSets.families.first { $0.id == id }!
    }
    private func entry(_ familyId: String, _ entryId: String) -> CardSetEntry {
        family(familyId).entries.first { $0.id == entryId }!
    }

    // MARK: (a) Rarity consistency

    @Test func everyFamilyEntryRarityMatchesCatalog() {
        for set in CardSets.families {
            for e in set.entries {
                guard let tc = e.representativeTypecode else {
                    Issue.record("Family entry '\(e.id)' has no typecode — families are typecode-driven")
                    continue
                }
                guard let table = AircraftNaming.rarity(forTypecode: tc) else {
                    Issue.record("Family entry '\(e.id)': typecode '\(tc)' missing from AircraftTypes.json")
                    continue
                }
                #expect(e.rarity == table,
                        "Family entry '\(e.id)' (\(tc)): rarity \(e.rarity.rawValue) != catalog \(table.rawValue)")
            }
        }
    }

    // MARK: (b) Precise variant matching

    @Test func typecodeFillsExactVariant_737() {
        let catch738 = mk(typecode: "B738")
        #expect(CardSets.matches(catch: catch738, entry: entry("fam-737", "f737-800")))
        #expect(!CardSets.matches(catch: catch738, entry: entry("fam-737", "f737-700")))
        #expect(!CardSets.matches(catch: catch738, entry: entry("fam-737", "f737-max8")))
    }

    @Test func neoDoesNotBleedIntoClassicSlot() {
        // The whole reason the classic A32x slots are typecode-only.
        let neo = mk(typecode: "A20N", model: "A320neo")
        #expect(CardSets.matches(catch: neo, entry: entry("fam-a320", "fa320neo")))
        #expect(!CardSets.matches(catch: neo, entry: entry("fam-a320", "fa320")),
                "An A320neo must NOT fill the classic A320 slot")
        let classic = mk(typecode: "A320", model: "A320")
        #expect(CardSets.matches(catch: classic, entry: entry("fam-a320", "fa320")))
        #expect(!CardSets.matches(catch: classic, entry: entry("fam-a320", "fa320neo")))
    }

    @Test func b77wDoesNotBleedInto777_300() {
        let er = mk(typecode: "B77W", model: "777-300ER")
        #expect(CardSets.matches(catch: er, entry: entry("fam-777", "f777-300er")))
        #expect(!CardSets.matches(catch: er, entry: entry("fam-777", "f777-300")),
                "A 777-300ER must NOT fill the 777-300 slot")
    }

    @Test func familyProgressCountsDistinctVariants() {
        let a320 = family("fam-a320")
        let caught = [mk(typecode: "A320"), mk(typecode: "A21N"), mk(typecode: "A20N")]
        let p = CardSets.progress(of: a320, against: caught)
        #expect(p.total == a320.entries.count)
        #expect(p.caught == 3, "A320 + A321neo + A320neo fill three distinct slots")
    }

    // MARK: (c) Lens + identity invariants

    @Test func lensMapsToTheRightArrays() {
        #expect(CardSets.sets(for: .type).map(\.id) == CardSets.all.map(\.id))
        #expect(CardSets.sets(for: .family).map(\.id) == CardSets.families.map(\.id))
        #expect(CardSets.families.count >= 10, "expected a meaningful roster of families")
    }

    @Test func allSetIDsAreUnique() {
        // Navigation/identity rely on stable, unique set ids across both lenses.
        let ids = (CardSets.all + CardSets.families).map(\.id)
        #expect(Set(ids).count == ids.count, "duplicate CardSet id across lenses")
    }

    @Test func entryIDsUniqueWithinEachFamily() {
        for set in CardSets.families {
            let ids = set.entries.map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate entry id in family '\(set.id)'")
            #expect(!set.entries.isEmpty, "family '\(set.id)' has no entries")
        }
    }

    // MARK: (d) Keyed overload equivalence

    /// The precomputed-key path (`matchKeys` + `matches(key:entry:)` +
    /// `status/progress(...againstKeys:)`) is a perf restructure only — it must
    /// produce BIT-FOR-BIT the same result as the legacy `[Catch]` path. This
    /// exercises a deliberately mixed fixture across BOTH lenses: precise
    /// typecode catches, catches whose canonical name differs from the raw
    /// model, token-only catches with no typecode, an unknown typecode that
    /// falls through to the token path, an all-nil catch, and a catch that
    /// matches nothing.
    @Test func keyedOverloadMatchesLegacyPath() {
        let catches: [Catch] = [
            mk(typecode: "B738", model: "738"),        // precise + canonical-token ("737-800")
            mk(typecode: "A20N", model: "A320neo"),    // precise neo (no classic bleed)
            mk(typecode: "A320", model: "A320"),       // precise classic
            mk(typecode: nil,   model: "Boeing 747-8"),// token-only, no typecode
            mk(typecode: nil,   model: "cessna 172"),  // token-only GA
            mk(typecode: "ZZZZ", model: "SR22"),       // unknown typecode → token path
            mk(typecode: nil,   model: nil),           // all-nil → matches nothing
            mk(typecode: nil,   model: "Zorpjet 9000"),// matches nothing
        ]
        let keys = CardSets.matchKeys(for: catches)
        #expect(keys.count == catches.count)

        let lenses = CardSets.all + CardSets.families

        // (1) Per-(catch, entry) pair: the keyed matcher agrees with the legacy
        // per-catch matcher everywhere.
        for set in lenses {
            for entry in set.entries {
                for (i, c) in catches.enumerated() {
                    #expect(CardSets.matches(key: keys[i], entry: entry)
                            == CardSets.matches(catch: c, entry: entry),
                            "keyed matcher diverged for entry '\(entry.id)' / catch #\(i)")
                }
            }
        }

        // (2) Per-set: keyed status + progress equal the legacy path (same slot
        // statuses, including the SAME filling-example instance, and the same
        // caught/total counts).
        for set in lenses {
            let keyedStatus = CardSets.status(of: set, againstKeys: keys).map(\.1)
            let legacyStatus = CardSets.status(of: set, against: catches).map(\.1)
            #expect(keyedStatus == legacyStatus, "status diverged for set '\(set.id)'")

            let keyedProgress = CardSets.progress(of: set, againstKeys: keys)
            let legacyProgress = CardSets.progress(of: set, against: catches)
            #expect(keyedProgress == legacyProgress, "progress diverged for set '\(set.id)'")
        }
    }
}
