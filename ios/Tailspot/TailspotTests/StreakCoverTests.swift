//
//  StreakCoverTests.swift
//  TailspotTests
//
//  Pins covered days (StreakCover.swift): the bridge-don't-count streak
//  maths, freeze earning and automatic spending, the manual repair offer,
//  the foreground pass's one toast line, the reminder planner on forgiven
//  days, the wire decoder and the store. Every day is a fixed key and every
//  store is a suite-scoped UserDefaults; nothing reads the wall clock.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Streak cover")
@MainActor
struct StreakCoverTests {

    private let today = "2026-11-13"   // a Friday

    /// `count` consecutive day keys ending at `end`.
    private func run(endingAt end: String, count: Int) -> Set<String> {
        var days = Set<String>()
        var cursor = end
        for _ in 0..<count {
            days.insert(cursor)
            cursor = Streaks.key(byAdding: -1, to: cursor)!
        }
        return days
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "StreakCoverTests.\(UUID().uuidString)")!
    }

    // MARK: - Streak maths

    @Test func coveredDayBridgesWithoutCounting() {
        // Caught 11-09, 11-10, missed 11-11 (covered), caught 11-12.
        let days: Set<String> = ["2026-11-09", "2026-11-10", "2026-11-12"]
        #expect(Streaks.currentStreak(days: days, todayKey: today) == 1)
        #expect(Streaks.currentStreak(days: days, todayKey: today, covered: ["2026-11-11"]) == 3)
        #expect(Streaks.longestStreak(days: days) == 2)
        #expect(Streaks.longestStreak(days: days, covered: ["2026-11-11"]) == 3)
    }

    @Test func coveredYesterdayKeepsTheStreakAliveToday() {
        let days = run(endingAt: "2026-11-11", count: 5)
        #expect(Streaks.currentStreak(days: days, todayKey: today) == 0)
        #expect(Streaks.currentStreak(days: days, todayKey: today, covered: ["2026-11-12"]) == 5)
    }

    @Test func coveredDaysAloneAreNotAStreak() {
        let covered: Set<String> = ["2026-11-11", "2026-11-12", "2026-11-13"]
        #expect(Streaks.currentStreak(days: [], todayKey: today, covered: covered) == 0)
        #expect(Streaks.longestStreak(days: [], covered: covered) == 0)
    }

    @Test func aCoveredCatchDayStillCountsOnce() {
        let days = run(endingAt: today, count: 3)
        #expect(Streaks.currentStreak(days: days, todayKey: today, covered: ["2026-11-12"]) == 3)
        #expect(Streaks.longestStreak(days: days, covered: ["2026-11-12"]) == 3)
    }

    @Test func noCoverMatchesTheOriginalMaths() {
        let days: Set<String> = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-12", "2026-11-13"]
        #expect(Streaks.currentStreak(days: days, todayKey: today) == 2)
        #expect(Streaks.longestStreak(days: days) == 3)
        #expect(Streaks.longestStreak(days: []) == 0)
    }

    @Test func summaryReportsAForgivenTodayAsNotAtRisk() {
        let rows = [Catch]()
        let s = Streaks.summary(catches: rows, assumingCatchOn: "2026-11-12",
                                asOf: noonUTC(today), timeZone: .gmt, covered: [today])
        #expect(s.current == 1)
        #expect(s.todayCovered)
        #expect(!s.atRisk)
    }

    @Test func dayPhraseNamesYesterdayAndWeekdays() {
        #expect(Streaks.dayPhrase(forKey: "2026-11-12", todayKey: today) == "yesterday")
        #expect(Streaks.dayPhrase(forKey: "2026-11-11", todayKey: today) == "Wednesday")
        #expect(Streaks.dayPhrase(forKey: today, todayKey: today) == "today")
    }

    // MARK: - Earning

    @Test func everySeventhDayEarnsAFreezeUpToTheCap() {
        var ledger = StreakLedger()
        var result = StreakCover.award(ledger, streakAfterCatch: 6, todayKey: "2026-11-01")
        #expect(!result.earned)
        result = StreakCover.award(ledger, streakAfterCatch: 7, todayKey: "2026-11-02")
        #expect(result.earned)
        #expect(result.ledger.freezesHeld == 1)
        #expect(result.ledger.lastEarnedDay == "2026-11-02")
        ledger = result.ledger
        // Same day again: no second freeze.
        #expect(!StreakCover.award(ledger, streakAfterCatch: 7, todayKey: "2026-11-02").earned)
        result = StreakCover.award(ledger, streakAfterCatch: 14, todayKey: "2026-11-09")
        #expect(result.ledger.freezesHeld == 2)
        result = StreakCover.award(result.ledger, streakAfterCatch: 21, todayKey: "2026-11-16")
        #expect(!result.earned)
        #expect(result.ledger.freezesHeld == StreakCover.maxFreezes)
    }

    @Test func seedingGivesALiveStreakWhatItAlreadyEarned() {
        #expect(StreakCover.seededLedger(currentStreak: 0).freezesHeld == 0)
        #expect(StreakCover.seededLedger(currentStreak: 6).freezesHeld == 0)
        #expect(StreakCover.seededLedger(currentStreak: 13).freezesHeld == 1)
        #expect(StreakCover.seededLedger(currentStreak: 40).freezesHeld == 2)
    }

    // MARK: - Spending

    @Test func aMissedDaySpendsOneFreeze() {
        let days = run(endingAt: "2026-11-11", count: 8)   // missed 11-12
        let result = StreakCover.settle(
            StreakLedger(freezesHeld: 1), catchDays: days, forgiven: [], todayKey: today)
        #expect(result.used == StreakCover.FreezeUse(days: ["2026-11-12"], streakKept: 8))
        #expect(result.ledger.freezesHeld == 0)
        #expect(result.ledger.freezeDays == ["2026-11-12"])
        // Settling again is a no-op: the day is covered now.
        let again = StreakCover.settle(result.ledger, catchDays: days, forgiven: [], todayKey: today)
        #expect(again.used == nil)
        #expect(again.ledger == result.ledger)
    }

    @Test func twoMissedDaysNeedTwoFreezes() {
        let days = run(endingAt: "2026-11-10", count: 8)   // missed 11-11, 11-12
        let one = StreakCover.settle(
            StreakLedger(freezesHeld: 1), catchDays: days, forgiven: [], todayKey: today)
        #expect(one.used == nil)
        #expect(one.ledger.freezesHeld == 1)   // half a bridge spends nothing
        let two = StreakCover.settle(
            StreakLedger(freezesHeld: 2), catchDays: days, forgiven: [], todayKey: today)
        #expect(two.used?.days.count == 2)
        #expect(two.ledger.freezesHeld == 0)
        #expect(Streaks.currentStreak(days: days, todayKey: today,
                                      covered: two.ledger.coveredDays) == 8)
    }

    @Test func forgivenDaysCostNoFreeze() {
        let days = run(endingAt: "2026-11-11", count: 8)
        let result = StreakCover.settle(
            StreakLedger(freezesHeld: 1), catchDays: days, forgiven: ["2026-11-12"], todayKey: today)
        #expect(result.used == nil)
        #expect(result.ledger.freezesHeld == 1)
    }

    @Test func noFreezeIsSpentWithNothingMissedOrNothingToProtect() {
        let ledger = StreakLedger(freezesHeld: 2)
        // Caught yesterday: nothing missed.
        #expect(StreakCover.settle(ledger, catchDays: run(endingAt: "2026-11-12", count: 4),
                                   forgiven: [], todayKey: today).used == nil)
        // A one-day streak is below the protected minimum.
        #expect(StreakCover.settle(ledger, catchDays: ["2026-11-11"],
                                   forgiven: [], todayKey: today).used == nil)
        // An empty Hangar.
        #expect(StreakCover.settle(ledger, catchDays: [], forgiven: [], todayKey: today).used == nil)
        // A streak that ended a month ago.
        #expect(StreakCover.settle(ledger, catchDays: run(endingAt: "2026-10-10", count: 9),
                                   forgiven: [], todayKey: today).used == nil)
    }

    @Test func settlingAfterTodaysCatchCountsToday() {
        var days = run(endingAt: "2026-11-11", count: 4)
        days.insert(today)
        let result = StreakCover.settle(
            StreakLedger(freezesHeld: 1), catchDays: days, forgiven: [], todayKey: today)
        #expect(result.used?.streakKept == 5)
    }

    @Test func aFreezeSpentOnALaterForgivenDayIsRefunded() {
        var ledger = StreakLedger(freezesHeld: 0)
        ledger.freezeDays = ["2026-11-05", "2026-11-12"]
        let refunded = StreakCover.refunded(ledger, forgiven: ["2026-11-12"])
        #expect(refunded.freezesHeld == 1)
        #expect(refunded.freezeDays == ["2026-11-05"])
        #expect(StreakCover.refunded(ledger, forgiven: []) == ledger)
        // The foreground pass refunds before it settles.
        let days = run(endingAt: "2026-11-11", count: 8)
        var spent = StreakLedger()
        spent.freezeDays = ["2026-11-12"]
        let pass = StreakCover.foregroundPass(
            spent, catchDays: days,
            forgiven: [ForgivenDay(day: "2026-11-12", reason: "FAA ground stop")], todayKey: today)
        #expect(pass.ledger.freezesHeld == 1)
        #expect(pass.ledger.freezeDays.isEmpty)
        #expect(pass.freezeUse == nil)
    }

    @Test func aCatchTimeFreezeIsAnnouncedOnTheNextForeground() {
        let d = defaults()
        let days = run(endingAt: "2026-11-11", count: 8)
        StreakCoverStore.save(StreakLedger(freezesHeld: 1), defaults: d)
        StreakCoverCenter.settleBeforeCatch(priorDays: days, todayKey: today, defaults: d)
        let ledger = StreakCoverStore.ledger(defaults: d)!
        #expect(ledger.pendingFreezeLine == "Freeze used for yesterday. 8-day streak intact.")
        let pass = StreakCover.foregroundPass(
            ledger, catchDays: days.union([today]), forgiven: [], todayKey: today)
        #expect(pass.toastLine == "Freeze used for yesterday. 8-day streak intact.")
        #expect(pass.ledger.pendingFreezeLine == nil)
    }

    @Test func mergeFollowsTheServerForRecentDaysAndKeepsOldOnes() {
        let old = ForgivenDay(day: "2026-10-01", reason: "Volcanic ash")
        let recent = ForgivenDay(day: "2026-11-12", reason: "Declared by mistake")
        let new = ForgivenDay(day: today, reason: "FAA ground stop")
        // The server came back without either cached day.
        #expect(StreakCoverStore.merged(cached: [old, recent], server: [new], todayKey: today)
                == [old, new])
        // An empty server list keeps settled history.
        #expect(StreakCoverStore.merged(cached: [old, recent], server: [], todayKey: today) == [old])
        // The server's reason wins for a day it still lists.
        let reworded = ForgivenDay(day: "2026-10-01", reason: "Ash cloud")
        #expect(StreakCoverStore.merged(cached: [old], server: [reworded], todayKey: today)
                == [reworded])
    }

    // MARK: - Repair

    @Test func yesterdaysMissIsRepairable() {
        let days = run(endingAt: "2026-11-11", count: 6)
        let offer = StreakCover.repairOffer(
            StreakLedger(), catchDays: days, forgiven: [], todayKey: today)
        #expect(offer == StreakCover.RepairOffer(missedDay: "2026-11-12", streakRestored: 6))
        let repaired = StreakCover.repair(StreakLedger(), offer: offer!, todayKey: today)
        #expect(repaired.repairedDays == ["2026-11-12"])
        #expect(Streaks.currentStreak(days: days, todayKey: today,
                                      covered: repaired.coveredDays) == 6)
        // Nothing left to repair, and the cooldown is running.
        #expect(StreakCover.repairOffer(repaired, catchDays: days, forgiven: [], todayKey: today) == nil)
    }

    @Test func theDayBeforeYesterdayIsRepairableWhenYesterdayWasCaught() {
        // Caught through 11-10, missed 11-11, caught 11-12.
        var days = run(endingAt: "2026-11-10", count: 5)
        days.insert("2026-11-12")
        let offer = StreakCover.repairOffer(
            StreakLedger(), catchDays: days, forgiven: [], todayKey: today)
        #expect(offer == StreakCover.RepairOffer(missedDay: "2026-11-11", streakRestored: 6))
    }

    @Test func repairIsNotOfferedOutsideItsRules() {
        let ledger = StreakLedger()
        // Two misses in a row.
        #expect(StreakCover.repairOffer(ledger, catchDays: run(endingAt: "2026-11-10", count: 6),
                                        forgiven: [], todayKey: today) == nil)
        // Outside the two-day window (missed 11-10, caught since).
        var old = run(endingAt: "2026-11-09", count: 6)
        old.formUnion(["2026-11-11", "2026-11-12"])
        #expect(StreakCover.repairOffer(ledger, catchDays: old, forgiven: [], todayKey: today) == nil)
        // A one-day streak isn't worth the repair.
        #expect(StreakCover.repairOffer(ledger, catchDays: ["2026-11-11"],
                                        forgiven: [], todayKey: today) == nil)
        // Nothing missed.
        #expect(StreakCover.repairOffer(ledger, catchDays: run(endingAt: "2026-11-12", count: 6),
                                        forgiven: [], todayKey: today) == nil)
        // The miss was forgiven.
        #expect(StreakCover.repairOffer(ledger, catchDays: run(endingAt: "2026-11-11", count: 6),
                                        forgiven: ["2026-11-12"], todayKey: today) == nil)
    }

    @Test func repairCooldownIsThirtyDays() {
        let days = run(endingAt: "2026-11-11", count: 6)
        var ledger = StreakLedger()
        ledger.lastRepairDay = "2026-10-15"   // 29 days before today
        #expect(StreakCover.repairOffer(ledger, catchDays: days, forgiven: [], todayKey: today) == nil)
        ledger.lastRepairDay = "2026-10-14"   // 30 days
        #expect(StreakCover.repairOffer(ledger, catchDays: days, forgiven: [], todayKey: today) != nil)
    }

    // MARK: - Foreground pass

    @Test func aFreezeIsSpentBeforeARepairIsOffered() {
        let days = run(endingAt: "2026-11-11", count: 8)
        let pass = StreakCover.foregroundPass(
            StreakLedger(freezesHeld: 1), catchDays: days, forgiven: [], todayKey: today)
        #expect(pass.freezeUse != nil)
        #expect(pass.repairToAnnounce == nil)
        #expect(pass.toastLine == "Freeze used for yesterday. 8-day streak intact.")
    }

    @Test func withNoFreezeTheRepairIsAnnouncedOnce() {
        let days = run(endingAt: "2026-11-11", count: 8)
        let first = StreakCover.foregroundPass(
            StreakLedger(), catchDays: days, forgiven: [], todayKey: today)
        #expect(first.toastLine == "Missed yesterday. Repair your 8-day streak in Profile.")
        let second = StreakCover.foregroundPass(
            first.ledger, catchDays: days, forgiven: [], todayKey: today)
        #expect(second.toastLine == nil)
        #expect(second.ledger == first.ledger)
    }

    @Test func aForgivenDayIsAnnouncedOnceAndOnlyWhenItSparedACatch() {
        let ground = ForgivenDay(day: today, reason: "FAA ground stop")
        let live = run(endingAt: "2026-11-12", count: 4)
        let first = StreakCover.foregroundPass(
            StreakLedger(), catchDays: live, forgiven: [ground], todayKey: today)
        #expect(first.toastLine == "No catch needed today: FAA ground stop.")
        #expect(StreakCover.foregroundPass(
            first.ledger, catchDays: live, forgiven: [ground], todayKey: today).toastLine == nil)
        // Already caught today: nothing was spared.
        #expect(StreakCover.foregroundPass(
            StreakLedger(), catchDays: live.union([today]), forgiven: [ground],
            todayKey: today).toastLine == nil)
        // No streak to spare.
        #expect(StreakCover.foregroundPass(
            StreakLedger(), catchDays: [], forgiven: [ground], todayKey: today).toastLine == nil)
        // Yesterday's forgiveness, seen the morning after.
        let late = StreakCover.foregroundPass(
            StreakLedger(), catchDays: run(endingAt: "2026-11-11", count: 4),
            forgiven: [ForgivenDay(day: "2026-11-12", reason: "FAA ground stop")], todayKey: today)
        #expect(late.toastLine == "Yesterday didn't count against your streak: FAA ground stop.")
    }

    // MARK: - Reminder planner

    @Test func aForgivenTodayPushesTheReminderToTheNextUnforgivenDay() {
        let days = run(endingAt: "2026-11-12", count: 3)
        let morning = noonUTC(today).addingTimeInterval(-3 * 3600)   // 09:00 UTC
        let plain = StreakReminders.decision(
            days: days, now: morning, timeZone: .gmt, enabled: true, authorized: true)
        #expect(plain == .schedule(dayKey: today, streakAtStake: 3))
        let forgiven = StreakReminders.decision(
            days: days, covered: [today, "2026-11-14"], now: morning, timeZone: .gmt,
            enabled: true, authorized: true)
        #expect(forgiven == .schedule(dayKey: "2026-11-15", streakAtStake: 3))
    }

    // MARK: - Wire + store

    @Test func decoderKeepsOnlyWellFormedRows() throws {
        let json = """
        {"days":[
          {"day":"2026-11-13","reason":"  FAA ground stop "},
          {"day":"2026-02-30","reason":"not a date"},
          {"day":"11/13/2026","reason":"wrong shape"},
          {"day":"2026-11-10","reason":""},
          {"day":"2026-11-13","reason":"duplicate"},
          {"day":"2026-11-01","reason":"Volcanic ash"}
        ]}
        """
        let days = try StreakForgivenessClient.decode(Data(json.utf8))
        #expect(days == [
            ForgivenDay(day: "2026-11-01", reason: "Volcanic ash"),
            ForgivenDay(day: "2026-11-13", reason: "FAA ground stop"),
        ])
    }

    @Test func storeRoundTripsAndFeedsTheCoveredSet() {
        let d = defaults()
        #expect(StreakCoverStore.ledger(defaults: d) == nil)
        #expect(StreakCoverStore.coveredDays(defaults: d).isEmpty)
        let before = StreakCoverStore.stateToken(defaults: d)
        var ledger = StreakLedger(freezesHeld: 1)
        ledger.freezeDays = ["2026-11-02"]
        ledger.repairedDays = ["2026-11-05"]
        StreakCoverStore.save(ledger, defaults: d)
        StreakCoverStore.saveForgiven([ForgivenDay(day: today, reason: "FAA ground stop")], defaults: d)
        #expect(StreakCoverStore.ledger(defaults: d) == ledger)
        #expect(StreakCoverStore.coveredDays(defaults: d) == ["2026-11-02", "2026-11-05", today])
        #expect(StreakCoverStore.stateToken(defaults: d) != before)
        // The server taking a day back removes it.
        StreakCoverStore.saveForgiven([], defaults: d)
        #expect(StreakCoverStore.coveredDays(defaults: d) == ["2026-11-02", "2026-11-05"])
    }

    @Test func catchTimeSettleAndAwardPersist() {
        let d = defaults()
        let days = run(endingAt: "2026-11-11", count: 13)   // seeds 1 freeze, missed 11-12
        StreakCoverCenter.settleBeforeCatch(priorDays: days, todayKey: today, defaults: d)
        // Seeding read the streak as broken (0 held), so nothing was spent.
        #expect(StreakCoverStore.ledger(defaults: d)?.freezesHeld == 0)

        let d2 = defaults()
        StreakCoverStore.save(StreakLedger(freezesHeld: 1), defaults: d2)
        StreakCoverCenter.settleBeforeCatch(priorDays: days, todayKey: today, defaults: d2)
        #expect(StreakCoverStore.ledger(defaults: d2)?.freezeDays == ["2026-11-12"])
        // Today's catch makes it 14: a freeze earned back.
        StreakCoverCenter.awardIfEarned(streakAfterCatch: 14, todayKey: today, defaults: d2)
        #expect(StreakCoverStore.ledger(defaults: d2)?.freezesHeld == 1)
    }

    private func noonUTC(_ key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return cal.date(from: c)!
    }
}
