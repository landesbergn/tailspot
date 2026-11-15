//
//  StreakCoverTests.swift
//  TailspotTests
//
//  Pins forgiven days (StreakCover.swift): the bridge-don't-count streak
//  maths, the one toast line, the reminder planner on forgiven days, the
//  wire decoder and the store. Every day is a fixed key and every store is
//  a suite-scoped UserDefaults; nothing reads the wall clock.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Streak cover")
@MainActor
struct StreakCoverTests {

    private let today = "2026-11-13"   // a Friday
    private let ground = ForgivenDay(day: "2026-11-13", reason: "FAA ground stop")

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

    private func noonUTC(_ key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return cal.date(from: c)!
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
        let s = Streaks.summary(catches: [], assumingCatchOn: "2026-11-12",
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

    // MARK: - Announcement

    @Test func aForgivenTodayIsAnnouncedOnALiveUncaughtStreak() {
        let live = run(endingAt: "2026-11-12", count: 4)
        let day = StreakCover.dayToAnnounce(
            catchDays: live, forgiven: [ground], announced: [], todayKey: today)
        #expect(day == ground)
        #expect(StreakCover.forgivenLine(ground, todayKey: today)
                == "No catch needed today: FAA ground stop.")
    }

    @Test func nothingIsAnnouncedWhenItSparedNothing() {
        let live = run(endingAt: "2026-11-12", count: 4)
        // Already announced.
        #expect(StreakCover.dayToAnnounce(
            catchDays: live, forgiven: [ground], announced: [today], todayKey: today) == nil)
        // Already caught today.
        #expect(StreakCover.dayToAnnounce(
            catchDays: live.union([today]), forgiven: [ground], announced: [], todayKey: today) == nil)
        // No streak to spare.
        #expect(StreakCover.dayToAnnounce(
            catchDays: [], forgiven: [ground], announced: [], todayKey: today) == nil)
        // A forgiven day from last week is old news.
        #expect(StreakCover.dayToAnnounce(
            catchDays: live, forgiven: [ForgivenDay(day: "2026-11-05", reason: "Volcanic ash")],
            announced: [], todayKey: today) == nil)
    }

    @Test func yesterdaysForgivenessIsAnnouncedTheMorningAfter() {
        let yesterday = ForgivenDay(day: "2026-11-12", reason: "FAA ground stop")
        let day = StreakCover.dayToAnnounce(
            catchDays: run(endingAt: "2026-11-11", count: 4), forgiven: [yesterday],
            announced: [], todayKey: today)
        #expect(day == yesterday)
        #expect(StreakCover.forgivenLine(yesterday, todayKey: today)
                == "Yesterday didn't count against your streak: FAA ground stop.")
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
        #expect(StreakCoverStore.coveredDays(defaults: d).isEmpty)
        let before = StreakCoverStore.stateToken(defaults: d)
        StreakCoverStore.saveForgiven([ground], defaults: d)
        #expect(StreakCoverStore.forgiven(defaults: d) == [ground])
        #expect(StreakCoverStore.coveredDays(defaults: d) == [today])
        #expect(StreakCoverStore.stateToken(defaults: d) != before)
        #expect(StreakCoverStore.announced(defaults: d).isEmpty)
        StreakCoverStore.markAnnounced(today, defaults: d)
        #expect(StreakCoverStore.announced(defaults: d) == [today])
    }

    @Test func mergeFollowsTheServerForRecentDaysAndKeepsOldOnes() {
        let old = ForgivenDay(day: "2026-10-01", reason: "Volcanic ash")
        let recent = ForgivenDay(day: "2026-11-12", reason: "Declared by mistake")
        // The server came back without either cached day.
        #expect(StreakCoverStore.merged(cached: [old, recent], server: [ground], todayKey: today)
                == [old, ground])
        // An empty server list keeps settled history and drops the recent day.
        #expect(StreakCoverStore.merged(cached: [old, recent], server: [], todayKey: today) == [old])
        // The server's reason wins for a day it still lists.
        let reworded = ForgivenDay(day: "2026-10-01", reason: "Ash cloud")
        #expect(StreakCoverStore.merged(cached: [old], server: [reworded], todayKey: today)
                == [reworded])
    }
}
