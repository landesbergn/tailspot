//
//  ChallengeModelsTests.swift
//  TailspotTests
//
//  Decoding fixtures for every Challenges wire shape pinned to PR #276's
//  actual backend, including additive unknown fields, null-tolerant
//  optionals (rarityBreakdown, myResult, winners), and the unknown-status
//  forward-compat fallback. Plus the ChallengeCreateRequest encode test.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Challenge models decoding")
struct ChallengeModelsTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ChallengeJSON.decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - ChallengeStatus

    @Test func statusDecodesKnownValues() throws {
        #expect(try decode(ChallengeStatus.self, "\"upcoming\"") == .upcoming)
        #expect(try decode(ChallengeStatus.self, "\"live\"") == .live)
        #expect(try decode(ChallengeStatus.self, "\"finished\"") == .finished)
        #expect(try decode(ChallengeStatus.self, "\"cancelled\"") == .cancelled)
    }

    @Test func statusFallsBackToUnknownForwardCompat() throws {
        #expect(try decode(ChallengeStatus.self, "\"some_future_status\"") == .unknown)
    }

    // MARK: - ChallengeSummary

    private let summaryJSON = """
    {
      "id": "c1", "kind": "private", "code": "K7M4QD2X",
      "inviteURL": "https://tailspot.app/c/K7M4QD2X", "name": "Weekend Flyoff",
      "creatorHandle": "eli", "startsAt": "2026-09-20T09:00:00.000Z",
      "endsAt": "2026-09-21T09:00:00.000Z", "durationPreset": "24h",
      "maxParticipants": 10, "status": "live", "outcome": null,
      "participantCount": 3, "isCreator": false, "isParticipant": true,
      "myResult": {"placement": 2, "points": 40, "catches": 3}
    }
    """

    @Test func summaryDecodesFullFixture() throws {
        let s = try decode(ChallengeSummary.self, summaryJSON)
        #expect(s.id == "c1")
        #expect(s.name == "Weekend Flyoff")
        #expect(s.code == "K7M4QD2X")
        #expect(s.inviteURL == "https://tailspot.app/c/K7M4QD2X")
        #expect(s.status == .live)
        #expect(s.isCreator == false)
        #expect(s.isParticipant == true)
        #expect(s.myResult == ChallengeMyResult(placement: 2, points: 40, catches: 3))
        #expect(s.isNoContest == false)
        #expect(s.isDecided == false)
    }

    @Test func summaryDecodesWithUnknownExtraField() throws {
        let withExtra = summaryJSON.replacingOccurrences(
            of: "\"kind\": \"private\",", with: "\"kind\": \"private\", \"futureField\": 123,"
        )
        let s = try decode(ChallengeSummary.self, withExtra)
        #expect(s.id == "c1")
    }

    @Test func summaryDecodesMissingOptionalFields() throws {
        let minimal = """
        {
          "id": "c2", "kind": "private", "code": null, "inviteURL": null,
          "name": "Quick Sprint", "creatorHandle": "noah",
          "startsAt": "2026-09-20T09:00:00.000Z", "endsAt": "2026-09-20T10:00:00.000Z",
          "durationPreset": "1h", "maxParticipants": 10, "status": "upcoming",
          "outcome": null, "participantCount": 1, "isCreator": true, "isParticipant": true
        }
        """
        let s = try decode(ChallengeSummary.self, minimal)
        #expect(s.code == nil)
        #expect(s.inviteURL == nil)
        #expect(s.outcome == nil)
        #expect(s.myResult == nil)
    }

    @Test func summaryOutcomeDrivesIsNoContestAndIsDecided() throws {
        let decided = summaryJSON.replacingOccurrences(of: "\"outcome\": null", with: "\"outcome\": \"decided\"")
        #expect(try decode(ChallengeSummary.self, decided).isDecided)
        #expect(!(try decode(ChallengeSummary.self, decided).isNoContest))

        let noContest = summaryJSON.replacingOccurrences(of: "\"outcome\": null", with: "\"outcome\": \"no_contest\"")
        #expect(try decode(ChallengeSummary.self, noContest).isNoContest)
        #expect(!(try decode(ChallengeSummary.self, noContest).isDecided))
    }

    // MARK: - ChallengeList

    @Test func listDecodesOpenAndHistory() throws {
        let json = "{\"open\": [\(summaryJSON)], \"history\": []}"
        let list = try decode(ChallengeList.self, json)
        #expect(list.open.count == 1)
        #expect(list.history.isEmpty)
    }

    @Test func listDefaultsMissingArraysToEmpty() throws {
        let list = try decode(ChallengeList.self, "{}")
        #expect(list.open.isEmpty)
        #expect(list.history.isEmpty)
    }

    // MARK: - ChallengeStanding

    @Test func standingDecodesFullFixture() throws {
        let json = """
        {"placement": 1, "handle": "noah", "points": 40, "catches": 3,
         "rarityBreakdown": {"common": 2, "rare": 1}, "isMe": true}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.rarityBreakdown == ["common": 2, "rare": 1])
        #expect(standing.isMe == true)
    }

    @Test func standingDefaultsNullRarityBreakdownToEmpty() throws {
        let json = """
        {"placement": 3, "handle": "noah", "points": 0, "catches": 0, "rarityBreakdown": null}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.rarityBreakdown == [:])
        #expect(standing.isMe == nil)
    }

    @Test func standingDecodesWithUnknownExtraField() throws {
        let json = """
        {"placement": 1, "handle": "noah", "points": 40, "catches": 3,
         "rarityBreakdown": {}, "isMe": false, "avatarUrl": "https://example.com/x.png"}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.handle == "noah")
    }

    // MARK: - ChallengeDetail

    @Test func detailDecodesFullFixtureForCreateOrDetail() throws {
        let json = """
        {"challenge": \(summaryJSON),
         "standings": [{"placement": 1, "handle": "eli", "points": 40, "catches": 3, "rarityBreakdown": {}}],
         "me": {"placement": 2, "points": 40, "catches": 3},
         "winners": ["eli"]}
        """
        let detail = try decode(ChallengeDetail.self, json)
        #expect(detail.standings.count == 1)
        #expect(detail.winners == ["eli"])
        #expect(detail.me == ChallengeMyResult(placement: 2, points: 40, catches: 3))
        #expect(detail.alreadyIn == nil)
        #expect(detail.newDevice == nil)
        #expect(detail.challenge.isNoContest == false)
    }

    @Test func detailDecodesJoinResponseFixture() throws {
        let json = """
        {"challenge": \(summaryJSON),
         "standings": [], "me": null, "winners": [],
         "alreadyIn": false, "newDevice": true}
        """
        let detail = try decode(ChallengeDetail.self, json)
        #expect(detail.alreadyIn == false)
        #expect(detail.newDevice == true)
        #expect(detail.me == nil)
    }

    @Test func detailDefaultsMissingWinnersAndStandingsForALiveChallenge() throws {
        let json = "{\"challenge\": \(summaryJSON)}"
        let detail = try decode(ChallengeDetail.self, json)
        #expect(detail.standings.isEmpty)
        #expect(detail.winners.isEmpty)
        #expect(detail.me == nil)
        #expect(detail.alreadyIn == nil)
        #expect(detail.newDevice == nil)
    }

    // MARK: - ChallengeCatchLogEntry / ChallengeCatchLog

    @Test func catchLogEntryDecodesFullFixture() throws {
        let json = """
        {"aircraft": "Boeing 737-800", "rarity": "common", "points": 10,
         "caughtAt": "2026-09-20T09:05:00.000Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, json)
        #expect(entry.aircraft == "Boeing 737-800")
    }

    @Test func catchLogEntryDecodesMissingAircraft() throws {
        let json = """
        {"aircraft": null, "rarity": "rare", "points": 25, "caughtAt": "2026-09-20T09:05:00.000Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, json)
        #expect(entry.aircraft == nil)
    }

    @Test func catchLogDecodesFullFixture() throws {
        let json = """
        {"handle": "noah", "catches": [
          {"aircraft": "Boeing 737-800", "rarity": "common", "points": 10, "caughtAt": "2026-09-20T09:05:00.000Z"}
        ]}
        """
        let log = try decode(ChallengeCatchLog.self, json)
        #expect(log.handle == "noah")
        #expect(log.catches.count == 1)
    }

    // MARK: - ChallengeInvitePreview

    @Test func invitePreviewDecodesFullFixture() throws {
        let json = """
        {"challenge": \(summaryJSON), "participants": ["eli", "noah"],
         "needsHandle": false, "alreadyIn": false, "canJoin": true, "extraFutureField": true}
        """
        let preview = try decode(ChallengeInvitePreview.self, json)
        #expect(preview.participants == ["eli", "noah"])
        #expect(preview.canJoin)
        #expect(preview.reason == nil)
    }

    @Test func invitePreviewDecodesCannotJoinWithReason() throws {
        let json = """
        {"challenge": \(summaryJSON), "participants": ["eli"],
         "needsHandle": false, "alreadyIn": false, "canJoin": false, "reason": "full"}
        """
        let preview = try decode(ChallengeInvitePreview.self, json)
        #expect(preview.canJoin == false)
        #expect(preview.reason == "full")
    }

    // MARK: - ChallengesConfig

    @Test func configDecodesFullFixture() throws {
        let json = """
        {"enabled": true, "availability": "testflight", "minBuild": 95,
         "appStoreURL": "https://apps.apple.com/app/id123"}
        """
        let config = try decode(ChallengesConfig.self, json)
        #expect(config.enabled)
        #expect(config.minBuild == 95)
        #expect(config.appStoreURL != nil)
    }

    @Test func configDecodesMissingAppStoreURL() throws {
        let json = """
        {"enabled": false, "availability": "public", "minBuild": 100}
        """
        let config = try decode(ChallengesConfig.self, json)
        #expect(config.appStoreURL == nil)
    }

    // MARK: - ChallengeAPIError

    @Test func apiErrorDecodesFixture() throws {
        let json = "{\"error\": \"full\"}"
        let err = try decode(ChallengeAPIError.self, json)
        #expect(err.error == "full")
    }

    // MARK: - Date fallback (fractional and plain ISO-8601)

    @Test func decoderAcceptsBothFractionalAndPlainISO8601() throws {
        let plainDateJSON = """
        {"aircraft": null, "rarity": "common", "points": 10, "caughtAt": "2026-09-20T09:05:00Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, plainDateJSON)
        #expect(entry.points == 10)
    }

    // MARK: - ChallengeCreateRequest (encode)

    @Test func createRequestEncodesStartingNow() throws {
        let request = ChallengeCreateRequest.startingNow(name: "Weekend Flyoff", duration: "24h")
        let data = try JSONEncoder().encode(request)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(obj?["name"] == "Weekend Flyoff")
        #expect(obj?["start"] == "now")
        #expect(obj?["duration"] == "24h")
    }

    @Test func createRequestEncodesScheduledAsFractionalISO8601() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let request = ChallengeCreateRequest.scheduled(name: "Weekend Flyoff", at: date, duration: "24h")
        let data = try JSONEncoder().encode(request)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: String]
        let start = try #require(obj?["start"])
        // Round-trips through the shared decoder's fractional-or-plain ISO-8601 fallback.
        let decoded = try ChallengeJSON.decoder.decode(
            ChallengeCatchLogEntry.self,
            from: Data("{\"aircraft\": null, \"rarity\": \"common\", \"points\": 1, \"caughtAt\": \"\(start)\"}".utf8)
        )
        #expect(decoded.caughtAt == date)
    }
}
