//
//  TrophiesTests.swift
//  TailspotTests
//
//  Pin the trophy roster + the `Trophies.inputs(from:)` aggregator
//  + per-achievement `currentTier`/`nextTier`/`isLocked` evaluation
//  so a tier-threshold tweak can't silently relabel achievements
//  the user already earned.
//
//  All inputs are synthetic Catches built inline (no SwiftData
//  container required) since Catch has a public init.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Trophies")
@MainActor
struct TrophiesTests {

    // MARK: - Catch builder

    /// Compact helper for terse tests. Resolved rarity / type fall
    /// out of the classifier when not specified.
    private func mk(
        model: String? = nil,
        manufacturer: String? = nil,
        operatorName: String? = nil,
        slantKm: Double = 1.0,
        caughtAt: Date = Date(timeIntervalSince1970: 1_716_000_000)
    ) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil,
            model: model,
            manufacturer: manufacturer,
            operatorName: operatorName,
            caughtAt: caughtAt,
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: slantKm * 1000
        )
    }

    // MARK: - Inputs aggregator

    @Test func zeroInputsFromEmpty() {
        let inputs = Trophies.inputs(from: [])
        #expect(inputs.totalCatches == 0)
        #expect(inputs.uniqueAirframes == 0)
        #expect(inputs.rarePlusUnique == 0)
        #expect(inputs.wideBodyCatches == 0)
        #expect(inputs.legendaryTierCatches == 0)
        #expect(inputs.longestSlantKm == 0)
    }

    @Test func inputsCountWideBodiesByResolvedType() {
        // A350 + 787 + A380 are .wide; 737 + A320 are .narrow.
        let catches: [Catch] = [
            mk(model: "A350-941",   manufacturer: "AIRBUS"),
            mk(model: "787-9",      manufacturer: "BOEING"),
            mk(model: "A380-800",   manufacturer: "AIRBUS"),
            mk(model: "737-800",    manufacturer: "BOEING"),
            mk(model: "A320-271N",  manufacturer: "AIRBUS"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.wideBodyCatches == 3)
        #expect(inputs.totalCatches == 5)
    }

    @Test func inputsCountRegionalByResolvedType() {
        let catches: [Catch] = [
            mk(model: "E175-200LR", manufacturer: "EMBRAER"),
            mk(model: "CRJ-700",    manufacturer: "BOMBARDIER"),
            mk(model: "737-800",    manufacturer: "BOEING"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.regionalCatches == 2)
    }

    @Test func inputsCountTierCatchesSeparately() {
        let catches: [Catch] = [
            mk(model: "A380-800",  manufacturer: "AIRBUS"),   // epic
            mk(model: "747-400",   manufacturer: "BOEING"),   // rare (scarce widebody)
            mk(model: "VC-25",     manufacturer: "BOEING", operatorName: "USAF"), // legendary
            mk(model: "737-800",   manufacturer: "BOEING"),   // common
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.rareTierCatches == 1)
        #expect(inputs.epicTierCatches == 1)
        #expect(inputs.legendaryTierCatches == 1)
        // All three rare+ — but each is a different airframe.
        #expect(inputs.rarePlusUnique == 3)
    }

    @Test func longestSlantPicksMax() {
        let catches: [Catch] = [
            mk(slantKm:  5),
            mk(slantKm: 18),
            mk(slantKm: 31),
            mk(slantKm: 12),
        ]
        #expect(Trophies.inputs(from: catches).longestSlantKm == 31)
    }

    @Test func nightCatchesUseLocalHourBoundary() {
        // Production reads Calendar.current — so the test must too,
        // or we'd fail on any non-UTC machine. We construct dates at
        // specific *local* hours so the .hour component round-trips
        // through the same calendar the classifier reads.
        let cal = Calendar.current
        let base = cal.startOfDay(for: Date())
        let nightHour = cal.date(byAdding: .hour, value: 23, to: base)!
        let earlyHour = cal.date(byAdding: .hour, value:  3, to: base)!
        let dayHour   = cal.date(byAdding: .hour, value: 12, to: base)!
        let catches = [mk(caughtAt: nightHour), mk(caughtAt: earlyHour), mk(caughtAt: dayHour)]
        // Both 23 and 3 are in the night window (>= 20 or < 6);
        // 12 is squarely day. Production should count exactly 2.
        #expect(Trophies.inputs(from: catches).nightCatches == 2)
    }

    // MARK: - Per-achievement evaluation

    @Test func catcherLockedWithZeroCatches() {
        guard let catcher = Trophies.roster.first(where: { $0.id == "catcher" }) else {
            Issue.record("catcher not in roster")
            return
        }
        let inputs = TrophyProgressInputs.zero
        #expect(catcher.isLocked(inputs: inputs))
        #expect(catcher.currentTier(inputs: inputs) == nil)
        #expect(catcher.nextTier(inputs: inputs)?.at == 10)
    }

    @Test func catcherClimbsBronzeAtTen() {
        guard let catcher = Trophies.roster.first(where: { $0.id == "catcher" }) else {
            Issue.record("catcher not in roster"); return
        }
        // Build 10 cheap catches; the classifier will resolve them
        // as common-narrow but that's fine for catcher (counts all).
        let catches = (0..<10).map { _ in mk(model: "737-800", manufacturer: "BOEING") }
        let inputs = Trophies.inputs(from: catches)
        #expect(catcher.currentTier(inputs: inputs) == .bronze)
        #expect(catcher.nextTier(inputs: inputs)?.tier == .silver)
        #expect(catcher.nextTier(inputs: inputs)?.at == 50)
    }

    @Test func catcherMaxPlatinumAtThousand() {
        guard let catcher = Trophies.roster.first(where: { $0.id == "catcher" }) else {
            Issue.record("catcher not in roster"); return
        }
        let inputs = TrophyProgressInputs(
            totalCatches: 1500, uniqueAirframes: 0,
            wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
        #expect(catcher.currentTier(inputs: inputs) == .platinum)
        #expect(catcher.nextTier(inputs: inputs) == nil)
    }

    @Test func legendaryUnlocksAtOneLegendaryCatch() {
        guard let legendary = Trophies.roster.first(where: { $0.id == "legendary" }) else {
            Issue.record("legendary not in roster"); return
        }
        let none = TrophyProgressInputs.zero
        #expect(legendary.isLocked(inputs: none))

        let one = TrophyProgressInputs(
            totalCatches: 1, uniqueAirframes: 1,
            wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 1,
            rarePlusUnique: 1, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
        #expect(legendary.currentTier(inputs: one) == .platinum)
        #expect(legendary.nextTier(inputs: one) == nil)
    }

    @Test func wideAwakeStaggersBronzeSilverGold() {
        guard let heavy = Trophies.roster.first(where: { $0.id == "heavy" }) else {
            Issue.record("heavy not in roster"); return
        }
        let inputs5 = TrophyProgressInputs(
            totalCatches: 5, uniqueAirframes: 5,
            wideBodyCatches: 5, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
        #expect(heavy.currentTier(inputs: inputs5) == .bronze)
        let inputs20 = TrophyProgressInputs(
            totalCatches: 20, uniqueAirframes: 20,
            wideBodyCatches: 20, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
        #expect(heavy.currentTier(inputs: inputs20) == .silver)
        let inputs50 = TrophyProgressInputs(
            totalCatches: 50, uniqueAirframes: 50,
            wideBodyCatches: 50, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: 0,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
        #expect(heavy.currentTier(inputs: inputs50) == .gold)
        #expect(heavy.nextTier(inputs: inputs50) == nil)
    }

    @Test func rosterIsNotEmptyAndHasUniqueIDs() {
        // Sanity: a typo'd duplicate id would break the ForEach on
        // Trophies screen (Identifiable identity collision).
        let ids = Trophies.roster.map(\.id)
        #expect(!ids.isEmpty)
        #expect(Set(ids).count == ids.count, "Duplicate achievement ID(s) in roster")
    }
}

@Suite("PokeSets")
@MainActor
struct PokeSetsTests {

    private func mk(model: String, manufacturer: String? = nil) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil,
            model: model,
            manufacturer: manufacturer,
            operatorName: nil,
            caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
    }

    @Test func emptyCatchesAllSlotsLocked() {
        for set in PokeSets.all {
            let result = PokeSets.status(of: set, against: [])
            #expect(result.allSatisfy { if case .locked = $0.1 { return true } else { return false } })
        }
    }

    @Test func boeing787CatchFillsWideBodySlot() {
        let wide = PokeSets.all.first { $0.id == "wide" }!
        let result = PokeSets.status(of: wide, against: [mk(model: "787-9", manufacturer: "BOEING")])
        let entry = result.first { $0.0.id == "w-787" }
        #expect(entry != nil)
        if case .caught = entry!.1 { /* good */ } else {
            Issue.record("787 slot didn't fill from a Boeing 787-9 catch")
        }
        // Other wide slots stay locked.
        let other = result.first { $0.0.id == "w-a380" }!
        if case .locked = other.1 { /* good */ } else {
            Issue.record("A380 slot incorrectly marked caught")
        }
    }

    @Test func a380FillsWideBodyA380Slot() {
        let wide = PokeSets.all.first { $0.id == "wide" }!
        let result = PokeSets.status(of: wide, against: [mk(model: "A380-800", manufacturer: "AIRBUS")])
        let entry = result.first { $0.0.id == "w-a380" }!
        if case .caught = entry.1 { /* good */ } else {
            Issue.record("A380 slot didn't fill")
        }
    }

    @Test func progressCountsCaughtSlots() {
        let wide = PokeSets.all.first { $0.id == "wide" }!
        let catches: [Catch] = [
            mk(model: "787-9"),
            mk(model: "A350-941"),
            mk(model: "777-300ER"),
        ]
        let progress = PokeSets.progress(of: wide, against: catches)
        #expect(progress.caught == 3)
        #expect(progress.total == wide.entries.count)
    }

    @Test func wrongSetWontFill() {
        // A 737 should fill a narrow slot, not a wide slot.
        let wide = PokeSets.all.first { $0.id == "wide" }!
        let result = PokeSets.status(of: wide, against: [mk(model: "737-800", manufacturer: "BOEING")])
        #expect(result.allSatisfy { if case .locked = $0.1 { return true } else { return false } })

        let narrow = PokeSets.all.first { $0.id == "narrow" }!
        let narrowResult = PokeSets.status(of: narrow, against: [mk(model: "737-800")])
        let entry737 = narrowResult.first { $0.0.id == "n-737-800" }!
        if case .caught = entry737.1 { /* good */ } else {
            Issue.record("737 didn't fill narrow 737-800 slot")
        }
    }

    @Test func caseInsensitiveModelMatching() {
        // Substring match folds case.
        let narrow = PokeSets.all.first { $0.id == "narrow" }!
        let lower = PokeSets.status(of: narrow, against: [mk(model: "737-800")])
        let upper = PokeSets.status(of: narrow, against: [mk(model: "BOEING 737-800")])
        let lowerCaught = lower.first { $0.0.id == "n-737-800" }!
        let upperCaught = upper.first { $0.0.id == "n-737-800" }!
        if case .caught = lowerCaught.1, case .caught = upperCaught.1 {
            // both filled
        } else {
            Issue.record("Case-insensitive match failed")
        }
    }

    @Test func setIDsAreUnique() {
        let setIDs = PokeSets.all.map(\.id)
        #expect(Set(setIDs).count == setIDs.count, "Duplicate PokeSet id(s)")
        for set in PokeSets.all {
            let entryIDs = set.entries.map(\.id)
            #expect(Set(entryIDs).count == entryIDs.count,
                    "Duplicate entry id(s) in set \(set.id)")
        }
    }
}

@Suite("MultiCatchReveal combo")
struct MultiCatchComboTests {

    @Test func multiplierLadder() {
        #expect(MultiCatchReveal.comboMultiplier(for: 1) == 1.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 2) == 1.5)
        #expect(MultiCatchReveal.comboMultiplier(for: 3) == 2.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 4) == 2.5)
        #expect(MultiCatchReveal.comboMultiplier(for: 5) == 3.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 9) == 3.0)
    }

    @Test func sub2IsIdentity() {
        // Defensive against a bad caller — fan-of-1 shouldn't bonus.
        #expect(MultiCatchReveal.comboMultiplier(for: 0) == 1.0)
        #expect(MultiCatchReveal.comboMultiplier(for: 1) == 1.0)
    }
}
