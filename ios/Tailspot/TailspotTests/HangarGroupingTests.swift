//
//  HangarGroupingTests.swift
//  TailspotTests
//
//  Pure-function tests for HangarGrouping. No SwiftData container
//  needed — we construct Catch instances directly and feed them in.
//
//  v1 update: groups now contain `rows: [HangarRow]` (deduped by
//  icao24) rather than `catches: [Catch]`. Each row carries the
//  count + the full underlying list for delete-all semantics.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Hangar grouping")
@MainActor
struct HangarGroupingTests {

    /// Convenience factory; only the fields relevant to grouping are
    /// parameterized — the rest get filler values that no test inspects.
    private func makeCatch(
        icao: String = "abc123",
        callsign: String? = nil,
        manufacturer: String? = nil,
        model: String? = nil,
        operatorName: String? = nil,
        caughtAt: Date = Date()
    ) -> Catch {
        Catch(
            icao24: icao,
            callsign: callsign,
            model: model,
            manufacturer: manufacturer,
            operatorName: operatorName,
            caughtAt: caughtAt,
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0
        )
    }

    @Test func groupsByManufacturerAndModel() {
        // Distinct icaos so dedupe doesn't collapse the two BOEINGs.
        let groups = HangarGrouping.group([
            makeCatch(icao: "b1", manufacturer: "BOEING", model: "737-800"),
            makeCatch(icao: "a1", manufacturer: "AIRBUS", model: "A320"),
            makeCatch(icao: "b2", manufacturer: "BOEING", model: "737-800"),
        ], by: .aircraftType)

        #expect(groups.count == 2)
        // Alphabetical → AIRBUS A320 before BOEING 737-800.
        #expect(groups[0].title == "AIRBUS A320")
        #expect(groups[0].rows.count == 1)
        #expect(groups[1].title == "BOEING 737-800")
        #expect(groups[1].rows.count == 2)
    }

    @Test func aircraftTypeFallsBackToManufacturerOrModelOrUnknown() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "boeing-only", manufacturer: "BOEING", model: nil),
            makeCatch(icao: "a320-only",   manufacturer: nil, model: "A320"),
            makeCatch(icao: "u1",          manufacturer: nil, model: nil),
            makeCatch(icao: "u2",          manufacturer: "",  model: ""),
        ], by: .aircraftType)

        let titles = groups.map(\.title)
        #expect(titles.contains("BOEING"))
        #expect(titles.contains("A320"))
        // Two distinct unknown-keyed planes collapse into the Unknown
        // bucket; each remains its own row since icao24 differs.
        let unknown = groups.first(where: { $0.title == HangarGrouping.unknownTitle })
        #expect(unknown?.rows.count == 2)
    }

    @Test func unknownGroupSortsToTheEnd() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "u",  manufacturer: nil, model: nil),
            makeCatch(icao: "a",  manufacturer: "AIRBUS", model: "A320"),
            makeCatch(icao: "b",  manufacturer: "BOEING", model: "737"),
        ], by: .aircraftType)

        #expect(groups.last?.title == HangarGrouping.unknownTitle)
    }

    @Test func rowsWithinAGroupAreSortedMostRecentFirst() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let groups = HangarGrouping.group([
            makeCatch(icao: "a", manufacturer: "BOEING", model: "737", caughtAt: t0),
            makeCatch(icao: "b", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(60)),
            makeCatch(icao: "c", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(30)),
        ], by: .aircraftType)

        let icaos = groups.first?.rows.map(\.icao24) ?? []
        #expect(icaos == ["b", "c", "a"])
    }

    @Test func emptyInputReturnsEmptyArray() {
        let groups = HangarGrouping.group([], by: .aircraftType)
        #expect(groups.isEmpty)
    }

    @Test func airlineModeGroupsByOperatorName() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "ua1",   operatorName: "United Airlines"),
            makeCatch(icao: "dal1",  operatorName: "Delta Air Lines"),
            makeCatch(icao: "ua2",   operatorName: "United Airlines"),
            makeCatch(icao: "ukn1",  operatorName: nil),
        ], by: .airline)

        #expect(groups.count == 3)
        #expect(groups[0].title == "Delta Air Lines")
        #expect(groups[1].title == "United Airlines")
        #expect(groups[1].rows.count == 2)
        #expect(groups.last?.title == HangarGrouping.unknownTitle)
    }

    @Test func airlineModeTrimsWhitespaceAndFoldsEmpty() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "ua1", operatorName: "  United Airlines  "),
            makeCatch(icao: "u1",  operatorName: ""),
            makeCatch(icao: "u2",  operatorName: "   "),
        ], by: .airline)

        let united = groups.first(where: { $0.title == "United Airlines" })
        let unknown = groups.first(where: { $0.title == HangarGrouping.unknownTitle })
        #expect(united?.rows.count == 1)
        #expect(unknown?.rows.count == 2)
    }

    // MARK: - v1 dedupe

    @Test func dedupesRepeatedCatchesOfSameIcao24() {
        // Three catches of UAL248, three of AAL110 — within the BOEING
        // 737-800 group they collapse into two rows with count = 3 each.
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let groups = HangarGrouping.group([
            makeCatch(icao: "abcdef", callsign: "UAL248", manufacturer: "BOEING", model: "737-800", caughtAt: t0),
            makeCatch(icao: "abcdef", callsign: "UAL248", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(60)),
            makeCatch(icao: "abcdef", callsign: "UAL248", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(30)),
            makeCatch(icao: "fedcba", callsign: "AAL110", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(120)),
            makeCatch(icao: "fedcba", callsign: "AAL110", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(180)),
            makeCatch(icao: "fedcba", callsign: "AAL110", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(150)),
        ], by: .aircraftType)

        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.rows.count == 2)
        // Row with the most recent caughtAt comes first (AAL110 at +180s).
        #expect(g.rows[0].icao24 == "fedcba")
        #expect(g.rows[0].count == 3)
        #expect(g.rows[0].allCatches.count == 3)
        // allCatches is sorted most-recent-first.
        #expect(g.rows[0].mostRecent.caughtAt == t0.addingTimeInterval(180))
        #expect(g.rows[0].allCatches.map(\.caughtAt) == [
            t0.addingTimeInterval(180),
            t0.addingTimeInterval(150),
            t0.addingTimeInterval(120),
        ])

        // UAL248 row.
        #expect(g.rows[1].icao24 == "abcdef")
        #expect(g.rows[1].count == 3)
        #expect(g.rows[1].mostRecent.caughtAt == t0.addingTimeInterval(60))
    }

    @Test func singleCatchProducesRowWithCountOne() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "solo", manufacturer: "BOEING", model: "737"),
        ], by: .aircraftType)

        #expect(groups.count == 1)
        #expect(groups[0].rows.count == 1)
        #expect(groups[0].rows[0].count == 1)
        #expect(groups[0].rows[0].allCatches.count == 1)
    }
}
