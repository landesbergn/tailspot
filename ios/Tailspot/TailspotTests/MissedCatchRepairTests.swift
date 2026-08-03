//
//  MissedCatchRepairTests.swift
//  TailspotTests
//
//  The one-shot missed-catch recovery (MissedCatchRepair).
//
//  The whole point of these tests is the BLAST RADIUS. This code ships to
//  every user, so what matters most is everything it must NOT do:
//    - never run on any device but the targeted one,
//    - never run twice,
//    - never insert anything outside the two-uuid allowlist (a general merge
//      would resurrect locally-deleted catches — there is no DELETE endpoint),
//    - never duplicate a row that is already in the Hangar.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Missed catch repair")
@MainActor
struct MissedCatchRepairTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        return container
    }

    /// A server row carrying an arbitrary uuid.
    private func row(uuid: String, icao24: String = "aaaaaa") -> RestoredCatchRow {
        RestoredCatchRow(
            catchUuid: uuid,
            icao24: icao24,
            callsign: nil,
            typecode: nil,
            rarity: nil,
            points: 10,
            firstOfType: false,
            guessKind: nil,
            guessValue: nil,
            guessCorrect: false,
            caughtAt: 1_700_000_000,
            observerLat: 43.65,
            observerLon: -70.25,
            aircraftAltitudeMeters: nil,
            registration: nil,
            manufacturer: nil,
            model: nil
        )
    }

    private var c5UUID: String { "bacf0000-0000-4000-8000-0000000000c5" }
    private var c340UUID: String { "bacf0000-0000-4000-8000-00000000c340" }

    // MARK: - Gate: which devices run at all

    @Test func runsOnlyOnTheTargetedDevice() {
        #expect(MissedCatchRepair.shouldRun(
            deviceID: MissedCatchRepair.repairDeviceID, alreadyRan: false
        ))
        // Every other install: no run, and therefore no network call.
        #expect(!MissedCatchRepair.shouldRun(
            deviceID: "11111111-2222-3333-4444-555555555555", alreadyRan: false
        ))
    }

    @Test func doesNotRunWithoutADeviceIdentity() {
        // A fresh install before registration has no device id yet.
        #expect(!MissedCatchRepair.shouldRun(deviceID: nil, alreadyRan: false))
    }

    @Test func doesNotRunTwice() {
        #expect(!MissedCatchRepair.shouldRun(
            deviceID: MissedCatchRepair.repairDeviceID, alreadyRan: true
        ))
    }

    @Test func matchesTheDeviceIdCaseInsensitively() {
        #expect(MissedCatchRepair.shouldRun(
            deviceID: MissedCatchRepair.repairDeviceID.uppercased(), alreadyRan: false
        ))
    }

    // MARK: - Allowlist: what may be inserted

    @Test func selectsOnlyTheTwoRecoveredRows() {
        let rows = [
            row(uuid: c5UUID, icao24: "ae0584"),
            row(uuid: "99999999-9999-4999-8999-999999999999", icao24: "organic"),
            row(uuid: c340UUID, icao24: "a3bef1"),
        ]
        let repairable = MissedCatchRepair.repairableRows(rows)
        #expect(repairable.map(\.icao24).sorted() == ["a3bef1", "ae0584"])
    }

    /// The load-bearing safety property: the user's OWN catches — including
    /// any they deleted locally, which the server still holds — must never be
    /// swept in. This is what separates the repair from a general merge.
    @Test func neverInsertsRowsOutsideTheAllowlist() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let serverRows = (0..<25).map { i in
            row(uuid: "77777777-7777-4777-8777-\(String(format: "%012d", i))",
                icao24: String(format: "%06x", 0xa0_0000 + i))
        }
        let repairable = MissedCatchRepair.repairableRows(serverRows)
        #expect(repairable.isEmpty)

        HangarRestore.insertRestored(repairable, into: context)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Catch>()) == 0)
    }

    @Test func matchesUuidsCaseInsensitively() {
        // Postgres returns lowercase; be robust to either.
        let repairable = MissedCatchRepair.repairableRows([row(uuid: c5UUID.uppercased())])
        #expect(repairable.count == 1)
    }

    // MARK: - Insert behaviour

    @Test func insertsTheRecoveredCardsIntoANonEmptyHangar() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // An existing organic catch — the repair must leave it alone.
        let organic = Catch(
            icao24: "cccccc",
            callsign: "SWA100",
            model: "737-800",
            manufacturer: "Boeing",
            caughtAt: Date(timeIntervalSince1970: 1_699_000_000),
            observerLat: 43.65,
            observerLon: -70.25,
            slantDistanceMeters: 4_200
        )
        organic.serverUuid = "99999999-9999-4999-8999-999999999999"
        organic.uploadedAt = Date()
        organic.photoFilename = "organic-photo.jpg"
        context.insert(organic)
        try context.save()

        let repairable = MissedCatchRepair.repairableRows([
            row(uuid: c5UUID, icao24: "ae0584"),
            row(uuid: c340UUID, icao24: "a3bef1"),
        ])
        #expect(HangarRestore.insertRestored(repairable, into: context) == 2)
        try context.save()

        let all = try context.fetch(FetchDescriptor<Catch>())
        #expect(all.count == 3)
        #expect(Set(all.map(\.icao24)) == ["cccccc", "ae0584", "a3bef1"])
        // The organic row's photo survives untouched.
        #expect(all.first { $0.icao24 == "cccccc" }?.photoFilename == "organic-photo.jpg")
    }

    @Test func isIdempotentEvenIfTheLatchIsLost() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let repairable = MissedCatchRepair.repairableRows([
            row(uuid: c5UUID, icao24: "ae0584"),
            row(uuid: c340UUID, icao24: "a3bef1"),
        ])

        #expect(HangarRestore.insertRestored(repairable, into: context) == 2)
        try context.save()
        // Second pass (latch lost / reinstall-restore already brought them
        // down) must not duplicate: serverUuid dedupe carries it.
        #expect(HangarRestore.insertRestored(repairable, into: context) == 0)
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<Catch>()) == 2)
    }

    @Test func recoveredRowsAreNeverReUploaded() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        HangarRestore.insertRestored(
            MissedCatchRepair.repairableRows([row(uuid: c5UUID, icao24: "ae0584")]),
            into: context
        )
        try context.save()

        // They came FROM the server; re-POSTing would double-credit.
        let pending = try context.fetch(
            FetchDescriptor<Catch>(predicate: CatchUploader.pendingPredicate)
        )
        #expect(pending.isEmpty)
    }

    // MARK: - Runner (no-op paths, no network)

    @Test func runnerIsANoOpOnAnUntargetedDevice() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "test.repair.\(UUID().uuidString)")!
        let runner = MissedCatchRepairRunner(defaults: defaults)

        // Wrong device → returns before any network call is attempted.
        let inserted = await runner.runIfNeeded(
            context: context, deviceID: "11111111-2222-3333-4444-555555555555"
        )
        #expect(inserted == 0)
        #expect(try context.fetchCount(FetchDescriptor<Catch>()) == 0)
        #expect(defaults.bool(forKey: MissedCatchRepair.latchKey) == false)
    }

    @Test func runnerIsANoOpOnceLatched() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let defaults = UserDefaults(suiteName: "test.repair.\(UUID().uuidString)")!
        defaults.set(true, forKey: MissedCatchRepair.latchKey)
        let runner = MissedCatchRepairRunner(defaults: defaults)

        let inserted = await runner.runIfNeeded(
            context: context, deviceID: MissedCatchRepair.repairDeviceID
        )
        #expect(inserted == 0)
        #expect(try context.fetchCount(FetchDescriptor<Catch>()) == 0)
    }
}
