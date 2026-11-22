//
//  NotablePlaneTests.swift
//  TailspotTests
//
//  The notable-airframe feature's logic: wire decoding (with, without and
//  malformed), the Catch fields, the upload claim, points, trophies, the
//  Hangar filter and the analytics property.
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
    }

    /// A restored row takes the notable flag the server stored at upload;
    /// null, no key (an old server) and a malformed object all restore plain.
    @Test func restoreAppliesTheStoredNotableAndNothingElse() throws {
        let page = try JSONDecoder().decode(
            RestoredCatchesResponse.self, from: listJSON([Self.teamJSON, "null", nil, "{}"]))
        let restored = page.catches.map { HangarRestore.makeCatch(from: $0) }
        #expect(restored[0].notableKind == "team")
        #expect(restored[0].notableLabel == "Team plane")
        #expect(restored[0].notableName == "Golden State Warriors")
        for plain in restored.dropFirst() {
            #expect(plain.notableKind == nil && plain.notableLabel == nil && plain.notableName == nil)
        }
        // A restored notable catch claims again if it is ever re-sent.
        #expect(restored.map(\.claimsNotable) == [true, false, false, false])
    }

    // MARK: Upload claim

    private func requestJSON(claim: Bool) throws -> String {
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111", icao24: "a1b2c3",
            callsign: nil, caughtAt: 1_790_000_000,
            observer: .init(lat: 37.8, lon: -122.2, headingDeg: nil, elevationDeg: nil,
                            headingAccuracyDeg: nil),
            aircraft: nil, guess: nil, notableClaim: claim)
        return String(decoding: try JSONEncoder().encode(req), as: UTF8.self)
    }

    /// `"notableClaim": true` when claiming; otherwise the key is absent
    /// (not false, not null), so the body matches what older builds send.
    @Test func uploadRequestCarriesTheClaimOnlyWhenTrue() throws {
        #expect(try requestJSON(claim: true).contains("\"notableClaim\":true"))
        #expect(try requestJSON(claim: false).contains("notableClaim") == false)
    }

    /// The claim comes from the row's own stored flag: a catch recorded as
    /// notable claims, an ordinary or pre-feature catch never does, and a
    /// row the server cleared stops claiming.
    @Test func onlyACatchRecordedAsNotableClaims() {
        #expect(makeCatch(icao: "a1b2c3", notable: Self.team).claimsNotable)
        #expect(makeCatch(icao: "a1b2c3", notable: Self.bizjet).claimsNotable)
        #expect(makeCatch(icao: "a1b2c3").claimsNotable == false)
        let cleared = makeCatch(icao: "a1b2c3", notable: Self.team)
        CatchUploader.reconcileNotable(cleared, with: response(.notNotable))
        #expect(cleared.claimsNotable == false)
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

    @Test func uploadResponseSetsCorrectsOrLeavesAlone() {
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

    @Test func trophyInputsCountDistinctNotableAirframes() {
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
        #expect(Trophies.inputs(from: [makeCatch(icao: "aaa004")]).notableAirframes == 0)
    }

    @Test func starSightingUnlocksOnTheFirstNotablePlane() {
        #expect(ach("notable").isEarned(inputs: .zero) == false)
        #expect(ach("notable").isEarned(inputs: Trophies.inputs(from: [makeCatch(icao: "aaa004")])) == false)
        let one = Trophies.inputs(from: [makeCatch(icao: "aaa001", notable: Self.team)])
        #expect(ach("notable").isEarned(inputs: one))
    }

    @Test func starSightingIsTheOnlyNotableTrophyAndAFeat() {
        #expect(ach("notable").title == "Star Sighting")
        #expect(ach("notable").threshold == 1)
        #expect(TrophyTracks.track(forAchievementID: "notable") == nil)
        #expect(TrophyTracks.feats().contains { $0.id == "notable" })
        #expect(TrophyTracks.featSymbols["notable"] != nil)
        #expect(TrophyTracks.displayTitle(for: ach("notable")) == "Star Sighting")
        #expect(Trophies.roster.filter { $0.id.hasPrefix("notable") }.map(\.id) == ["notable"])
    }

    // MARK: Hangar search

    private func rows(_ catches: [Catch]) -> [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    @Test func hangarRowStarFollowsTheCatchItShows() {
        // The flag is per catch. A row shows its newest catch, so the star
        // and the bonus in its points come from that catch alone.
        let before = makeCatch(icao: "aaa001", at: 1_790_000_000)
        let after = makeCatch(icao: "aaa001", at: 1_790_100_000, notable: Self.team)
        let starred = try! #require(rows([before, after]).first)
        #expect(starred.mostRecent === after)
        #expect(starred.notableInfo == Self.team)
        #expect(before.notableInfo == nil)  // the older catch gains nothing

        // The other way round: an older notable catch does not star a row
        // whose newest catch earned no bonus.
        let older = makeCatch(icao: "aaa002", at: 1_790_000_000, notable: Self.team)
        let newer = makeCatch(icao: "aaa002", at: 1_790_100_000)
        let plain = try! #require(rows([older, newer]).first)
        #expect(plain.mostRecent === newer)
        #expect(plain.notableInfo == nil)
        #expect(HangarGrouping.search([plain], query: "notable").isEmpty)
    }

    @Test func notableSearchWordKeepsOnlyNotableRows() {
        let catches = [
            makeCatch(icao: "aaa001", at: 1_790_000_300, notable: Self.team),
            makeCatch(icao: "aaa002", at: 1_790_000_200),
            makeCatch(icao: "aaa003", at: 1_790_000_100, notable: Self.bizjet),
        ]
        let all = rows(catches)
        let index = HangarGrouping.searchIndex(for: all)
        // The word works in the search field too, like a tier name.
        #expect(HangarGrouping.search(all, query: "notable").map(\.icao24) == ["aaa001", "aaa003"])
        #expect(HangarGrouping.search(all, query: "NOTABLE b738").map(\.icao24) == ["aaa001", "aaa003"])
        // Findable by who it is, and by category.
        #expect(HangarGrouping.search(all, query: "warriors").map(\.icao24) == ["aaa001"])
        #expect(HangarGrouping.search(all, query: "business jet").map(\.icao24) == ["aaa003"])
        #expect(index.map(\.isNotablePlane) == [true, false, true])
    }

    @Test func notableSearchEmptyStates() {
        let plain = rows([makeCatch(icao: "aaa002")])
        #expect(HangarGrouping.search(plain, query: "notable").isEmpty)
        #expect(HangarRecentView.emptyMessage(query: "notable") == "No notable planes caught yet")
        #expect(HangarRecentView.emptyMessage(query: "Notable") == "No notable planes caught yet")
        #expect(HangarRecentView.emptyMessage(query: "zzz") == "No catches match \u{201C}zzz\u{201D}")
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
