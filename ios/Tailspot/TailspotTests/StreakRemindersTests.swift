//
//  StreakRemindersTests.swift
//  TailspotTests
//
//  The reminder planner's guardrail matrix (StreakReminders.decision) is
//  the feature's spec: exactly one nudge slot, only for a live streak worth
//  protecting, never for a lapsed user, never after the evening window,
//  never when muted or unauthorized. Pure function, fixed clock, injected
//  zone — every case is a plain table check.
//

import Testing
import Foundation
import UserNotifications
@testable import Tailspot

@Suite("Streak reminders")
struct StreakRemindersTests {

    private let utc = TimeZone(identifier: "UTC")!
    private let la = TimeZone(identifier: "America/Los_Angeles")!

    // 2026-08-17T00:00Z + offset hours.
    private func utcInstant(hour: Double) -> Date {
        Date(timeIntervalSince1970: 1_786_924_800 + hour * 3600)
    }

    /// A live 4-day streak through "yesterday" (Aug 13–16, UTC days).
    private let streakThroughYesterday: Set<String> = [
        "2026-08-13", "2026-08-14", "2026-08-15", "2026-08-16",
    ]

    // MARK: - Mute + permission guards

    @Test func mutedSchedulesNothing() {
        let d = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 9), timeZone: utc,
            enabled: false, authorized: true)
        #expect(d == .cancel)
    }

    @Test func unauthorizedSchedulesNothing() {
        let d = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 9), timeZone: utc,
            enabled: true, authorized: false)
        #expect(d == .cancel)
    }

    // MARK: - Streak thresholds

    @Test func oneDayStreakIsNotWorthNagging() {
        // Caught today only — a fresh day-1 streak schedules nothing for
        // tomorrow (no re-engagement nag off a single catch).
        let d = StreakReminders.decision(
            days: ["2026-08-17"], now: utcInstant(hour: 9), timeZone: utc,
            enabled: true, authorized: true)
        #expect(d == .cancel)
    }

    @Test func twoDayStreakCaughtTodaySchedulesTomorrow() {
        let d = StreakReminders.decision(
            days: ["2026-08-16", "2026-08-17"], now: utcInstant(hour: 9), timeZone: utc,
            enabled: true, authorized: true)
        #expect(d == .schedule(dayKey: "2026-08-18", streakAtStake: 2))
    }

    // MARK: - The at-risk day

    @Test func liveStreakUncaughtMorningSchedulesThisEvening() {
        let d = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 9), timeZone: utc,
            enabled: true, authorized: true)
        #expect(d == .schedule(dayKey: "2026-08-17", streakAtStake: 4))
    }

    @Test func windowClosesAtSixPMSharp() {
        // 17:59 still schedules today; 18:00:00 and later do not (the
        // trigger would be in the past), and tomorrow is NOT scheduled
        // either — whether the streak survives today is still unknown.
        let before = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 17.99), timeZone: utc,
            enabled: true, authorized: true)
        #expect(before == .schedule(dayKey: "2026-08-17", streakAtStake: 4))
        let atSix = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 18), timeZone: utc,
            enabled: true, authorized: true)
        #expect(atSix == .cancel)
        let evening = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 18.5), timeZone: utc,
            enabled: true, authorized: true)
        #expect(evening == .cancel)
    }

    @Test func catchingTodayMovesTheNudgeToTomorrow() {
        // Same streak, plus today's catch at 17:00 → the pending today-18:00
        // request is replaced by tomorrow's (AE: no nag minutes after a catch).
        var days = streakThroughYesterday
        days.insert("2026-08-17")
        let d = StreakReminders.decision(
            days: days, now: utcInstant(hour: 17), timeZone: utc,
            enabled: true, authorized: true)
        #expect(d == .schedule(dayKey: "2026-08-18", streakAtStake: 5))
    }

    // MARK: - Never nag the lapsed

    @Test func brokenStreakSchedulesNothingEver() {
        // A glorious 4-day run that ended two days ago: current streak is 0,
        // so nothing schedules — a lapsed user never hears from us again.
        let d = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 9).addingTimeInterval(86_400 * 2),
            timeZone: utc, enabled: true, authorized: true)
        #expect(d == .cancel)
    }

    @Test func emptyHangarSchedulesNothing() {
        let d = StreakReminders.decision(
            days: [], now: utcInstant(hour: 9), timeZone: utc,
            enabled: true, authorized: true)
        #expect(d == .cancel)
    }

    // MARK: - Zone injection

    @Test func decisionUsesTheGivenZoneForTodayAndTheHour() {
        // 18:30Z on Aug 17 is 11:30 in California — the LA "today" window is
        // still open, and LA's today (the 17th) is the target. The LA day set
        // must be a streak through the LA yesterday.
        let d = StreakReminders.decision(
            days: streakThroughYesterday, now: utcInstant(hour: 18.5), timeZone: la,
            enabled: true, authorized: true)
        #expect(d == .schedule(dayKey: "2026-08-17", streakAtStake: 4))
    }

    // MARK: - Trigger + copy

    @Test func triggerComponentsNameOneSpecificEvening() {
        let comps = StreakReminders.triggerComponents(dayKey: "2026-08-18")
        #expect(comps?.year == 2026)
        #expect(comps?.month == 8)
        #expect(comps?.day == 18)
        #expect(comps?.hour == StreakReminders.reminderHour)
        // Floating local time — a fixed zone would detach the nudge from
        // the user's evening after travel.
        #expect(comps?.timeZone == nil)
        #expect(StreakReminders.triggerComponents(dayKey: "garbage") == nil)
    }

    @Test func notificationCopyQuotesTheStake() {
        #expect(StreakReminders.body(streakAtStake: 4).contains("4-day"))
        #expect(!StreakReminders.title(streakAtStake: 4).isEmpty)
    }

    // MARK: - Permission-ask eligibility

    @Test func askEligibilityMatrix() {
        // Eligible: streak at threshold, enabled, unasked, undetermined.
        #expect(StreakReminders.shouldOfferAsk(
            currentStreak: 2, enabled: true, alreadyAsked: false,
            authStatusIsNotDetermined: true))
        // A longer streak stays eligible (a contested day-2 moment retries).
        #expect(StreakReminders.shouldOfferAsk(
            currentStreak: 6, enabled: true, alreadyAsked: false,
            authStatusIsNotDetermined: true))
        // Each guard alone kills it.
        #expect(!StreakReminders.shouldOfferAsk(
            currentStreak: 1, enabled: true, alreadyAsked: false,
            authStatusIsNotDetermined: true))
        #expect(!StreakReminders.shouldOfferAsk(
            currentStreak: 2, enabled: false, alreadyAsked: false,
            authStatusIsNotDetermined: true))
        #expect(!StreakReminders.shouldOfferAsk(
            currentStreak: 2, enabled: true, alreadyAsked: true,
            authStatusIsNotDetermined: true))
        #expect(!StreakReminders.shouldOfferAsk(
            currentStreak: 2, enabled: true, alreadyAsked: false,
            authStatusIsNotDetermined: false))
    }

    // MARK: - Foreground presentation (Noah, 2026-08-19)

    /// Silent on the camera, banner everywhere else. On the viewfinder the
    /// reminder would be asking for exactly what the user is already doing;
    /// in the Hangar or Settings there is no such contradiction.
    @Test func foregroundPresentationIsSilentOnlyOnTheCamera() {
        #expect(StreakReminders.foregroundPresentation(cameraFrontmost: true).isEmpty)
        #expect(StreakReminders.foregroundPresentation(cameraFrontmost: false)
                == [.banner, .sound])
    }

    /// The tap toast names the streak when the request carried one, and
    /// still says something useful when it didn't (an old request scheduled
    /// by a build that predates the userInfo payload).
    @Test func tapToastLineNamesTheStakeWhenKnown() {
        #expect(StreakReminders.tapToastLine(streakAtStake: 5)
                == "5-day streak — catch one before midnight")
        #expect(StreakReminders.tapToastLine(streakAtStake: nil)
                == "Streak at risk — catch one before midnight")
    }

    /// The debug fire must NOT share the real slot. `sync()` clears
    /// `notificationId` on every foreground, so a debug request filed there
    /// was deleted by backgrounding the app and coming back — which is
    /// exactly what you do while waiting for a test notification.
    @Test func debugReminderUsesItsOwnSlot() {
        #expect(StreakReminders.debugNotificationId != StreakReminders.notificationId)
        // The delegate still answers for both.
        #expect(StreakReminders.isStreakReminder(StreakReminders.notificationId))
        #expect(StreakReminders.isStreakReminder(StreakReminders.debugNotificationId))
        #expect(!StreakReminders.isStreakReminder("com.example.other"))
    }
}
