//
//  StreakRemindersTests.swift
//  TailspotTests
//
//  Pin the reminder planner's guardrail matrix (streaks plan U3 / R2) and
//  the contextual permission-ask eligibility (U5 / KTD5). The decision
//  function is pure — injected day-sets, clocks, and stored state — so the
//  matrix IS the spec (test-first per the plan's execution note).
//

import Testing
import Foundation
import UserNotifications
@testable import Tailspot

@Suite("Streak reminders — guardrail matrix + permission ask")
@MainActor
struct StreakRemindersTests {

    private let cal = Calendar(identifier: .gregorian)

    private func date(dayOffset: Int = 0, hour: Int = 12) -> Date {
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let shifted = cal.date(byAdding: .day, value: dayOffset, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
    }

    private func days(_ offsets: [Int]) -> Set<Date> {
        Set(offsets.map { cal.startOfDay(for: date(dayOffset: $0)) })
    }

    private var today: Date { cal.startOfDay(for: date()) }
    private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today)! }

    private func decide(
        _ offsets: [Int],
        hour: Int,
        lastScheduledDay: String? = nil,
        enabled: Bool = true,
        authorized: Bool = true
    ) -> StreakReminders.Decision {
        StreakReminders.decision(
            days: days(offsets),
            now: date(hour: hour),
            calendar: cal,
            lastScheduledDay: lastScheduledDay,
            enabled: enabled,
            authorized: authorized
        )
    }

    // MARK: - The matrix (R2, AE1–AE4, AE6, AE8)

    @Test func liveStreakUncaughtMorningSchedulesToday() {
        // Covers AE1: streak 4 through yesterday, nothing today, 09:00.
        #expect(decide(Array(-4 ... -1), hour: 9) == .schedule(day: today, streak: 4))
    }

    @Test func catchBeforeFireHourReschedulesToTomorrow() {
        // Covers AE1: a 17:00 catch replaces today's pending with tomorrow —
        // remove-then-add on one identifier IS the cancel.
        #expect(decide(Array(-4 ... 0), hour: 17,
                       lastScheduledDay: Catch.dayKey(for: today, calendar: cal))
                == .schedule(day: tomorrow, streak: 5))
    }

    @Test func twoDayStreakNeverSchedules() {
        // Covers AE2.
        #expect(decide([-2, -1], hour: 9) == .cancel)
    }

    @Test func brokenStreakSchedulesNothing() {
        // Covers AE3: streak died yesterday (last catch two days ago).
        #expect(decide([-4, -3, -2], hour: 9) == .cancel)
    }

    @Test func lapsedUserGetsSilence() {
        // Covers AE3: ancient history only.
        #expect(decide([-30, -29, -28], hour: 19) == .cancel)
    }

    @Test func mutedNeverSchedulesAndCancelsPending() {
        // Covers AE4.
        #expect(decide(Array(-4 ... -1), hour: 9, enabled: false) == .cancel)
    }

    @Test func unauthorizedNeverSchedules() {
        // Covers AE8.
        #expect(decide(Array(-4 ... -1), hour: 9, authorized: false) == .cancel)
    }

    @Test func spentDayIsNotRescheduled() {
        // Covers AE6: 17:59 foreground scheduled today; the 18:02 (well,
        // any later) re-foreground must not double-book the day.
        #expect(decide(Array(-4 ... -1), hour: 9,
                       lastScheduledDay: Catch.dayKey(for: today, calendar: cal)) == .noop)
    }

    @Test func pastFireHourUncaughtSchedulesNothing() {
        // 19:00, no catch today: if tonight stays catchless the streak is
        // dead by tomorrow, and R2 forbids nudging a broken streak — so no
        // tomorrow pre-arm from an uncaught evening.
        #expect(decide(Array(-4 ... -1), hour: 19) == .cancel)
    }

    @Test func caughtTodayTomorrowAlreadySpentIsNoop() {
        #expect(decide(Array(-4 ... 0), hour: 20,
                       lastScheduledDay: Catch.dayKey(for: tomorrow, calendar: cal)) == .noop)
    }

    @Test func exactlyThreeDaysThroughYesterdayIsProtected() {
        // The R2 boundary: 3 is in, 2 is out (tested above).
        #expect(decide([-3, -2, -1], hour: 9) == .schedule(day: today, streak: 3))
    }

    // MARK: - Permission-ask eligibility (KTD5)

    @Test func askFiresExactlyAtStreakThree() {
        #expect(StreakReminders.shouldOfferPermissionAsk(
            currentStreak: 3,
            authStatusRaw: UNAuthorizationStatus.notDetermined.rawValue,
            asked: false, enabled: true))
    }

    @Test func askSuppressedByEachFailedCondition() {
        let nd = UNAuthorizationStatus.notDetermined.rawValue
        // Wrong streak (2 and 4 — the ask is one-shot AT the completion).
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 2, authStatusRaw: nd, asked: false, enabled: true))
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 4, authStatusRaw: nd, asked: false, enabled: true))
        // Already determined (granted or denied — never re-ask).
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 3, authStatusRaw: UNAuthorizationStatus.denied.rawValue, asked: false, enabled: true))
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 3, authStatusRaw: UNAuthorizationStatus.authorized.rawValue, asked: false, enabled: true))
        // Latched (any prior dismissal of the pre-prompt).
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 3, authStatusRaw: nd, asked: true, enabled: true))
        // Pre-emptively muted in Settings — never ask for a declined feature.
        #expect(!StreakReminders.shouldOfferPermissionAsk(currentStreak: 3, authStatusRaw: nd, asked: false, enabled: false))
    }

    // MARK: - Stored-state defaults

    @Test func remindersDefaultOnWhenKeyAbsent() {
        let suite = UserDefaults(suiteName: "StreakRemindersTests-\(UUID().uuidString)")!
        #expect(StreakReminders.isEnabled(defaults: suite))
        suite.set(false, forKey: StreakReminders.enabledKey)
        #expect(!StreakReminders.isEnabled(defaults: suite))
    }

    @Test func absentCachedStatusReadsNotDetermined() {
        let suite = UserDefaults(suiteName: "StreakRemindersTests-\(UUID().uuidString)")!
        #expect(StreakReminders.cachedAuthStatus(defaults: suite) == .notDetermined)
        #expect(!StreakReminders.isAuthorized(defaults: suite))
    }
}
