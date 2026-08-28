//
//  StreaksTests.swift
//  TailspotTests
//
//  Pins the daily-streak engine (Streaks.swift): frozen day-key semantics,
//  UTC key arithmetic (DST-proof by construction), the grace rule ("a
//  streak reads through yesterday"), the action-day ledger, and the
//  telemetry property builder. Every clock and timezone is injected —
//  no test reads the wall clock except the Catch-init stamping test,
//  which compares two same-zone derivations.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Streaks")
@MainActor
struct StreaksTests {

    // Fixed instants (UTC): 2026-08-17T00:00Z and offsets.
    private static let aug17midnightUTC = Date(timeIntervalSince1970: 1_786_924_800)

    /// Noon UTC on a "yyyy-MM-dd" key — an unambiguous "now" for asOf.
    private static func noonUTC(on key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return cal.date(from: c)!
    }
    private let bali = TimeZone(identifier: "Asia/Makassar")!        // UTC+8, no DST
    private let la = TimeZone(identifier: "America/Los_Angeles")!    // UTC-7/-8

    // MARK: - Day keys

    @Test func dayKeyFollowsTheZoneItWasAskedFor() {
        // 2026-08-16T22:00Z: already Aug 17 morning in Bali, still Aug 16
        // afternoon in California.
        let instant = Date(timeIntervalSince1970: 1_786_917_600)
        #expect(Streaks.dayKey(for: instant, timeZone: bali) == "2026-08-17")
        #expect(Streaks.dayKey(for: instant, timeZone: la) == "2026-08-16")
    }

    @Test func dayKeyIsStableAcrossADSTTransition() {
        // California springs forward on 2026-03-08 (a 23-hour local day).
        // Both ends of that local day still label "2026-03-08".
        let earlyLocal = Date(timeIntervalSince1970: 1_772_964_000)  // 02:00 PST
        let lateLocal = Date(timeIntervalSince1970: 1_773_014_400)   // 17:00 PDT
        #expect(Streaks.dayKey(for: earlyLocal, timeZone: la) == "2026-03-08")
        #expect(Streaks.dayKey(for: lateLocal, timeZone: la) == "2026-03-08")
    }

    @Test func catchInitStampsTheFrozenKey() {
        let caughtAt = Self.aug17midnightUTC
        let row = mk(caughtAt: caughtAt)
        #expect(row.caughtDayKey == Streaks.dayKey(for: caughtAt))
    }

    @Test func frozenKeyBeatsCurrentZoneDerivation() {
        // A catch stamped in Bali keeps its Bali day even when the day set
        // is built in a California calendar (AE: fly home, streak intact).
        let row = mk(caughtAt: Date(timeIntervalSince1970: 1_786_917_600))
        row.caughtDayKey = "2026-08-17"
        #expect(Streaks.daySet(catches: [row], timeZone: la) == ["2026-08-17"])
    }

    @Test func legacyRowsFallBackToTheGivenZone() {
        let row = mk(caughtAt: Date(timeIntervalSince1970: 1_786_917_600))
        row.caughtDayKey = nil  // pre-feature row
        #expect(Streaks.daySet(catches: [row], timeZone: la) == ["2026-08-16"])
        #expect(Streaks.daySet(catches: [row], timeZone: bali) == ["2026-08-17"])
    }

    // MARK: - Key arithmetic

    @Test func keyArithmeticCrossesMonthAndYearBoundaries() {
        #expect(Streaks.key(byAdding: -1, to: "2026-01-01") == "2025-12-31")
        #expect(Streaks.key(byAdding: 1, to: "2026-02-28") == "2026-03-01")
        #expect(Streaks.key(byAdding: 1, to: "2024-02-28") == "2024-02-29")  // leap
        #expect(Streaks.key(byAdding: 1, to: "2024-02-29") == "2024-03-01")
    }

    @Test func malformedKeysNeverChain() {
        #expect(Streaks.key(byAdding: 1, to: "garbage") == nil)
        #expect(Streaks.key(byAdding: 1, to: "2026-13-40") == nil)
        #expect(Streaks.key(byAdding: 1, to: "") == nil)
    }

    // MARK: - Current streak (grace rule)

    @Test func currentStreakAnchorsOnToday() {
        let days: Set<String> = ["2026-08-15", "2026-08-16", "2026-08-17"]
        #expect(Streaks.currentStreak(days: days, todayKey: "2026-08-17") == 3)
    }

    @Test func currentStreakReadsThroughYesterdayUntilMidnight() {
        // 12 days ending Aug 16; at 09:00 on the 17th (no catch yet) the
        // streak still reads 12 — it only breaks after a FULL empty day.
        var days = Set<String>()
        var cursor = "2026-08-05"
        for _ in 0..<12 {
            days.insert(cursor)
            cursor = Streaks.key(byAdding: 1, to: cursor)!
        }
        #expect(days.contains("2026-08-16"))
        #expect(Streaks.currentStreak(days: days, todayKey: "2026-08-17") == 12)
        // Two empty days later it's dead.
        #expect(Streaks.currentStreak(days: days, todayKey: "2026-08-18") == 0)
    }

    @Test func currentStreakStopsAtGaps() {
        let days: Set<String> = ["2026-08-13", "2026-08-15", "2026-08-16"]
        #expect(Streaks.currentStreak(days: days, todayKey: "2026-08-16") == 2)
    }

    @Test func currentStreakZeroWhenEmptyOrStale() {
        #expect(Streaks.currentStreak(days: [], todayKey: "2026-08-17") == 0)
        #expect(Streaks.currentStreak(days: ["2026-08-10"], todayKey: "2026-08-17") == 0)
    }

    @Test func singleCatchTodayIsAOneDayStreak() {
        #expect(Streaks.currentStreak(days: ["2026-08-17"], todayKey: "2026-08-17") == 1)
    }

    // MARK: - Longest streak

    @Test func longestStreakFindsTheBestRun() {
        #expect(Streaks.longestStreak(days: []) == 0)
        #expect(Streaks.longestStreak(days: ["2026-08-17"]) == 1)
        let days: Set<String> = [
            "2026-08-01", "2026-08-02", "2026-08-03",  // 3
            "2026-08-05", "2026-08-06",                // 2
            "2026-08-30",                              // 1
        ]
        #expect(Streaks.longestStreak(days: days) == 3)
    }

    @Test func longestStreakSurvivesGarbageEntries() {
        let days: Set<String> = ["2026-08-01", "2026-08-02", "garbage"]
        #expect(Streaks.longestStreak(days: days) == 2)
    }

    @Test func longestStreakCrossesMonthBoundary() {
        let days: Set<String> = ["2026-01-30", "2026-01-31", "2026-02-01", "2026-02-02"]
        #expect(Streaks.longestStreak(days: days) == 4)
    }

    // MARK: - Summary

    @Test func summaryAtRiskStates() {
        let yesterday = mk(caughtAt: Self.aug17midnightUTC)
        yesterday.caughtDayKey = "2026-08-16"
        let dayBefore = mk(caughtAt: Self.aug17midnightUTC)
        dayBefore.caughtDayKey = "2026-08-15"
        // Streak alive through yesterday, nothing today → at risk.
        let asOf = Date(timeIntervalSince1970: 1_786_924_800 + 9 * 3600)  // 09:00Z Aug 17
        let atRisk = Streaks.summary(
            catches: [yesterday, dayBefore], asOf: asOf, timeZone: .init(identifier: "UTC")!)
        #expect(atRisk.current == 2)
        #expect(atRisk.longest == 2)
        #expect(atRisk.atRisk)
        #expect(!atRisk.caughtToday)
        // Catch today → safe.
        let today = mk(caughtAt: Self.aug17midnightUTC)
        today.caughtDayKey = "2026-08-17"
        let safe = Streaks.summary(
            catches: [yesterday, dayBefore, today], asOf: asOf, timeZone: .init(identifier: "UTC")!)
        #expect(safe.current == 3)
        #expect(safe.caughtToday)
        #expect(!safe.atRisk)
        // Nothing at all → not "at risk", just zero.
        let empty = Streaks.summary(catches: [], asOf: asOf, timeZone: .init(identifier: "UTC")!)
        #expect(empty.current == 0)
        #expect(!empty.atRisk)
    }

    // MARK: - Telemetry builder

    @Test func extendedPropertiesCarryTheStreak() {
        let props = StreakTelemetry.extendedProperties(streakDays: 5)
        #expect(props.count == 1)
        guard case .int(let n)? = props["streak_days"] else {
            Issue.record("streak_days missing or mistyped")
            return
        }
        #expect(n == 5)
    }

    @Test func askResponsePropertiesCarryBothFacts() {
        let accepted = StreakTelemetry.askResponseProperties(accepted: true, streakDays: 3)
        guard case .bool(let a)? = accepted["accepted"],
              case .int(let n)? = accepted["streak_days"] else {
            Issue.record("accepted/streak_days missing or mistyped")
            return
        }
        #expect(a && n == 3)
        guard case .bool(let declined)? = StreakTelemetry
            .askResponseProperties(accepted: false, streakDays: 1)["accepted"] else {
            Issue.record("accepted missing on decline")
            return
        }
        #expect(!declined)
    }

    /// The scheduled-event dedupe identity: a new day OR a new stake is
    /// news; the same evening at the same stake is not.
    @Test func scheduledStampChangesWithDayAndStake() {
        let base = StreakTelemetry.scheduledStamp(dayKey: "2026-08-28", streakDays: 4)
        #expect(base == StreakTelemetry.scheduledStamp(dayKey: "2026-08-28", streakDays: 4))
        #expect(base != StreakTelemetry.scheduledStamp(dayKey: "2026-08-29", streakDays: 4))
        #expect(base != StreakTelemetry.scheduledStamp(dayKey: "2026-08-28", streakDays: 5))
    }

    @Test func deliveredPropertiesDistinguishSuppressedFromPresented() {
        let suppressed = StreakTelemetry.reminderDeliveredProperties(
            streakDays: 4, foreground: true, presented: false)
        guard case .bool(let fg)? = suppressed["foreground"],
              case .bool(let shown)? = suppressed["presented"],
              case .int(let n)? = suppressed["streak_days"] else {
            Issue.record("delivered properties missing or mistyped")
            return
        }
        #expect(fg && !shown && n == 4)
        // A background delivery scanned off Notification Center may predate
        // the userInfo streak — the event still fires, without the count.
        let scanned = StreakTelemetry.reminderDeliveredProperties(
            streakDays: nil, foreground: false, presented: true)
        #expect(scanned["streak_days"] == nil)
        #expect(scanned.count == 2)
    }

    // MARK: - Catch builder (TrophiesTests pattern)

    private func mk(caughtAt: Date) -> Catch {
        Catch(
            icao24: UUID().uuidString.prefix(6).lowercased(),
            callsign: nil,
            model: nil,
            manufacturer: nil,
            caughtAt: caughtAt,
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 1000
        )
    }

    // MARK: - One source of truth (regression, 2026-08-21)

    /// The Profile showed 12 while the very next catch reveal showed 26.
    /// Cause: the Profile went through `Streaks.summary` and the catch path
    /// re-derived the streak with `currentStreak` directly, so a debug
    /// override applied inside the day-set funnel reached one and not the
    /// other. Both now read the same entry point; pin that they agree.
    @Test func catchPathAndProfileAgreeOnTheSameHangar() {
        // Four consecutive days ending yesterday, today still uncaught.
        let rows = (1...4).map { back -> Catch in
            let r = mk(caughtAt: Self.aug17midnightUTC)
            r.caughtDayKey = Streaks.key(byAdding: -back, to: "2026-08-20")
            return r
        }
        let asOf = Self.noonUTC(on: "2026-08-20")

        // What the Profile card renders.
        let profile = Streaks.summary(catches: rows, asOf: asOf, timeZone: .gmt)
        #expect(profile.current == 4)      // grace: reads through yesterday
        #expect(profile.caughtToday == false)

        // What the catch path computes for the reveal line, for a catch
        // landing today whose row the @Query slice hasn't observed yet.
        let afterCatch = Streaks.summary(
            catches: rows, assumingCatchOn: "2026-08-20", asOf: asOf, timeZone: .gmt
        )
        #expect(afterCatch.current == 5)   // exactly one more, never a second number
        #expect(afterCatch.caughtToday)

        // And once the row IS visible, the Profile agrees with the reveal.
        let settled = mk(caughtAt: Self.aug17midnightUTC)
        settled.caughtDayKey = "2026-08-20"
        let reloaded = Streaks.summary(catches: rows + [settled], asOf: asOf, timeZone: .gmt)
        #expect(reloaded.current == afterCatch.current)
    }

    /// Telemetry must never report a wrench-forced streak: `streak_extended`
    /// lands in PostHog permanently. `realDaySet` is the rows-only read the
    /// catch path uses for the event, and it ignores the override by
    /// construction (it is what `daySet` falls through to).
    @Test func realDaySetReadsRowsOnly() {
        let row = mk(caughtAt: Self.aug17midnightUTC)
        row.caughtDayKey = "2026-08-17"
        #expect(Streaks.realDaySet(catches: [row]) == ["2026-08-17"])
        #expect(Streaks.realDaySet(catches: []).isEmpty)
    }
}
