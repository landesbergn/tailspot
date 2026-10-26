//
//  TypeHistoryTests.swift
//  TailspotTests
//
//  "You and this type" on the back of the catch card: the first-caught date
//  and the catch log (catches per operator, via the shared operator label),
//  matched by CardSetEntry with a same-typecode fallback when none matches.
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

    @Test func firstCaughtIsTheEarliestCatchOfTheSameEntry() {
        let shown = mk("a00001", typecode: "B738", callsign: "UAL100", minutes: 50)
        let all = [
            shown,
            mk("a00001", typecode: "B738", callsign: "UAL200", minutes: 30),
            mk("a00002", typecode: "B738", callsign: "SWA300", minutes: 10),  // earliest
            mk("a00003", typecode: "B738", callsign: "UAL400", minutes: 20),
            mk("a00004", typecode: "A20N", callsign: "UAL500", minutes: 5),   // other type
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(10 * 60))
        #expect(h.airlines.map(\.count).reduce(0, +) == 4)
    }

    @Test func maxCatchesWithA737DashEightModelDontCountAs737_800s() {
        // A B38M whose raw model reads "737-8" token-matches the 737-800
        // slot, but TypeInfoStore resolves it to the MAX 8 (exact typecode
        // first), so it must not show up in the 737-800 card's log.
        let shown = mk("d00001", typecode: "B738", callsign: "UAL1")
        let all = [
            shown,
            mk("d00002", typecode: "B38M", model: "737-8", callsign: "SWA2"),
            mk("d00003", typecode: "B38M", model: "737-8 MAX", callsign: "SWA3"),
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.airlines == [.init(name: "United Airlines", count: 1)])

        let max = TypeHistory.compute(for: all[1], in: all)
        #expect(max.airlines == [.init(name: "Southwest Airlines", count: 2)])
    }

    @Test func logsCatchesPerOperatorSortedByCountThenName() {
        let shown = mk("b00001", typecode: "B738", callsign: "UAL1")
        let all = [
            shown,
            mk("b00001", typecode: "B738", callsign: "UAL2"),          // same jet again: a second catch
            mk("b00002", typecode: "B738", callsign: "UAL3"),
            mk("b00003", typecode: "B738", callsign: "SWA4"),
            mk("b00004", typecode: "B738", callsign: "DAL5"),
            mk("b00005", typecode: "B738", callsign: "N738XX"),        // GA reg → "Private"
            mk("b00006", typecode: "B738", callsign: "ZQX9",
               operatorName: "Southwest Airlines"),                    // recorded operator wins
            mk("b00007", typecode: "B738", callsign: "QQQ123"),        // unknown airline: omitted
            mk("b00008", typecode: "B738"),                            // no operator, no callsign: omitted
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.airlines == [
            .init(name: "United Airlines", count: 3),
            .init(name: "Southwest Airlines", count: 2),
            .init(name: "Delta Air Lines", count: 1),
            .init(name: "Private", count: 1),
        ])
    }

    @Test func countsTheShownCatchEvenWhenTheListPredatesIt() {
        let shown = mk("d00001", typecode: "B738", callsign: "UAL9", minutes: 99)
        let h = TypeHistory.compute(for: shown, in: [mk("d00002", typecode: "B738", minutes: 1)])
        #expect(h.firstCaughtAt == t0.addingTimeInterval(60))
        #expect(h.airlines == [.init(name: "United Airlines", count: 1)])
    }

    @Test func noEntryFallsBackToSameTypecode() {
        // ZZZZ resolves to no CardSetEntry.
        let shown = mk("e00001", typecode: "ZZZZ", callsign: "UAL7", minutes: 40)
        let all = [
            shown,
            mk("e00002", typecode: "zzzz", callsign: "UAL8", minutes: 20),   // case-insensitive
            mk("e00002", typecode: "ZZZZ", minutes: 30),                      // no operator: not logged
            mk("e00003", typecode: "B738", callsign: "UAL1", minutes: 1),     // different type
        ]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(20 * 60))
        #expect(h.airlines == [.init(name: "United Airlines", count: 2)])
    }

    @Test func noEntryNoTypecodeIsJustThisAirframe() {
        let shown = mk("f00001", typecode: nil, callsign: "UAL1", minutes: 5)
        let all = [shown, mk("f00001", typecode: nil, callsign: "UAL2", minutes: 2),
                   mk("f00002", typecode: nil, callsign: "UAL3")]
        let h = TypeHistory.compute(for: shown, in: all)
        #expect(h.firstCaughtAt == t0.addingTimeInterval(2 * 60))
        #expect(h.airlines == [.init(name: "United Airlines", count: 2)])
    }
}
