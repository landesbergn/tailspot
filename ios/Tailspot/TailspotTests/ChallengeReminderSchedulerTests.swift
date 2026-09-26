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
    /// Makes `add` slow, so a second `sync` has a window to interleave —
    /// the race the scheduler's serialization exists to close.
    var addDelayNanoseconds: UInt64 = 0

    func add(_ request: UNNotificationRequest) async throws {
        if addDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: addDelayNanoseconds)
        }
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

/// A counter the scheduler's APNs-registration hook increments. A reference
/// type because the hook is an escaping closure, and a plain `var` in a
/// value-type suite could not be written from it. The unit-test process must
/// never call the real `UIApplication.shared.registerForRemoteNotifications()`,
/// so every scheduler built here injects one of these (or a no-op).
@MainActor
final class RemoteRegistrationCounter {
    private(set) var count = 0
    func record() { count += 1 }
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
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        await scheduler.sync(open: [upcomingChallenge()])

        let byId = Dictionary(uniqueKeysWithValues: center.added.map { ($0.identifier, $0) })
        // starts, midway (24h), ending_soon, finished. `now` is 08:00 UTC and
        // the suite pins GMT, so the midpoint (20:01) is inside the daylight
        // window and the midway nudge survives.
        #expect(byId.count == 4)
        let midwayTrigger = try #require(byId["tailspot.challenge.c1.midway"]?.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(midwayTrigger.timeInterval - (60 + 12 * 3600)) < 0.001)

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
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.pending.count == 4)

        // The user left — the challenge no longer appears in `open`.
        await scheduler.sync(open: [])
        #expect(center.pending.isEmpty)
    }

    // MARK: - a pending streak identifier is never touched

    @Test func pendingStreakIdentifierIsNeverRemovedOrAdded() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = [pendingStub(identifier: StreakReminders.notificationId)]
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        await scheduler.sync(open: [])

        #expect(center.pending.contains { $0.identifier == StreakReminders.notificationId })
        #expect(center.added.allSatisfy { $0.identifier != StreakReminders.notificationId })
        #expect(center.removedIdentifiers.allSatisfy { !$0.contains(StreakReminders.notificationId) })
    }

    @Test func pendingStreakIdentifierSurvivesAFullChallengeSync() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = [pendingStub(identifier: StreakReminders.notificationId)]
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.pending.contains { $0.identifier == StreakReminders.notificationId })
    }

    // MARK: - disabled toggle

    @Test func disabledTogglePreventsAddingAndRemovesExistingChallengeIds() async {
        let center = FakeChallengeNotificationCenter()
        center.pending = ChallengeReminders.identifiers(challengeId: "c1").map(pendingStub(identifier:))
        let defaults = freshDefaults()
        defaults.set(false, forKey: ChallengeReminderScheduler.enabledKey)
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        // The challenge is still open, but reminders are toggled off.
        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.added.isEmpty)
        #expect(center.pending.isEmpty)
    }

    // MARK: - unauthorized

    @Test func unauthorizedPreventsAdding() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .denied
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        await scheduler.sync(open: [upcomingChallenge()])

        #expect(center.added.isEmpty)
    }

    // MARK: - cancel

    @Test func cancelRemovesExactlyThatChallengesFixedIdentifiers() {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        scheduler.cancel(challengeId: "c1")

        #expect(center.removedIdentifiers.last == ChallengeReminders.identifiers(challengeId: "c1"))
    }

    /// A 7d challenge's daily nudges survive a leave: the fixed four come
    /// off synchronously, the per-day slots on the queued sweep (they carry
    /// a day key `cancel` has no dates to reproduce).
    @Test func cancelSweepsTheDailyIdentifiersToo() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(
            center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        let long = ChallengeFixtures.summary(
            id: "c9", name: "Long Haul", creator: "noah", code: nil,
            startsAt: now.addingTimeInterval(60),
            endsAt: now.addingTimeInterval(60 + 7 * 86_400),
            preset: "7d", status: .upcoming, participantCount: 3)
        await scheduler.sync(open: [long])
        #expect(center.pending.contains { $0.identifier.contains(".daily.") })

        scheduler.cancel(challengeId: "c9")
        await scheduler.enqueueCancelSweep(challengeId: "c9").value
        #expect(center.pending.isEmpty)
    }

    // MARK: - placements feed the mid-challenge copy

    @Test func placementsReachTheDailyCopy() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(
            center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        let long = ChallengeFixtures.summary(
            id: "c9", name: "Long Haul", creator: "noah", code: nil,
            startsAt: now.addingTimeInterval(60),
            endsAt: now.addingTimeInterval(60 + 7 * 86_400),
            preset: "7d", status: .upcoming, participantCount: 4)

        await scheduler.sync(open: [long], placements: ["c9": 2])
        let daily = center.added.first { $0.identifier.contains(".daily.") }
        #expect(daily?.content.body == "You're 2nd in Long Haul.")

        // No placement known → the neutral line, not a missing banner.
        let plain = FakeChallengeNotificationCenter()
        let plainScheduler = ChallengeReminderScheduler(
            center: plain, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        await plainScheduler.sync(open: [long])
        let neutral = plain.added.first { $0.identifier.contains(".daily.") }
        #expect(neutral?.content.body == "Long Haul is on. Check the standings.")
    }

    /// The tap-routing contract: every scheduled request carries the
    /// challenge id and the moment in `userInfo`, exactly like the remote
    /// pushes the backend sends.
    @Test func everyRequestCarriesTheRoutingUserInfo() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(
            center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        await scheduler.sync(open: [upcomingChallenge()])

        for request in center.added {
            #expect(request.content.userInfo["challengeId"] as? String == "c1")
            let kind = request.content.userInfo["kind"] as? String
            #expect(kind != nil)
            #expect(ChallengeReminders.Moment(rawValue: kind ?? "") != nil)
        }
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
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.added.isEmpty, "undetermined permission schedules nothing")

        let granted = await scheduler.requestAuthorizationIfNeeded()
        #expect(granted)
        #expect(center.authorizationRequests == 1)
        // The shared one-shot latch is set, so the streak pre-prompt won't
        // ask again for a permission iOS has already resolved.
        #expect(defaults.bool(forKey: StreakReminders.permissionAskedKey))

        await scheduler.sync(open: [upcomingChallenge()])
        #expect(center.added.count == 4)
    }

    @Test func requestAuthorizationDoesNotAskWhenAlreadyDecided() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .authorized
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        #expect(await scheduler.requestAuthorizationIfNeeded())
        #expect(center.authorizationRequests == 0)

        center.status = .denied
        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        #expect(center.authorizationRequests == 0)
    }

    /// Local permission is also APNs permission. The moment the ask
    /// succeeds — or the moment we find it already granted — the app asks
    /// iOS for a device token, so the backend can send the remote moments.
    @Test func grantedAuthorizationAsksIOSForADeviceToken() async {
        let counter = RemoteRegistrationCounter()
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        let scheduler = ChallengeReminderScheduler(
            center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: { counter.record() })

        #expect(await scheduler.requestAuthorizationIfNeeded())
        #expect(counter.count == 1)

        // Already authorized on a later run: still register (iOS hands back
        // the same token, and a reinstall needs a fresh one).
        #expect(await scheduler.requestAuthorizationIfNeeded())
        #expect(counter.count == 2)
    }

    @Test func deniedAuthorizationNeverAsksForADeviceToken() async {
        let counter = RemoteRegistrationCounter()
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        center.grantsAuthorization = false
        let scheduler = ChallengeReminderScheduler(
            center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: { counter.record() })

        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        #expect(counter.count == 0)
    }

    @Test func requestAuthorizationDoesNotAskWhenTheToggleIsOff() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        let defaults = freshDefaults()
        defaults.set(false, forKey: ChallengeReminderScheduler.enabledKey)
        let scheduler = ChallengeReminderScheduler(center: center, defaults: defaults, now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

        #expect(await scheduler.requestAuthorizationIfNeeded() == false)
        #expect(center.authorizationRequests == 0)
    }

    @Test func requestAuthorizationDeniedLeavesNothingScheduled() async {
        let center = FakeChallengeNotificationCenter()
        center.status = .notDetermined
        center.grantsAuthorization = false
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})

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
    /// same three identifiers as an upsert, and the pending list is
    /// unchanged by it — the state half of "nothing new was scheduled".
    /// That the EVENT doesn't fire again is asserted through the analytics
    /// sink in `AnalyticsFacadeTests`
    /// (`reminderScheduledFiresOncePerIdentifierNotPerSync`), which is the
    /// one serialized owner of the process-global `Analytics._testSink`.
    @Test func resyncUpsertsTheSameIdentifiers() async {
        let center = FakeChallengeNotificationCenter()
        let scheduler = ChallengeReminderScheduler(center: center, defaults: freshDefaults(), now: { now },
            timeZone: { .gmt }, registerForRemoteNotifications: {})
        await scheduler.sync(open: [upcomingChallenge()])
        let firstRound = Set(center.pending.map(\.identifier))
        #expect(firstRound.count == 4)

        await scheduler.sync(open: [upcomingChallenge()])
        #expect(Set(center.pending.map(\.identifier)) == firstRound)
        #expect(center.added.count == 8, "both syncs upsert; the second adds no NEW identifier")
    }
}
