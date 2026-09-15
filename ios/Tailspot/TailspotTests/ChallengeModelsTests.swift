//
//  ChallengeModelsTests.swift
//  TailspotTests
//
//  Decoding fixtures for every Challenges wire model (spec section 13:
//  "Decoding fixtures for every response, including additive unknown
//  fields"). Each suite decodes a full fixture, a fixture with an extra
//  unknown key (must still decode), and — where the model has an optional
//  field — a fixture missing it.
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
      "id": "c1", "kind": "private", "name": "Weekend Flyoff", "code": "K7M4QD2X",
      "creatorHandle": "eli", "startsAt": "2026-09-20T09:00:00.000Z",
      "endsAt": "2026-09-21T09:00:00.000Z", "durationPreset": "24h",
      "participantCount": 3, "maxParticipants": 10, "status": "live",
      "cancelledAt": null, "outcome": null, "myPlacement": 2, "myPoints": 40
    }
    """

    @Test func summaryDecodesFullFixture() throws {
        let s = try decode(ChallengeSummary.self, summaryJSON)
        #expect(s.id == "c1")
        #expect(s.name == "Weekend Flyoff")
        #expect(s.code == "K7M4QD2X")
        #expect(s.status == .live)
        #expect(s.myPlacement == 2)
        #expect(s.myPoints == 40)
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
          "id": "c2", "kind": "private", "name": "Quick Sprint", "creatorHandle": "noah",
          "startsAt": "2026-09-20T09:00:00.000Z", "endsAt": "2026-09-20T10:00:00.000Z",
          "durationPreset": "1h", "participantCount": 1, "maxParticipants": 10,
          "status": "upcoming"
        }
        """
        let s = try decode(ChallengeSummary.self, minimal)
        #expect(s.code == nil)
        #expect(s.cancelledAt == nil)
        #expect(s.outcome == nil)
        #expect(s.myPlacement == nil)
        #expect(s.myPoints == nil)
    }

    // MARK: - ChallengeStanding

    @Test func standingDecodesFullFixture() throws {
        let json = """
        {"handle": "noah", "points": 40, "catches": 3, "placement": 1,
         "rarityBreakdown": {"common": 2, "rare": 1}, "isMe": true}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.rarityBreakdown == ["common": 2, "rare": 1])
        #expect(standing.isMe == true)
    }

    @Test func standingDefaultsMissingRarityBreakdownToEmpty() throws {
        let json = """
        {"handle": "noah", "points": 0, "catches": 0, "placement": 3}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.rarityBreakdown == [:])
        #expect(standing.isMe == nil)
    }

    @Test func standingDecodesWithUnknownExtraField() throws {
        let json = """
        {"handle": "noah", "points": 40, "catches": 3, "placement": 1,
         "rarityBreakdown": {}, "isMe": false, "avatarUrl": "https://example.com/x.png"}
        """
        let standing = try decode(ChallengeStanding.self, json)
        #expect(standing.handle == "noah")
    }

    // MARK: - ChallengeDetail

    @Test func detailDecodesFullFixture() throws {
        let json = """
        {"challenge": \(summaryJSON),
         "standings": [{"handle": "eli", "points": 40, "catches": 3, "placement": 1, "rarityBreakdown": {}}],
         "winners": ["eli"], "noContest": false}
        """
        let detail = try decode(ChallengeDetail.self, json)
        #expect(detail.standings.count == 1)
        #expect(detail.winners == ["eli"])
        #expect(detail.noContest == false)
    }

    @Test func detailDefaultsMissingFieldsForALiveNotYetFinalizedChallenge() throws {
        let json = "{\"challenge\": \(summaryJSON)}"
        let detail = try decode(ChallengeDetail.self, json)
        #expect(detail.standings.isEmpty)
        #expect(detail.winners.isEmpty)
        #expect(detail.noContest == false)
    }

    // MARK: - ChallengeCatchLogEntry

    @Test func catchLogEntryDecodesFullFixture() throws {
        let json = """
        {"make": "Boeing", "model": "737-800", "rarity": "common", "points": 10,
         "caughtAt": "2026-09-20T09:05:00.000Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, json)
        #expect(entry.make == "Boeing")
        #expect(entry.model == "737-800")
    }

    @Test func catchLogEntryDecodesMissingMakeAndModel() throws {
        let json = """
        {"rarity": "rare", "points": 25, "caughtAt": "2026-09-20T09:05:00.000Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, json)
        #expect(entry.make == nil)
        #expect(entry.model == nil)
    }

    // MARK: - ChallengeInvitePreview

    @Test func invitePreviewDecodesFullFixture() throws {
        let json = """
        {"name": "Weekend Flyoff", "creatorHandle": "eli",
         "startsAt": "2026-09-20T09:00:00.000Z", "endsAt": "2026-09-21T09:00:00.000Z",
         "participantHandles": ["eli", "noah"], "participantCount": 2,
         "maxParticipants": 10, "status": "upcoming", "extraFutureField": true}
        """
        let preview = try decode(ChallengeInvitePreview.self, json)
        #expect(preview.participantHandles == ["eli", "noah"])
        #expect(preview.status == .upcoming)
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

    // MARK: - Date fallback (fractional and plain ISO-8601)

    @Test func decoderAcceptsBothFractionalAndPlainISO8601() throws {
        let json = """
        {"enabled": true, "availability": "public", "minBuild": 1}
        """
        // No date fields here; date fallback is exercised via summary fixtures
        // above (fractional) and this one (plain, via ChallengeCatchLogEntry).
        _ = try decode(ChallengesConfig.self, json)
        let plainDateJSON = """
        {"rarity": "common", "points": 10, "caughtAt": "2026-09-20T09:05:00Z"}
        """
        let entry = try decode(ChallengeCatchLogEntry.self, plainDateJSON)
        #expect(entry.points == 10)
    }
}
