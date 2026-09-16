//
//  ChallengeScreensLogicTests.swift
//  TailspotTests
//
//  Assertion tests for the pure parts of the Challenges screens: section
//  membership from the fixture world, the create sheet's suggested name,
//  the join sheet's phase mapping, the results verdict, history labels,
//  the results-seen flag, and the copy helpers. Everything runs against
//  FixtureChallengesService with an injected clock.
//

#if DEBUG
import Testing
import Foundation
@testable import Tailspot

@MainActor
@Suite("Challenge screens — logic")
struct ChallengeScreensLogicTests {

    /// A fixed "now" (a Tuesday, 10:00 local) so countdown and weekday copy
    /// are deterministic.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 15; c.hour = 10; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    private func makeModel(state: FixtureChallengesService.State? = nil) -> (ChallengesModel, FixtureChallengesService) {
        let service = FixtureChallengesService(state: state ?? ChallengeFixtures.demoState(now: Self.now))
        let defaults = UserDefaults(suiteName: "ChallengeScreensLogicTests-\(UUID().uuidString)")!
        let model = ChallengesModel(service: service, currentBuild: 100, now: { Self.now }, defaults: defaults)
        return (model, service)
    }

    // MARK: Hub sections

    @Test func hubSectionsFromFixtureWorld() async {
        let (model, _) = makeModel()
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.isAvailable)
        #expect(model.live.map(\.id) == ["c-live"])
        #expect(model.upcoming.map(\.id) == ["c-upcoming"])
        #expect(model.history.map(\.id) == ["c-won", "c-lost", "c-nocontest", "c-cancelled"])
        if case .live(let s) = model.headline { #expect(s.id == "c-live") } else { Issue.record("headline should be the live challenge") }
    }

    @Test func hubEmptyWorldHasNoSections() async {
        let (model, _) = makeModel(state: ChallengeFixtures.emptyState())
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.live.isEmpty && model.upcoming.isEmpty && model.history.isEmpty)
        #expect(model.headline == .none)
    }

    @Test func verdictsFromConfig() async {
        var disabled = ChallengeFixtures.demoState(now: Self.now)
        disabled.config = ChallengesConfig(enabled: false, availability: "public", minBuild: 1, appStoreURL: nil)
        let (m1, _) = makeModel(state: disabled)
        await m1.refreshConfig()
        #expect(m1.verdict == .disabled)

        var old = ChallengeFixtures.demoState(now: Self.now)
        old.config = ChallengesConfig(enabled: true, availability: "public", minBuild: 999, appStoreURL: "https://apps.apple.com/x")
        let (m2, _) = makeModel(state: old)
        await m2.refreshConfig()
        #expect(m2.verdict == .updateRequired(minBuild: 999))
    }

    // MARK: Create sheet

    @Test func suggestedNameByWeekday() {
        let cal = Calendar.current
        // 2026-09-14 is a Monday.
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 14; c.hour = 12
        let monday = cal.date(from: c)!
        let expected = ["Monday Flyoff", "Tuesday Flyoff", "Wednesday Flyoff", "Thursday Flyoff",
                        "Weekend Flyoff", "Weekend Flyoff", "Weekend Flyoff"]
        for offset in 0..<7 {
            let day = cal.date(byAdding: .day, value: offset, to: monday)!
            #expect(ChallengeCopy.suggestedName(for: day, calendar: cal) == expected[offset], "offset \(offset)")
        }
    }

    @Test func nextWholeHourRoundsUp() {
        let cal = Calendar.current
        var c = DateComponents(); c.year = 2026; c.month = 9; c.day = 15; c.hour = 10; c.minute = 20
        let d = cal.date(from: c)!
        let next = ChallengeCreateSheet.nextWholeHour(after: d, calendar: cal)
        #expect(cal.component(.hour, from: next) == 11)
        #expect(cal.component(.minute, from: next) == 0)
    }

    // MARK: Join sheet phase mapping

    private func preview(canJoin: Bool, reason: String?, alreadyIn: Bool = false, needsHandle: Bool = false) -> ChallengeInvitePreview {
        let s = ChallengeFixtures.demoState(now: Self.now).open[1]
        return ChallengeInvitePreview(challenge: s, participants: ["eli"], needsHandle: needsHandle,
                                      alreadyIn: alreadyIn, canJoin: canJoin, reason: reason)
    }

    @Test func joinPhaseMapping() {
        typealias P = ChallengeJoinSheet.Phase
        #expect(P.from(preview: preview(canJoin: true, reason: nil)) == .preview(preview(canJoin: true, reason: nil), nil))
        #expect(P.from(preview: preview(canJoin: false, reason: "full")) == .preview(preview(canJoin: false, reason: "full"), .full))
        #expect(P.from(preview: preview(canJoin: false, reason: "ended")) == .preview(preview(canJoin: false, reason: "ended"), .ended))
        #expect(P.from(preview: preview(canJoin: false, reason: "cancelled")) == .preview(preview(canJoin: false, reason: "cancelled"), .cancelled))
        // Already in wins over everything, even a full board.
        #expect(P.from(preview: preview(canJoin: false, reason: "full", alreadyIn: true)) == .preview(preview(canJoin: false, reason: "full", alreadyIn: true), .alreadyIn))
        // needsHandle is not a terminal state — the button stays, gated.
        #expect(P.from(preview: preview(canJoin: true, reason: nil, needsHandle: true)) == .preview(preview(canJoin: true, reason: nil, needsHandle: true), nil))
    }

    @Test func fixtureJoinOutcomes() async {
        let (model, _) = makeModel()
        await model.refreshConfig()
        await model.refreshList()
        let d = try? await model.join(code: ChallengeFixtures.Codes.joinable)
        #expect(d?.challenge.id == "c-upcoming")
        await #expect(throws: ChallengesError.full) { try await model.join(code: ChallengeFixtures.Codes.full) }
        await #expect(throws: ChallengesError.closed) { try await model.join(code: ChallengeFixtures.Codes.ended) }
        await #expect(throws: ChallengesError.handleRequired) { try await model.join(code: ChallengeFixtures.Codes.needsHandle) }
        await #expect(throws: ChallengesError.notFound) { try await model.join(code: "ZZZZZZZZ") }
    }

    // MARK: Results verdict

    @Test func verdictLines() {
        let state = ChallengeFixtures.demoState(now: Self.now)
        #expect(ChallengeCopy.verdict(state.details["c-won"]!) == "You won by 40 points")
        #expect(ChallengeCopy.verdict(state.details["c-lost"]!) == "3rd of 6")
        #expect(ChallengeCopy.verdict(state.details["c-nocontest"]!) == "No contest")
        #expect(ChallengeCopy.verdict(state.details["c-cancelled"]!) == "Cancelled")

        // A tie at the top.
        let won = state.details["c-won"]!
        let tied = ChallengeDetail(
            challenge: won.challenge,
            standings: [
                ChallengeFixtures.standing(1, "noah", 620, 9, me: true),
                ChallengeFixtures.standing(1, "eli", 620, 10),
                ChallengeFixtures.standing(3, "maya", 250, 6),
            ],
            me: ChallengeMyResult(placement: 1, points: 620, catches: 9),
            winners: ["noah", "eli"], alreadyIn: nil, newDevice: nil)
        #expect(ChallengeCopy.verdict(tied) == "You tied for 1st")
        #expect(ChallengeCopy.isTie(tied))
        #expect(!ChallengeCopy.isTie(won))

        // Won by exactly one point reads singular.
        let byOne = ChallengeDetail(
            challenge: won.challenge,
            standings: [ChallengeFixtures.standing(1, "noah", 11, 1, me: true), ChallengeFixtures.standing(2, "eli", 10, 1)],
            me: ChallengeMyResult(placement: 1, points: 11, catches: 1), winners: ["noah"], alreadyIn: nil, newDevice: nil)
        #expect(ChallengeCopy.verdict(byOne) == "You won by 1 point")
    }

    @Test func historyLabels() {
        let state = ChallengeFixtures.demoState(now: Self.now)
        let byId = Dictionary(uniqueKeysWithValues: state.history.map { ($0.id, $0) })
        #expect(ChallengeCopy.historyLabel(byId["c-won"]!) == "Won")
        #expect(ChallengeCopy.historyLabel(byId["c-lost"]!) == "3rd of 6")
        #expect(ChallengeCopy.historyLabel(byId["c-nocontest"]!) == "No contest")
        #expect(ChallengeCopy.historyLabel(byId["c-cancelled"]!) == "Cancelled")
    }

    // MARK: Results seen once

    @Test func resultsSeenOnceThenQuiet() async {
        let (model, _) = makeModel()
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.unseenResults.map(\.id).contains("c-won"))
        #expect(!model.seenResultIds.contains("c-won"))
        model.markResultsSeen(id: "c-won")
        #expect(model.seenResultIds.contains("c-won"))
        #expect(!model.unseenResults.map(\.id).contains("c-won"))
        // Idempotent.
        model.markResultsSeen(id: "c-won")
        #expect(model.seenResultIds.count == 1)
    }

    @Test func hubSeenFlagPersists() {
        let (model, _) = makeModel()
        #expect(!model.hubSeen)
        model.markHubSeen()
        #expect(model.hubSeen)
    }

    // MARK: Copy helpers

    @Test func relativeMomentBuckets() {
        let cal = Calendar.current
        let now = Self.now
        #expect(ChallengeCopy.relativeMoment(now.addingTimeInterval(8 * 3600), now: now, calendar: cal).hasPrefix("today at"))
        #expect(ChallengeCopy.relativeMoment(now.addingTimeInterval(26 * 3600), now: now, calendar: cal).hasPrefix("tomorrow at"))
        #expect(ChallengeCopy.relativeMoment(now.addingTimeInterval(-20 * 3600), now: now, calendar: cal).hasPrefix("yesterday at"))
        let inThree = ChallengeCopy.relativeMoment(now.addingTimeInterval(3 * 86_400), now: now, calendar: cal)
        #expect(!inThree.hasPrefix("today") && !inThree.hasPrefix("tomorrow"))
        #expect(ChallengeCopy.endsLine(endsAt: now.addingTimeInterval(3600), now: now, calendar: cal).hasPrefix("ends today at"))
        #expect(ChallengeCopy.startsLine(startsAt: now.addingTimeInterval(3600), now: now, calendar: cal).hasPrefix("starts today at"))
    }

    @Test func spottersAndDurations() {
        #expect(ChallengeCopy.spotters(1) == "1 spotter")
        #expect(ChallengeCopy.spotters(5) == "5 spotters")
        #expect(ChallengeCopy.durationLabel("1h") == "1 hour")
        #expect(ChallengeCopy.durationLabel("7d") == "7 days")
    }

    @Test func shareMessageMentionsNameAndTiming() {
        let now = Self.now
        let nowMsg = ChallengeCopy.shareMessage(name: "Weekend Flyoff", preset: "24h", startsAt: now, now: now)
        #expect(nowMsg == "Race me on Tailspot — Weekend Flyoff, 24 hours starting now.")
        let later = ChallengeCopy.shareMessage(name: "Sunday Circuit", preset: "3d", startsAt: now.addingTimeInterval(3 * 3600), now: now)
        #expect(later.hasPrefix("Race me on Tailspot — Sunday Circuit, 3 days starting today at"))
    }

    @Test func errorMessagesArePlainSentences() {
        for e in [ChallengesError.unauthorized, .notFound, .full, .closed, .handleRequired,
                  .invalid("name must be 3–24 characters"), .conflict("challenge already started"),
                  .rateLimited, .unavailable, .network("x"), .decoding("y")] {
            let msg = ChallengeCopy.message(for: e)
            #expect(msg.hasSuffix("."), "\(e) → \(msg)")
            #expect(msg.first?.isUppercase == true, "\(e) → \(msg)")
        }
    }
}
#endif
