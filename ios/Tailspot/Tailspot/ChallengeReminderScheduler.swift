//
//  ChallengeReminderScheduler.swift
//  Tailspot
//
//  Applies `ChallengeReminders.plan(...)` to the system notification center.
//  The `ChallengesModel` hook (`ChallengeReminderScheduling`); the actual
//  `UNUserNotificationCenter` calls sit behind `ChallengeNotificationCenter`
//  so tests inject a fake and never touch the real notification system —
//  same seam shape as `ChallengesService` / `ADSBSource`.
//
//  Deliberately does NOT set the center's delegate — `StreakReminderCenter`
//  already owns the app's single `UNUserNotificationCenterDelegate`
//  (assigned in `TailspotApp.init`); routing a tapped challenge reminder to
//  a screen is integration work for whoever wires this scheduler in, not
//  this pass.
//
//  Every identifier this type touches comes from `ChallengeReminders`, whose
//  prefix (`"tailspot.challenge."`) is chosen specifically so it can never
//  collide with `StreakReminders.notificationId` — the removal pass below
//  filters on that prefix before touching anything, so the streak reminder's
//  slot is structurally untouchable here.
//

import Foundation
import UserNotifications
import os

/// The seam over `UNUserNotificationCenter` this scheduler needs — four
/// methods, none of which the real center exposes with quite this shape
/// (the async convenience wrappers below adapt its callback/property API).
/// `@MainActor` because the project's default actor isolation would make it
/// so anyway (this type is only ever driven from the MainActor scheduler),
/// matching `ChallengeReminderScheduling`'s explicit annotation.
@MainActor
protocol ChallengeNotificationCenter {
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func pendingRequests() async -> [UNNotificationRequest]
    func authorizationStatus() async -> UNAuthorizationStatus
}

extension UNUserNotificationCenter: ChallengeNotificationCenter {
    func pendingRequests() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

@MainActor
final class ChallengeReminderScheduler: ChallengeReminderScheduling {
    /// Settings toggle for challenge reminders specifically — independent of
    /// `StreakReminders.enabledKey`, absent-means-on like it.
    static let enabledKey = "tailspot.challenges.remindersEnabled"

    private let center: ChallengeNotificationCenter
    private let defaults: UserDefaults
    private let now: () -> Date

    init(
        center: ChallengeNotificationCenter = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.defaults = defaults
        self.now = now
    }

    var remindersEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - ChallengeReminderScheduling

    /// Fire-and-forget entry point the model calls after every refresh,
    /// create and join. The real work is the `async` overload just below —
    /// tests call that one directly so assertions run after it completes
    /// instead of racing a detached `Task`.
    func sync(open: [ChallengeSummary]) {
        Task { await sync(open: open) }
    }

    func cancel(challengeId: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: ChallengeReminders.identifiers(challengeId: challengeId)
        )
    }

    // MARK: - Core

    /// Recompute the plan for every open challenge and make the notification
    /// center match it: remove any challenge-prefixed pending identifier
    /// whose challenge is no longer open or whose exact moment is no longer
    /// planned, then (re-)add every currently-planned moment. Re-adding an
    /// already-pending identifier is a no-op replace (`UNUserNotificationCenter`
    /// treats `add` as upsert-by-identifier), so this never double-schedules.
    func sync(open: [ChallengeSummary]) async {
        let authorized = await center.authorizationStatus() == .authorized
        let enabled = remindersEnabled
        let t = now()

        let openIds = Set(open.map(\.id))
        let wantedPlans = open.flatMap { challenge in
            ChallengeReminders.plan(
                challengeId: challenge.id,
                name: challenge.name,
                startsAt: challenge.startsAt,
                endsAt: challenge.endsAt,
                durationPreset: challenge.durationPreset,
                now: t,
                enabled: enabled,
                authorized: authorized
            )
        }
        let wantedIds = Set(wantedPlans.map(\.identifier))

        let pending = await center.pendingRequests()
        let staleIds = pending.map(\.identifier).filter { identifier in
            guard ChallengeReminders.isChallengeIdentifier(identifier),
                  let challengeId = ChallengeReminders.challengeId(fromNotificationIdentifier: identifier)
            else { return false }
            return !openIds.contains(challengeId) || !wantedIds.contains(identifier)
        }
        if !staleIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: staleIds)
        }

        for plan in wantedPlans {
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            if let challengeId = ChallengeReminders.challengeId(fromNotificationIdentifier: plan.identifier) {
                content.userInfo = ["challengeId": challengeId]
            }
            // At least 1s: `plan` only emits moments strictly in the future,
            // but guard the system trigger's hard minimum anyway.
            let interval = max(1, plan.fireAt.timeIntervalSince(t))
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                Log.ui.debug("Challenge reminder scheduling failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
