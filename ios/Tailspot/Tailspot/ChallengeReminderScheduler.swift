//
//  ChallengeReminderScheduler.swift
//  Tailspot
//
//  Applies `ChallengeReminders.plan(...)` to the system notification center
//  — the fixed moments (starts / midway / ending_soon / finished) and the
//  per-day `daily` slots alike.
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
import UIKit
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
    /// The time zone the daily/midway day math runs in. Injected so the
    /// tests are not at the mercy of the simulator's zone; production reads
    /// the device's current zone on every plan, so a flight across zones is
    /// picked up by the next foreground sync.
    private let timeZone: () -> TimeZone
    /// Ask iOS for an APNs device token. A closure, not a direct
    /// `UIApplication` call, so the tests can watch it happen without a
    /// UIKit application object (and so the push half stays one seam).
    private let registerForRemoteNotifications: @MainActor () -> Void

    init(
        center: ChallengeNotificationCenter = UNUserNotificationCenter.current(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        timeZone: @escaping () -> TimeZone = { .current },
        registerForRemoteNotifications: (@MainActor () -> Void)? = nil
    ) {
        self.center = center
        self.defaults = defaults
        self.now = now
        self.timeZone = timeZone
        self.registerForRemoteNotifications = registerForRemoteNotifications ?? {
            PushRegistration.registerForRemoteNotifications()
        }
    }

    var remindersEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: - ChallengeReminderScheduling

    /// Fire-and-forget entry point the model calls after every refresh,
    /// create and join. The real work is the `async` overload just below —
    /// tests call that one directly so assertions run after it completes
    /// instead of racing a detached `Task`.
    func sync(open: [ChallengeSummary], placements: [String: Int]) {
        enqueueSync(open: open, placements: placements)
    }

    /// Drop every slot this challenge owns.
    ///
    /// Two halves, because the daily identifiers carry a day key this call
    /// has no dates to reproduce. The synchronous half removes the four
    /// fixed moments immediately (so a leave is visibly instant, and the
    /// behaviour every existing test pins is unchanged); the queued half
    /// sweeps the pending list for anything else belonging to this
    /// challenge — the dailies, and any moment a future build adds.
    func cancel(challengeId: String) {
        center.removePendingNotificationRequests(
            withIdentifiers: ChallengeReminders.identifiers(challengeId: challengeId)
        )
        enqueueCancelSweep(challengeId: challengeId)
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
        guard status == .notDetermined else {
            let authorized = status == .authorized
            if authorized { registerForRemoteNotifications() }
            return authorized
        }
        // Latch the shared one-shot so the in-camera streak pre-prompt
        // doesn't ask again for a permission iOS has already resolved.
        defaults.set(true, forKey: StreakReminders.permissionAskedKey)
        let granted = (try? await center.requestAuthorization()) ?? false
        ActivationTelemetry.firePermissionOutcome(permission: "notifications", granted: granted)
        // Local permission is also APNs permission: the moment the user
        // says yes, ask iOS for a device token so the backend can send the
        // remote moments (`overtaken`). Registering is cheap and idempotent
        // — iOS answers the delegate with the same token every launch.
        if granted { registerForRemoteNotifications() }
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
    func enqueueSync(open: [ChallengeSummary], placements: [String: Int] = [:]) -> Task<Void, Never> {
        let previous = inFlightSync
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.syncBody(open: open, placements: placements)
        }
        inFlightSync = task
        return task
    }

    /// The queued half of `cancel(challengeId:)`: remove every remaining
    /// pending identifier that belongs to this challenge. Chained onto the
    /// same task as the syncs so it can never read a pending list a sync is
    /// halfway through rewriting.
    @discardableResult
    func enqueueCancelSweep(challengeId: String) -> Task<Void, Never> {
        let previous = inFlightSync
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let stale = await self.center.pendingRequests().map(\.identifier).filter {
                ChallengeReminders.challengeId(fromNotificationIdentifier: $0) == challengeId
            }
            if !stale.isEmpty {
                self.center.removePendingNotificationRequests(withIdentifiers: stale)
            }
        }
        inFlightSync = task
        return task
    }

    // MARK: - Core

    /// Await a sync of this list — queued behind any sync already running.
    /// The production callers use the fire-and-forget `sync(open:)`; tests
    /// await this so assertions run after the work completes.
    func sync(open: [ChallengeSummary], placements: [String: Int] = [:]) async {
        await enqueueSync(open: open, placements: placements).value
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
    private func syncBody(open: [ChallengeSummary], placements: [String: Int]) async {
        let authorized = await center.authorizationStatus() == .authorized
        let enabled = remindersEnabled
        let t = now()
        let zone = timeZone()

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
                authorized: authorized,
                // Last-known standing, deliberately allowed to be stale —
                // every sync re-plans from whatever the model has now.
                placement: placements[challenge.id],
                participantCount: challenge.participantCount,
                timeZone: zone
            )
        }
        // Budget before anything else: iOS keeps only 64 pending local
        // notifications per app, silently dropping the rest, and the streak
        // reminder shares that pool.
        let (plans, droppedPlans) = Self.trimmedToBudget(wantedPlans)
        if !droppedPlans.isEmpty {
            Log.ui.notice(
                "Challenge reminders over budget: dropped \(droppedPlans.count, privacy: .public) of \(wantedPlans.count, privacy: .public)")
        }
        let wantedIds = Set(plans.map(\.identifier))

        let pending = await center.pendingRequests()
        let newIdentifiers = Self.newlyScheduledIdentifiers(
            planned: plans.map(\.identifier), pending: pending.map(\.identifier)
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

        for plan in plans {
            let parsed = ChallengeReminders.parse(plan.identifier)
            let content = UNMutableNotificationContent()
            content.title = plan.title
            content.body = plan.body
            content.sound = .default
            if let parsed {
                // `challengeId` is the tap-routing contract, and the REMOTE
                // pushes the backend sends carry the same two keys — see
                // ChallengeNotificationRouting.
                content.userInfo = [
                    "challengeId": parsed.challengeId,
                    "kind": parsed.moment.rawValue,
                ]
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
                continue
            }
            // AFTER a successful add, never before (review of PR #289): iOS
            // refuses an add when the 64-request pool is full, and an event
            // fired ahead of the call counted reminders that do not exist.
            //
            // Only count a reminder as newly scheduled. `sync` runs on every
            // foreground, refresh, create and join, and re-adding an
            // already-pending identifier is an upsert no-op — firing the
            // event there inflated the count by however often the app was
            // opened, which is not what "scheduled" means.
            if let parsed, newIdentifiers.contains(plan.identifier) {
                Analytics.capture("challenge_reminder_scheduled", [
                    "challenge_id": .string(parsed.challengeId),
                    "moment": .string(parsed.moment.rawValue),
                ])
            }
        }
    }

    // MARK: - Request budget

    /// The most pending challenge requests this app will hold at once.
    ///
    /// iOS caps an app at **64** pending local notifications and silently
    /// drops every request past it — and that pool is shared with the
    /// streak reminder. One 7d challenge now plans up to nine moments
    /// (starts + six dailies + ending_soon + finished), so a spotter in a
    /// handful of long challenges can reach the cap on their own. 40 leaves
    /// clear air for the streak slot and anything a later feature wants,
    /// and it is a number we choose rather than a limit we discover by
    /// having reminders vanish.
    static let requestBudget = 40

    /// Trim a plan set to the budget, dropping the least valuable moments
    /// first: the FURTHEST-FUTURE `daily` nudges (a nudge a week out is the
    /// one you would miss least, and by the time it matters another sync
    /// will have re-planned it), then `midway`. `starts`, `ending_soon` and
    /// `finished` are never dropped — they are the ones a user would call a
    /// bug if they went missing.
    nonisolated static func trimmedToBudget(
        _ plans: [ChallengeReminderPlan], limit: Int = requestBudget
    ) -> (kept: [ChallengeReminderPlan], dropped: [ChallengeReminderPlan]) {
        guard plans.count > limit else { return (plans, []) }
        var over = plans.count - limit
        var dropping = Set<String>()
        // Droppable moments in order of what we give up first.
        for moment in [ChallengeReminders.Moment.daily, .midway] where over > 0 {
            let candidates = plans
                .filter { ChallengeReminders.moment(fromNotificationIdentifier: $0.identifier) == moment }
                // Furthest future first.
                .sorted { $0.fireAt > $1.fireAt }
            for candidate in candidates where over > 0 {
                dropping.insert(candidate.identifier)
                over -= 1
            }
        }
        let kept = plans.filter { !dropping.contains($0.identifier) }
        let dropped = plans.filter { dropping.contains($0.identifier) }
        return (kept, dropped)
    }
}
