//
//  StreakReminders.swift
//  Tailspot
//
//  Streak-protection reminders: at most ONE pending local notification at
//  any time, scheduled for the next evening on which a missing catch would
//  break a live streak. Local UserNotifications only — no push, no server
//  awareness, no capability or Info.plist string required.
//
//  Architecture mirrors the repo's planner convention (GuessScheduler):
//  a pure, clock-injected decision function carries ALL the guardrails and
//  is exhaustively unit-tested; a thin MainActor scheduler applies the
//  decision to the system notification center. The scheduler is invoked at
//  every point the right answer can change — after a catch, on foreground,
//  on a timezone change, and on the Settings toggle — and each run REPLACES
//  whatever was pending (single request identifier), so stale state
//  self-heals on the next trigger rather than needing a synchronous write.
//
//  Foreground policy (Noah, 2026-08-19): the nudge is SUPPRESSED while the
//  viewfinder is frontmost — if you are pointing the camera at the sky, a
//  banner telling you to go catch a plane is the app arguing with itself —
//  and PRESENTED anywhere else in the app, where you might genuinely not
//  have noticed the hour. `foregroundPresentation` holds that rule as a
//  pure function; the delegate only supplies the signal.
//
//  Guardrails, all structural:
//  - Streaks below `minimumStreak` schedule nothing (no day-1 nag; the
//    reminder only ever protects something already worth keeping).
//  - A broken or absent streak schedules nothing — a lapsed user is NEVER
//    nagged, because a reminder only exists while a streak is alive.
//  - One nudge per day at most: the pending slot is singular, and a
//    same-day reminder is only ever scheduled for a FUTURE 18:00 (a
//    post-18:00 recompute schedules nothing today — it can't know whether
//    today's catch will happen, so tomorrow stays unscheduled too until
//    a catch or the next foreground decides).
//  - Catching before 18:00 replaces today's pending nudge with tomorrow's;
//    the delivered copy (if any) is also retired from Notification Center.
//

import Foundation
import SwiftData
import UserNotifications
import UIKit
import os

nonisolated enum StreakReminders {
    /// The single notification identifier — pending and delivered alike.
    /// Remove-then-add on this one id is what makes the slot singular.
    static let notificationId = "tailspot.streak.reminder"
    /// Settings toggle, default ON (`@AppStorage` reads absent as true via
    /// the registered default in `StreakReminderCenter.remindersEnabled`).
    static let enabledKey = "tailspot.streak.remindersEnabled"
    /// One-shot latch for the in-camera permission pre-prompt. Set when the
    /// prompt is shown (any outcome) and by a Settings-initiated request —
    /// the ask never repeats; recovery from denial is the Settings row.
    static let permissionAskedKey = "tailspot.streak.permissionAsked"
    /// Fixed early-evening reminder hour (local). Not a setting in v1.
    static let reminderHour = 18
    /// The smallest streak worth protecting — also the reveal-chip and
    /// permission-ask threshold, so the three surfaces agree on when a
    /// streak "exists". TWO, not the scope doc's original three (Noah,
    /// 2026-08-19): two days is the first moment there is a streak to
    /// protect, and the ask reads strongest as "you have a 2-day streak,
    /// protect it?". Scope R2/AE2 were amended to match.
    static let minimumStreak = 2

    enum Decision: Equatable, Sendable {
        /// Schedule the one reminder for `dayKey` at 18:00 local, telling
        /// the user a `streakAtStake`-day streak ends that midnight.
        case schedule(dayKey: String, streakAtStake: Int)
        /// Ensure nothing is pending.
        case cancel
    }

    /// The whole guardrail matrix, pure. `days` is the catch-day set from
    /// `Streaks.daySet`; `now` and `timeZone` are injected so every case is
    /// testable at a fixed clock.
    static func decision(
        days: Set<String>,
        now: Date,
        timeZone: TimeZone = .current,
        enabled: Bool,
        authorized: Bool
    ) -> Decision {
        guard enabled, authorized else { return .cancel }
        let todayKey = Streaks.dayKey(for: now, timeZone: timeZone)
        let current = Streaks.currentStreak(days: days, todayKey: todayKey)
        guard current >= minimumStreak else { return .cancel }
        if days.contains(todayKey) {
            // Today is safe — protect the streak's continuation tomorrow.
            // (By tomorrow evening, "streak through yesterday" == today's
            // `current`, so the stake reads correctly when it fires.)
            guard let tomorrow = Streaks.key(byAdding: 1, to: todayKey) else { return .cancel }
            return .schedule(dayKey: tomorrow, streakAtStake: current)
        }
        // Live streak through yesterday, nothing today: nudge this evening —
        // but only while 18:00 is still ahead (scheduling a past calendar
        // trigger would never fire; scheduling tomorrow instead would nag a
        // possibly-already-broken streak).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        guard cal.component(.hour, from: now) < reminderHour else { return .cancel }
        return .schedule(dayKey: todayKey, streakAtStake: current)
    }

    /// Pre-prompt eligibility, pure: streak worth protecting, reminders not
    /// muted, never asked before, and the system prompt still available.
    static func shouldOfferAsk(
        currentStreak: Int,
        enabled: Bool,
        alreadyAsked: Bool,
        authStatusIsNotDetermined: Bool
    ) -> Bool {
        currentStreak >= minimumStreak && enabled && !alreadyAsked && authStatusIsNotDetermined
    }

    /// Foreground presentation policy, pure. Empty options = iOS suppresses
    /// the banner silently, which is right ONLY on the camera: the reminder
    /// asks for exactly what the user is already doing. In the Hangar, the
    /// Profile or Settings there is no such contradiction, so it presents.
    static func foregroundPresentation(cameraFrontmost: Bool) -> UNNotificationPresentationOptions {
        cameraFrontmost ? [] : [.banner, .sound]
    }

    /// The toast line shown over the viewfinder after a reminder tap — the
    /// user arrived here on purpose, so restate the stake rather than
    /// dropping them on a bare camera.
    static func tapToastLine(streakAtStake: Int?) -> String {
        guard let streakAtStake else { return "Streak at risk — catch one before midnight" }
        return "\(streakAtStake)-day streak — catch one before midnight"
    }

    // MARK: Notification copy (dried voice)

    static func title(streakAtStake: Int) -> String {
        "Streak on the line"
    }

    static func body(streakAtStake: Int) -> String {
        "Your \(streakAtStake)-day catch streak ends at midnight. One plane keeps it alive."
    }

    /// Calendar-trigger components for `dayKey` at 18:00. Full y/m/d so the
    /// trigger names ONE specific evening (hour-only components would fire
    /// on the next 18:00, wrong day included). No `timeZone`: the trigger
    /// floats with the device's zone, matching the frozen-label model.
    static func triggerComponents(dayKey: String) -> DateComponents? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]
        comps.month = parts[1]
        comps.day = parts[2]
        comps.hour = reminderHour
        return comps
    }
}

// MARK: - Scheduler + delegate

/// App→view channel for the reminder-tap toast line. `ContentView` observes
/// it, shows the line in the shared top-toast slot, and clears it. It exists
/// because the delegate is app-level while the toast slot is view-private.
@MainActor
@Observable
final class StreakToastRelay {
    var streakLine: String?
}

/// Applies `StreakReminders.decision` to the system notification center, and
/// receives the reminder's foreground delivery and tap (delegate assigned in
/// `TailspotApp.init` so a cold-start tap is caught).
final class StreakReminderCenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = StreakReminderCenter()

    /// The tap→toast channel, handed over by `TailspotApp` at launch.
    @MainActor var toastRelay: StreakToastRelay?

    /// The Settings toggle, absent-means-on.
    var remindersEnabled: Bool {
        UserDefaults.standard.object(forKey: StreakReminders.enabledKey) as? Bool ?? true
    }

    /// Convenience for callers holding a context, not rows (foreground /
    /// timezone / Settings triggers). One full fetch of the Hangar — the
    /// same order of work every Profile open already does.
    func sync(context: ModelContext, now: Date = Date()) async {
        let catches = (try? context.fetch(FetchDescriptor<Catch>())) ?? []
        await sync(catches: catches, now: now)
    }

    /// Recompute the decision and make the notification center match it.
    func sync(catches: [Catch], now: Date = Date()) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized = settings.authorizationStatus == .authorized
        let days = Streaks.daySet(catches: catches)
        let decision = StreakReminders.decision(
            days: days, now: now, enabled: remindersEnabled, authorized: authorized
        )
        // Replace-not-accumulate: clear the singular slot first. The
        // delivered copy is retired too — once the user has caught (or
        // muted, or lapsed), a stale nudge sitting in Notification Center
        // is a false statement.
        center.removePendingNotificationRequests(withIdentifiers: [StreakReminders.notificationId])
        center.removeDeliveredNotifications(withIdentifiers: [StreakReminders.notificationId])
        guard case let .schedule(dayKey, streak) = decision,
              let comps = StreakReminders.triggerComponents(dayKey: dayKey) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = StreakReminders.title(streakAtStake: streak)
        content.body = StreakReminders.body(streakAtStake: streak)
        content.sound = .default
        content.interruptionLevel = .active
        // Carried so the tap toast can restate the stake without re-deriving
        // a streak that may have moved on since the request was scheduled.
        content.userInfo = ["streak": streak]
        let request = UNNotificationRequest(
            identifier: StreakReminders.notificationId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        )
        do {
            try await center.add(request)
            Log.ui.notice("Streak reminder scheduled: \(dayKey, privacy: .public) 18:00, streak \(streak, privacy: .public)")
        } catch {
            Log.ui.error("Streak reminder scheduling failed: \(error, privacy: .public)")
        }
    }

    /// Fire the system permission prompt (from the pre-prompt's accept or
    /// the Settings toggle) and report the outcome through the standard
    /// activation event.
    func requestPermission() async -> Bool {
        UserDefaults.standard.set(true, forKey: StreakReminders.permissionAskedKey)
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
        ActivationTelemetry.firePermissionOutcome(permission: "notifications", granted: granted)
        return granted
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Delivered while the app is in the foreground. Suppressed on the
    /// camera, presented everywhere else — the rule lives in
    /// `StreakReminders.foregroundPresentation`; this only reads the signal.
    ///
    /// "Camera frontmost" is asked of UIKit rather than mirrored out of
    /// `ContentView`: every surface that covers the viewfinder (the Hangar,
    /// the Profile, both reveal covers, the replay sheet) is presented as a
    /// child of the root controller, so `presentedViewController == nil` IS
    /// the question, and reading it here keeps a state mirror — and another
    /// modifier link — out of `body` (the type-check budget, PR #184).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier == StreakReminders.notificationId else {
            return [.banner, .sound]
        }
        return await MainActor.run {
            StreakReminders.foregroundPresentation(cameraFrontmost: Self.cameraIsFrontmost())
        }
    }

    /// True when nothing is covering the viewfinder.
    @MainActor
    private static func cameraIsFrontmost() -> Bool {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        // No window at all (backgrounded mid-flight) counts as "not on the
        // camera": presenting is the recoverable side of the guess.
        guard let root else { return false }
        return root.presentedViewController == nil
    }

    /// Reminder tapped → the app opens to the camera (its root), so there is
    /// nothing to route: record that the nudge worked, and hand the toast
    /// line to the view so the user lands with the stake restated instead of
    /// on a bare viewfinder. The callback arrives on an arbitrary queue,
    /// hence `nonisolated`.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == StreakReminders.notificationId else {
            return
        }
        let streak = response.notification.request.content.userInfo["streak"] as? Int
        Analytics.capture(
            StreakTelemetry.reminderOpenedEvent,
            streak.map { ["streak": AnalyticsValue.int($0)] } ?? [:]
        )
        await MainActor.run {
            toastRelay?.streakLine = StreakReminders.tapToastLine(streakAtStake: streak)
        }
    }
}
