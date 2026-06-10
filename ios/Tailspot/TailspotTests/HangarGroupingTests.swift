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
        caughtAt: Date = Date(),
        typecode: String? = nil
    ) -> Catch {
        Catch(
            icao24: icao,
            callsign: callsign,
            model: model,
            manufacturer: manufacturer,
            operatorName: operatorName,
            caughtAt: caughtAt,
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: typecode
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
        // Alphabetical → Airbus A320 before Boeing 737-800.
        #expect(groups[0].title == "Airbus A320")
        #expect(groups[0].rows.count == 1)
        #expect(groups[1].title == "Boeing 737-800")
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
        #expect(titles.contains("Boeing"))
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

    @Test func hangarRowFirstCatchIsEarliestInAllCatches() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let groups = HangarGrouping.group([
            makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(120)),
            makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0),
            makeCatch(icao: "x", manufacturer: "BOEING", model: "737", caughtAt: t0.addingTimeInterval(60)),
        ], by: .aircraftType)

        let row = groups[0].rows[0]
        #expect(row.icao24 == "x")
        #expect(row.firstCatch.caughtAt == t0)
        #expect(row.mostRecent.caughtAt == t0.addingTimeInterval(120))
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

    // MARK: - Recent mode

    @Test func recentModeProducesSingleGroupWithDedupedRowsByRecency() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let groups = HangarGrouping.group([
            // Three icaos across two manufacturers — recent mode flattens.
            makeCatch(icao: "old", manufacturer: "AIRBUS", model: "A320", caughtAt: t0),
            makeCatch(icao: "new", manufacturer: "BOEING", model: "737",  caughtAt: t0.addingTimeInterval(120)),
            makeCatch(icao: "mid", manufacturer: "EMBRAER", model: "E175", caughtAt: t0.addingTimeInterval(60)),
            // Two repeats of "new" — should dedupe into ×3.
            makeCatch(icao: "new", manufacturer: "BOEING", model: "737",  caughtAt: t0.addingTimeInterval(90)),
            makeCatch(icao: "new", manufacturer: "BOEING", model: "737",  caughtAt: t0.addingTimeInterval(30)),
        ], by: .recent)

        #expect(groups.count == 1)
        let g = groups[0]
        #expect(g.title == HangarGrouping.recentTitle)
        #expect(g.id == HangarGrouping.recentTitle)
        // 3 unique icaos → 3 rows.
        #expect(g.rows.count == 3)
        // Sorted most-recent-first by each row's mostRecent.caughtAt.
        #expect(g.rows.map(\.icao24) == ["new", "mid", "old"])
        #expect(g.rows[0].count == 3)
        #expect(g.rows[1].count == 1)
        #expect(g.rows[2].count == 1)
    }

    @Test func recentModeEmptyInputReturnsEmptyArray() {
        let groups = HangarGrouping.group([], by: .recent)
        #expect(groups.isEmpty)
    }

    @Test func recentModeIgnoresGroupingKeyFields() {
        // Even if every catch lacks manufacturer/operator (would land in
        // Unknown buckets in the other modes), recent mode flattens
        // them all into one group keyed only by recency.
        let groups = HangarGrouping.group([
            makeCatch(icao: "a", manufacturer: nil, model: nil, operatorName: nil),
            makeCatch(icao: "b", manufacturer: nil, model: nil, operatorName: nil),
        ], by: .recent)

        #expect(groups.count == 1)
        #expect(groups[0].title == HangarGrouping.recentTitle)
        #expect(groups[0].rows.count == 2)
    }

    // MARK: - resolveSlots

    @Test func resolveSlotsForSetGroupsCaughtTailsByEntry() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        // Two 737s (different tails), one A320, plus one wide-body 747
        // that should NOT land in any narrow-body slot — sets are a
        // curated lens, not a universal bucket.
        let catches = [
            makeCatch(icao: "boeing1", manufacturer: "BOEING", model: "737-800", caughtAt: t0),
            makeCatch(icao: "boeing2", manufacturer: "BOEING", model: "737-800", caughtAt: t0.addingTimeInterval(60)),
            makeCatch(icao: "airbus1", manufacturer: "AIRBUS", model: "A320",    caughtAt: t0.addingTimeInterval(30)),
            makeCatch(icao: "wide747", manufacturer: "BOEING", model: "747-400", caughtAt: t0.addingTimeInterval(90)),
        ]
        let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
        #expect(rows.count == 4)

        // Find the narrow-body set in CardSets.all.
        guard let narrow = CardSets.all.first(where: { $0.type == .narrow }) else {
            Issue.record("No narrow-body set declared in CardSets.all")
            return
        }

        let slots = HangarGrouping.resolveSlots(for: narrow, in: rows)
        #expect(slots.count == narrow.entries.count)

        // The 737-800 slot has 2 distinct tails.
        let b737 = slots.first(where: { $0.entry.modelTokens.contains(where: { $0.localizedCaseInsensitiveContains("737") }) })
        #expect(b737?.tails.count == 2)

        // The A320 slot has 1.
        let a320 = slots.first(where: { $0.entry.modelTokens.contains(where: { $0.localizedCaseInsensitiveContains("a320") }) })
        #expect(a320?.tails.count == 1)

        // Unmatched rows (the 747) are dropped from the result — no
        // narrow-body slot should contain a tail with that icao24.
        let allTailIcaos = slots.flatMap { $0.tails.map(\.icao24) }
        #expect(!allTailIcaos.contains("wide747"))
    }

    // MARK: - Canonical naming integration

    @Test func customerCodeVariantsCollapseIntoOneGroup() {
        // Same airframe model, two airlines, two customer codes —
        // must be ONE group keyed by the canonical name.
        let groups = HangarGrouping.group([
            makeCatch(icao: "s1", manufacturer: "BOEING", model: "737-8H4"),
            makeCatch(icao: "u1", manufacturer: "BOEING", model: "737-824"),
        ], by: .aircraftType)

        #expect(groups.count == 1)
        #expect(groups[0].title == "Boeing 737-800")
        #expect(groups[0].rows.count == 2)
    }

    @Test func typecodeDrivesGroupTitleWhenPresent() {
        let groups = HangarGrouping.group([
            makeCatch(icao: "w1", manufacturer: "BOEING", model: "777-322ER", typecode: "B77W"),
        ], by: .aircraftType)
        #expect(groups[0].title == "Boeing 777-300ER")
    }

    @Test func unknownModelGroupSortsLastInModelGroups() {
        // Unknown has MORE tails than the named group — under the old
        // count-desc-first sort it landed on top. It must pin to the end.
        //
        // Build entirely within the .ga type (the default for unknown
        // aircraft) so the type filter works cleanly: three no-name catches
        // (→ Unknown group, 3 tails) plus one named Cessna 172 (→ named
        // group, 1 tail). Both are GA so they appear in the same
        // modelGroups call. Without the pin, Unknown's count of 3 would
        // sort before the named group's count of 1.
        let catches = [
            // Three anonymous catches — no make/model → Unknown, type → ga.
            makeCatch(icao: "x1"),
            makeCatch(icao: "x2"),
            makeCatch(icao: "x3"),
            // One named GA aircraft — Cessna + "172" → .ga via classifier.
            makeCatch(icao: "c1", manufacturer: "Cessna", model: "172"),
        ]
        let rows = HangarGrouping.group(catches, by: .recent).first?.rows ?? []
        // All four rows should be .ga. Provide .ga explicitly to avoid
        // relying on rows.first's ordering.
        let gaRows = rows.filter { $0.aircraftType == .ga }
        let groups = HangarGrouping.modelGroups(in: gaRows, type: .ga)

        // Unknown group must sort last, not first (even though it has 3 tails).
        #expect(groups.last?.model == HangarGrouping.unknownTitle,
                "Unknown group must sort last, got: \(groups.map(\.model))")
    }

    // MARK: - Space-variant and engine-code styles collapse into one group

    /// Old catches (no typecode) with space-style ("A380 842") or raw
    /// engine-code suffix ("A380-861") must collapse into the same
    /// group as a catch with typecode A388 (which resolves via the
    /// DOC 8643 table to "Airbus A380-800"). All three → ONE group.
    @Test func spaceAndVariantStylesCollapseIntoOneGroup() {
        let groups = HangarGrouping.group([
            // Old catch — space style, no typecode
            makeCatch(icao: "a1", manufacturer: "AIRBUS", model: "A380 842"),
            // Old catch — dash + engine code, no typecode
            makeCatch(icao: "a2", manufacturer: "AIRBUS", model: "A380-861"),
            // New catch — typecode present, resolves via table
            makeCatch(icao: "a3", manufacturer: "AIRBUS", model: "A380-861", typecode: "A388"),
        ], by: .aircraftType)

        #expect(groups.count == 1, "Expected 1 group, got \(groups.count): \(groups.map(\.title))")
        #expect(groups[0].title == "Airbus A380-800")
        #expect(groups[0].rows.count == 3)
    }
}
