//
//  LeaderboardWindows.swift
//  Tailspot
//
//  Pure display helpers for the windowed leaderboard (dynamic-leaderboards
//  PR2): the reset-countdown lines, the champion-banner copy, and the
//  weekly race-gap line ("N PTS TO PASS @x"). Kept out of
//  the view so the string/date math is unit-testable with injected
//  locale/timezone/now — the views call these with the device defaults.
//
//  Wire types (`LeaderboardWindow`, `LeaderboardChampion`, `resetsAt`) live
//  in TailspotAccountClient.swift; this file is presentation only.
//

import Foundation

// MARK: - Reset countdown

/// Formats the "RESETS …" caption under the window switcher. All output is
/// computed in the CALLER'S timezone/locale (defaults: the device) — the
/// backend speaks UTC instants but the user never sees "UTC". No live
/// ticking: the label is recomputed per render, which is plenty for a
/// days/hours readout.
nonisolated enum LeaderboardCountdown {

    /// Week tab: "RESETS MONDAY · 2D 14H LEFT". The weekday is the LOCAL
    /// weekday of the reset instant (a Monday-00:00-UTC reset is still
    /// Sunday evening in California — that's the honest local answer).
    static func weekLabel(resetsAt: Date,
                          now: Date,
                          locale: Locale = .current,
                          timeZone: TimeZone = .current) -> String {
        let weekday = resetWeekday(resetsAt: resetsAt, locale: locale, timeZone: timeZone)

        let remaining = max(0, resetsAt.timeIntervalSince(now))
        let totalHours = Int(remaining / 3600)
        let days = totalHours / 24
        let hours = totalHours % 24
        let left: String
        if days > 0 {
            left = "\(days)D \(hours)H LEFT"
        } else if hours > 0 {
            left = "\(hours)H LEFT"
        } else {
            left = "UNDER 1H LEFT"
        }
        return "RESETS \(weekday) · \(left)"
    }

    /// "MONDAY" — the LOCAL weekday of the reset instant, uppercased. Shared
    /// by `weekLabel` and the race-gap line's "RESETS …" clause so the two
    /// can never name different days.
    static func resetWeekday(resetsAt: Date,
                             locale: Locale = .current,
                             timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = timeZone
        fmt.dateFormat = "EEEE"
        return fmt.string(from: resetsAt).uppercased(with: locale)
    }

    /// Month tab: "RESETS AUG 1". Localized month-day order via the
    /// "MMMd" template (en_GB renders "RESETS 1 AUG"); wraps cleanly
    /// across year boundaries ("RESETS JAN 1").
    static func monthLabel(resetsAt: Date,
                           locale: Locale = .current,
                           timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = timeZone
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return "RESETS " + fmt.string(from: resetsAt).uppercased(with: locale)
    }
}

// MARK: - Champion banner copy

/// Copy rules for the LAST WEEK/MONTH CHAMPION banner. Shared crowns exist —
/// the champions array may carry several names — and a champion who never
/// claimed a handle displays as "anonymous spotter".
nonisolated enum ChampionBanner {

    /// Eyebrow line: singular/plural on the crown count.
    static func eyebrow(count: Int, window: LeaderboardWindow = .week) -> String {
        let period = window == .month ? "MONTH" : "WEEK"
        let noun = count > 1 ? "CHAMPIONS" : "CHAMPION"
        return "LAST \(period)'S \(noun)"
    }

    /// Names line: "@skykid" / "@a & @b" / "@a, @b +1 more".
    static func names(_ champions: [LeaderboardChampion]) -> String {
        let display = champions.map { $0.handle.map { "@\($0)" } ?? "anonymous spotter" }
        switch display.count {
        case 0:  return ""
        case 1:  return display[0]
        case 2:  return "\(display[0]) & \(display[1])"
        default: return "\(display[0]), \(display[1]) +\(display.count - 2) more"
        }
    }

    /// The zero-champion week (empty `champions` array — the board reset
    /// with nobody on it).
    static let noChampionTitle = "NO CHAMPION CROWNED"

    static func noChampionSubtitle(window: LeaderboardWindow) -> String {
        window == .month ? "The sky was quiet last month." : "The sky was quiet last week."
    }
}

// MARK: - Weekly race gap

/// The "how far to the next goal" line under YOUR STANDING on the WEEK tab:
/// "51 PTS TO PASS @planespotter · ≈ 6 COMMON CATCHES". Built from the
/// board the screen already fetched — no extra request.
///
/// Computed by POINTS and ROW POSITION, never by `me.rank`. The two ranks
/// mean different things: `me.rank` counts every device with points this
/// week (handle-less and disabled ones included), while `entries[].rank`
/// is the row position among visible, handled spotters. Indexing
/// `entries[me.rank - 2]` would point at the wrong person whenever a hidden
/// device has points — so the copy names a handle, never a rank number.
nonisolated struct RaceGap: Equatable, Sendable {

    enum Target: Equatable, Sendable {
        /// Overtake this spotter (the row directly above mine).
        case pass(handle: String)
        /// Has a handle but no row on the visible board yet (nothing caught
        /// this week, or below the last row of a full board): points
        /// needed to earn a row. Never used for handle-less devices — the
        /// backend lists only handled devices, so no number of points
        /// earns them a row.
        case makeBoard
    }

    let target: Target
    /// Points still needed. Always ≥ 1 — a zero gap is no goal.
    let points: Int
    /// Points to reach the visible Top 10, when I'm on the board but below
    /// it and the Top 10 isn't the same goal as `target`. Nil otherwise.
    let topTenPoints: Int?

    /// Base points of a common catch (`Rarity.common.basePoints`, pinned to
    /// scoring-points.json). The units-neutral yardstick: real catches earn
    /// more with rarity and bonuses, so "≈ N common catches" is an upper
    /// bound on how many catches it takes.
    static let commonCatchPoints = Rarity.common.basePoints

    /// Gaps wider than this many common catches are hidden. The top of a
    /// week board is often one whale far ahead (2026-10-21: #2 trailed #1
    /// by 2,345 pts) — showing #2 "≈ 235 COMMON CATCHES" is discouraging,
    /// not a goal.
    static let maxCatches = 20

    /// "≈ N common catches" for the gap, rounded up.
    var catchesEquivalent: Int { Self.catches(for: points) }

    static func catches(for points: Int) -> Int {
        (points + commonCatchPoints - 1) / commonCatchPoints
    }

    /// The gap for this board, or nil when the line should be hidden.
    ///
    /// - `myHandle`: the local handle, or nil when the device has none.
    ///
    /// Hidden when: not the week window (month/all-time, or the pre-windows
    /// backend with no `window` key), no `me` (not registered), an empty
    /// board, I'm first on the board, or the gap is past `maxCatches`.
    static func compute(response: LeaderboardResponse,
                        window: LeaderboardWindow,
                        myHandle: String?) -> RaceGap? {
        guard window == .week,
              response.window == LeaderboardWindow.week.rawValue,
              let me = response.me else { return nil }
        let entries = response.displayedEntries
        guard !entries.isEmpty else { return nil }

        let myIndex = myHandle.flatMap { handle in
            entries.firstIndex { $0.handle.lowercased() == handle.lowercased() }
        }

        let target: Target
        let gap: Int
        if let myIndex {
            // On the board: pass the row directly above. Ties break by
            // registration time on the server, so drawing level isn't
            // enough — it takes one point more than them.
            guard myIndex > 0 else { return nil }  // I'm #1
            let above = entries[myIndex - 1]
            target = .pass(handle: above.handle)
            gap = above.points - me.points + 1
        } else {
            // Handle-less devices never get a row (the backend lists only
            // handled devices in `entries`), so a points goal would be a
            // promise points alone can't keep. The existing "claim a
            // handle" hint is their whole story.
            guard myHandle != nil else { return nil }
            // Handled but not a row on the board. With room left (under
            // the display limit), any point earns a row; a full board
            // means beating the last row.
            target = .makeBoard
            if entries.count < LeaderboardResponse.displayLimit {
                gap = 1 - me.points
            } else {
                gap = entries[entries.count - 1].points - me.points + 1
            }
        }
        guard gap >= 1, catches(for: gap) <= maxCatches else { return nil }

        // Top 10 clause: only for a row below the visible tenth, and only
        // when the tenth isn't the very spotter I'm already told to pass.
        var topTen: Int? = nil
        if let myIndex, myIndex > 10, entries.count >= 10 {
            let tenthGap = entries[9].points - me.points + 1
            if tenthGap >= 1, catches(for: tenthGap) <= maxCatches {
                topTen = tenthGap
            }
        }
        return RaceGap(target: target, points: gap, topTenPoints: topTen)
    }

    /// The goal: "51 PTS TO PASS @planespotter" / "1 PT TO MAKE THE BOARD".
    /// Kept short so it fits one line at default type; the yardstick and
    /// reset day go on `detail`.
    var headline: String {
        let goal: String
        switch target {
        case .pass(let handle): goal = "TO PASS @\(handle)"
        case .makeBoard:        goal = "TO MAKE THE BOARD"
        }
        return "\(Self.pts(points)) \(goal)"
    }

    /// "101 PTS TO THE TOP 10", or nil when there's no separate Top 10 goal.
    var topTenLine: String? {
        topTenPoints.map { "\(Self.pts($0)) TO THE TOP 10" }
    }

    /// "≈ 6 COMMON CATCHES · RESETS SUNDAY" (the reset clause is dropped
    /// when the board has no reset instant).
    func detail(resetWeekday: String?) -> String {
        let n = catchesEquivalent
        let catches = "≈ \(n) COMMON CATCH\(n == 1 ? "" : "ES")"
        guard let resetWeekday else { return catches }
        return "\(catches) · RESETS \(resetWeekday)"
    }

    private static func pts(_ value: Int) -> String {
        value == 1 ? "1 PT" : "\(value.formatted(.number)) PTS"
    }
}
