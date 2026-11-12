//
//  WeeklyRecapReminder.swift
//  Tailspot
//
//  The Monday-morning "your week" notification (Noah, 2026-11-10). One
//  pending local notification at most, for the next Monday 09:00 local,
//  summarising the week that Monday closes. Tapping it opens the weekly
//  recap as its own sheet over the camera.
//
//  Same shape as StreakReminders: a pure, clock-injected `plan` holds every
//  rule and is unit-tested; `WeeklyRecapReminderScheduler.sync` applies it.
//  It runs inside `StreakReminderCenter.sync`, which already fires after a
//  catch, on every foreground, on a timezone change and from Settings — so
//  the pending copy is rewritten each time the week's numbers move. Catches
//  only happen with the app open, so by Monday the copy is final.
//
//  Rules:
//  - Nothing without notification permission, and nothing with the
//    Settings toggle off. The recap never asks for permission itself.
//  - Nothing for a week with no catches: the notification only reports
//    planes you actually caught, it never nags a lapsed user.
//  - Silent while the camera is frontmost (the streak nudge's rule): a
//    banner over the viewfinder gets in the way of a plane overhead.
//

import Foundation
import UserNotifications
import os

enum WeeklyRecapReminder {
    static let notificationId = "tailspot.weeklyRecap.reminder"
    static let enabledKey = "tailspot.weeklyRecap.remindersEnabled"
    /// Local hour on Monday.
    static let hour = 9

    struct Plan: Equatable, Sendable {
        /// The Monday it fires, "yyyy-MM-dd" local.
        let fireDayKey: String
        /// The Monday the summarised week started.
        let weekStartKey: String
        let catchCount: Int
        let newTypes: Int
        let title: String
        let body: String
    }

    /// Which Monday fires next, and which week it reports. Before 09:00 on
    /// a Monday that's this morning (reporting last week); otherwise next
    /// Monday (reporting the week in progress).
    static func target(now: Date, timeZone: TimeZone) -> (fire: String, weekStart: String)? {
        let todayKey = Streaks.dayKey(for: now, timeZone: timeZone)
        guard let offset = WeeklyRecap.daysSinceMonday(key: todayKey),
              let thisMonday = Streaks.key(byAdding: -offset, to: todayKey) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if offset == 0, cal.component(.hour, from: now) < hour,
           let lastMonday = Streaks.key(byAdding: -7, to: thisMonday) {
            return (thisMonday, lastMonday)
        }
        guard let nextMonday = Streaks.key(byAdding: 7, to: thisMonday) else { return nil }
        return (nextMonday, thisMonday)
    }

    @MainActor
    static func plan(
        catches: [Catch],
        now: Date,
        timeZone: TimeZone = .current,
        enabled: Bool,
        authorized: Bool
    ) -> Plan? {
        guard enabled, authorized,
              let t = target(now: now, timeZone: timeZone),
              let recap = WeeklyRecap.week(startingAt: t.weekStart, catches: catches, timeZone: timeZone),
              recap.catchCount > 0 else { return nil }
        return Plan(
            fireDayKey: t.fire,
            weekStartKey: t.weekStart,
            catchCount: recap.catchCount,
            newTypes: recap.newTypes,
            title: "Your week in planes",
            body: body(catchCount: recap.catchCount, newTypes: recap.newTypes)
        )
    }

    /// "9 planes caught, 3 new types. Tap to see your week."
    static func body(catchCount: Int, newTypes: Int) -> String {
        let planes = catchCount == 1 ? "1 plane caught" : "\(catchCount) planes caught"
        let types: String
        switch newTypes {
        case 0: types = ""
        case 1: types = ", 1 new type"
        default: types = ", \(newTypes) new types"
        }
        return "\(planes)\(types). Tap to see your week."
    }

    static func triggerComponents(dayKey: String) -> DateComponents? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = hour
        return comps
    }
}

enum WeeklyRecapReminderScheduler {
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: WeeklyRecapReminder.enabledKey) as? Bool ?? true
    }

    /// Replace the pending notification with the current plan (or none).
    static func sync(catches: [Catch], now: Date, center: UNUserNotificationCenter, authorized: Bool) async {
        let plan = WeeklyRecapReminder.plan(
            catches: catches, now: now, enabled: enabled, authorized: authorized)
        center.removePendingNotificationRequests(withIdentifiers: [WeeklyRecapReminder.notificationId])
        guard let plan, let comps = WeeklyRecapReminder.triggerComponents(dayKey: plan.fireDayKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = plan.title
        content.body = plan.body
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo = ["weekStart": plan.weekStartKey]
        let request = UNNotificationRequest(
            identifier: WeeklyRecapReminder.notificationId,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do {
            try await center.add(request)
            Log.ui.notice("Weekly recap reminder scheduled: \(plan.fireDayKey, privacy: .public), \(plan.catchCount, privacy: .public) catches")
        } catch {
            Log.ui.error("Weekly recap reminder scheduling failed: \(error, privacy: .public)")
        }
    }
}

/// A tapped recap notification parks here; `WeeklyRecapRouter` (inside the
/// catch screen) closes whatever sheet is up and opens the recap sheet.
@MainActor
@Observable
final class WeeklyRecapRelay {
    static let shared = WeeklyRecapRelay()
    var pendingOpen = false
}
