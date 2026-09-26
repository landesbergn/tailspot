//
//  ChallengeMidChallengeReminderTests.swift
//  TailspotTests
//
//  The two mid-challenge moments added in the notifications v2 pass:
//  `daily` (3d / 7d, 17:00 local on every interior day) and `midway`
//  (24h only, daylight-shifted). Everything here pins a fixed time zone —
//  the CI simulator's zone is not ours to assume, and every rule in these
//  moments is expressed in LOCAL days and hours.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("Challenge mid-challenge reminders")
struct ChallengeMidChallengeReminderTests {

    /// A DST-free zone so a "17:00 local" assertion is arithmetic, not a
    /// coin flip on which side of a transition the test day fell.
    private let zone = TimeZone.gmt

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    /// 2026-09-28 is a Monday — the brief's worked example starts there.
    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func plans(
        preset: String,
        startsAt: Date,
        now: Date,
        name: String = "Weekend Flyoff",
        placement: Int? = nil,
        participantCount: Int? = nil
    ) -> [ChallengeReminderPlan] {
        ChallengeReminders.plan(
            challengeId: "c1", name: name, startsAt: startsAt,
            endsAt: startsAt.addingTimeInterval(ChallengeDurations.seconds(for: preset)),
            durationPreset: preset, now: now, enabled: true, authorized: true,
            placement: placement, participantCount: participantCount, timeZone: zone)
    }

    private func dailies(_ plans: [ChallengeReminderPlan]) -> [ChallengeReminderPlan] {
        plans.filter { ChallengeReminders.moment(fromNotificationIdentifier: $0.identifier) == .daily }
    }

    private func midway(_ plans: [ChallengeReminderPlan]) -> ChallengeReminderPlan? {
        plans.first { ChallengeReminders.moment(fromNotificationIdentifier: $0.identifier) == .midway }
    }

    // MARK: - daily: which days

    /// A 7d challenge that starts Monday 10:00 nudges on every full day
    /// between the start day and the end day: Tuesday through Sunday. The
    /// start day is covered by `starts` (and by the user being in the app
    /// that made it); the end day — the following Monday — by `ending_soon`
    /// and `finished`, which is why it is excluded here.
    @Test func sevenDayNudgesEveryInteriorDayAtFive() {
        let starts = date(2026, 9, 28, 10)          // Monday
        let result = dailies(plans(preset: "7d", startsAt: starts, now: starts.addingTimeInterval(-3600)))

        #expect(result.map(\.identifier) == [
            "tailspot.challenge.c1.daily.2026-09-29",
            "tailspot.challenge.c1.daily.2026-09-30",
            "tailspot.challenge.c1.daily.2026-10-01",
            "tailspot.challenge.c1.daily.2026-10-02",
            "tailspot.challenge.c1.daily.2026-10-03",
            "tailspot.challenge.c1.daily.2026-10-04",
        ])
        // Every one at 17:00 local, and the end day (Monday 2026-10-05) is
        // absent.
        for plan in result {
            #expect(calendar.component(.hour, from: plan.fireAt) == StreakReminders.reminderHour)
            #expect(calendar.component(.minute, from: plan.fireAt) == 0)
        }
        #expect(result.first?.fireAt == date(2026, 9, 29, 17))
        #expect(result.first?.title == "Day 2 of 7")
        #expect(result.last?.title == "Day 7 of 7")
    }

    @Test func threeDayYieldsTwoDailies() {
        let starts = date(2026, 9, 28, 10)          // Monday
        let result = dailies(plans(preset: "3d", startsAt: starts, now: starts.addingTimeInterval(-3600)))

        #expect(result.count == 2)
        #expect(result.map(\.fireAt) == [date(2026, 9, 29, 17), date(2026, 9, 30, 17)])
        #expect(result.map(\.title) == ["Day 2 of 3", "Day 3 of 3"])
    }

    @Test func shortPresetsNeverGetADaily() {
        let starts = date(2026, 9, 28, 10)
        for preset in ["1h", "24h"] {
            let result = dailies(plans(preset: preset, startsAt: starts,
                                       now: starts.addingTimeInterval(-3600)))
            #expect(result.isEmpty, "\(preset) must not plan a daily nudge")
        }
    }

    /// Never two banners on one calendar day. A 3d challenge that ends just
    /// after midnight has its `ending_soon` land at 23:30 the night before —
    /// on what is otherwise an interior day — so that day's daily is dropped.
    @Test func dailyIsSkippedOnTheDayEndingSoonFallsOn() {
        let starts = date(2026, 9, 28, 0, 30)       // Monday 00:30
        let all = plans(preset: "3d", startsAt: starts, now: starts.addingTimeInterval(-3600))
        let endingSoon = all.first {
            ChallengeReminders.moment(fromNotificationIdentifier: $0.identifier) == .endingSoon
        }
        // ends Thursday 00:30 → ending_soon Wednesday 23:30.
        #expect(endingSoon?.fireAt == date(2026, 9, 30, 23, 30))
        // Interior days are Tuesday and Wednesday; Wednesday loses its daily.
        #expect(dailies(all).map(\.fireAt) == [date(2026, 9, 29, 17)])
    }

    @Test func daysAlreadyPassedAreNotPlanned() {
        let starts = date(2026, 9, 28, 10)          // Monday
        // The app is opened on Wednesday evening, after that day's 17:00.
        let result = dailies(plans(preset: "7d", startsAt: starts, now: date(2026, 9, 30, 20)))

        #expect(result.map(\.identifier) == [
            "tailspot.challenge.c1.daily.2026-10-01",
            "tailspot.challenge.c1.daily.2026-10-02",
            "tailspot.challenge.c1.daily.2026-10-03",
            "tailspot.challenge.c1.daily.2026-10-04",
        ])
    }

    // MARK: - daily: copy

    @Test func dailyCopyStatesThePlacementWhenItIsKnown() {
        let starts = date(2026, 9, 28, 10)
        let result = dailies(plans(preset: "3d", startsAt: starts,
                                   now: starts.addingTimeInterval(-3600),
                                   placement: 2, participantCount: 5))
        #expect(result.first?.body == "You're 2nd in Weekend Flyoff.")
    }

    @Test func dailyCopyFallsBackWithoutAPlacement() {
        let starts = date(2026, 9, 28, 10)
        let result = dailies(plans(preset: "3d", startsAt: starts,
                                   now: starts.addingTimeInterval(-3600)))
        #expect(result.first?.body == "Weekend Flyoff is on. Check the standings.")
    }

    /// "You're 1st" in a field of one is not a standing, it is a joke.
    @Test func dailyCopyFallsBackInASoloField() {
        let starts = date(2026, 9, 28, 10)
        let result = dailies(plans(preset: "3d", startsAt: starts,
                                   now: starts.addingTimeInterval(-3600),
                                   placement: 1, participantCount: 1))
        #expect(result.first?.body == "Weekend Flyoff is on. Check the standings.")
    }

    // MARK: - midway (24h only)

    @Test func midwayLandsOnTheTrueMidpointInsideDaylight() {
        // 09:00 → midpoint 21:00, the inclusive top of the window.
        let starts = date(2026, 9, 28, 9)
        #expect(midway(plans(preset: "24h", startsAt: starts,
                             now: starts.addingTimeInterval(-60)))?.fireAt == date(2026, 9, 28, 21))

        // 20:00 → midpoint 08:00 next day, the inclusive bottom.
        let evening = date(2026, 9, 28, 20)
        #expect(midway(plans(preset: "24h", startsAt: evening,
                             now: evening.addingTimeInterval(-60)))?.fireAt == date(2026, 9, 29, 8))

        // 22:00 → midpoint 10:00 next day.
        let late = date(2026, 9, 28, 22)
        #expect(midway(plans(preset: "24h", startsAt: late,
                             now: late.addingTimeInterval(-60)))?.fireAt == date(2026, 9, 29, 10))
    }

    @Test func midwayOutsideDaylightShiftsToNineAM() {
        // 14:00 → midpoint 02:00, the middle of the night → next 09:00.
        // ending_soon is 13:00 that day, four hours later, so it survives.
        let starts = date(2026, 9, 28, 14)
        let all = plans(preset: "24h", startsAt: starts, now: starts.addingTimeInterval(-60))
        #expect(midway(all)?.fireAt == date(2026, 9, 29, 9))
    }

    /// A shifted midway that lands on top of `ending_soon` is not a
    /// mid-challenge nudge, it is a duplicate. 10:00 start → midpoint 22:00
    /// → shifted to 09:00 next day, which IS the ending_soon instant.
    @Test func midwayIsSkippedWhenItCrowdsEndingSoon() {
        let starts = date(2026, 9, 28, 10)
        let all = plans(preset: "24h", startsAt: starts, now: starts.addingTimeInterval(-60))
        #expect(midway(all) == nil)
        #expect(all.contains { $0.identifier == "tailspot.challenge.c1.ending_soon" })
    }

    @Test func midwayAlreadyPassedIsNotPlanned() {
        let starts = date(2026, 9, 28, 9)           // midway 21:00
        let all = plans(preset: "24h", startsAt: starts, now: date(2026, 9, 28, 22))
        #expect(midway(all) == nil)
    }

    @Test func midwayIsNeverPlannedForOtherPresets() {
        let starts = date(2026, 9, 28, 9)
        for preset in ["1h", "3d", "7d"] {
            let all = plans(preset: preset, startsAt: starts, now: starts.addingTimeInterval(-60))
            #expect(midway(all) == nil, "\(preset) must not plan a midway nudge")
        }
    }

    @Test func midwayCopy() {
        let starts = date(2026, 9, 28, 9)
        let withPlacement = midway(plans(preset: "24h", startsAt: starts,
                                         now: starts.addingTimeInterval(-60),
                                         placement: 2, participantCount: 5))
        #expect(withPlacement?.title == "Halfway there")
        #expect(withPlacement?.body == "You're 2nd in Weekend Flyoff.")

        let without = midway(plans(preset: "24h", startsAt: starts,
                                   now: starts.addingTimeInterval(-60)))
        #expect(without?.body == "Weekend Flyoff is half over. Check the standings.")
    }

    // MARK: - identifiers

    @Test func dailyIdentifiersRoundTrip() {
        let id = "3f9a1c2e-1234-4abc-9def-0987654321ab"
        let identifier = ChallengeReminders.identifier(challengeId: id, moment: .daily,
                                                       dayKey: "2026-09-29")
        #expect(identifier == "tailspot.challenge.\(id).daily.2026-09-29")
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: identifier) == id)
        #expect(ChallengeReminders.moment(fromNotificationIdentifier: identifier) == .daily)
        #expect(ChallengeReminders.isChallengeIdentifier(identifier))
    }

    @Test func everyMomentIdentifierRoundTrips() {
        for moment in ChallengeReminders.Moment.allCases where moment != .daily {
            let identifier = ChallengeReminders.identifier(challengeId: "c1", moment: moment)
            #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: identifier) == "c1")
            #expect(ChallengeReminders.moment(fromNotificationIdentifier: identifier) == moment)
        }
    }

    @Test func aBareDailyIdentifierWithoutADayKeyIsRejected() {
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "tailspot.challenge.c1.daily") == nil)
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "tailspot.challenge.c1.daily.notadate") == nil)
    }

    /// `identifiers(challengeId:)` enumerates the FIXED four only. The
    /// per-day slots are not enumerable without the window, and no caller
    /// reliably has it — the scheduler's pending-sweep cancels those (see
    /// `cancelSweepsTheDailyIdentifiersToo`).
    @Test func identifiersEnumeratesTheFixedMomentsOnly() {
        #expect(Set(ChallengeReminders.identifiers(challengeId: "c1")) == [
            "tailspot.challenge.c1.starts",
            "tailspot.challenge.c1.midway",
            "tailspot.challenge.c1.ending_soon",
            "tailspot.challenge.c1.finished",
        ])
    }

    /// Whatever `plan` emits that is NOT a daily must be inside what
    /// `identifiers` enumerates, or a leave would strand it.
    @Test func plannedFixedIdentifiersAreCancellable() {
        let starts = date(2026, 9, 28, 10)
        let planned = plans(preset: "7d", startsAt: starts,
                            now: starts.addingTimeInterval(-3600))
        let fixed = Set(planned.map(\.identifier).filter { !$0.contains(".daily.") })
        #expect(fixed.isSubset(of: Set(ChallengeReminders.identifiers(challengeId: "c1"))))
        // And every daily IS parseable back to the challenge, which is what
        // the sweep matches on.
        for plan in planned where plan.identifier.contains(".daily.") {
            #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: plan.identifier) == "c1")
        }
    }

    // MARK: - "Day N of M" counts elapsed time, not calendar days

    /// The bug this replaced: a 3d challenge created Friday 20:00 runs to
    /// Monday 20:00, and the Sunday 17:00 nudge — with 27 hours still to
    /// play — read "Day 3 of 3" because Sunday is the third calendar day.
    @Test func dayNumberCountsElapsedTimeNotCalendarDays() {
        let friday = date(2026, 9, 25, 20)          // Friday 20:00
        let result = dailies(plans(preset: "3d", startsAt: friday,
                                   now: friday.addingTimeInterval(-3600)))
        // Interior days: Saturday and Sunday (it ends Monday 20:00).
        #expect(result.map(\.fireAt) == [date(2026, 9, 26, 17), date(2026, 9, 27, 17)])
        // Saturday 17:00 is 21 h in — still day 1. Sunday 17:00 is 45 h in.
        #expect(result.map(\.title) == ["Day 1 of 3", "Day 2 of 3"])
    }

    @Test func dayNumberIsPureAndClamped() {
        let start = date(2026, 9, 28, 10)
        #expect(ChallengeReminders.dayNumber(fireAt: start, startsAt: start, total: 7) == 1)
        #expect(ChallengeReminders.dayNumber(
            fireAt: start.addingTimeInterval(23 * 3600), startsAt: start, total: 7) == 1)
        #expect(ChallengeReminders.dayNumber(
            fireAt: start.addingTimeInterval(24 * 3600), startsAt: start, total: 7) == 2)
        #expect(ChallengeReminders.dayNumber(
            fireAt: start.addingTimeInterval(6 * 86_400 + 7 * 3600), startsAt: start, total: 7) == 7)
        // Clamped at both ends: never "Day 0", never past the total.
        #expect(ChallengeReminders.dayNumber(
            fireAt: start.addingTimeInterval(-3600), startsAt: start, total: 3) == 1)
        #expect(ChallengeReminders.dayNumber(
            fireAt: start.addingTimeInterval(30 * 86_400), startsAt: start, total: 3) == 3)
    }
}
