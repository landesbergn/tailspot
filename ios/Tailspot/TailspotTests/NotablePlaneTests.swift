//
//  NotablePlaneTests.swift
//  TailspotTests
//
//  The notable-airframe feature's logic: wire decoding (with, without and
//  malformed), the Catch fields, points, trophies, the one-time backfill,
//  the Hangar filter and the analytics property.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@MainActor
@Suite("Notable planes")
struct NotablePlaneTests {

    // MARK: Fixtures

    private static let team = NotablePlane(kind: "team", label: "Team plane",
                                           name: "Golden State Warriors")!
    private static let bizjet = NotablePlane(kind: "business", label: "Business jet", name: nil)!

    private func makeCatch(
        icao: String, typecode: String? = "B738", at: TimeInterval = 1_790_000_000,
        notable: NotablePlane? = nil, uuid: String? = nil
    ) -> Catch {
        let c = Catch(icao24: icao, callsign: "TST1", model: nil, manufacturer: nil,
                      caughtAt: Date(timeIntervalSince1970: at),
                      observerLat: 37.8, observerLon: -122.2, slantDistanceMeters: 9_000,
                      typecode: typecode)
        c.setNotable(notable)
        c.serverUuid = uuid
        return c
    }

    private func container() throws -> ModelContainer {
        let container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        return container
    }

    private func makeDefaults() -> UserDefaults {
        let name = "NotablePlaneTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func aircraftJSON(_ notable: String?) -> Data {
        let extra = notable.map { ", \"notable\": \($0)" } ?? ""
        return Data("""
        {"fetchedAt": 1790000000, "aircraft": [
          {"icao24": "a1b2c3", "callsign": "DAL8935", "originCountry": "United States",
           "longitude": -122.3, "latitude": 37.7, "altitudeMeters": 9000,
           "velocityMps": 230, "trackDeg": 90, "onGround": false,
           "positionTimestamp": 1790000000\(extra)}
        ]}
        """.utf8)
    }

    private func decodeAircraft(_ notable: String?) throws -> Aircraft {
        let response = try JSONDecoder().decode(BackendAircraftResponse.self, from: aircraftJSON(notable))
        return try #require(response.aircraft.first).asAircraft()
    }

    // MARK: Decoding

    @Test func aircraftWithoutNotableDecodesAsOrdinary() throws {
        #expect(try decodeAircraft(nil).notable == nil)
        #expect(try decodeAircraft("null").notable == nil)
    }

    @Test func aircraftWithNotableDecodesAllThreeFields() throws {
        let a = try decodeAircraft(#"{"kind": "team", "label": "Team plane", "name": "Golden State Warriors"}"#)
        #expect(a.notable == Self.team)
        #expect(a.notable?.plateTitle == "NOTABLE · TEAM PLANE")
    }

    @Test func notableWithoutNameDecodes() throws {
        let a = try decodeAircraft(#"{"kind": "business", "label": "Business jet"}"#)
        #expect(a.notable == Self.bizjet)
        #expect(a.notable?.shortText == "Business jet")
        let nullName = try decodeAircraft(#"{"kind": "business", "label": "Business jet", "name": null}"#)
        #expect(nullName.notable?.name == nil)
        let blankName = try decodeAircraft(#"{"kind": "business", "label": "Business jet", "name": "  "}"#)
        #expect(blankName.notable?.name == nil)
    }

    @Test func unknownKindRendersFromItsLabel() throws {
        let a = try decodeAircraft(#"{"kind": "Zeppelin", "label": "Airship of note", "name": "LZ 129"}"#)
        #expect(a.notable?.kind == "zeppelin")
        #expect(a.notable?.label == "Airship of note")
        #expect(a.notable?.plateTitle == "NOTABLE · AIRSHIP OF NOTE")
    }

    /// A broken flag costs only the flag: the rest of the poll still decodes.
    @Test func malformedNotableNeverFailsTheFeed() throws {
        for bad in [#""yes""#, "true", "7", "[]", "{}", #"{"kind": 3, "label": false}"#] {
            let a = try decodeAircraft(bad)
            #expect(a.icao24 == "a1b2c3")
            #expect(a.notable == nil, "\(bad)")
        }
        // A kind with no label still gets readable text.
        let kindOnly = try decodeAircraft(#"{"kind": "team"}"#)
        #expect(kindOnly.notable?.label == "Team")
    }

    private func uploadJSON(_ notable: String?) -> Data {
        let extra = notable.map { ", \"notable\": \($0)" } ?? ""
        return Data("""
        {"catchId": "1", "points": 10, "rarity": "common", "typecode": "B738", "duplicate": false\(extra)}
        """.utf8)
    }

    private func listJSON(_ notables: [String?]) -> Data {
        let rows = notables.enumerated().map { i, notable -> String in
            let extra = notable.map { ", \"notable\": \($0)" } ?? ""
            return """
            {"catchUuid": "uuid-\(i)", "icao24": "a1b2c3", "callsign": null, "typecode": "B752",
             "rarity": "uncommon", "points": 30, "firstOfType": false, "guessKind": null,
             "guessValue": null, "guessCorrect": false, "caughtAt": 1790000000,
             "observerLat": 37.8, "observerLon": -122.2, "aircraftAltitudeMeters": null,
             "registration": null, "manufacturer": null, "model": null\(extra)}
            """
        }
        return Data("{\"total\": \(notables.count), \"catches\": [\(rows.joined(separator: ","))]}".utf8)
    }

    private static let teamJSON = #"{"kind": "team", "label": "Team plane", "name": "Golden State Warriors"}"#

    /// Absent key, explicit null and an object are three different answers.
    @Test func uploadResponseDecodesThreeStates() throws {
        func verdict(_ notable: String?) throws -> NotableVerdict {
            try JSONDecoder().decode(UploadCatchResponse.self, from: uploadJSON(notable)).notable
        }
        #expect(try verdict(nil) == .unknown)             // a server older than the feature
        #expect(try verdict("null") == .notNotable)       // "not notable, no bonus paid"
        #expect(try verdict(Self.teamJSON) == .notable(Self.team))
        // A malformed value never throws and reads as "said nothing".
        for bad in [#""yes""#, "true", "7", "[]", "{}", #"{"kind": 3, "label": false}"#] {
            #expect(try verdict(bad) == .unknown, "\(bad)")
        }
    }

    @Test func catchListDecodesThreeStatesPerRow() throws {
        let page = try JSONDecoder().decode(
            RestoredCatchesResponse.self, from: listJSON([Self.teamJSON, "null", nil, "{}"]))
        #expect(page.catches.map(\.notable) == [.notable(Self.team), .notNotable, .unknown, .unknown])
        // A restored Hangar comes back with the flag.
        #expect(HangarRestore.makeCatch(from: page.catches[0]).notableInfo == Self.team)
        #expect(HangarRestore.makeCatch(from: page.catches[1]).notableInfo == nil)
        #expect(HangarRestore.makeCatch(from: page.catches[2]).notableInfo == nil)
    }

    /// The verdict also decodes on its own (as a present value).
    @Test func verdictDecodesAsAStandaloneValue() throws {
        let values = try JSONDecoder().decode(
            [NotableVerdict].self, from: Data("[null, \(Self.teamJSON), 3]".utf8))
        #expect(values == [.notNotable, .notable(Self.team), .unknown])
    }

    // MARK: Catch fields

    @Test func catchStartsOrdinaryAndTakesTheFlag() {
        let c = makeCatch(icao: "a1b2c3")
        #expect(c.notableInfo == nil)
        #expect(c.notableKind == nil && c.notableLabel == nil && c.notableName == nil)

        #expect(c.setNotable(Self.team))
        #expect(c.notableKind == "team")
        #expect(c.notableLabel == "Team plane")
        #expect(c.notableName == "Golden State Warriors")
        #expect(c.notableInfo == Self.team)
        // Writing the same value again is not a change.
        #expect(c.setNotable(Self.team) == false)

        #expect(c.setNotable(Self.bizjet))
        #expect(c.notableName == nil)
    }

    /// Every stored field that is NOT one of the three notable ones, as one
    /// comparable value: proves a clear or a set moved nothing else.
    private func otherFields(_ c: Catch) -> [String] {
        [c.icao24, c.callsign ?? "-", c.model ?? "-", c.manufacturer ?? "-",
         c.operatorName ?? "-", c.photoFilename ?? "-", "\(c.caughtAt.timeIntervalSince1970)",
         c.caughtDayKey ?? "-", "\(c.observerLat)", "\(c.observerLon)",
         "\(c.slantDistanceMeters)", c.rarity ?? "-", c.aircraftType ?? "-",
         c.registration ?? "-", c.typecode ?? "-", c.category ?? "-",
         "\(String(describing: c.altitudeMeters))", "\(String(describing: c.velocityMps))",
         c.originIcao ?? "-", c.destIcao ?? "-", c.originIata ?? "-", c.destIata ?? "-",
         c.originName ?? "-", c.destName ?? "-", c.placeName ?? "-", c.country ?? "-",
         c.serverUuid ?? "-", "\(String(describing: c.uploadedAt))", c.suspectReason ?? "-",
         "\(String(describing: c.photoFocusX))", "\(String(describing: c.photoFocusY))",
         c.guessKind ?? "-", c.guessValue ?? "-", "\(String(describing: c.guessCorrect))",
         c.captureDiagnosticsJSON ?? "-", "\(String(describing: c.guessRecreditedAt))",
         "\(String(describing: c.pressSize))"]
    }

    /// A row with every optional field filled, so a stray write would show.
    private func fullCatch(notable: NotablePlane?, uuid: String = "AAAA-1111") -> Catch {
        let c = Catch(icao24: "a1b2c3", callsign: "DAL8935", model: "757-200", manufacturer: "Boeing",
                      operatorName: "Delta Air Lines", photoFilename: "a1b2c3_1.jpg",
                      caughtAt: Date(timeIntervalSince1970: 1_790_000_000),
                      observerLat: 37.8, observerLon: -122.2, slantDistanceMeters: 9_000,
                      registration: "N661DN", typecode: "B752", category: "A4",
                      altitudeMeters: 9_000, velocityMps: 230,
                      originIcao: "KOAK", destIcao: "KDEN", originIata: "OAK", destIata: "DEN",
                      originName: "Oakland", destName: "Denver",
                      placeName: "Oakland, CA", country: "US",
                      photoFocusX: 0.4, photoFocusY: 0.6)
        c.serverUuid = uuid
        c.uploadedAt = Date(timeIntervalSince1970: 1_790_000_100)
        c.guessKind = "route"; c.guessValue = "KDEN"; c.guessCorrect = true
        c.captureDiagnosticsJSON = "{}"
        c.pressSize = 2
        c.setNotable(notable)
        return c
    }

    private func response(_ verdict: NotableVerdict) -> UploadCatchResponse {
        UploadCatchResponse(catchId: "1", points: 10, rarity: "common", typecode: "B738",
                            duplicate: false, firstOfType: false, guessCorrect: nil,
                            notable: verdict)
    }

    @Test func uploadResponseSetsCorrectsClearsOrLeavesAlone() {
        // Feed said nothing, server says notable: set.
        let fresh = makeCatch(icao: "a1b2c3")
        CatchUploader.reconcileNotable(fresh, with: response(.notable(Self.team)))
        #expect(fresh.notableInfo == Self.team)
        // Feed and server disagree: the server wins.
        let stale = makeCatch(icao: "a1b2c3", notable: Self.bizjet)
        CatchUploader.reconcileNotable(stale, with: response(.notable(Self.team)))
        #expect(stale.notableInfo == Self.team)
        // No key (an older backend): the row keeps what the feed said.
        let kept = makeCatch(icao: "a1b2c3", notable: Self.team)
        CatchUploader.reconcileNotable(kept, with: response(.unknown))
        #expect(kept.notableInfo == Self.team)
    }

    /// Explicit null: the server did not pay the bonus, so the row drops its
    /// flag. Nothing but the three notable fields may move.
    @Test func uploadNullClearsOnlyTheThreeNotableFields() {
        let row = fullCatch(notable: Self.team)
        let before = otherFields(row)
        CatchUploader.reconcileNotable(row, with: response(.notNotable))
        #expect(row.notableKind == nil && row.notableLabel == nil && row.notableName == nil)
        #expect(row.notableInfo == nil)
        #expect(otherFields(row) == before)
        // And a set moves nothing else either.
        CatchUploader.reconcileNotable(row, with: response(.notable(Self.bizjet)))
        #expect(row.notableInfo == Self.bizjet)
        #expect(otherFields(row) == before)
        // Null on a row that was never flagged is not a change.
        let plain = fullCatch(notable: nil)
        #expect(plain.applyNotable(.notNotable) == false)
    }

    /// The Hangar memoizes its rows, search index and trophy inputs on this
    /// hash; a flag that lands after the row exists has to bust it.
    @Test func hangarCacheFingerprintChangesWhenTheFlagLands() {
        let c = makeCatch(icao: "a1b2c3")
        let before = CatchFingerprint.of([c])
        c.setNotable(Self.team)
        #expect(CatchFingerprint.of([c]) != before)
    }

    // MARK: Points

    @Test func notableBonusIsHalfTheBaseAndStacksAdditively() {
        let now = ScoringBonuses.routeGuessCutover.addingTimeInterval(60)
        #expect(ScoringBonuses.notableBonus(base: 10) == 5)
        #expect(ScoringBonuses.notableBonus(base: 50) == 25)
        // Alone: rare 50 + 25.
        #expect(ScoringBonuses.displayPoints(
            base: 50, isFirstOfType: false, guessKind: nil, caughtAt: now,
            isNotablePlane: true) == (75, 25))
        // With first-of-type: 50 + 25 + 25, not 50 × 1.5 × 1.5.
        #expect(ScoringBonuses.displayPoints(
            base: 50, isFirstOfType: true, guessKind: nil, caughtAt: now,
            isNotablePlane: true) == (100, 50))
        // With first-of-type and a triple catch: 50 + 25 + 25 + 25.
        #expect(ScoringBonuses.displayPoints(
            base: 50, isFirstOfType: true, guessKind: nil, caughtAt: now,
            pressSize: 3, isNotablePlane: true) == (125, 75))
        // Everything at once on a legendary: 500 + 250 + 250 + 125 + 125.
        #expect(ScoringBonuses.displayPoints(
            base: 500, isFirstOfType: true, guessKind: .route, caughtAt: now,
            pressSize: 2, isNotablePlane: true) == (1250, 750))
        // Not notable: unchanged from before the feature.
        #expect(ScoringBonuses.displayPoints(
            base: 50, isFirstOfType: true, guessKind: nil, caughtAt: now, pressSize: 3) == (100, 50))
    }

    @Test func multiCatchTallyCountsTheNotableBonusForFreshPlanesOnly() {
        let star = CardPlane(callsign: "DAL8935", model: "Boeing 757-200", carrier: "Delta",
                             rarity: .uncommon, type: .narrow, isFirstOfType: true,
                             notable: Self.team)
        let plain = CardPlane(callsign: "SWA1", model: "Boeing 737-800", carrier: "Southwest",
                              rarity: .common, type: .narrow)
        let dupStar = CardPlane(callsign: "EJA1", model: "Gulfstream G650", carrier: "NetJets",
                                rarity: .rare, type: .biz, notable: Self.bizjet)
        let entries: [MultiCatchReveal.Entry] = [
            .init(plane: star, isDuplicate: false),
            .init(plane: plain, isDuplicate: false),
            .init(plane: dupStar, isDuplicate: true),
        ]
        let tally = MultiCatchReveal.tally(entries)
        #expect(tally.notablePoints == 10)          // uncommon 20 × 0.5, the duplicate earns nothing
        #expect(tally.basePoints == 30)
        #expect(tally.firstOfTypePoints == 10)
        #expect(tally.multiCatchPoints == 5 + 3)    // a double: +25% each
        #expect(tally.awarded == 30 + 10 + 8 + 10)
        // Per-plane amounts add up to the run's total.
        #expect(entries.map { MultiCatchReveal.earned($0, in: entries) } == [45, 13, 0])
        #expect(MultiCatchReveal.announcement(for: tally).contains("notable plane plus 10"))
    }

    @Test func weeklyRecapPointsIncludeTheNotableBonus() {
        let plain = makeCatch(icao: "a1b2c3")
        let star = makeCatch(icao: "a1b2c3", notable: Self.team)
        let base = plain.resolvedRarity.basePoints
        #expect(WeeklyRecap.displayPoints(plain, isFirstOfType: false) == base)
        #expect(WeeklyRecap.displayPoints(star, isFirstOfType: false)
                == base + ScoringBonuses.notableBonus(base: base))
    }

    // MARK: Trophies

    private func ach(_ id: String) -> Achievement { Trophies.roster.first { $0.id == id }! }

    @Test func trophyInputsCountDistinctNotableAirframesAndKinds() {
        let catches = [
            makeCatch(icao: "aaa001", notable: Self.team),
            // The same airframe again: still one.
            makeCatch(icao: "aaa001", at: 1_790_100_000, notable: Self.team),
            makeCatch(icao: "aaa002", notable: Self.bizjet),
            makeCatch(icao: "aaa003", notable: NotablePlane(kind: "team", label: "Team plane", name: "Dallas Mavericks")),
            makeCatch(icao: "aaa004"),
        ]
        let inputs = Trophies.inputs(from: catches)
        #expect(inputs.notableAirframes == 3)
        #expect(inputs.notableKinds == 2)
        #expect(Trophies.inputs(from: [makeCatch(icao: "aaa004")]).notableAirframes == 0)
    }

    @Test func notableTrophiesUnlockAtOneTenAndFourKinds() {
        #expect(ach("notable").isEarned(inputs: .zero) == false)
        let one = Trophies.inputs(from: [makeCatch(icao: "aaa001", notable: Self.team)])
        #expect(ach("notable").isEarned(inputs: one))
        #expect(ach("notable2").isEarned(inputs: one) == false)
        #expect(ach("notablekinds").isEarned(inputs: one) == false)

        // Nine airframes across three kinds: neither hard trophy yet.
        let kinds = ["team", "business", "government"]
        var catches = (0..<9).map { i in
            makeCatch(icao: String(format: "bbb%03d", i),
                      notable: NotablePlane(kind: kinds[i % 3], label: kinds[i % 3], name: nil))
        }
        var inputs = Trophies.inputs(from: catches)
        #expect(ach("notable2").isEarned(inputs: inputs) == false)
        #expect(ach("notablekinds").isEarned(inputs: inputs) == false)

        // The tenth is a fourth kind (one the app has never heard of).
        catches.append(makeCatch(icao: "bbb009",
                                 notable: NotablePlane(kind: "zeppelin", label: "Airship", name: nil)))
        inputs = Trophies.inputs(from: catches)
        #expect(ach("notable2").isEarned(inputs: inputs))
        #expect(ach("notablekinds").isEarned(inputs: inputs))
    }

    @Test func notableTrophiesSitInTheRosterAsATrackAndAFeat() {
        #expect(TrophyTracks.track(forAchievementID: "notable")?.id == "notables")
        #expect(TrophyTracks.level(ofAchievementID: "notable2") == 2)
        #expect(TrophyTracks.track(forAchievementID: "notablekinds") == nil)
        #expect(TrophyTracks.featSymbols["notablekinds"] != nil)
        #expect(ach("notable2").threshold == 10)
        #expect(ach("notablekinds").threshold == 4)
    }

    // MARK: Backfill

    private typealias ServerRow = NotableBackfill.ServerRow

    private func runner(
        defaults: UserDefaults, hasToken: Bool = true,
        pages: @escaping NotableBackfillRunner.FetchPage
    ) -> NotableBackfillRunner {
        NotableBackfillRunner(defaults: defaults, hasToken: { hasToken }, fetchPage: pages)
    }

    @Test func backfillMarksMatchingRowsOnceAndLeavesEverythingElseAlone() async throws {
        let container = try container()
        let ctx = container.mainContext
        // Local uuids are uppercase, the server's lowercase.
        let star = makeCatch(icao: "aaa001", uuid: "AAAA-1111")
        let plain = makeCatch(icao: "aaa002", uuid: "BBBB-2222")
        let pending = makeCatch(icao: "aaa003", uuid: nil)
        plain.placeName = "Oakland"
        [star, plain, pending].forEach(ctx.insert)
        try ctx.save()

        let defaults = makeDefaults()
        var calls = 0
        let r = runner(defaults: defaults) { _, _ in
            calls += 1
            return ([ServerRow(uuid: "aaaa-1111", verdict: .notable(Self.team)),
                     ServerRow(uuid: "bbbb-2222", verdict: .notNotable),
                     // A server row the phone doesn't have: ignored.
                     ServerRow(uuid: "zzzz-9999", verdict: .notable(Self.bizjet))], 3)
        }
        #expect(await r.runIfNeeded(context: ctx) == 1)
        #expect(star.notableInfo == Self.team)
        #expect(plain.notableInfo == nil && pending.notableInfo == nil)
        #expect(plain.placeName == "Oakland")
        #expect(try ctx.fetchCount(FetchDescriptor<Catch>()) == 3)
        #expect(r.isComplete)

        // Latched: a second run does nothing and makes no request.
        #expect(await r.runIfNeeded(context: ctx) == nil)
        #expect(calls == 1)
    }

    @Test func backfillIsIdempotentWhenForcedToRunAgain() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", uuid: "AAAA-1111")
        ctx.insert(star)
        try ctx.save()
        let page: NotableBackfillRunner.FetchPage = { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notable(Self.team))], 1)
        }
        // Fresh defaults each time = no latch, so the reconcile really runs twice.
        #expect(await runner(defaults: makeDefaults(), pages: page).runIfNeeded(context: ctx) == 1)
        #expect(await runner(defaults: makeDefaults(), pages: page).runIfNeeded(context: ctx) == 0)
        #expect(star.notableInfo == Self.team)
        #expect(try ctx.fetchCount(FetchDescriptor<Catch>()) == 1)
    }

    /// An old server (no `notable` key on its rows): nothing changes, the
    /// latch stays unset, and the run stops after ONE request so the retry
    /// on a later launch stays cheap.
    @Test func backfillAgainstAnOldServerStaysUnlatchedAndCheap() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", notable: Self.team, uuid: "AAAA-1111")
        ctx.insert(star)
        try ctx.save()
        let defaults = makeDefaults()
        var calls = 0
        let old = runner(defaults: defaults) { _, offset in
            calls += 1
            // 1,200 rows, none carrying the key.
            let n = min(500, 1_200 - offset)
            return ((0..<n).map { ServerRow(uuid: "row-\(offset + $0)", verdict: .unknown) }
                    + (offset == 0 ? [ServerRow(uuid: "aaaa-1111", verdict: .unknown)] : []), 1_200)
        }
        #expect(await old.runIfNeeded(context: ctx) == nil)
        #expect(calls == 1)
        #expect(!old.isComplete)
        #expect(star.notableInfo == Self.team)

        // A later launch, once the server is deployed, finishes the job.
        let aware = runner(defaults: defaults) { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notable(Self.team))], 1)
        }
        #expect(await aware.runIfNeeded(context: ctx) == 0)
        #expect(aware.isComplete)
    }

    /// One row without the key is enough to withhold the latch, and then
    /// nothing is applied: half a list is not a verdict.
    @Test func backfillWithAMixedPageAppliesNothingAndDoesNotLatch() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", uuid: "AAAA-1111")
        ctx.insert(star)
        try ctx.save()
        let r = runner(defaults: makeDefaults()) { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notable(Self.team)),
              ServerRow(uuid: "bbbb-2222", verdict: .unknown)], 2)
        }
        #expect(await r.runIfNeeded(context: ctx) == nil)
        #expect(star.notableInfo == nil && !r.isComplete)
    }

    /// An aware server with no notable catches at all: every row says null.
    /// That is a full answer, so the run latches having changed nothing.
    @Test func backfillAgainstAnAwareServerWithZeroNotableRowsLatches() async throws {
        let container = try container()
        let ctx = container.mainContext
        let plain = makeCatch(icao: "aaa001", uuid: "AAAA-1111")
        ctx.insert(plain)
        try ctx.save()
        let r = runner(defaults: makeDefaults()) { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notNotable),
              ServerRow(uuid: "bbbb-2222", verdict: .notNotable)], 2)
        }
        #expect(await r.runIfNeeded(context: ctx) == 0)
        #expect(r.isComplete)
        #expect(plain.notableInfo == nil)
    }

    /// The server lists nothing for this device: that proves nothing about
    /// whether it knows notable planes, so no latch.
    @Test func backfillAgainstAnEmptyServerListDoesNotLatch() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", notable: Self.team, uuid: "AAAA-1111")
        ctx.insert(star)
        try ctx.save()
        let r = runner(defaults: makeDefaults()) { _, _ in ([], 0) }
        #expect(await r.runIfNeeded(context: ctx) == nil)
        #expect(!r.isComplete)
        #expect(star.notableInfo == Self.team)
        #expect(NotableBackfill.provesServerAware([]) == false)
    }

    /// Per row: null clears, an object sets, a row the server did not list
    /// is left alone. Nothing but the three notable fields moves.
    @Test func backfillNullClearsOnlyTheThreeNotableFields() async throws {
        let container = try container()
        let ctx = container.mainContext
        let wronglyFlagged = fullCatch(notable: Self.team, uuid: "AAAA-1111")
        let unflagged = fullCatch(notable: nil, uuid: "BBBB-2222")
        let unlisted = fullCatch(notable: Self.bizjet, uuid: "CCCC-3333")
        [wronglyFlagged, unflagged, unlisted].forEach(ctx.insert)
        try ctx.save()
        let before = [wronglyFlagged, unflagged, unlisted].map(otherFields)

        let r = runner(defaults: makeDefaults()) { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notNotable),
              ServerRow(uuid: "bbbb-2222", verdict: .notable(Self.team))], 2)
        }
        #expect(await r.runIfNeeded(context: ctx) == 2)
        #expect(wronglyFlagged.notableKind == nil && wronglyFlagged.notableLabel == nil
                && wronglyFlagged.notableName == nil)
        #expect(unflagged.notableInfo == Self.team)
        #expect(unlisted.notableInfo == Self.bizjet)
        #expect([wronglyFlagged, unflagged, unlisted].map(otherFields) == before)
        #expect(try ctx.fetchCount(FetchDescriptor<Catch>()) == 3)
        #expect(r.isComplete)
    }

    @Test func backfillIsSafeOfflineAndUnregisteredAndRetriesLater() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", uuid: "AAAA-1111")
        ctx.insert(star)
        try ctx.save()

        // No token: no request, no latch.
        let defaults = makeDefaults()
        var calls = 0
        let unregistered = runner(defaults: defaults, hasToken: false) { _, _ in
            calls += 1
            return ([], 0)
        }
        #expect(await unregistered.runIfNeeded(context: ctx) == nil)
        #expect(calls == 0 && !unregistered.isComplete)

        // Offline: the page throws. Nothing changes, nothing latches.
        let offline = runner(defaults: defaults) { _, _ in throw URLError(.notConnectedToInternet) }
        #expect(await offline.runIfNeeded(context: ctx) == nil)
        #expect(star.notableInfo == nil && !offline.isComplete)

        // A later run with the network back finishes the job.
        let online = runner(defaults: defaults) { _, _ in
            ([ServerRow(uuid: "aaaa-1111", verdict: .notable(Self.team))], 1)
        }
        #expect(await online.runIfNeeded(context: ctx) == 1)
        #expect(star.notableInfo == Self.team && online.isComplete)
    }

    @Test func backfillReadsEveryPageBeforeLatching() async throws {
        let container = try container()
        let ctx = container.mainContext
        let late = makeCatch(icao: "aaa001", uuid: "LATE-0001")
        ctx.insert(late)
        try ctx.save()
        var offsets: [Int] = []
        let r = runner(defaults: makeDefaults()) { _, offset in
            offsets.append(offset)
            // 1,200 server rows in pages of 500; the flagged one is the last.
            let n = min(500, 1_200 - offset)
            var rows = (0..<n).map { ServerRow(uuid: "row-\(offset + $0)", verdict: .notNotable) }
            if offset == 1_000 { rows[n - 1] = ServerRow(uuid: "late-0001", verdict: .notable(Self.team)) }
            return (rows, 1_200)
        }
        #expect(await r.runIfNeeded(context: ctx) == 1)
        #expect(offsets == [0, 500, 1_000])
        #expect(late.notableInfo == Self.team)
        #expect(r.isComplete)
    }

    /// A later page that fails mid-list: nothing applied, nothing latched.
    @Test func backfillThatLosesTheNetworkMidListChangesNothing() async throws {
        let container = try container()
        let ctx = container.mainContext
        let star = makeCatch(icao: "aaa001", uuid: "ROW-0")
        ctx.insert(star)
        try ctx.save()
        let r = runner(defaults: makeDefaults()) { _, offset in
            if offset > 0 { throw URLError(.timedOut) }
            return ((0..<500).map { ServerRow(uuid: "row-\($0)", verdict: .notable(Self.team)) }, 1_200)
        }
        #expect(await r.runIfNeeded(context: ctx) == nil)
        #expect(star.notableInfo == nil && !r.isComplete)
    }

    @Test func backfillSkipsAnEmptyHangarWithoutLatching() async throws {
        let ctx = try container().mainContext
        var calls = 0
        let r = runner(defaults: makeDefaults()) { _, _ in
            calls += 1
            return ([], 0)
        }
        #expect(await r.runIfNeeded(context: ctx) == nil)
        #expect(calls == 0 && !r.isComplete)
    }

    // MARK: Hangar filter

    private func rows(_ catches: [Catch]) -> [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    @Test func hangarRowIsNotableWhenAnyCatchOfTheAirframeIs() {
        // The newest catch of this airframe predates nothing but has no flag
        // (say it was caught again before the upload answered); the older does.
        let older = makeCatch(icao: "aaa001", at: 1_790_000_000, notable: Self.team)
        let newer = makeCatch(icao: "aaa001", at: 1_790_100_000)
        let row = try! #require(rows([older, newer]).first)
        #expect(row.mostRecent === newer)
        #expect(row.notableInfo == Self.team)
    }

    @Test func notableFilterAndSearchWordKeepOnlyNotableRows() {
        let catches = [
            makeCatch(icao: "aaa001", at: 1_790_000_300, notable: Self.team),
            makeCatch(icao: "aaa002", at: 1_790_000_200),
            makeCatch(icao: "aaa003", at: 1_790_000_100, notable: Self.bizjet),
        ]
        let all = rows(catches)
        let index = HangarGrouping.searchIndex(for: all)
        #expect(HangarGrouping.notableOnly(all, index: index).map(\.icao24) == ["aaa001", "aaa003"])
        // The word works in the search field too, like a tier name.
        #expect(HangarGrouping.search(all, query: "notable").map(\.icao24) == ["aaa001", "aaa003"])
        #expect(HangarGrouping.search(all, query: "NOTABLE b738").map(\.icao24) == ["aaa001", "aaa003"])
        // Findable by who it is, and by category.
        #expect(HangarGrouping.search(all, query: "warriors").map(\.icao24) == ["aaa001"])
        #expect(HangarGrouping.search(all, query: "business jet").map(\.icao24) == ["aaa003"])

        // The toggle and a query combine.
        #expect(HangarRecentView.visibleRows(all, index: index, query: "", notableOnly: true).count == 2)
        #expect(HangarRecentView.visibleRows(all, index: index, query: "warriors", notableOnly: true)
            .map(\.icao24) == ["aaa001"])
        #expect(HangarRecentView.visibleRows(all, index: index, query: "zzz", notableOnly: true).isEmpty)
        #expect(HangarRecentView.visibleRows(all, index: index, query: "", notableOnly: false).count == 3)
    }

    @Test func notableFilterEmptyStates() {
        let plain = rows([makeCatch(icao: "aaa002")])
        #expect(HangarGrouping.search(plain, query: "notable").isEmpty)
        #expect(HangarRecentView.emptyMessage(query: "notable", notableOnly: false)
                == "No notable planes caught yet")
        #expect(HangarRecentView.emptyMessage(query: "zzz", notableOnly: true)
                == "No notable catches match \u{201C}zzz\u{201D}")
        #expect(HangarRecentView.emptyMessage(query: "zzz", notableOnly: false)
                == "No catches match \u{201C}zzz\u{201D}")
    }

    // MARK: Analytics

    @Test func catchPerformedCarriesNotableKindOnlyWhenPresent() {
        func props(_ kind: String?) -> [String: AnalyticsValue] {
            CatchTelemetry.performedProperties(
                icao24: "a1b2c3", rarity: "common", aircraftType: "narrow", slantKm: 9,
                visualConfirmEnabled: false, visualFixConfidence: nil, notableKind: kind)
        }
        if case .string(let kind)? = props("team")["notable_kind"] {
            #expect(kind == "team")
        } else {
            Issue.record("notable_kind missing or not a string")
        }
        #expect(props(nil)["notable_kind"] == nil)
        #expect(props("  ")["notable_kind"] == nil)
    }
}
