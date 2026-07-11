//
//  HangarRestoreTests.swift
//  TailspotTests
//
//  The Hangar restore-from-server core (PLAN §9 #7, issue #58):
//    - wire decode of GET /v1/catches (incl. null-heavy rows),
//    - the server-row → Catch mapper (full + nil-field cases, the
//      uploadedAt / guessCorrect-nil rules),
//    - the idempotency plan (case-folded uuids, intra-batch dupes,
//      re-run inserts nothing),
//    - the never-re-upload guarantee (restored rows fail the uploader's
//      pending predicate),
//    - the trophy-ledger reseed (a bulk restore never queues celebrations).
//
//  In-memory ModelContainer + suite-isolated UserDefaults throughout, per
//  the repo's test conventions.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Hangar restore")
@MainActor
struct HangarRestoreTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Catch.self, configurations: config)
    }

    /// A fully-populated server row (the B738 the backend tests use).
    private func fullRow(uuid: String = "11111111-1111-4111-8111-111111111111") -> RestoredCatchRow {
        RestoredCatchRow(
            catchUuid: uuid,
            icao24: "aaaaaa",
            callsign: "UAL123",
            typecode: "B738",
            rarity: "rare",
            points: 75,
            firstOfType: true,
            guessKind: "route",
            guessValue: "KSFO",
            guessCorrect: true,
            caughtAt: 1_700_000_000,
            observerLat: 37.8,
            observerLon: -122.27,
            aircraftAltitudeMeters: 3000,
            registration: "N12345",
            manufacturer: "Boeing",
            model: "737-800"
        )
    }

    /// The null-heavy row an unresolved airframe produces server-side.
    private func bareRow(uuid: String = "22222222-2222-4222-8222-222222222222") -> RestoredCatchRow {
        RestoredCatchRow(
            catchUuid: uuid,
            icao24: "bbbbbb",
            callsign: nil,
            typecode: nil,
            rarity: nil,
            points: 10,
            firstOfType: false,
            guessKind: nil,
            guessValue: nil,
            guessCorrect: false,
            caughtAt: 1_700_000_060,
            observerLat: -8.7,
            observerLon: 115.2,
            aircraftAltitudeMeters: nil,
            registration: nil,
            manufacturer: nil,
            model: nil
        )
    }

    // MARK: - Wire decode

    @Test func decodesTheWireResponseIncludingNullFields() throws {
        let json = """
        {
          "total": 2,
          "catches": [
            {
              "catchUuid": "11111111-1111-4111-8111-111111111111",
              "icao24": "aaaaaa", "callsign": "UAL123",
              "typecode": "B738", "rarity": "rare", "points": 75,
              "firstOfType": true,
              "guessKind": "type", "guessValue": "B738", "guessCorrect": true,
              "caughtAt": 1700000000,
              "observerLat": 37.8, "observerLon": -122.27,
              "aircraftAltitudeMeters": null,
              "registration": "N12345", "manufacturer": "Boeing", "model": "737-800"
            },
            {
              "catchUuid": "22222222-2222-4222-8222-222222222222",
              "icao24": "bbbbbb", "callsign": null,
              "typecode": null, "rarity": null, "points": 10,
              "firstOfType": false,
              "guessKind": null, "guessValue": null, "guessCorrect": false,
              "caughtAt": 1700000060,
              "observerLat": -8.7, "observerLon": 115.2,
              "aircraftAltitudeMeters": null,
              "registration": null, "manufacturer": null, "model": null
            }
          ]
        }
        """
        let decoded = try JSONDecoder().decode(RestoredCatchesResponse.self, from: Data(json.utf8))
        #expect(decoded.total == 2)
        #expect(decoded.catches.count == 2)
        #expect(decoded.catches[0].typecode == "B738")
        #expect(decoded.catches[0].guessCorrect == true)
        #expect(decoded.catches[1].callsign == nil)
        #expect(decoded.catches[1].rarity == nil)
        #expect(decoded.catches[1].aircraftAltitudeMeters == nil)
    }

    // MARK: - Mapper

    @Test func mapsAFullServerRowOntoACatch() {
        let c = HangarRestore.makeCatch(from: fullRow())
        #expect(c.icao24 == "aaaaaa")
        #expect(c.callsign == "UAL123")
        #expect(c.typecode == "B738")
        #expect(c.registration == "N12345")
        #expect(c.manufacturer == "Boeing")
        #expect(c.model == "737-800")
        #expect(c.caughtAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(c.observerLat == 37.8)
        #expect(c.observerLon == -122.27)
        #expect(c.altitudeMeters == 3000)
        // The as-caught audit tier maps through the shared raw values.
        #expect(c.rarity == "rare")
        // The frozen guess comes back whole.
        #expect(c.guessKind == "route")
        #expect(c.guessValue == "KSFO")
        #expect(c.guessCorrect == true)
        // Restore bookkeeping: keyed to the server row, born already-uploaded.
        #expect(c.serverUuid == "11111111-1111-4111-8111-111111111111")
        #expect(c.uploadedAt != nil)
        // What the server never had stays honest: no photo, unknown distance.
        #expect(c.photoFilename == nil)
        #expect(c.slantDistanceMeters == 0)
        #expect(c.suspectReason == nil)
    }

    @Test func mapsANilHeavyRowWithoutInventingValues() {
        let c = HangarRestore.makeCatch(from: bareRow())
        #expect(c.callsign == nil)
        #expect(c.typecode == nil)
        #expect(c.registration == nil)
        #expect(c.manufacturer == nil)
        #expect(c.model == nil)
        #expect(c.altitudeMeters == nil)
        #expect(c.velocityMps == nil)
        #expect(c.originIcao == nil && c.destIcao == nil)
        #expect(c.placeName == nil && c.country == nil)
        // No guess made → guessCorrect must stay nil (the server echoes
        // false for guess-less rows; false locally would mean "guessed wrong").
        #expect(c.guessKind == nil)
        #expect(c.guessCorrect == nil)
        // Unknown airframe → conservative common on read, like organic rows.
        #expect(c.resolvedRarity == .common)
    }

    @Test func zeroSlantRendersAsUnknownNotZeroKm() {
        // The display seam for the 0 sentinel: cards show "—", never "0.0 km".
        #expect(CardPlane.distText(fromMeters: 0) == nil)
        #expect(CardPlane.distText(fromMeters: 12_000) == "12.0 km")
        let plane = CardPlane(catchRecord: HangarRestore.makeCatch(from: fullRow()))
        #expect(plane.distText == nil)
    }

    // MARK: - Idempotency

    @Test func planSkipsExistingUuidsCaseInsensitively() {
        // Locally-minted uuids are uppercase (UUID().uuidString); the server
        // returns lowercase. The plan must treat them as the same key.
        let existing: Set<String> = ["11111111-1111-4111-8111-111111111111"]
        let planned = HangarRestore.rowsToInsert(
            [fullRow(uuid: "11111111-1111-4111-8111-111111111111".uppercased()), bareRow()],
            existingServerUuids: existing
        )
        #expect(planned.map(\.icao24) == ["bbbbbb"])
    }

    @Test func planDedupesWithinTheBatch() {
        // A paging overlap (same row on two pages) must not double-insert.
        let planned = HangarRestore.rowsToInsert(
            [fullRow(), fullRow(), bareRow()],
            existingServerUuids: []
        )
        #expect(planned.count == 2)
    }

    @Test func reRunningInsertRestoredInsertsNothing() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let rows = [fullRow(), bareRow()]
        let first = HangarRestore.insertRestored(rows, into: context)
        try context.save()
        #expect(first == 2)

        // The whole point: a second pass over the same server rows is a no-op.
        let second = HangarRestore.insertRestored(rows, into: context)
        try context.save()
        #expect(second == 0)
        #expect(try context.fetchCount(FetchDescriptor<Catch>()) == 2)
    }

    // MARK: - Never re-upload

    @Test func restoredRowsAreNotPendingUpload() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        HangarRestore.insertRestored([fullRow(), bareRow()], into: context)
        try context.save()

        // The uploader fetches `uploadedAt == nil` rows; restored rows are
        // born uploaded, so re-POSTing (and its per-catch telemetry) can't fire.
        let pending = try context.fetch(FetchDescriptor<Catch>(predicate: CatchUploader.pendingPredicate))
        #expect(pending.isEmpty)
    }

    // MARK: - Trophy reseed (no celebration flood)

    @Test func reseedAfterRestoreQueuesNoCelebrations() throws {
        let suite = "test.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let ledger = UserDefaultsTrophyLedger(defaults: defaults)
        let events = TrophyEventStore(defaults: defaults)
        let center = TrophyUnlockCenter(ledger: ledger, events: events)

        // Fresh install: the launch diff task seeds over an EMPTY Hangar
        // (this is exactly the state a restore lands into).
        center.enqueueNewUnlocks(from: [])
        #expect(ledger.isSeeded)
        #expect(center.pendingEvents.isEmpty)

        // Restore a collection big enough to earn real roster trophies.
        let container = try makeContainer()
        let context = ModelContext(container)
        let rows: [RestoredCatchRow] = (0..<12).map { (i: Int) in
            let uuid: String = "33333333-3333-4333-8333-" + String(format: "%012d", i)
            let icao: String = String(format: "%06x", 0xa0_0000 + i)
            let caughtAt: Double = 1_700_000_000.0 + Double(i) * 60.0
            return RestoredCatchRow(
                catchUuid: uuid,
                icao24: icao,
                callsign: nil, typecode: "B738", rarity: "common", points: 10,
                firstOfType: i == 0,
                guessKind: nil, guessValue: nil, guessCorrect: false,
                caughtAt: caughtAt,
                observerLat: 37.8, observerLon: -122.27,
                aircraftAltitudeMeters: nil,
                registration: nil, manufacturer: "Boeing", model: "737-800"
            )
        }
        HangarRestore.insertRestored(rows, into: context)
        let all = try context.fetch(FetchDescriptor<Catch>())

        // The manager's ordering: reseed with the restored rows BEFORE any
        // diff can observe them.
        center.reseedAfterRestore(from: all)
        #expect(center.pendingEvents.isEmpty)

        // And the ledger really is aligned: a follow-up diff over the same
        // collection (ContentView's `.task(id: catches.count)` firing after
        // the insert) finds nothing to celebrate…
        center.enqueueNewUnlocks(from: all)
        #expect(center.pendingEvents.isEmpty)

        // …while a genuinely NEW catch after the restore still can.
        let inputs = Trophies.inputs(from: all, events: events)
        #expect(Trophies.roster.contains { $0.isEarned(inputs: inputs) },
                "fixture should earn at least one trophy for the reseed to be meaningful")
    }
}
