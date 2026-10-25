//
//  TypeHistoryTests.swift
//  TailspotTests
//
//  "You and this type" on the back of the catch card. Distinct airframes,
//  first-caught date, airline tallies via the shared operator label, family
//  progress via the Sets tab's matcher, and the same-typecode fallback when
//  no CardSetEntry matches.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Type history")
struct TypeHistoryTests {

    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func mk(_ icao: String, typecode: String?, model: String? = nil,
                    callsign: String? = nil, operatorName: String? = nil,
                    minutes: Double = 0) -> Catch {
        Catch(icao24: icao, callsign: callsign, model: model, manufacturer: nil,
              operatorName: operatorName,
              caughtAt: t0.addingTimeInterval(minutes * 60),
              observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
              typecode: typecode)
    }

    private var fam737: CardSet {
        CardSets.families.first { $0.id == "fam-737" }!
    }

    @Test func countsDistinctAirframesOfTheSameEntry() {
        let shown = mk("a00001", typecode: "B738", callsign: "UAL100", minutes: 50)
        let all = [
            shown,
            mk("a00001", typecode: "B738", callsign: "UAL200", minutes: 30),  // same airframe again
            mk("a00002", typecode: "B738", callsign: "SWA300", minutes: 10),  // earliest
            mk("a00003", typecode: "B738", callsign: "UAL400", minutes: 20),
            mk("a00004", typecode: "A20N", callsign: "UAL500", minutes: 5),   // other type
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.timesCaught == 3)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(10 * 60))
    }

    @Test func maxCatchesWithA737DashEightModelDontCountAs737_800s() {
        // A B38M whose raw model reads "737-8" token-matches the 737-800
        // slot, but TypeInfoStore resolves it to the MAX 8 (exact typecode
        // first), so it must not inflate the 737-800 card's numbers.
        let shown = mk("d00001", typecode: "B738", callsign: "UAL1")
        let all = [
            shown,
            mk("d00002", typecode: "B38M", model: "737-8", callsign: "SWA2"),
            mk("d00003", typecode: "B38M", model: "737-8 MAX", callsign: "SWA3"),
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.timesCaught == 1)
        #expect(h.airlines.map(\.name) == ["United Airlines"])

        let max = TypeHistory.compute(for: all[1], in: all)
        #expect(max.timesCaught == 2)
    }

    @Test func talliesAirlinesByAirframeSortedByCountThenName() {
        let shown = mk("b00001", typecode: "B738", callsign: "UAL1")
        let all = [
            shown,
            mk("b00001", typecode: "B738", callsign: "UAL2"),          // dup airframe: counts once
            mk("b00002", typecode: "B738", callsign: "UAL3"),
            mk("b00003", typecode: "B738", callsign: "SWA4"),
            mk("b00004", typecode: "B738", callsign: "DAL5"),
            mk("b00005", typecode: "B738", callsign: "N738XX"),        // GA reg → "Private"
            mk("b00006", typecode: "B738", callsign: "ZQX9",
               operatorName: "Southwest Airlines"),                    // recorded operator wins
            mk("b00007", typecode: "B738", callsign: "QQQ123"),        // unknown airline: omitted
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.airlines == [
            .init(name: "Southwest Airlines", count: 2),
            .init(name: "United Airlines", count: 2),
            .init(name: "Delta Air Lines", count: 1),
            .init(name: "Private", count: 1),
        ])
        #expect(h.timesCaught == 7)
    }

    @Test func familyProgressMatchesTheSetsTab() {
        let shown = mk("c00001", typecode: "B738")
        let all = [
            shown,
            mk("c00002", typecode: "B739"),
            mk("c00003", typecode: "B739"),
            mk("c00004", typecode: "A20N"),
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.familyTitle == "Boeing 737")
        #expect(h.variantsTotal == fam737.entries.count)
        #expect(h.variantsCaught == 2)
        let sets = CardSets.progress(of: fam737, against: all)
        #expect(h.variantsCaught == sets.caught)
        #expect(h.variantsTotal == sets.total)
    }

    @Test func countsTheShownCatchEvenWhenTheListPredatesIt() {
        let shown = mk("d00001", typecode: "B738", callsign: "UAL9", minutes: 99)
        let h = TypeHistory.compute(for: shown, in: [mk("d00002", typecode: "B738", minutes: 1)])
        #expect(h.timesCaught == 2)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(60))
        #expect(h.variantsCaught == 1)
        #expect(h.airlines.contains(.init(name: "United Airlines", count: 1)))
    }

    @Test func noEntryFallsBackToSameTypecode() {
        // ZZZZ resolves to nothing: no CardSetEntry, no family.
        let shown = mk("e00001", typecode: "ZZZZ", callsign: "UAL7", minutes: 40)
        let all = [
            shown,
            mk("e00002", typecode: "zzzz", callsign: "UAL8", minutes: 20),   // case-insensitive
            mk("e00002", typecode: "ZZZZ", minutes: 30),                      // dup airframe
            mk("e00003", typecode: "B738", minutes: 1),                       // different type
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.familyTitle == nil)
        #expect(h.variantsCaught == 0)
        #expect(h.variantsTotal == 0)
        #expect(h.timesCaught == 2)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(20 * 60))
        #expect(h.airlines == [.init(name: "United Airlines", count: 2)])
    }

    @Test func noEntryNoTypecodeIsJustThisAirframe() {
        let shown = mk("f00001", typecode: nil, minutes: 5)
        let all = [shown, mk("f00001", typecode: nil, minutes: 2), mk("f00002", typecode: nil)]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.timesCaught == 1)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(2 * 60))
        #expect(h.familyTitle == nil)
    }
}
