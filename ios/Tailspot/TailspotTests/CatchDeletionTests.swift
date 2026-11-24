//
//  CatchDeletionTests.swift
//  TailspotTests
//
//  A Hangar delete removes only the catch on screen, never the earlier
//  catches of the same airframe (2026-11-05).
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Catch deletion")
@MainActor
struct CatchDeletionTests {

    private func makeCatch(callsign: String, caughtAt: Date, serverUuid: String?) -> Catch {
        let c = Catch(
            icao24: "a1b2c3",
            callsign: callsign,
            model: "737-7H4",
            manufacturer: "BOEING",
            operatorName: "Southwest Airlines",
            caughtAt: caughtAt,
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: "B737"
        )
        c.serverUuid = serverUuid
        return c
    }

    @Test func deletesOnlyTheShownCatchOfAReCaughtAirframe() throws {
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        TestContainerRetention.retain(container)
        let context = ModelContext(container)

        let july = makeCatch(callsign: "SWA4842",
                             caughtAt: Date(timeIntervalSince1970: 1_784_840_000),
                             serverUuid: "JULY-UUID")
        let november = makeCatch(callsign: "SWA503",
                                 caughtAt: Date(timeIntervalSince1970: 1_793_900_000),
                                 serverUuid: "NOV-UUID")
        context.insert(july)
        context.insert(november)
        try context.save()

        let row = HangarGrouping.group(try context.fetch(FetchDescriptor<Catch>()), by: .recent)
            .flatMap(\.rows)[0]
        #expect(row.mostRecent.callsign == "SWA503")

        var remote: [[String]] = []
        let saved = CatchDeletion.delete(row.mostRecent, in: context) { remote.append($0) }

        #expect(saved)
        let left = try context.fetch(FetchDescriptor<Catch>())
        #expect(left.map(\.callsign) == ["SWA4842"])
        // Only the deleted catch's server copy is removed.
        #expect(remote == [["NOV-UUID"]])
    }

    @Test func unsyncedCatchSendsNoServerDelete() throws {
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        TestContainerRetention.retain(container)
        let context = ModelContext(container)
        let c = makeCatch(callsign: "SWA503", caughtAt: .now, serverUuid: nil)
        context.insert(c)
        try context.save()

        var remote: [[String]] = []
        CatchDeletion.delete(c, in: context) { remote.append($0) }

        #expect(try context.fetch(FetchDescriptor<Catch>()).isEmpty)
        #expect(remote.isEmpty)
    }

    @Test func deleteFiresTheEventForTheDeletedCatch() throws {
        // Both delete buttons go through here, so the event can't be
        // forgotten on one of them again (the long-press menu sent none).
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        TestContainerRetention.retain(container)
        let context = ModelContext(container)
        let c = makeCatch(callsign: "SWA503",
                          caughtAt: Date(timeIntervalSince1970: 1_793_900_000),
                          serverUuid: "NOV-UUID")
        context.insert(c)
        try context.save()

        var fired: [String] = []
        CatchDeletion.delete(c, in: context,
                             deleteRemotely: { _ in },
                             fireEvent: { fired.append($0.callsign ?? "") })

        #expect(fired == ["SWA503"])
    }

    // MARK: - Multi-catch press size

    private func press(uploaded: Bool, size: Int) throws -> (ModelContext, [Catch]) {
        let container = try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        TestContainerRetention.retain(container)
        let context = ModelContext(container)
        let at = Date(timeIntervalSince1970: 1_790_000_000.4567)
        let rows = (0..<size).map { _ in makeCatch(callsign: "SWA1", caughtAt: at, serverUuid: nil) }
        for row in rows {
            row.pressSize = size
            if uploaded { row.uploadedAt = at }
            context.insert(row)
        }
        try context.save()
        return (context, rows)
    }

    @Test func deletingAnUnuploadedPlaneShrinksThePress() throws {
        let (context, rows) = try press(uploaded: false, size: 3)
        CatchDeletion.delete(rows[0], in: context, deleteRemotely: { _ in }, fireEvent: { _ in })
        #expect(rows[1].pressSize == 2)
        #expect(rows[2].pressSize == 2)
        CatchDeletion.delete(rows[1], in: context, deleteRemotely: { _ in }, fireEvent: { _ in })
        #expect(rows[2].pressSize == nil)
    }

    @Test func deletingAnUploadedPlaneKeepsTheOthersBonus() throws {
        let (context, rows) = try press(uploaded: true, size: 2)
        CatchDeletion.delete(rows[0], in: context, deleteRemotely: { _ in }, fireEvent: { _ in })
        #expect(rows[1].pressSize == 2)
    }
}
