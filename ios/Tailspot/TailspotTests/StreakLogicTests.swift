//
//  StreakLogicTests.swift
//  TailspotTests
//
//  Pin the streak computation (streaks plan U1): the current-streak run,
//  the frozen dayKey and its catchDay/dayBuckets bucketing, the asOf
//  threading through Trophies.inputs, and a regression pin that the
//  longest-streak math (the secret 7-day trophy's input) is unchanged.
//
//  All dates are fixed-epoch (no Date() in assertions) per the repo test
//  convention.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Streak logic — current run, dayKey freezing, inputs threading")
@MainActor
struct StreakLogicTests {

    private let cal = Calendar(identifier: .gregorian)

    /// Fixed anchor: some midday moment. dayOffset shifts whole days.
    private func date(dayOffset: Int = 0, hour: Int = 12) -> Date {
        let base = cal.startOfDay(for: Date(timeIntervalSince1970: 1_716_000_000))
        let shifted = cal.date(byAdding: .day, value: dayOffset, to: base)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
    }

    private func days(_ offsets: [Int]) -> Set<Date> {
        Set(offsets.map { cal.startOfDay(for: date(dayOffset: $0)) })
    }

    private func makeCatch(icao: String = "abc123", dayOffset: Int, hour: Int = 12) -> Catch {
        Catch(icao24: icao, callsign: nil, model: nil, manufacturer: nil,
              caughtAt: date(dayOffset: dayOffset, hour: hour),
              observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 5_000)
    }

    // MARK: - currentConsecutiveDayRun (R4)

    @Test func twelveDayRunReadsTwelveAllDayBeforeTodaysCatch() {
        // Covers AE5: caught the last 12 days ending yesterday, nothing yet
        // today at 09:00 → still 12.
        let run = days(Array(-12 ... -1))
        #expect(Trophies.currentConsecutiveDayRun(run, asOf: date(hour: 9), calendar: cal) == 12)
    }

    @Test func runReadsZeroAfterAFullUncaughtDay() {
        // Covers AE5: the same 12-day run, but a whole day has now passed
        // with no catch — dead.
        let run = days(Array(-13 ... -2))
        #expect(Trophies.currentConsecutiveDayRun(run, asOf: date(hour: 0), calendar: cal) == 0)
    }

    @Test func catchTodayExtendsTheRunImmediately() {
        let run = days(Array(-3 ... 0))
        #expect(Trophies.currentConsecutiveDayRun(run, asOf: date(hour: 13), calendar: cal) == 4)
    }

    @Test func singleCatchTodayIsAOneDayStreak() {
        #expect(Trophies.currentConsecutiveDayRun(days([0]), asOf: date(hour: 13), calendar: cal) == 1)
    }

    @Test func gapTwoDaysAgoResetsTheRun() {
        // Caught -5..-4, gap at -3, caught -2..-1 → live run is 2.
        let run = days([-5, -4, -2, -1])
        #expect(Trophies.currentConsecutiveDayRun(run, asOf: date(hour: 9), calendar: cal) == 2)
    }

    @Test func emptyHangarHasNoRun() {
        #expect(Trophies.currentConsecutiveDayRun([], asOf: date(), calendar: cal) == 0)
    }

    // MARK: - dayKey freezing (R7 / KTD4)

    @Test func dayKeyFormatsLocalCalendarDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 1716000000 = 2024-05-18 02:40 UTC.
        #expect(Catch.dayKey(for: Date(timeIntervalSince1970: 1_716_000_000), calendar: utc) == "2024-05-18")
    }

    @Test func catchInitFreezesTheDay() {
        let c = makeCatch(dayOffset: 0)
        #expect(c.dayKey == Catch.dayKey(for: c.caughtAt))
    }

    @Test func frozenDayKeySurvivesAZoneChange() {
        // Covers AE7: a catch frozen in Bali (UTC+8) at 06:00 local. Read
        // back in a Los Angeles calendar, the raw caughtAt would re-bucket
        // to the PREVIOUS day — the frozen key must win.
        var bali = Calendar(identifier: .gregorian)
        bali.timeZone = TimeZone(identifier: "Asia/Makassar")!   // UTC+8
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!

        // 2026-06-10 06:00 in Bali.
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 10; comps.hour = 6
        let baliMoment = bali.date(from: comps)!

        let c = Catch(icao24: "bali01", callsign: nil, model: nil, manufacturer: nil,
                      caughtAt: baliMoment, observerLat: -8.7, observerLon: 115.2,
                      slantDistanceMeters: 4_000)
        c.dayKey = Catch.dayKey(for: baliMoment, calendar: bali)   // frozen at catch

        let frozen = Trophies.catchDay(c, calendar: la)
        let naive = la.startOfDay(for: baliMoment)
        #expect(la.dateComponents([.day], from: frozen).day == 10)
        #expect(naive != frozen)   // the naive re-bucket would land on June 9
    }

    @Test func legacyNilDayKeyFallsBackToCurrentZone() {
        let c = makeCatch(dayOffset: -2)
        c.dayKey = nil
        #expect(Trophies.catchDay(c, calendar: cal) == cal.startOfDay(for: c.caughtAt))
    }

    @Test func dayBucketsDedupesSameDayCatches() {
        let catches = [makeCatch(icao: "a", dayOffset: 0, hour: 9),
                       makeCatch(icao: "b", dayOffset: 0, hour: 18),
                       makeCatch(icao: "c", dayOffset: -1)]
        #expect(Trophies.dayBuckets(from: catches, calendar: cal).count == 2)
    }

    // MARK: - inputs threading (asOf, no hidden clock)

    @Test func inputsCarriesCurrentStreakAndCaughtToday() {
        let catches = [makeCatch(dayOffset: -2), makeCatch(dayOffset: -1), makeCatch(dayOffset: 0)]
        let inputs = Trophies.inputs(from: catches, asOf: date(hour: 20))
        #expect(inputs.currentDayStreak == 3)
        #expect(inputs.caughtToday)
        #expect(inputs.longestDayStreak == 3)
    }

    @Test func inputsAtRiskShape() {
        // 3 days ending yesterday, nothing today: current stays 3, but
        // caughtToday is false — the Profile's at-risk condition.
        let catches = [makeCatch(dayOffset: -3), makeCatch(dayOffset: -2), makeCatch(dayOffset: -1)]
        let inputs = Trophies.inputs(from: catches, asOf: date(hour: 9))
        #expect(inputs.currentDayStreak == 3)
        #expect(!inputs.caughtToday)
    }

    @Test func longestStreakRegressionUnchanged() {
        // The secret 7-day trophy's input: longest counts a PAST run even
        // when the live run is shorter.
        let catches = (-10 ... -4).map { makeCatch(dayOffset: $0) } + [makeCatch(dayOffset: -1)]
        let inputs = Trophies.inputs(from: catches, asOf: date(hour: 9))
        #expect(inputs.longestDayStreak == 7)
        #expect(inputs.currentDayStreak == 1)
    }

    // MARK: - DST boundaries

    @Test func dstTransitionDaysStayDistinctAndConsecutive() {
        // US spring-forward 2026-03-08 (23-hour day) in Los Angeles: three
        // catches on 03-07/08/09 form a 3-day run.
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        var run = Set<Date>()
        for day in 7...9 {
            var comps = DateComponents()
            comps.year = 2026; comps.month = 3; comps.day = day; comps.hour = 12
            run.insert(la.startOfDay(for: la.date(from: comps)!))
        }
        var asOfComps = DateComponents()
        asOfComps.year = 2026; asOfComps.month = 3; asOfComps.day = 9; asOfComps.hour = 20
        let asOf = la.date(from: asOfComps)!
        #expect(Trophies.currentConsecutiveDayRun(run, asOf: asOf, calendar: la) == 3)
        #expect(Trophies.longestConsecutiveDayRun(run, calendar: la) == 3)
    }
}
