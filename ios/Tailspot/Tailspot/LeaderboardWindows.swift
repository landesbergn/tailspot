//
//  LeaderboardWindows.swift
//  Tailspot
//
//  Pure display helpers for the windowed leaderboard (dynamic-leaderboards
//  PR2): the reset countdown, the champion-banner copy, and the standing
//  line under the switcher ("You're 18th this week" / "10 points behind
//  @randy98 · resets in 2d 9h", every window). Kept out of the view so the string/date math is unit-testable with injected
//  locale/timezone/now — the views call these with the device defaults.
//
//  Wire types (`LeaderboardWindow`, `LeaderboardChampion`, `resetsAt`) live
//  in TailspotAccountClient.swift; this file is presentation only.
//

import Foundation

// MARK: - Reset countdown

/// The reset countdown, folded into the standing line's subtitle
/// ("10 points behind @randy98 · resets in 2d 9h"). All output is computed
/// in the CALLER'S timezone/locale (defaults: the device) — the backend
/// speaks UTC instants but the user never sees "UTC". No live ticking: the
/// text is recomputed per render, which is plenty for a days/hours readout.
nonisolated enum LeaderboardCountdown {

    /// Whole days and hours left, floored; a reset already passed (stale
    /// cached response) clamps to zero rather than going negative.
    static func remaining(resetsAt: Date, now: Date) -> (days: Int, hours: Int) {
        let totalHours = Int(max(0, resetsAt.timeIntervalSince(now)) / 3600)
        return (totalHours / 24, totalHours % 24)
    }

    /// Week tab: "resets in 2d 14h" / "resets in 14h" / "resets in under 1h".
    static func weekProse(resetsAt: Date, now: Date) -> String {
        let (days, hours) = remaining(resetsAt: resetsAt, now: now)
        if days > 0 { return hours > 0 ? "resets in \(days)d \(hours)h" : "resets in \(days)d" }
        if hours > 0 { return "resets in \(hours)h" }
        return "resets in under 1h"
    }

    /// VoiceOver for `weekProse`: "resets in 2 days, 14 hours".
    static func weekSpoken(resetsAt: Date, now: Date) -> String {
        let (days, hours) = remaining(resetsAt: resetsAt, now: now)
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if days > 0 {
            return hours > 0 ? "resets in \(unit(days, "day")), \(unit(hours, "hour"))"
                             : "resets in \(unit(days, "day"))"
        }
        if hours > 0 { return "resets in \(unit(hours, "hour"))" }
        return "resets in under an hour"
    }

    /// Month tab: "resets Aug 1". Localized month-day order via the "MMMd"
    /// template (en_GB renders "resets 1 Aug"); the LOCAL date of the reset
    /// instant, so an Aug-1-UTC reset reads "Jul 31" in California.
    static func monthProse(resetsAt: Date,
                           locale: Locale = .current,
                           timeZone: TimeZone = .current) -> String {
        let fmt = DateFormatter()
        fmt.locale = locale
        fmt.timeZone = timeZone
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return "resets " + fmt.string(from: resetsAt)
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

// MARK: - Race gap

/// The "how far to the next spotter" goal on the standing line under the
/// leaderboard switcher: "50 points behind @planespotter". One per
/// window (WEEK, MONTH, ALL TIME), each built from that window's own board —
/// no extra request.
///
/// Computed by POINTS and ROW POSITION, never by `me.rank`. The two ranks
/// mean different things: `me.rank` counts every device with points in the
/// window (handle-less and disabled ones included), while `entries[].rank`
/// is the row position among visible, handled spotters. Indexing
/// `entries[me.rank - 2]` would point at the wrong person whenever a hidden
/// device has points — so the target is the row above MY ROW, and the "#N"
/// kept is that row's own printed rank (see `StandingLine`).
nonisolated struct RaceGap: Equatable, Sendable {

    enum Target: Equatable, Sendable {
        /// Overtake this spotter (the row directly above mine), printed on
        /// the board at `rank`.
        case pass(handle: String, rank: Int)
        /// Has a handle but no row on the visible board yet (nothing caught
        /// in this window, or below the last row of a full board): points
        /// needed to earn a row. Never used for handle-less devices — the
        /// backend lists only handled devices, so no number of points
        /// earns them a row.
        ///
        /// `full`: the board already has its 50 rows, so the goal is
        /// beating the last one ("31 points to make the top 50"); with
        /// room left, any point earns a row ("1 point to get on the
        /// board").
        case makeBoard(full: Bool)
    }

    let target: Target
    /// Points still needed. Always ≥ 1 — a zero gap is no goal. No upper
    /// cap: big gaps (common on ALL TIME) still show who is ahead and by
    /// how much (Noah, 2026-10-22).
    let points: Int

    /// Base points of a common catch (`Rarity.common.basePoints`, pinned to
    /// scoring-points.json). Only feeds the `catches_equiv` telemetry
    /// property now — the "≈ N common catches" copy was cut.
    static let commonCatchPoints = Rarity.common.basePoints

    /// The gap in common catches, rounded up (telemetry only).
    var catchesEquivalent: Int {
        (points + Self.commonCatchPoints - 1) / Self.commonCatchPoints
    }

    /// The gap for this window's board, or nil when the line should be hidden.
    ///
    /// - `myHandle`: the local handle, or nil when the device has none.
    /// - `handleConfirmed`: whether the server has acknowledged `myHandle`
    ///   for this device (`SpotterHandle.isConfirmed`). The make-the-board
    ///   goal needs it: a stranded handle (claim 409'd or never synced) gets
    ///   no row however many points it earns.
    ///
    /// Hidden when: the response isn't this window's (the pre-windows
    /// backend sends no `window` key — its board is all-time even when the
    /// screen files it under `.week`), no `me` (not registered — also a
    /// disabled device, whose token the server no longer resolves), an
    /// empty board, I'm first on the board, or a handle-less / not-yet-
    /// confirmed device that isn't on the board.
    static func compute(response: LeaderboardResponse,
                        window: LeaderboardWindow,
                        myHandle: String?,
                        handleConfirmed: Bool) -> RaceGap? {
        guard response.window == window.rawValue,
              let me = response.me else { return nil }
        let entries = response.displayedEntries
        guard !entries.isEmpty else { return nil }

        let myIndex = LeaderboardEntry.myIndex(in: entries, myHandle: myHandle,
                                               handleConfirmed: handleConfirmed)
        // `me` comes from a separate server query (myStanding) than the
        // rows; a catch uploading between the two leaves them out of step.
        // When I'm a row, measure from MY ROW's points so the line always
        // agrees with the numbers printed on the board.
        let myPoints = myIndex.map { entries[$0].points } ?? me.points

        let target: Target
        let gap: Int
        if let myIndex {
            // On the board: pass the row directly above. Ties break by
            // registration time on the server, so drawing level isn't
            // enough — it takes one point more than them.
            guard myIndex > 0 else { return nil }  // I'm #1
            let above = entries[myIndex - 1]
            target = .pass(handle: above.handle, rank: above.rank)
            gap = above.points - myPoints + 1
        } else {
            // Handle-less devices never get a row (the backend lists only
            // handled devices in `entries`), so a points goal would be a
            // promise points alone can't keep. The existing "claim a
            // handle" hint is their whole story.
            guard myHandle != nil else { return nil }
            // Stranded: the server doesn't hold this handle, so no number
            // of points earns a row. (A stranded handle never matches a row
            // either — see `LeaderboardEntry.myIndex`.)
            guard handleConfirmed else { return nil }
            // Handled but not a row on the board. With room left, any
            // point earns a row; a full board means beating the last row.
            // "Full" trusts the server's `totalCatchers` (qualifying
            // spotters before the row limit) as well as the row count, so
            // a short response can't promise "1 PT" when the real board is
            // full. An older server without the count falls back to rows.
            //
            // Belt and braces for a strand the marker missed: a device
            // with points that still isn't a row on a board with room can't
            // be listed, and the gap below comes out ≤ 0 and hides.
            let boardFull = entries.count >= LeaderboardResponse.displayLimit
                || (response.totalCatchers ?? 0) >= LeaderboardResponse.displayLimit
            target = .makeBoard(full: boardFull)
            if boardFull {
                // Full by `totalCatchers` but fewer rows came back: the last
                // row isn't the 50th, so any number measured from it would
                // overstate the gap. Say nothing rather than guess.
                guard entries.count >= LeaderboardResponse.displayLimit else { return nil }
                gap = entries[entries.count - 1].points - myPoints + 1
            } else {
                gap = 1 - myPoints
            }
        }
        guard gap >= 1 else { return nil }
        return RaceGap(target: target, points: gap)
    }

    /// The goal in prose, for the standing line's subtitle.
    ///
    /// - pass: "10 points behind @randy98" — the honest distance, i.e.
    ///   `points - 1`, since `points` includes the extra point a tie needs
    ///   (ties break by registration time). Level on points reads "1 point
    ///   to pass @randy98", because "0 points behind" would be no goal.
    /// - make the board: "31 points to make the top 50" on a full board,
    ///   "1 point to get on the board" with room left.
    var prose: String {
        switch target {
        case .pass(let handle, _):
            let behind = points - 1
            return behind == 0
                ? "1 point to pass @\(handle)"
                : "\(Self.pointsText(behind)) behind @\(handle)"
        case .makeBoard(let full):
            return full
                ? "\(Self.pointsText(points)) to make the top \(LeaderboardResponse.displayLimit)"
                : "\(Self.pointsText(points)) to get on the board"
        }
    }

    /// Analytics `target` value for `leaderboard_gap_shown`.
    var analyticsTarget: String {
        switch target {
        case .pass:      return "pass"
        case .makeBoard: return "make_board"
        }
    }

    /// Dedup key for `leaderboard_gap_shown`: one event per goal per window
    /// per screen visit, however often the user flips back to the tab.
    func reportKey(window: LeaderboardWindow) -> String {
        switch target {
        case .pass(let handle, _): return "\(window.rawValue):pass:\(handle.lowercased())"
        case .makeBoard:           return "\(window.rawValue):make_board"
        }
    }

    static func pointsText(_ value: Int) -> String {
        "\(value.formatted(.number)) point\(value == 1 ? "" : "s")"
    }
}

// MARK: - Standing line

/// The standing line under the WEEK / MONTH / ALL TIME switcher (Noah's
/// option "D · One sentence", 2026-10-23), centred:
///
///         You're 18th this week
///   10 points behind @randy98 · resets in 2d 9h
///
/// It replaced the YOUR STANDING card (rank, handle, points, YOU pill and a
/// goal line), which read as busy. The ordinal is the only number in the
/// heading; the subtitle holds the gap and, on week and month, the reset.
///
/// RANK CONSISTENCY: the ordinal is MY ROW's printed rank, so it always
/// matches the list. `me.rank` (which also counts hidden handle-less and
/// disabled devices; see `RaceGap`) is never printed: when I'm not a row
/// the heading says "You're not on the board yet".
nonisolated struct StandingLine: Equatable, Sendable {

    enum GoalLine: Equatable, Sendable {
        /// Points to the row above (or to make the board).
        case gap(RaceGap)
        /// I'm first: my lead over the row below. `points` is 0 when I
        /// hold #1 on the registration-time tiebreak.
        case leading(handle: String, points: Int)
    }

    /// My row's printed rank; 0 when I'm not a row on the board.
    let rank: Int
    /// My handle, nil for a handle-less device (claim-a-handle hint, no
    /// goal).
    let handle: String?
    let goal: GoalLine?
    /// "this week" / "this month" / "all time"; nil on the pre-windows
    /// backend, whose single board isn't any one window's.
    let windowPhrase: String?

    /// The line for this window's response, or nil when there's no `me`
    /// (not registered, or a disabled device) and the device has a handle —
    /// the view then shows the reset alone. A handle-less device with no
    /// `me` still gets the claim-a-handle line.
    ///
    /// The goal is left out on the pre-windows backend (its board is
    /// all-time even when filed under `.week`), for a handle-less device,
    /// and wherever `RaceGap.compute` hides (stranded handle, empty board…).
    static func compute(response: LeaderboardResponse,
                        window: LeaderboardWindow,
                        myHandle: String?,
                        handleConfirmed: Bool) -> StandingLine? {
        let windowMatches = response.window == window.rawValue
        guard response.me != nil else {
            // Unregistered and handle-less: the claim-a-handle hint is the
            // one way onto the board, so it still shows. Unregistered with
            // a handle → nil (the view shows the reset alone).
            guard myHandle == nil else { return nil }
            return StandingLine(rank: 0, handle: nil, goal: nil,
                                windowPhrase: windowMatches ? window.standingPhrase : nil)
        }
        let entries = response.displayedEntries
        let myIndex = LeaderboardEntry.myIndex(in: entries, myHandle: myHandle,
                                               handleConfirmed: handleConfirmed)

        let goal: GoalLine?
        if myHandle == nil || !windowMatches {
            goal = nil
        } else if myIndex == 0 {
            // First on the board: a positive line about the row below.
            // Alone on the board → nothing to lead (the "1st" says it).
            goal = entries.count > 1
                ? .leading(handle: entries[1].handle,
                           points: max(0, entries[0].points - entries[1].points))
                : nil
        } else {
            goal = RaceGap.compute(response: response, window: window,
                                   myHandle: myHandle, handleConfirmed: handleConfirmed)
                .map(GoalLine.gap)
        }
        return StandingLine(rank: myIndex.map { entries[$0].rank } ?? 0,
                            handle: myHandle,
                            goal: goal,
                            windowPhrase: windowMatches ? window.standingPhrase : nil)
    }

    /// The race gap, when the goal is one (telemetry reports these).
    var raceGap: RaceGap? {
        if case .gap(let gap) = goal { return gap }
        return nil
    }

    var isOnBoard: Bool { rank >= 1 }

    /// "18th", drawn in Brand cyan inside the heading; nil off the board.
    var ordinal: String? { isOnBoard ? Ordinal.english(rank) : nil }

    /// What follows the ordinal: " this week", or "" on the old backend.
    var headingSuffix: String { windowPhrase.map { " \($0)" } ?? "" }

    /// "You're 18th this week" / "You're not on the board yet".
    var heading: String {
        ordinal.map { "You're \($0)\(headingSuffix)" } ?? "You're not on the board yet"
    }

    /// The goal (or the claim-a-handle hint), without the reset.
    var detail: String? {
        switch goal {
        case .gap(let gap)?:
            return gap.prose
        case .leading(let handle, let lead)?:
            return lead == 0
                ? "Tied with @\(handle), ahead on the tiebreak"
                : "\(RaceGap.pointsText(lead)) ahead of @\(handle)"
        case nil:
            return handle == nil ? Self.claimHint : nil
        }
    }

    static let claimHint = "Claim a handle in Profile → Settings to join"

    /// The second line: detail and reset joined by " · ", first letter
    /// capitalised ("Resets in 2d 9h" when the reset stands alone). Nil when
    /// both are missing. Static so the view can show the reset with no
    /// standing at all (unregistered device).
    ///
    /// The reset phrase and the "·" before it use no-break spaces, so a
    /// narrow screen wraps between the two halves ("… @flydelta ·" /
    /// "resets in 2d 14h") instead of orphaning "2d 14h" on its own line.
    static func subtitle(detail: String?, reset: String?) -> String? {
        let nbsp = "\u{00A0}"
        let keptReset = reset.map { $0.replacingOccurrences(of: " ", with: nbsp) }
        let parts = [detail, keptReset].compactMap { $0 }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\(nbsp)· ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    /// VoiceOver for the whole line: "You're 18th this week. 10 points
    /// behind randy98. Resets in 2 days, 9 hours." `spokenReset` is the
    /// countdown's spoken form ("resets in 2 days, 9 hours").
    static func spoken(_ line: StandingLine?, spokenReset: String?) -> String {
        var sentences: [String] = []
        if let line {
            sentences.append(line.heading)
            if let detail = line.detail {
                sentences.append(detail
                    .replacingOccurrences(of: "@", with: "")
                    .replacingOccurrences(of: " → ", with: ", "))
            }
        }
        if let spokenReset { sentences.append(spokenReset) }
        return sentences
            .map { ($0.prefix(1).uppercased() + $0.dropFirst()) + "." }
            .joined(separator: " ")
    }
}

extension LeaderboardWindow {
    /// The window as the standing heading says it: "this week" /
    /// "this month" / "all time".
    nonisolated var standingPhrase: String {
        switch self {
        case .week:  return "this week"
        case .month: return "this month"
        case .all:   return "all time"
        }
    }
}

/// English ordinals: 1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 101st 111th.
/// Hand-rolled rather than `NumberFormatter(.ordinal)` because the
/// sentence around it is English; a device in French would otherwise read
/// "You're 18e this week".
nonisolated enum Ordinal {
    static func english(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1):       suffix = "st"
        case (_, 2):       suffix = "nd"
        case (_, 3):       suffix = "rd"
        default:           suffix = "th"
        }
        // English digits and grouping too ("1,001st"), not the device's.
        return n.formatted(.number.locale(Locale(identifier: "en_US"))) + suffix
    }
}

extension LeaderboardEntry {
    /// Case-insensitive handle match.
    nonisolated func isHandle(_ handle: String) -> Bool {
        self.handle.lowercased() == handle.lowercased()
    }

    /// The one "is this row me?" rule, shared by the board's highlight, the
    /// standing line and `RaceGap`: my public handle, and only once the
    /// server has confirmed it. A stranded handle (claim 409'd because
    /// someone else holds it) would otherwise match THEIR row and describe
    /// their rank and points as mine.
    nonisolated static func isMe(_ entry: LeaderboardEntry, myHandle: String?,
                                 handleConfirmed: Bool) -> Bool {
        guard handleConfirmed, let myHandle else { return false }
        return entry.isHandle(myHandle)
    }

    nonisolated static func myIndex(in entries: [LeaderboardEntry], myHandle: String?,
                                    handleConfirmed: Bool) -> Int? {
        entries.firstIndex { isMe($0, myHandle: myHandle, handleConfirmed: handleConfirmed) }
    }
}

extension SpotterHandle {
    /// The public handle, or nil for empty / the untouched placeholder —
    /// the "has a handle" test the leaderboard uses.
    nonisolated static func publicHandle(_ stored: String?) -> String? {
        guard let stored, !stored.isEmpty, stored != defaultPlaceholder else { return nil }
        return stored
    }

    /// True when the server has acknowledged `handle` for this device: the
    /// `confirmedKey` marker matches it (the same test `HandleSyncer` uses
    /// to decide nothing needs syncing).
    nonisolated static func isConfirmed(_ handle: String?, confirmed: String?) -> Bool {
        guard let handle, let confirmed else { return false }
        return handle == confirmed
    }
}
