//
//  ChallengeReminderSchedulerTests.swift
//  TailspotTests
//
//  `ChallengeReminderScheduler` against a fake `ChallengeNotificationCenter`
//  — no real UNUserNotificationCenter access, so these run without a
//  permission prompt and deterministically. Covers: fire dates match
//  `ChallengeReminders.plan`, a re-sync after a leave removes the stale
//  identifiers, a pending `StreakReminders.notificationId` is never touched,
//  the disabled toggle and unauthorized status both suppress adding (and
//  the disabled case still cleans up what's already pending), and
//  `cancel(challengeId:)` removes exactly that challenge's three slots.
//

import Foundation
import Testing
import UserNotifications
@testable import Tailspot

@MainActor
final class FakeChallengeNotificationCenter: ChallengeNotificationCenter {
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedIdentifiers: [[String]] = []
    var pending: [UNNotificationRequest] = []
    var status: UNAuthorizationStatus = .authorized
    /// How many times the permission prompt was put up, and what the user
    /// "answers" (the fake also flips `status` the way iOS would).
    private(set) var authorizationRequests = 0
    var grantsAuthorization = true

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        pending
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        status = grantsAuthorization ? .authorized : .denied
        return grantsAuthorization
    }
}

@Suite("Challenge reminder scheduler")
@MainActor
struct ChallengeReminderSchedulerTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ChallengeReminderSchedulerTests.\(UUID().uuidString)")!
    }

    private func upcomingChallenge(id: String = "c1") -> ChallengeSummary {
        ChallengeFixtures.summary(
            id: id, name: "Weekend Flyoff", creator: "noah", code: nil,
            startsAt: now.addingTimeInterval(60), endsAt: now.addingTimeInterval(60 + 3600 * 24),
            preset: "24h", status: .upcoming, participantCount: 2, isCreator: true)
    }

    private func pendingStub(identifier: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: identifier, content: UNMutableNotificationContent(), trigger: nil)
    }

    // MARK: - sync adds planned identifiers with correct fire dates

    @Test func syncAddsPlannedIdentifiersWithCorrectFireDates() async throws {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })
        await scheduler.sync(open: [upcomingChallenge()])

        let byId = Dictionary(uniqueKeysWithValues: center.added.map { ($0.identifier, $0) })
        #expect(byId.count == 3)

        let startsTrigger = try #require(byId["tailspot.challenge.c1.starts"]?.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(startsTrigger.timeInterval - 60) < 0.001)

        // 24h preset: 1-hour ending-soon lead. endsAt = now + 60 + 86400.
        let endingSoonTrigger = try #require(byId["tailspot.challenge.c1.ending_soon"]?.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(endingSoonTrigger.timeInterval - (60 + 86_400 - 3600)) < 0.001)

        let finishedTrigger = try #require(byId["tailspot.challenge.c1.finished"]?.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(finishedTrigger.timeInterval - (60 + 86_400)) < 0.001)
    }

    // MARK: - re-sync after a leave removes them

    @Test func reSyncAfterLeaveRemovesThePlannedIdentifiers() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })
        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.pending.count == 3)

        // The user left — the challenge no longer appears in `open`.
        await scheduler.sync(open: [])
        #expect(center.pending.isEmpty)
    }

    // MARK: - a pending streak identifier is never touched

    @Test func pendingStreakIdentifierIsNeverRemovedOrAdded() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = [pendingStub(identifier: StreakReminders.notificationId)]
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })

        await scheduler.sync(open: [])

        #expect(center.pending.contains { $0.identifier == StreakReminders.notificationId })
        #expect(center.added.allSatisfy { $0.identifier != StreakReminders.notificationId })
        #expect(center.removedIdentifiers.allSatisfy { !$0.contains(StreakReminders.notificationId) })
    }

    @Test func pendingStreakIdentifierSurvivesAFullChallengeSync() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = [pendingStub(identifier: StreakReminders.notificationId)]
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })

        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.pending.contains { $0.identifier == StreakReminders.notificationId })
    }

    // MARK: - disabled toggle

    @Test func disabledTogglePreventsAddingAndRemovesExistingChallengeIds() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = ChallengeReminders.identifiers(challengeId: "c1").map(pendingStub(identifier:))
        let defaults = freshDefaults()
        defaults.set(false, forKey: ChallengeReminderScheduler.enabledKey)
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now })

        // The challenge is still open, but reminders are toggled off.
        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.added.isEmpty)
        #expect(center.pending.isEmpty)
    }

    // MARK: - unauthorized

    @Test func unauthorizedPreventsAdding() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .denied
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })

        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.added.isEmpty)
    }

    // MARK: - cancel

    @Test func cancelRemovesExactlyThatChallengesThreeIdentifiers() {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })

        scheduler.cancel(challengeId: "c1")

        #expect(center.removedIdentifiers.last == ChallengeReminders.identifiers(challengeId: "c1"))
    }

    // MARK: - permission

    /// The gap this closes: `plan(...)` refuses to schedule anything unless
    /// notifications are authorized, and nothing in the Challenges flow ever
    /// asked — so for a user who never met the streak pre-prompt, challenge
    /// reminders could not exist.
    @Test func requestAuthorizationAsksOnceWhenUndeterminedThenSchedules() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        let defaults = freshDefaults()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now })

        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.added.isEmpty, "undetermined permission schedules nothing")

        let granted = await scheduler.requestAuthorizationIfNeeded()
        #expect(granted)
        #expect(center.authorizationRequests == 1)
        // The shared one-shot latch is set, so the streak pre-prompt won't
        // ask again for a permission iOS has already resolved.
        #expect(defaults.bool(forKey: StreakReminders.permissionAskedKey))

        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.added.count == 3)
    }

    @Test func requestAuthorizationDoesNotAskWhenAlreadyDecided() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .authorized
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })
        #expect(await scheduler.requestAuthorizationIfNeeded())
        #expect(center.authorizationRequests == 0)

        center.status = .denied
        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        #expect(center.authorizationRequests == 0)
    }

    @Test func requestAuthorizationDoesNotAskWhenTheToggleIsOff() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        let defaults = freshDefaults()
        defaults.set(false, forKey: ChallengeReminderScheduler.enabledKey)
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now })

        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        #expect(center.authorizationRequests == 0)
    }

    @Test func requestAuthorizationDeniedLeavesNothingScheduled() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        center.grantsAuthorization = false
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })

        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.added.isEmpty)
    }

    // MARK: - `challenge_reminder_scheduled` fires once per identifier

    @Test func onlyIdentifiersNotAlreadyPendingCountAsNewlyScheduled() {
        let planned = ChallengeReminders.identifiers(challengeId: "c1")
        #expect(ChallengeReminderScheduler.newlyScheduledIdentifiers(planned: planned, pending: [])
                == Set(planned))
        #expect(ChallengeReminderScheduler.newlyScheduledIdentifiers(planned: planned, pending: planned)
                .isEmpty)
        #expect(ChallengeReminderScheduler.newlyScheduledIdentifiers(
            planned: planned, pending: [planned[0], "tailspot.streak.reminder"])
                == Set(planned.dropFirst()))
    }

    /// A re-sync (every foreground, every refresh, every create) re-adds the
    /// same identifiers as an upsert — none of them is newly scheduled, so
    /// none of them fires `challenge_reminder_scheduled` a second time.
    @Test func resyncSchedulesNothingNew() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now })
        await scheduler.sync(open: [upcomingChallenge()])
        let firstRound = center.pending.map(\.identifier)
        #expect(firstRound.count == 3)

        await scheduler.sync(open: [upcomingChallenge()])
        let newlySecondRound = ChallengeReminderScheduler.newlyScheduledIdentifiers(
            planned: center.added.suffix(3).map(\.identifier), pending: firstRound
        )
        #expect(newlySecondRound.isEmpty)
    }
}
