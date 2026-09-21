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
import UIKit
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

    /// A server `{"error": ""}` used to render as a bare "." — capitalize
    /// nothing, append a period.
    @Test func blankServerMessageFallsBackToAGenericSentence() {
        #expect(ChallengeCopy.message(for: .invalid("")) == "Something went wrong. Try again.")
        #expect(ChallengeCopy.message(for: .conflict("   ")) == "Something went wrong. Try again.")
        #expect(ChallengeCopy.message(for: .invalid("\n")) == "Something went wrong. Try again.")
    }

    @Test func serverMessageIsCapitalizedAndEndsInOnePeriod() {
        #expect(ChallengeCopy.message(for: .invalid("name must be 3–24 characters"))
                == "Name must be 3–24 characters.")
        // Already punctuated: no doubled period.
        #expect(ChallengeCopy.message(for: .conflict("challenge already started."))
                == "Challenge already started.")
        #expect(ChallengeCopy.message(for: .conflict("  padded reason  ")) == "Padded reason.")
    }

    // MARK: - detail polling cadence

    /// The 60 s poll used to run for `.upcoming` too — a challenge starting
    /// in three days re-fetched standings that cannot change, once a minute,
    /// for as long as the screen was open.
    @Test func pollWaitOnlyRunsWhileThereIsSomethingToPoll() {
        let live = ChallengeDetailScreen.livePollInterval
        #expect(ChallengeDetailScreen.pollWait(status: .live, secondsUntilStart: nil, hasDetail: true) == live)
        #expect(ChallengeDetailScreen.pollWait(status: .finished, secondsUntilStart: nil, hasDetail: true) == nil)
        #expect(ChallengeDetailScreen.pollWait(status: .cancelled, secondsUntilStart: nil, hasDetail: true) == nil)
        // A status this build doesn't recognize keeps refreshing rather
        // than freezing on a screen it can't reason about.
        #expect(ChallengeDetailScreen.pollWait(status: .unknown, secondsUntilStart: nil, hasDetail: true) == live)
    }

    /// The regression this guards: with no detail loaded there is no
    /// summary, so the status reads `.unknown` — and a poll table that
    /// stopped there left the error card with no way to heal itself short
    /// of a pull-to-refresh. Every status must keep retrying while the
    /// load has never succeeded.
    @Test func pollWaitKeepsRetryingWhileNothingHasLoaded() {
        let live = ChallengeDetailScreen.livePollInterval
        for status in [ChallengeStatus.unknown, .live, .upcoming, .finished, .cancelled] {
            #expect(ChallengeDetailScreen.pollWait(status: status, secondsUntilStart: nil, hasDetail: false) == live,
                    "\(status) with no detail must keep retrying")
        }
    }

    @Test func pollWaitSleepsUntilAnUpcomingStartBoundedByTheCap() {
        // Starts in 90 s: wake exactly at the start.
        #expect(ChallengeDetailScreen.pollWait(status: .upcoming, secondsUntilStart: 90, hasDetail: true) == 90)
        // Starts in three days: capped, so a cancel or a new joiner still
        // lands within the cap.
        #expect(ChallengeDetailScreen.pollWait(status: .upcoming, secondsUntilStart: 3 * 86_400, hasDetail: true)
                == ChallengeDetailScreen.upcomingPollCap)
        // Start already passed (the status hasn't caught up yet): never a
        // zero or negative sleep.
        #expect(ChallengeDetailScreen.pollWait(status: .upcoming, secondsUntilStart: -10, hasDetail: true) == 1)
    }

    // MARK: - view analytics latch

    /// The latch must not burn on a FAILED first load: the view analytics
    /// and `markResultsSeen` belong to the first load that produced a
    /// detail, even if that is a later pull-to-refresh.
    @Test func viewedFiresOnTheFirstSuccessfulLoadNotTheFirstAttempt() {
        #expect(!ChallengeDetailScreen.shouldFireViewed(hasDetail: false, alreadyFired: false))
        #expect(ChallengeDetailScreen.shouldFireViewed(hasDetail: true, alreadyFired: false))
        #expect(!ChallengeDetailScreen.shouldFireViewed(hasDetail: true, alreadyFired: true))
    }

    // MARK: - create lead time

    /// The server validates the 15-minute lead when the request ARRIVES, so
    /// a form that allows exactly 15 minutes 422s on a valid-looking tap.
    @Test func createLeadHasAMinuteOfCushionOverTheServerRule() {
        // The server's rule is 15 minutes, checked on arrival.
        #expect(!ChallengeCreateSheet.isValidLead(15 * 60))
        #expect(!ChallengeCreateSheet.isValidLead(15 * 60 + 59))
        // The copy the sheet shows quotes the client floor, not the
        // server's, so the message can't contradict the picker.
        #expect(ChallengeCreateSheet.minLeadMinutes == 16)
        #expect(ChallengeCreateSheet.isValidLead(16 * 60))
        #expect(ChallengeCreateSheet.isValidLead(14 * 86_400))
        #expect(!ChallengeCreateSheet.isValidLead(14 * 86_400 + 1))
    }

    // MARK: - share outcome

    /// `challenge_invite_shared` must mean "shared", not "opened the sheet".
    @Test func shareMethodIsOnlyReportedForACompletedShare() {
        #expect(ActivityShareSheet.method(activityType: nil, completed: false) == nil)
        #expect(ActivityShareSheet.method(activityType: .message, completed: false) == nil)
        #expect(ActivityShareSheet.method(activityType: .message, completed: true)
                == UIActivity.ActivityType.message.rawValue)
        // Completed but unattributed (iOS does this for some targets).
        #expect(ActivityShareSheet.method(activityType: nil, completed: true) == "share_sheet")
        #expect(ActivityShareSheet.method(activityType: UIActivity.ActivityType(""), completed: true)
                == "share_sheet")
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
