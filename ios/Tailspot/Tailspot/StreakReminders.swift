//
//  StreakReminders.swift
//  Tailspot
//
//  The guardrailed local streak-protection reminder (streaks plan U3).
//
//  Shape: a PURE decision function (the R2 guardrail matrix — unit-tested
//  with injected dates, never reading Date() or the notification center) and
//  a thin async wrapper that applies the decision via UNUserNotificationCenter.
//  The app pre-schedules at most ONE request ahead (single identifier,
//  remove-then-add), so "never nag a lapsed user" is structural: a broken
//  streak simply schedules nothing.
//
//  UserNotifications has no synchronous API, so the authorization status is
//  CACHED in UserDefaults (refreshed on every foreground) — that keeps the
//  decision synchronous while the apply hops through an async Task (KTD2).
//  A force-kill between a catch and the apply can leave a stale nudge; the
//  next foreground recompute repairs it.
//

import Foundation
import SwiftData
import UserNotifications
import os

nonisolated enum StreakReminders {

    // MARK: - Keys & constants

    /// App-level mute (the Settings REMINDERS toggle). Absent means ON —
    /// reminders default on (release-scope KD3), read via `isEnabled`.
    static let enabledKey = "tailspot.reminders.streakEnabled"
    /// The day a reminder was last scheduled FOR ("yyyy-MM-dd"). A day is
    /// spent once scheduled, regardless of delivery — the double-schedule
    /// guard (KTD3, AE6).
    static let lastScheduledDayKey = "tailspot.streak.lastReminderScheduledDay"
    /// One-shot latch for the contextual permission ask (KTD5). Set on ANY
    /// dismissal of the pre-prompt, accept or decline.
    static let permissionAskedKey = "tailspot.reminders.permissionAsked"
    /// Cached `UNAuthorizationStatus.rawValue`, refreshed on every
    /// foreground so the planner never has to await the center.
    static let cachedAuthStatusKey = "tailspot.reminders.cachedAuthStatus"

    /// Single pending-request identifier — remove-then-add on this ID is
    /// what makes a reschedule subsume cancelation.
    static let requestIdentifier = "tailspot.streak.reminder"
    /// Local fire hour. Fixed at 18:00 in v1 (no hour setting — plan scope).
    static let fireHour = 18
    /// Streaks shorter than this get no reminder (R2) and no at-risk
    /// styling on the Profile (R4).
    static let minProtectedStreak = 3

    static let scheduledEvent = "streak_reminder_scheduled"
    static let openedEvent = "streak_reminder_opened"

    // MARK: - Decision (pure)

    enum Decision: Equatable {
        /// Schedule (replacing any pending request) for `day` at 18:00
        /// local, protecting a streak of `streak` days.
        case schedule(day: Date, streak: Int)
        /// Remove any pending request.
        case cancel
        /// Leave the notification store and the spent marker untouched.
        case noop
    }

    /// The guardrail matrix (R2) as a pure function. `days` comes from
    /// `Trophies.dayBuckets(from:)`; everything else is injected state.
    ///
    /// Targets at most one day: today (live 3+ streak through yesterday, no
    /// catch yet, before 18:00, day unspent) or tomorrow (caught today with
    /// a resulting 3+ streak — pre-arm the next at-risk evening). Past
    /// 18:00 with no catch, nothing is scheduled: if tonight stays
    /// catchless the streak is dead by tomorrow, and R2 forbids nudging a
    /// broken streak — the next catch or foreground recompute arms tomorrow
    /// instead.
    static func decision(
        days: Set<Date>,
        now: Date,
        calendar: Calendar,
        lastScheduledDay: String?,
        enabled: Bool,
        authorized: Bool
    ) -> Decision {
        guard enabled, authorized else { return .cancel }
        let streak = Trophies.currentConsecutiveDayRun(days, asOf: now, calendar: calendar)
        guard streak >= minProtectedStreak else { return .cancel }

        let today = calendar.startOfDay(for: now)
        if days.contains(today) {
            // Caught today — protect tomorrow evening.
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return .noop }
            guard lastScheduledDay != Catch.dayKey(for: tomorrow, calendar: calendar) else { return .noop }
            return .schedule(day: tomorrow, streak: streak)
        }
        // Live streak through yesterday, today still uncaught.
        let hour = calendar.component(.hour, from: now)
        guard hour < fireHour else { return .cancel }
        guard lastScheduledDay != Catch.dayKey(for: today, calendar: calendar) else { return .noop }
        return .schedule(day: today, streak: streak)
    }

    /// The contextual permission ask fires exactly once, at the catch that
    /// completes a 3-day streak, and never for a user who already muted
    /// reminders in Settings (KTD5).
    static func shouldOfferPermissionAsk(
        currentStreak: Int,
        authStatusRaw: Int,
        asked: Bool,
        enabled: Bool
    ) -> Bool {
        currentStreak == minProtectedStreak
            && authStatusRaw == UNAuthorizationStatus.notDetermined.rawValue
            && !asked
            && enabled
    }

    // MARK: - Stored state helpers

    /// Absent key means true — reminders are on by default (KD3).
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    static func cachedAuthStatus(defaults: UserDefaults = .standard) -> UNAuthorizationStatus {
        UNAuthorizationStatus(rawValue: defaults.integer(forKey: cachedAuthStatusKey)) ?? .notDetermined
    }

    static func isAuthorized(defaults: UserDefaults = .standard) -> Bool {
        cachedAuthStatus(defaults: defaults) == .authorized
    }

    // MARK: - Apply (thin async wrapper)

    /// Apply a decision to the notification store and the spent marker.
    static func apply(
        _ decision: Decision,
        calendar: Calendar = Calendar(identifier: .gregorian),
        defaults: UserDefaults = .standard
    ) async {
        let center = UNUserNotificationCenter.current()
        switch decision {
        case .noop:
            return
        case .cancel:
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        case .schedule(let day, let streak):
            center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
            let content = UNMutableNotificationContent()
            content.title = "Streak at risk"
            content.body = "\(streak)-day streak, no catch yet today. One plane before midnight keeps it."
            content.sound = .default
            content.interruptionLevel = .active
            content.userInfo = ["streak": streak]
            // Full date components so today's 18:00 and tomorrow's are
            // distinct targets; timeZone stays nil so the fire time floats
            // with the device's local zone (KTD2).
            var comps = calendar.dateComponents([.year, .month, .day], from: day)
            comps.hour = fireHour
            comps.minute = 0
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: requestIdentifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
                defaults.set(Catch.dayKey(for: day, calendar: calendar), forKey: lastScheduledDayKey)
                Analytics.capture(scheduledEvent, ["streak": .int(streak)])
                Log.ui.info("StreakReminders: scheduled for \(Catch.dayKey(for: day, calendar: calendar), privacy: .public) (streak \(streak, privacy: .public))")
            } catch {
                Log.ui.error("StreakReminders: schedule failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Lifecycle entry points

    /// Foreground refresh: re-read the real authorization status into the
    /// cache (it can change in iOS Settings at any time — R6's heal path),
    /// then recompute and apply. MainActor: fetches from the main
    /// SwiftData context and `Catch` rows never cross actors.
    @MainActor
    static func foregroundRefresh(context: ModelContext) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        UserDefaults.standard.set(settings.authorizationStatus.rawValue, forKey: cachedAuthStatusKey)
        await recompute(context: context)
    }

    /// Recompute from the Hangar and apply — the post-catch hook (cached
    /// auth status; the catch path must not await the center before
    /// deciding) and the tail of `foregroundRefresh`.
    @MainActor
    static func recompute(context: ModelContext, now: Date = Date()) async {
        let catches = (try? context.fetch(FetchDescriptor<Catch>())) ?? []
        let calendar = Calendar(identifier: .gregorian)
        let d = decision(
            days: Trophies.dayBuckets(from: catches, calendar: calendar),
            now: now,
            calendar: calendar,
            lastScheduledDay: UserDefaults.standard.string(forKey: lastScheduledDayKey),
            enabled: isEnabled(),
            authorized: isAuthorized()
        )
        await apply(d, calendar: calendar)
    }
}
