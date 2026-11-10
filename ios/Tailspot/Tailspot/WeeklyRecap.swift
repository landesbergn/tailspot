//
//  WeeklyRecap.swift
//  Tailspot
//
//  "Your week": a Monday-to-Sunday summary of the last full week of
//  catches, shown as a banner in the Hangar for the whole following week
//  and shareable as a 9:16 image (WeeklyRecapViews.swift). Growth idea 8
//  from the 2026-11-08 ideas round: a reason to come back on Monday, and a
//  share image that carries a campaign-attributed App Store link.
//
//  Everything is computed on the device from the Hangar. No backend call:
//  last week's leaderboard rank isn't kept anywhere the app can read once
//  the board resets, so the recap shows points instead.
//
//  Week math reuses the streak engine's frozen day keys (Streaks.swift), so
//  a catch lands in the same day here as it does for the streak, even after
//  a timezone change. Weeks start on Monday everywhere, whatever the
//  locale's first weekday, because the card is "the Monday recap".
//

import Foundation
import SwiftData

struct WeeklyRecap {
    /// "yyyy-MM-dd" of the recap's Monday. Also the dismiss key: closing the
    /// banner hides THIS week's recap only.
    let weekStartKey: String
    /// The seven day keys, Monday first.
    let dayKeys: [String]
    /// Catches per day, aligned with `dayKeys`.
    let dayCounts: [Int]
    /// Every catch row in the week, re-catches of a known tail included
    /// (each is a real catch with its own points).
    let catchCount: Int
    /// Airframes whose first-ever catch fell in this week.
    let newAirframes: Int
    /// Typecodes whose first-ever catch fell in this week.
    let newTypes: Int
    /// The week's display points: base plus first-of-type and correct-guess
    /// bonuses, derived the same way the Hangar's catch cards derive them.
    let points: Int
    /// The LIVE streak as of when the recap was built (Streaks.summary, the
    /// same number the Profile shows), not a figure frozen inside the week.
    let currentStreak: Int
    /// The week's standout catch: highest tier, then a photo, then a
    /// first-of-type, then the most recent.
    let rarest: Catch
    /// The standout as a Hangar row, so the recap can open its detail. The
    /// row's `mostRecent` IS the standout (the detail renders `mostRecent`).
    let rarestRow: HangarRow

    /// Builds the recap of the last FULL Monday–Sunday week before `now`.
    /// nil when that week has no catches (nothing to show).
    static func lastWeek(
        catches: [Catch],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> WeeklyRecap? {
        let todayKey = Streaks.dayKey(for: now, timeZone: timeZone)
        guard let start = lastWeekStartKey(todayKey: todayKey) else { return nil }
        let streak = Streaks.summary(catches: catches, asOf: now, timeZone: timeZone).current
        return week(startingAt: start, catches: catches, currentStreak: streak, timeZone: timeZone)
    }

    /// The Monday key of the week BEFORE the one `todayKey` falls in.
    static func lastWeekStartKey(todayKey: String) -> String? {
        guard let offset = daysSinceMonday(key: todayKey),
              let thisMonday = Streaks.key(byAdding: -offset, to: todayKey) else { return nil }
        return Streaks.key(byAdding: -7, to: thisMonday)
    }

    /// 0 for a Monday key … 6 for a Sunday key. nil for a malformed key.
    static func daysSinceMonday(key: String) -> Int? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]; comps.hour = 12
        guard let date = utc.date(from: comps) else { return nil }
        // Gregorian weekday: 1 = Sunday … 7 = Saturday.
        let weekday = utc.component(.weekday, from: date)
        return (weekday + 5) % 7
    }

    /// The recap for the week starting at `startKey` (a Monday).
    static func week(
        startingAt startKey: String,
        catches: [Catch],
        currentStreak: Int = 0,
        timeZone: TimeZone = .current
    ) -> WeeklyRecap? {
        let dayKeys = (0..<7).compactMap { Streaks.key(byAdding: $0, to: startKey) }
        guard dayKeys.count == 7 else { return nil }
        let index = Dictionary(uniqueKeysWithValues: dayKeys.enumerated().map { ($1, $0) })

        // First-ever catch of each airframe and each typecode, across the
        // whole Hangar (a "new" tail this week is one never caught before).
        var firstOfAirframe: [String: Date] = [:]
        var firstOfType: [String: Date] = [:]
        for c in catches {
            let tail = c.icao24.lowercased()
            if firstOfAirframe[tail].map({ c.caughtAt < $0 }) ?? true { firstOfAirframe[tail] = c.caughtAt }
            if let tc = normalizedTypecode(c.typecode),
               firstOfType[tc].map({ c.caughtAt < $0 }) ?? true { firstOfType[tc] = c.caughtAt }
        }

        var counts = Array(repeating: 0, count: 7)
        var inWeek: [Catch] = []
        for c in catches {
            guard let i = index[Streaks.dayKey(for: c, timeZone: timeZone)] else { continue }
            counts[i] += 1
            inWeek.append(c)
        }
        guard !inWeek.isEmpty else { return nil }

        var newAirframes = 0
        var newTypes = 0
        var points = 0
        var seenTails = Set<String>()
        var seenTypes = Set<String>()
        for c in inWeek {
            let tail = c.icao24.lowercased()
            if firstOfAirframe[tail] == c.caughtAt, seenTails.insert(tail).inserted { newAirframes += 1 }
            let tc = normalizedTypecode(c.typecode)
            let isFirstOfType = tc.map { firstOfType[$0] == c.caughtAt } ?? false
            if isFirstOfType, let tc, seenTypes.insert(tc).inserted { newTypes += 1 }
            points += displayPoints(c, isFirstOfType: isFirstOfType)
        }

        let rarest = inWeek.max { a, b in
            standoutRank(a, firstOfType: firstOfType) < standoutRank(b, firstOfType: firstOfType)
        }!
        let tail = rarest.icao24.lowercased()
        let airframe = catches
            .filter { $0.icao24.lowercased() == tail }
            .sorted { $0.caughtAt > $1.caughtAt }
        let rarestRow = HangarRow(icao24: rarest.icao24, mostRecent: rarest,
                                  count: airframe.count, allCatches: airframe)

        return WeeklyRecap(
            weekStartKey: startKey,
            dayKeys: dayKeys,
            dayCounts: counts,
            catchCount: inWeek.count,
            newAirframes: newAirframes,
            newTypes: newTypes,
            points: points,
            currentStreak: currentStreak,
            rarest: rarest,
            rarestRow: rarestRow
        )
    }

    // MARK: - Pieces

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func normalizedTypecode(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !t.isEmpty else { return nil }
        return t
    }

    /// Same derivation as the Hangar's TailCard: base for the live tier,
    /// plus first-of-type and a recorded CORRECT guess.
    static func displayPoints(_ c: Catch, isFirstOfType: Bool) -> Int {
        let guessKind: GuessKind? = (c.guessCorrect == true)
            ? c.guessKind.flatMap(GuessKind.init(rawValue:))
            : nil
        return ScoringBonuses.displayPoints(
            base: c.resolvedRarity.basePoints,
            isFirstOfType: isFirstOfType,
            guessKind: guessKind,
            caughtAt: c.caughtAt
        ).total
    }

    /// Ordering for the standout catch, compared lexicographically.
    private static func standoutRank(
        _ c: Catch, firstOfType: [String: Date]
    ) -> (Int, Int, Int, Date) {
        let firstType = normalizedTypecode(c.typecode).map { firstOfType[$0] == c.caughtAt } ?? false
        return (
            c.resolvedRarity.basePoints,
            c.photoFilename == nil ? 0 : 1,
            firstType ? 1 : 0,
            c.caughtAt
        )
    }


    // MARK: - Copy

    /// "9 planes caught".
    var headline: String {
        "\(CountCopy.phrase(catchCount, singular: "plane")) caught"
    }

    /// The line under the headline.
    var subline: String {
        newAirframes > 0
            ? "\(newAirframes.formatted()) new to your Hangar"
            : "All repeat visitors"
    }

    /// The subline in the sharer's voice, for the share image.
    var sharedSubline: String {
        newAirframes > 0
            ? "\(newAirframes.formatted()) new to my Hangar"
            : "All repeat visitors"
    }

    /// "NOV 2 – 8", or "OCT 26 – NOV 1" across a month boundary.
    func rangeLabel(locale: Locale = .current) -> String {
        guard let first = dayKeys.first, let last = dayKeys.last,
              let a = Self.anchor(first), let b = Self.anchor(last) else { return "" }
        let month = Self.monthFormatter(locale)
        let sameMonth = Self.utc.component(.month, from: a) == Self.utc.component(.month, from: b)
        let dayA = Self.utc.component(.day, from: a)
        let dayB = Self.utc.component(.day, from: b)
        let left = "\(month.string(from: a)) \(dayA)"
        let right = sameMonth ? "\(dayB)" : "\(month.string(from: b)) \(dayB)"
        return "\(left) – \(right)".uppercased(with: locale)
    }

    /// "MMM" formatters, one per locale; building a DateFormatter is costly
    /// and the banner asks on every Hangar body pass.
    private static var monthFormatters: [String: DateFormatter] = [:]
    private static func monthFormatter(_ locale: Locale) -> DateFormatter {
        if let cached = monthFormatters[locale.identifier] { return cached }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = utc.timeZone
        f.setLocalizedDateFormatFromTemplate("MMM")
        monthFormatters[locale.identifier] = f
        return f
    }

    /// One-letter weekday labels, Monday first ("M T W T F S S").
    static func weekdayLetters(locale: Locale = .current) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = locale
        let sundayFirst = cal.veryShortStandaloneWeekdaySymbols
        guard sundayFirst.count == 7 else { return ["M", "T", "W", "T", "F", "S", "S"] }
        return Array(sundayFirst[1...]) + [sundayFirst[0]]
    }

    private static func anchor(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = p[0]; comps.month = p[1]; comps.day = p[2]; comps.hour = 12
        return utc.date(from: comps)
    }
}

// MARK: - When the Hangar shows it

nonisolated enum WeeklyRecapPresentation {
    /// The `weekStartKey` the user closed. One key, so a new week's recap
    /// comes back on its own.
    static let dismissedWeekKey = "tailspot.weeklyRecap.dismissedWeek"
    /// The `weekStartKey` whose banner has already sent `weekly_recap_shown`.
    static let shownWeekKey = "tailspot.weeklyRecap.shownWeek"

    static func shouldShow(weekStartKey: String?, dismissedWeek: String) -> Bool {
        guard let weekStartKey else { return false }
        return weekStartKey != dismissedWeek
    }
}

// MARK: - Telemetry

enum WeeklyRecapTelemetry {
    static let shownEvent = "weekly_recap_shown"
    static let openedEvent = "weekly_recap_opened"
    static let dismissedEvent = "weekly_recap_dismissed"
    static let sharedEvent = "weekly_recap_shared"

    /// App Store campaign for installs that come from a shared recap.
    static let campaign = "Weekly Recap"

    static func properties(_ r: WeeklyRecap) -> [String: AnalyticsValue] {
        [
            "week_start": .string(r.weekStartKey),
            "catch_count": .int(r.catchCount),
            "new_airframes": .int(r.newAirframes),
            "active_days": .int(r.dayCounts.filter { $0 > 0 }.count),
            "rarest_rarity": .string(r.rarest.isDeleted ? "deleted" : r.rarest.resolvedRarity.rawValue),
        ]
    }

    static func fire(_ event: String, _ r: WeeklyRecap, extra: [String: AnalyticsValue] = [:]) {
        Analytics.capture(event, properties(r).merging(extra) { _, new in new })
    }
}

// MARK: - Last week's rank

/// The recap's WEEKLY RANK: this device's final rank in the last closed
/// week, from `GET /v1/leaderboard?window=week` (`me.lastWeekRank`, server
/// 2026-11-09). The board's weeks are Monday 00:00 UTC; the recap's are the
/// local Monday. The rank is used only when the server's last closed week
/// starts on the same date as the recap's week — east of UTC, early Monday,
/// the board's week hasn't closed yet and the rank would be the week before.
enum WeeklyRecapRank {
    static let cacheKey = "tailspot.weeklyRecap.rank"

    /// "yyyy-MM-dd" of the server's last closed week: `resetsAt` (the NEXT
    /// week start) minus 14 days.
    nonisolated static func lastClosedWeekStart(_ response: LeaderboardResponse) -> String? {
        guard let next = response.resetsAtDate else { return nil }
        return Streaks.dayKey(for: next.addingTimeInterval(-14 * 86_400), timeZone: .gmt)
    }

    /// The rank to show for `weekStart`, or nil (unknown, unranked, or the
    /// board's week doesn't match the recap's).
    nonisolated static func rank(from response: LeaderboardResponse, weekStart: String) -> Int? {
        guard lastClosedWeekStart(response) == weekStart,
              let rank = response.me?.lastWeekRank, rank >= 1 else { return nil }
        return rank
    }

    static func cached(weekStart: String, defaults: UserDefaults = .standard) -> Int? {
        guard let raw = defaults.string(forKey: cacheKey) else { return nil }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, parts[0] == weekStart, let rank = Int(parts[1]) else { return nil }
        return rank
    }

    /// Fetches and caches the rank. nil on any failure (offline, old server).
    static func fetch(weekStart: String, client: TailspotAccountClient = TailspotAccountClient()) async -> Int? {
        guard let response = try? await client.leaderboard(window: .week, limit: 1),
              let rank = rank(from: response, weekStart: weekStart) else { return nil }
        UserDefaults.standard.set("\(weekStart)|\(rank)", forKey: cacheKey)
        return rank
    }
}
