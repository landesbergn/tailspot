//
//  GameSystemTests.swift
//  TailspotTests
//
//  Pure-function tests for the rarity / type classifier and the
//  Rarity / AircraftType enums themselves. The classifier is the
//  load-bearing piece: every Catch row's rarity + type either come
//  from it directly (at insert time) or fall back to it via the
//  resolved* computed properties on Catch.
//
//  These tests pin the curated table so a rule edit can't silently
//  shift the tier of an airframe that's already had badges issued
//  in the wild.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("AircraftClassifier")
struct AircraftClassifierTests {

    // MARK: - Legendary tier

    @Test func vc25IsLegendaryWhenOperatedByUSAF() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "VC-25A",
            operatorName: "USAF"
        )
        #expect(rarity == .legendary)
        #expect(type == .mil)
    }

    @Test func vc25FallsThroughWithoutMilitaryOperator() {
        // A civilian 747-2 isn't a VC-25 — the operator gate makes
        // sure a generic 747-200 doesn't get flagged as legendary.
        let (rarity, _) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "747-200F",
            operatorName: "Kalitta Air"
        )
        // No operator-gated rule matches → falls through to the 747
        // rare bucket.
        #expect(rarity == .rare)
    }

    @Test func sr71IsLegendary() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "Lockheed",
            model: "SR-71",
            operatorName: nil
        )
        #expect(rarity == .legendary)
        #expect(type == .mil)
    }

    @Test func b2IsLegendary() {
        let (rarity, _) = AircraftClassifier.classify(
            manufacturer: "Northrop",
            model: "B-2",
            operatorName: nil
        )
        #expect(rarity == .legendary)
    }

    // MARK: - Epic tier

    @Test func a380IsEpicWide() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "AIRBUS",
            model: "A380-800",
            operatorName: "British Airways"
        )
        #expect(rarity == .epic)
        #expect(type == .wide)
    }

    @Test func boeing747_8IsEpic() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "747-8F",
            operatorName: "Cargolux"
        )
        #expect(rarity == .epic)
        #expect(type == .wide)
    }

    // MARK: - Rare tier

    @Test func boeing787IsRareWide() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "787-9",
            operatorName: "United Airlines"
        )
        #expect(rarity == .rare)
        #expect(type == .wide)
    }

    @Test func a350IsRareWide() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "AIRBUS",
            model: "A350-941",
            operatorName: "Delta"
        )
        #expect(rarity == .rare)
        #expect(type == .wide)
    }

    @Test func legacyHangarRareList_stillClassifyRareOrAbove() {
        // The pre-Pokédex HangarRarity binary list flagged these as
        // .rare. Every entry on that list must still resolve to
        // .rare or higher under the new 5-tier system, or we'd
        // silently downgrade rows that the user already trophies.
        let legacy: [String] = [
            "747-400", "A380-800", "A340-600",
            "C-130J", "C-17", "C-5M",
            "KC-135", "KC-46",
            "B-52H", "B-1B", "B-2",
            "AH-64", "AH-1Z",
        ]
        for model in legacy {
            let (rarity, _) = AircraftClassifier.classify(
                manufacturer: nil,
                model: model,
                operatorName: nil
            )
            #expect(rarity.ordinal >= Rarity.rare.ordinal,
                    "Legacy rare model '\(model)' resolved to \(rarity), expected .rare or higher")
        }
    }

    // MARK: - Uncommon tier

    @Test func a220IsUncommonNarrow() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "AIRBUS",
            model: "A220-300",
            operatorName: "JetBlue"
        )
        #expect(rarity == .uncommon)
        #expect(type == .narrow)
    }

    @Test func b737MaxIsUncommon() {
        let (rarity, _) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "737 MAX 9",
            operatorName: "Alaska"
        )
        #expect(rarity == .uncommon)
    }

    // MARK: - Common tier

    @Test func b737NgIsCommonNarrow() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "737-800",
            operatorName: "Southwest"
        )
        #expect(rarity == .common)
        #expect(type == .narrow)
    }

    @Test func a320IsCommonNarrow() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "AIRBUS",
            model: "A320-271N",
            operatorName: "United"
        )
        #expect(rarity == .common)
        #expect(type == .narrow)
    }

    @Test func e175IsCommonRegional() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "EMBRAER",
            model: "E175-200LR",
            operatorName: "SkyWest"
        )
        #expect(rarity == .common)
        #expect(type == .regional)
    }

    @Test func cessna172IsCommonGA() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "Cessna",
            model: "172",
            operatorName: "Private"
        )
        #expect(rarity == .common)
        #expect(type == .ga)
    }

    // MARK: - Fallback / case insensitivity

    @Test func caseInsensitiveMatching() {
        let (lower, _) = AircraftClassifier.classify(
            manufacturer: "boeing",
            model: "787-9",
            operatorName: nil
        )
        let (upper, _) = AircraftClassifier.classify(
            manufacturer: "BOEING",
            model: "787-9",
            operatorName: nil
        )
        #expect(lower == upper)
        #expect(lower == .rare)
    }

    @Test func nilAndEmptyInputs_fallToGADefault() {
        // Default is GA, not narrow — the long tail of unknown aircraft
        // is light general aviation. Changed from .narrow in the
        // typecode-driven classification overhaul (2026-06-07).
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: nil,
            model: nil,
            operatorName: nil
        )
        #expect(rarity == .common)
        #expect(type == .ga)
    }

    @Test func unknownManufacturer_fallsToGACommon() {
        // Same: unknown → GA, not narrow.
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "Acme Aerospace",
            model: "ZZ-9 Plural Z Alpha",
            operatorName: nil
        )
        #expect(rarity == .common)
        #expect(type == .ga)
    }

    // MARK: - Rotorcraft fallback (no typecode path)

    @Test func robinsonR44_classifierFallback_isGA() {
        // Robinson by manufacturer name → ga (helicopter brand hint).
        let (_, type) = AircraftClassifier.classify(
            manufacturer: "ROBINSON",
            model: "R44",
            operatorName: nil
        )
        #expect(type == .ga)
    }

    @Test func eurocopterByName_fallback_isGA() {
        // Eurocopter by manufacturer name → ga.
        let (_, type) = AircraftClassifier.classify(
            manufacturer: "Eurocopter",
            model: "EC135",
            operatorName: nil
        )
        #expect(type == .ga)
    }

    @Test func embraerNoModel_hintsRegional() {
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: "Embraer",
            model: nil,
            operatorName: nil
        )
        #expect(rarity == .common)
        #expect(type == .regional)
    }

    @Test func determinismSameInputSameOutput() {
        let a = AircraftClassifier.classify(
            manufacturer: "Airbus",
            model: "A350-1000",
            operatorName: "Qatar Airways"
        )
        let b = AircraftClassifier.classify(
            manufacturer: "Airbus",
            model: "A350-1000",
            operatorName: "Qatar Airways"
        )
        #expect(a.rarity == b.rarity)
        #expect(a.type == b.type)
    }
}

// MARK: - Typecode-driven type resolution

/// Pins the three categories of bug reported by the user: helicopters
/// (EC35, R44) and light GA (C172) landing in Narrow-body. These tests
/// exercise the full resolution chain through `AircraftNaming.aircraftType`.
@Suite("AircraftTypeResolution — typecode path")
@MainActor
struct AircraftTypeResolutionTests {

    // MARK: Typecode → table lookups

    @Test func ec35_typecode_isGA() {
        // Airbus Helicopters H-135 is a helicopter → ga, not narrow.
        #expect(AircraftNaming.aircraftType(forTypecode: "EC35") == .ga)
    }

    @Test func r44_typecode_isGA() {
        // Robinson R44 is a helicopter → ga.
        #expect(AircraftNaming.aircraftType(forTypecode: "R44") == .ga)
    }

    @Test func c172_typecode_isGA() {
        // Cessna 172 is light piston GA → ga, not narrow.
        #expect(AircraftNaming.aircraftType(forTypecode: "C172") == .ga)
    }

    @Test func b738_typecode_isNarrow() {
        // Boeing 737-800 → narrow.
        #expect(AircraftNaming.aircraftType(forTypecode: "B738") == .narrow)
    }

    @Test func b77w_typecode_isWide() {
        // Boeing 777-300ER → wide.
        #expect(AircraftNaming.aircraftType(forTypecode: "B77W") == .wide)
    }

    @Test func crj7_typecode_isRegional() {
        // Bombardier CRJ-700 → regional.
        #expect(AircraftNaming.aircraftType(forTypecode: "CRJ7") == .regional)
    }

    @Test func glf5_typecode_isBiz() {
        // Gulfstream G550 → biz.
        #expect(AircraftNaming.aircraftType(forTypecode: "GLF5") == .biz)
    }

    @Test func unknownTypecode_returnsNil() {
        // Unknown typecode falls through to nil; callers use classifier.
        #expect(AircraftNaming.aircraftType(forTypecode: "ZZZZ") == nil)
        #expect(AircraftNaming.aircraftType(forTypecode: nil) == nil)
    }

    // MARK: Catch.resolvedType — typecode wins over stale snapshot

    @Test func resolvedType_typecodeWinsOverStaleSnapshot() throws {
        // A Catch with typecode "EC35" but stored aircraftType "narrow"
        // (stale snapshot from before the fix) must resolve to .ga via
        // the typecode path, overriding the stale stored value.
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: modelConfig)
        let context = ModelContext(container)

        // Insert with stale stored type (simulate a pre-fix row)
        let c = Catch(
            icao24: "abc123",
            callsign: "TEST1",
            model: "H-135",
            manufacturer: "Airbus Helicopters",
            caughtAt: Date(),
            observerLat: 37.8,
            observerLon: -122.2,
            slantDistanceMeters: 2000,
            typecode: "EC35",
            aircraftType: .narrow   // stale snapshot — should be overridden
        )
        context.insert(c)
        // Typecode path must win.
        #expect(c.resolvedType == .ga,
                "EC35 typecode must resolve to .ga, not the stale .narrow snapshot")
    }
}

@Suite("Rarity + AircraftType enums")
struct GameSystemEnumTests {

    @Test func basePointsLadder() {
        #expect(Rarity.common.basePoints    == 10)
        #expect(Rarity.uncommon.basePoints  == 25)
        #expect(Rarity.rare.basePoints      == 100)
        #expect(Rarity.epic.basePoints      == 500)
        #expect(Rarity.legendary.basePoints == 2000)
    }

    @Test func ordinalsAreMonotonic() {
        // Defends against an accidental reordering of `allCases` that
        // would silently flip rare-vs-common comparisons across the app.
        #expect(Rarity.common.ordinal    < Rarity.uncommon.ordinal)
        #expect(Rarity.uncommon.ordinal  < Rarity.rare.ordinal)
        #expect(Rarity.rare.ordinal      < Rarity.epic.ordinal)
        #expect(Rarity.epic.ordinal      < Rarity.legendary.ordinal)
    }

    @Test func everyTypeHasNonEmptyDisplayFields() {
        for t in AircraftType.allCases {
            #expect(!t.label.isEmpty)
            #expect(!t.glyph.isEmpty)
            #expect(!t.summary.isEmpty)
        }
    }

    @Test func rarityRawValuesRoundTrip() {
        // Catch persists `rarity: String?` via rawValue, so a refactor
        // that renames a case has to be caught here, not in production.
        for r in Rarity.allCases {
            #expect(Rarity(rawValue: r.rawValue) == r)
        }
    }
}
