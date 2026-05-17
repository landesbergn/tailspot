//
//  HangarGroupingTests.swift
//  TailspotTests
//
//  Pure-function tests for HangarGrouping. No SwiftData container
//  needed — we construct Catch instances directly and feed them in.
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
        let groups = HangarGrouping.group([
            makeCatch(manufacturer: "BOEING", model: "737-800"),
            makeCatch(manufacturer: "AIRBUS", model: "A320"),
            makeCatch(manufacturer: "BOEING", model: "737-800"),
        ], by: .aircraftType)

        #expect(groups.count == 2)
        // Alphabetical → AIRBUS A320 before BOEING 737-800.
        #expect(groups[0].title == "AIRBUS A320")
        #expect(groups[0].catches.count == 1)
        #expect(groups[1].title == "BOEING 737-800")
        #expect(groups[1].catches.count == 2)
    }

    @Test func aircraftTypeFallsBackToManufacturerOrModelOrUnknown() {
        let groups = HangarGrouping.group([
            makeCatch(manufacturer: "BOEING", model: nil),
            makeCatch(manufacturer: nil, model: "A320"),
            makeCatch(manufacturer: nil, model: nil),
            makeCatch(manufacturer: "", model: ""),
        ], by: .aircraftType)

        let titles = groups.map(\.title)
        #expect(titles.contains("BOEING"))
        #expect(titles.contains("A320"))
        // Two catches collapsed into the Unknown bucket (nil/nil and ""/"").
        let unknown = groups.first(where: { $0.title == HangarGrouping.unknownTitle })
        #expect(unknown?.catches.count == 2)
    }

    @Test func unknownGroupSortsToTheEnd() {
        let groups = HangarGrouping.group([
            makeCatch(manufacturer: nil, model: nil),
            makeCatch(manufacturer: "AIRBUS", model: "A320"),
            makeCatch(manufacturer: "BOEING", model: "737"),
        ], by: .aircraftType)

        #expect(groups.last?.title == HangarGrouping.unknownTitle)
    }

    @Test func catchesWithinAGroupAreSortedMostRecentFirst() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let groups = HangarGrouping.group([
            makeCatch(icao: "a", manufacturer: "BOEING", model: "737", caughtAt: t0),
            makeCatch(icao: "b", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(60)),
            makeCatch(icao: "c", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(30)),
        ], by: .aircraftType)

        let icaos = groups.first?.catches.map(\.icao24) ?? []
        #expect(icaos == ["b", "c", "a"])
    }

    @Test func emptyInputReturnsEmptyArray() {
        let groups = HangarGrouping.group([], by: .aircraftType)
        #expect(groups.isEmpty)
    }

    @Test func airlineModeGroupsByOperatorName() {
        let groups = HangarGrouping.group([
            makeCatch(operatorName: "United Airlines"),
            makeCatch(operatorName: "Delta Air Lines"),
            makeCatch(operatorName: "United Airlines"),
            makeCatch(operatorName: nil),
        ], by: .airline)

        #expect(groups.count == 3)
        #expect(groups[0].title == "Delta Air Lines")
        #expect(groups[1].title == "United Airlines")
        #expect(groups[1].catches.count == 2)
        #expect(groups.last?.title == HangarGrouping.unknownTitle)
    }

    @Test func airlineModeTrimsWhitespaceAndFoldsEmpty() {
        let groups = HangarGrouping.group([
            makeCatch(operatorName: "  United Airlines  "),
            makeCatch(operatorName: ""),
            makeCatch(operatorName: "   "),
        ], by: .airline)

        // The two blank-strings collapse into Unknown alongside any nil.
        let united = groups.first(where: { $0.title == "United Airlines" })
        let unknown = groups.first(where: { $0.title == HangarGrouping.unknownTitle })
        #expect(united?.catches.count == 1)
        #expect(unknown?.catches.count == 2)
    }
}
