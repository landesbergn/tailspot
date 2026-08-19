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
}
