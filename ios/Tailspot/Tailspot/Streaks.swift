//
//  Streaks.swift
//  Tailspot
//
//  Daily catch-streak engine: "how many consecutive local calendar days
//  has the user caught at least one plane?"
//
//  Three design rules, each load-bearing:
//
//  1. STREAK DAYS ARE FROZEN LABELS, NOT TIMESTAMPS. A catch's streak day
//     is the "yyyy-MM-dd" string of the local calendar day where/when the
//     catch happened, stamped at insert (`Catch.caughtDayKey`). Re-deriving
//     days from `caughtAt` in the CURRENT zone would let a timezone change
//     reshuffle history: a 06:00 catch in Bali (UTC+8) lands on the
//     previous day once the phone re-zones to SFO (UTC-7), silently
//     breaking or forging streaks in flight. Legacy rows written before
//     the field existed fall back to current-zone derivation — accepted,
//     converges as new catches accrue.
//
//  2. DAY ARITHMETIC RUNS IN UTC. Once a day is a zone-free label,
//     "adjacent day" is pure calendar math with no wall-clock component —
//     stepping via a fixed UTC calendar at NOON makes it immune to DST
//     (a 23/25-hour local day is still exactly one label) and to any
//     current-zone weirdness. The current timezone matters in exactly one
//     place: producing TODAY's key.
//
//  3. ROWS ARE THE WHOLE TRUTH, BECAUSE THE DUPLICATE RULE NARROWED.
//     This engine ships alongside the v1.1 duplicate rule (scope R11/R12,
//     `Catch.isDuplicate`): a sighting is a duplicate only for the same
//     airframe under the same callsign on the same local day. So the first
//     catch of any airframe on any day always writes a row, and a day with
//     a catch action is exactly a day with a `Catch` row. Under the OLD
//     lifetime-per-airframe gate that was false — a regular spotter's sky
//     repeats tails constantly, so a day of familiar planes recorded
//     nothing and would have silently broken the streak. Order matters:
//     if the narrowed rule is ever reverted, this engine needs a
//     side-channel record of catch actions again.
//

import Foundation

nonisolated enum Streaks {

    // MARK: - Frozen day keys

    /// Fixed UTC calendar for key↔date conversion and day stepping. UTC is
    /// arbitrary but must be fixed: keys are zone-free labels, so stepping
    /// them in a DST-observing zone could double- or zero-count a label.
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// The "yyyy-MM-dd" label for the calendar day `date` falls on in
    /// `timeZone` (default: the device's current zone).
    static func dayKey(for date: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The streak day a stored catch belongs to: the frozen insert-time key
    /// when present (rule 1 above), else derived from `caughtAt` in
    /// `timeZone` for legacy rows.
    static func dayKey(for c: Catch, timeZone: TimeZone = .current) -> String {
        c.caughtDayKey ?? dayKey(for: c.caughtAt, timeZone: timeZone)
    }

    /// The distinct set of streak days for a Hangar. The ONE owner of day
    /// bucketing — the Profile card, the reveal chip, the reminder planner
    /// and the secret streak trophy all read sets built here, so they can
    /// never disagree about what "consecutive days" means.
    static func daySet(
        catches: [Catch],
        timeZone: TimeZone = .current
    ) -> Set<String> {
        var days = Set<String>()
        for c in catches { days.insert(dayKey(for: c, timeZone: timeZone)) }
        return days
    }

    // MARK: - Key arithmetic (UTC — rule 2 above)

    /// A key's anchor Date: NOON UTC on that day, so a ±1-day step can
    /// never straddle a boundary. nil for a malformed key.
    private static func anchorDate(fromKey key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return utc.date(from: comps)
    }

    /// The key `delta` calendar days away from `key`, or nil for a
    /// malformed input (malformed keys simply never chain).
    static func key(byAdding delta: Int, to key: String) -> String? {
        guard let date = anchorDate(fromKey: key),
              let shifted = utc.date(byAdding: .day, value: delta, to: date) else { return nil }
        let c = utc.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Streak metrics

    /// The LIVE run of consecutive catch-days ending at `todayKey` or the
    /// day before. Grace semantics: a streak "reads through yesterday" —
    /// it only drops to 0 after a FULL local day passes with no catch.
    /// (Showing 0 at 00:01 after a 12-day run reads as data loss, and the
    /// evening nudge would be nonsense if the streak it protects were
    /// already displayed as dead.)
    static func currentStreak(days: Set<String>, todayKey: String) -> Int {
        let anchor: String
        if days.contains(todayKey) {
            anchor = todayKey
        } else if let yesterday = key(byAdding: -1, to: todayKey), days.contains(yesterday) {
            anchor = yesterday
        } else {
            return 0
        }
        var run = 1
        var cursor = anchor
        while let prev = key(byAdding: -1, to: cursor), days.contains(prev) {
            run += 1
            cursor = prev
        }
        return run
    }

    /// The longest run of consecutive days ever present in `days`.
    /// Lexicographic order of "yyyy-MM-dd" keys IS chronological order,
    /// so a single sorted pass suffices.
    static func longestStreak(days: Set<String>) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var best = 1
        var run = 1
        for i in 1..<sorted.count {
            if key(byAdding: 1, to: sorted[i - 1]) == sorted[i] {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }

    /// Everything a streak display needs, computed in one pass.
    struct Summary: Equatable, Sendable {
        let current: Int
        let longest: Int
        let caughtToday: Bool
        /// A live streak with no catch yet today — it survives until
        /// midnight, then breaks. Drives the "catch today to keep it" hint.
        var atRisk: Bool { current > 0 && !caughtToday }
    }

    static func summary(
        catches: [Catch],
        asOf: Date = Date(),
        timeZone: TimeZone = .current
    ) -> Summary {
        let days = daySet(catches: catches, timeZone: timeZone)
        let today = dayKey(for: asOf, timeZone: timeZone)
        return Summary(
            current: currentStreak(days: days, todayKey: today),
            longest: longestStreak(days: days),
            caughtToday: days.contains(today)
        )
    }
}

// MARK: - Telemetry

/// Streak analytics, following the CatchTelemetry pure-builder pattern:
/// property builders are pure (unit-tested), fire wrappers go through the
/// single Analytics pipeline.
nonisolated enum StreakTelemetry {
    /// Fired once per day, on the first successful catch action of that
    /// day — `streak_days` is the resulting current streak, so day-1
    /// starts, extensions, and post-break restarts are all visible in one
    /// stream.
    static let extendedEvent = "streak_extended"
    /// Fired when the user opens the app from a streak-protection
    /// reminder — the reminder's effectiveness signal.
    static let reminderOpenedEvent = "streak_reminder_opened"

    static func extendedProperties(streakDays: Int) -> [String: AnalyticsValue] {
        ["streak_days": .int(streakDays)]
    }

    static func fireExtended(streakDays: Int) {
        Analytics.capture(extendedEvent, extendedProperties(streakDays: streakDays))
    }
}
