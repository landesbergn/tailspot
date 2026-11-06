//
//  HangarReconcileTests.swift
//  TailspotTests
//
//  The one-time server cleanup for pre-#295 Hangar deletes:
//    - the plan: which server rows count as deleted (uuid absent, caught at
//      or after the oldest Hangar catch, not already in the delete ledger),
//      case folding, and the more-than-half refusal;
//    - the launch run: deletes + one analytics event, the latch, and every
//      guard that must skip without deleting (empty Hangar, restore up,
//      network failure, no token).
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Hangar reconcile")
@MainActor
struct HangarReconcileTests {

    private typealias Row = HangarReconcile.ServerCatch

    private func uuid(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }

    // MARK: - Plan

    @Test func deletesOnlyServerRowsMissingFromTheHangar() {
        let server = (1...6).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(1), uuid(2), uuid(4), uuid(6)],
            oldestLocalCaughtAt: 101,
            alreadyDeleted: []
        )
        #expect(plan == .delete([uuid(3), uuid(5)]))
    }

    @Test func rowsOlderThanTheOldestHangarCatchAreLeftAlone() {
        // A reinstall that skipped restore: rows 1-3 are from the old install.
        let server = (1...6).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(4), uuid(6)],
            oldestLocalCaughtAt: 104,
            alreadyDeleted: []
        )
        #expect(plan == .delete([uuid(5)]))
    }

    @Test func comparisonIgnoresCase() {
        // Local uuids are minted uppercase; the server returns lowercase.
        let server = [Row(uuid: "abcdef01-0000-4000-8000-000000000001", caughtAt: 10),
                      Row(uuid: "abcdef01-0000-4000-8000-000000000002", caughtAt: 11),
                      Row(uuid: "abcdef01-0000-4000-8000-000000000003", caughtAt: 12)]
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: ["ABCDEF01-0000-4000-8000-000000000001", "ABCDEF01-0000-4000-8000-000000000002"],
            oldestLocalCaughtAt: 10,
            alreadyDeleted: []
        )
        #expect(plan == .delete(["abcdef01-0000-4000-8000-000000000003"]))
    }

    @Test func ledgerDeletesAreNotCountedAgain() {
        let server = (1...4).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(1), uuid(2)],
            oldestLocalCaughtAt: 101,
            alreadyDeleted: [uuid(3).uppercased(), uuid(4)]
        )
        #expect(plan == .nothing)
    }

    @Test func refusesWhenMoreThanHalfWouldGo() {
        let server = (1...5).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(1), uuid(2)],
            oldestLocalCaughtAt: 101,
            alreadyDeleted: []
        )
        #expect(plan == .tooMany(orphans: 3))
    }

    @Test func exactlyHalfStillDeletes() {
        let server = (1...4).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(1), uuid(2)],
            oldestLocalCaughtAt: 101,
            alreadyDeleted: []
        )
        #expect(plan == .delete([uuid(3), uuid(4)]))
    }

    @Test func duplicateServerRowsCountOnce() {
        let server = [Row(uuid: uuid(1), caughtAt: 101), Row(uuid: uuid(2), caughtAt: 102),
                      Row(uuid: uuid(3), caughtAt: 103), Row(uuid: uuid(3), caughtAt: 103)]
        let plan = HangarReconcile.plan(
            server: server,
            localUuids: [uuid(1), uuid(2)],
            oldestLocalCaughtAt: 101,
            alreadyDeleted: []
        )
        #expect(plan == .delete([uuid(3)]))
    }

    // MARK: - Launch run

    private final class Recorder {
        var sent: [[String]] = []
        var events: [(String, [String: AnalyticsValue])] = []
        var fetches = 0
    }

    private func makeDefaults() -> UserDefaults {
        let name = "HangarReconcileTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func makeContext(localUuids: [String], caughtAt: [Double]) throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        let context = ModelContext(container)
        for (u, t) in zip(localUuids, caughtAt) {
            let c = Catch(icao24: "aaaaaa", callsign: nil, model: nil, manufacturer: nil,
                          caughtAt: Date(timeIntervalSince1970: t),
                          observerLat: 0, observerLon: 0, slantDistanceMeters: 0)
            c.serverUuid = u.uppercased()
            context.insert(c)
        }
        try context.save()
        return context
    }

    private func makeManager(
        defaults: UserDefaults,
        server: [Row],
        recorder: Recorder,
        fail: Bool = false,
        token: Bool = true,
        ledger: Set<String> = []
    ) -> HangarReconcileManager {
        HangarReconcileManager(
            defaults: defaults,
            hasToken: { token },
            fetchPage: { limit, offset in
                recorder.fetches += 1
                if fail { throw URLError(.notConnectedToInternet) }
                let slice = Array(server.dropFirst(offset).prefix(limit))
                return (slice, server.count)
            },
            deletedLedger: { ledger },
            sendDeletes: { recorder.sent.append($0) },
            capture: { recorder.events.append(($0, $1)) }
        )
    }

    @Test func runDeletesOrphansReportsAndLatches() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let server = (1...4).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let context = try makeContext(localUuids: [uuid(1), uuid(2), uuid(4)], caughtAt: [101, 102, 104])
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.sent == [[uuid(3)]])
        #expect(recorder.events.count == 1)
        #expect(recorder.events.first?.0 == "hangar_reconciled")
        #expect(recorder.events.first?.1["orphans"]?.jsonValue as? Int == 1)
        #expect(recorder.events.first?.1["outcome"]?.jsonValue as? String == "deleted")
        #expect(recorder.events.first?.1["server_total"]?.jsonValue as? Int == 4)
        #expect(recorder.events.first?.1["local_total"]?.jsonValue as? Int == 3)
        #expect(defaults.bool(forKey: HangarReconcileManager.doneKey))

        // A second manager on the same install does nothing.
        let again = makeManager(defaults: defaults, server: server, recorder: recorder)
        await again.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)
        #expect(recorder.fetches == 1)
        #expect(recorder.sent.count == 1)
    }

    @Test func pagesThroughTheWholeServerList() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let server = (1...1_200).map { Row(uuid: uuid($0), caughtAt: Double($0)) }
        let local = (1...1_199).map { uuid($0) }
        let context = try makeContext(localUuids: local, caughtAt: (1...1_199).map(Double.init))
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.fetches == 3)
        #expect(recorder.sent == [[uuid(1_200)]])
    }

    @Test func emptyHangarSkipsWithoutLatching() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let server = (1...3).map { Row(uuid: uuid($0), caughtAt: Double($0)) }
        let context = try makeContext(localUuids: [], caughtAt: [])
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.sent.isEmpty)
        #expect(recorder.events.isEmpty)
        #expect(!defaults.bool(forKey: HangarReconcileManager.doneKey))
    }

    @Test func restorePromptSkipsWithoutLatching() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let server = (1...3).map { Row(uuid: uuid($0), caughtAt: Double($0)) }
        let context = try makeContext(localUuids: [uuid(1), uuid(2)], caughtAt: [1, 2])
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { true }, tokenWaitSeconds: 0)

        #expect(recorder.fetches == 0)
        #expect(recorder.sent.isEmpty)
        #expect(!defaults.bool(forKey: HangarReconcileManager.doneKey))
    }

    @Test func networkFailureSkipsWithoutLatching() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let context = try makeContext(localUuids: [uuid(1)], caughtAt: [1])
        let manager = makeManager(defaults: defaults, server: [], recorder: recorder, fail: true)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.sent.isEmpty)
        #expect(recorder.events.isEmpty)
        #expect(!defaults.bool(forKey: HangarReconcileManager.doneKey))
    }

    @Test func noTokenSkipsWithoutFetching() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let context = try makeContext(localUuids: [uuid(1)], caughtAt: [1])
        let manager = makeManager(defaults: defaults, server: [], recorder: recorder, token: false)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.fetches == 0)
        #expect(!defaults.bool(forKey: HangarReconcileManager.doneKey))
    }

    @Test func operatorCreditedRowsAreNeverDeleted() async throws {
        // MissedCatchRepair's rows may still be on their way into the Hangar.
        let defaults = makeDefaults()
        let recorder = Recorder()
        let repair = MissedCatchRepair.repairableUUIDs.sorted()
        let server = [Row(uuid: uuid(1), caughtAt: 101), Row(uuid: uuid(2), caughtAt: 102),
                      Row(uuid: uuid(3), caughtAt: 103), Row(uuid: uuid(4), caughtAt: 104)]
            + repair.map { Row(uuid: $0, caughtAt: 200) }
        let context = try makeContext(localUuids: [uuid(1), uuid(2), uuid(3)], caughtAt: [101, 102, 103])
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.sent == [[uuid(4)]])
    }

    @Test func tooManyReportsLatchesAndDeletesNothing() async throws {
        let defaults = makeDefaults()
        let recorder = Recorder()
        let server = (1...4).map { Row(uuid: uuid($0), caughtAt: Double(100 + $0)) }
        let context = try makeContext(localUuids: [uuid(1)], caughtAt: [101])
        let manager = makeManager(defaults: defaults, server: server, recorder: recorder)

        await manager.runIfNeeded(context: context, restorePresenting: { false }, tokenWaitSeconds: 0)

        #expect(recorder.sent.isEmpty)
        #expect(recorder.events.first?.1["outcome"]?.jsonValue as? String == "too_many")
        #expect(recorder.events.first?.1["orphans"]?.jsonValue as? Int == 3)
        #expect(defaults.bool(forKey: HangarReconcileManager.doneKey))
    }
}
