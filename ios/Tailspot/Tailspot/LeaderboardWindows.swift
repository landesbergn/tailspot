//
//  LeaderboardWindows.swift
//  Tailspot
//
//  Pure display helpers for the windowed leaderboard (dynamic-leaderboards
//  PR2): the reset-countdown lines and the champion-banner copy. Kept out of
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
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = timeZone
        fmt.dateFormat = "EEEE"
        let weekday = fmt.string(from: resetsAt).uppercased(with: locale)

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

/// Copy rules for the LAST WEEK'S CHAMPION banner. Shared crowns exist —
/// the champions array may carry several names — and a champion who never
/// claimed a handle displays as "anonymous spotter".
nonisolated enum ChampionBanner {

    /// Eyebrow line: singular/plural on the crown count.
    static func eyebrow(count: Int) -> String {
        count > 1 ? "LAST WEEK'S CHAMPIONS" : "LAST WEEK'S CHAMPION"
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
    static let noChampionSubtitle = "The sky was quiet last week."
}
