//
//  WeeklyRecapReminderTests.swift
//  TailspotTests
//
//  The Monday "your week" notification's planner: which Monday, which
//  week, and when it stays silent.
//

import Testing
import Foundation
@testable import Tailspot

@MainActor
@Suite("Weekly recap reminder")
struct WeeklyRecapReminderTests {

    private static func at(_ key: String, hour: Int, tz: TimeZone = .gmt) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = hour
        return cal.date(from: c)!
    }

    private static func catchOn(_ day: String, tc: String = "B738", icao: String = "abc123") -> Catch {
        let c = Catch(icao24: icao, callsign: "SWA1", model: nil, manufacturer: nil,
                      caughtAt: at(day, hour: 12), observerLat: 0, observerLon: 0,
                      slantDistanceMeters: 1000, typecode: tc)
        c.caughtDayKey = day
        return c
    }

    // 2026-11-09 is a Monday.

    @Test func midweekTargetsNextMondayForThisWeek() {
        let t = WeeklyRecapReminder.target(now: Self.at("2026-11-11", hour: 15), timeZone: .gmt)
        #expect(t?.fire == "2026-11-16")
        #expect(t?.weekStart == "2026-11-09")
    }

    @Test func mondayBeforeNineTargetsThisMorningForLastWeek() {
        let t = WeeklyRecapReminder.target(now: Self.at("2026-11-09", hour: 7), timeZone: .gmt)
        #expect(t?.fire == "2026-11-09")
        #expect(t?.weekStart == "2026-11-02")
    }

    @Test func mondayAfterNineMovesOnToNextWeek() {
        let t = WeeklyRecapReminder.target(now: Self.at("2026-11-09", hour: 10), timeZone: .gmt)
        #expect(t?.fire == "2026-11-16")
        #expect(t?.weekStart == "2026-11-09")
    }

    @Test func sundayNightTargetsTomorrow() {
        let t = WeeklyRecapReminder.target(now: Self.at("2026-11-15", hour: 23), timeZone: .gmt)
        #expect(t?.fire == "2026-11-16")
        #expect(t?.weekStart == "2026-11-09")
    }

    @Test func plansWithCountsForTheReportedWeek() {
        let catches = [
            Self.catchOn("2026-11-10", tc: "B738", icao: "a00001"),
            Self.catchOn("2026-11-12", tc: "A388", icao: "a00002"),
            Self.catchOn("2026-11-12", tc: "B738", icao: "a00003"),
            Self.catchOn("2026-11-03", tc: "E75L", icao: "a00004"), // last week: not counted
        ]
        let plan = WeeklyRecapReminder.plan(
            catches: catches, now: Self.at("2026-11-13", hour: 18), timeZone: .gmt,
            enabled: true, authorized: true)
        #expect(plan?.fireDayKey == "2026-11-16")
        #expect(plan?.weekStartKey == "2026-11-09")
        #expect(plan?.catchCount == 3)
        #expect(plan?.newTypes == 2)
        #expect(plan?.body == "3 planes caught, 2 new types. Tap to see your week.")
    }

    @Test func silentForAnEmptyWeek() {
        let catches = [Self.catchOn("2026-11-03")]
        #expect(WeeklyRecapReminder.plan(
            catches: catches, now: Self.at("2026-11-13", hour: 18), timeZone: .gmt,
            enabled: true, authorized: true) == nil)
    }

    @Test func silentWithoutPermissionOrWhenOff() {
        let catches = [Self.catchOn("2026-11-10")]
        let now = Self.at("2026-11-13", hour: 18)
        #expect(WeeklyRecapReminder.plan(catches: catches, now: now, timeZone: .gmt,
                                         enabled: true, authorized: false) == nil)
        #expect(WeeklyRecapReminder.plan(catches: catches, now: now, timeZone: .gmt,
                                         enabled: false, authorized: true) == nil)
    }

    @Test func bodyCopy() {
        #expect(WeeklyRecapReminder.body(catchCount: 1, newTypes: 0) == "1 plane caught. Tap to see your week.")
        #expect(WeeklyRecapReminder.body(catchCount: 4, newTypes: 1) == "4 planes caught, 1 new type. Tap to see your week.")
    }

    @Test func triggerIsNineLocal() {
        let c = WeeklyRecapReminder.triggerComponents(dayKey: "2026-11-16")
        #expect(c?.year == 2026 && c?.month == 11 && c?.day == 16 && c?.hour == 9)
        #expect(c?.minute == nil)
    }
}

@MainActor
@Suite("Weekly recap bar heights")
struct WeeklyRecapBarHeightTests {
    @Test func smallCountsStayDistinctUnderABigPeak() {
        let h = { (n: Int) in WeeklyRecapDayBars.barHeight(count: n, peak: 8, height: 88) }
        #expect(h(1) < h(2))
        #expect(h(2) < h(3))
        #expect(h(2) - h(1) >= 8)
        #expect(h(8) == 88)
        #expect(h(1) > WeeklyRecapDayBars.minCountedBar)
        #expect(h(0) == 3)
    }
}
