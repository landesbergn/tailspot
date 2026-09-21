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
    /// Put the system permission prompt up. Only ever called from
    /// `requestAuthorizationIfNeeded()` below, which checks the status
    /// first — iOS shows the prompt exactly once per install, and a second
    /// call on a denied install resolves `false` without any UI.
    func requestAuthorization() async throws -> Bool
}

extension UNUserNotificationCenter: ChallengeNotificationCenter {
    func pendingRequests() async -> [UNNotificationRequest] {
        await pendingNotificationRequests()
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }

    /// Same options as `StreakReminderCenter.requestPermission` — one app,
    /// one permission, so the two features must not ask for different sets.
    func requestAuthorization() async throws -> Bool {
        try await requestAuthorization(options: [.alert, .sound])
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
        enqueueSync(open: open)
    }

    func cancel(challengeId: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: ChallengeReminders.identifiers(challengeId: challengeId)
        )
    }

    /// Ask for notification permission, but only when asking can do
    /// something: the challenge-reminders toggle is on and iOS has never
    /// shown the prompt for this install. Returns whether reminders can be
    /// delivered afterwards.
    ///
    /// Without this, `plan(...)`'s `authorized` guard meant challenge
    /// reminders NEVER scheduled for a user who never met the streak
    /// pre-prompt — the feature was silently dead for them.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        guard remindersEnabled else { return false }
        let status = await center.authorizationStatus()
        guard status == .notDetermined else { return status == .authorized }
        // Latch the shared one-shot so the in-camera streak pre-prompt
        // doesn't ask again for a permission iOS has already resolved.
        defaults.set(true, forKey: StreakReminders.permissionAskedKey)
        let granted = (try? await center.requestAuthorization()) ?? false
        ActivationTelemetry.firePermissionOutcome(permission: "notifications", granted: granted)
        return granted
    }

    /// Which planned identifiers are not already pending — i.e. the ones
    /// this sync genuinely schedules. Everything else is an upsert of a
    /// notification that was already on the books.
    nonisolated static func newlyScheduledIdentifiers(planned: [String], pending: [String]) -> Set<String> {
        Set(planned).subtracting(pending)
    }

    // MARK: - Serialization

    /// The sync currently running (or queued behind one). Every entry point
    /// chains onto it, so only one sync is ever in flight.
    ///
    /// Explain-as-we-go: `syncBody` reads the pending list, decides what is
    /// new, and only then adds. Between the read and the add it `await`s —
    /// and an `await` is a place where ANOTHER sync can start running on the
    /// same actor. Two overlapping syncs therefore both read a pending list
    /// that lacks the reminders the other is about to add, both conclude
    /// "these are new", and both fire `challenge_reminder_scheduled`. That
    /// race is easy to hit in real use: Settings' toggle re-sync against a
    /// foreground refresh, or a create against the permission ask that
    /// follows it. Chaining each call onto the previous task's `value` makes
    /// the read-decide-add sequence effectively atomic without a lock.
    private var inFlightSync: Task<Void, Never>?

    /// Queue a sync behind whatever is already running, and hand back the
    /// task so a caller (or a test) can await the whole chain.
    @discardableResult
    func enqueueSync(open: [ChallengeSummary]) -> Task<Void, Never> {
        let previous = inFlightSync
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.syncBody(open: open)
        }
        inFlightSync = task
        return task
    }

    // MARK: - Core

    /// Await a sync of this list — queued behind any sync already running.
    /// The production callers use the fire-and-forget `sync(open:)`; tests
    /// await this so assertions run after the work completes.
    func sync(open: [ChallengeSummary]) async {
        await enqueueSync(open: open).value
    }

    /// Recompute the plan for every open challenge and make the notification
    /// center match it: remove any challenge-prefixed pending identifier
    /// whose challenge is no longer open or whose exact moment is no longer
    /// planned, then (re-)add every currently-planned moment. Re-adding an
    /// already-pending identifier is a no-op replace (`UNUserNotificationCenter`
    /// treats `add` as upsert-by-identifier), so this never double-schedules.
    ///
    /// Never call this directly — go through `enqueueSync` / `sync`, which
    /// keep two of these from interleaving.
    private func syncBody(open: [ChallengeSummary]) async {
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
        let newIdentifiers = Self.newlyScheduledIdentifiers(
            planned: wantedPlans.map(\.identifier), pending: pending.map(\.identifier)
        )
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
                // Only count a reminder as newly scheduled. `sync` runs on
                // every foreground, refresh, create and join, and re-adding
                // an already-pending identifier is an upsert no-op — firing
                // the event there inflated the count by however often the
                // app was opened, which is not what "scheduled" means.
                if newIdentifiers.contains(plan.identifier) {
                    Analytics.capture("challenge_reminder_scheduled", [
                        "challenge_id": .string(challengeId),
                        "moment": .string(String(plan.identifier.split(separator: ".").last ?? "")),
                    ])
                }
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
