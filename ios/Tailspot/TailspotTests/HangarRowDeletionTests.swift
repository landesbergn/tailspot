//
//  HangarRowDeletionTests.swift
//  TailspotTests
//
//  The shared Hangar delete (both delete buttons call it): it fires the
//  delete event, removes every catch in the row, and queues every server
//  uuid for the server delete.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Hangar row deletion")
@MainActor
struct HangarRowDeletionTests {

    @Test func deleteFiresTheEventRemovesTheCatchesAndQueuesTheServerDelete() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        let context = ModelContext(container)

        func make(_ uuid: String?, at t: Double) -> Catch {
            let c = Catch(icao24: "abc123", callsign: nil, model: nil, manufacturer: nil,
                          caughtAt: Date(timeIntervalSince1970: t),
                          observerLat: 0, observerLon: 0, slantDistanceMeters: 0)
            c.serverUuid = uuid
            context.insert(c)
            return c
        }
        let older = make("UUID-A", at: 100)
        let newer = make("UUID-B", at: 200)
        let unsent = make(nil, at: 300)
        let keep = make("UUID-KEEP", at: 400)
        keep.icao24 = "def456"
        try context.save()

        let row = HangarRow(icao24: "abc123", mostRecent: unsent, count: 3,
                            allCatches: [unsent, newer, older])
        var events: [HangarRow] = []
        var queued: [[String]] = []

        try HangarRowDeletion.delete(row, context: context,
                                     fireEvent: { events.append($0) },
                                     deleteRemotely: { queued.append($0) })

        #expect(events.map(\.icao24) == ["abc123"])
        #expect(queued == [["UUID-B", "UUID-A"]])
        let left = try context.fetch(FetchDescriptor<Catch>())
        #expect(left.map(\.icao24) == ["def456"])
    }
}
