//
//  LeaderboardWindows.swift
//  Tailspot
//
//  Pure display helpers for the windowed leaderboard (dynamic-leaderboards
//  PR2): the reset-countdown lines, the champion-banner copy, and the
//  YOUR STANDING card with its goal line ("N PTS TO PASS #17 @x", every
//  window). Kept out of
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

    /// "MONDAY" — the LOCAL weekday of the reset instant, uppercased, as
    /// `weekLabel` prints it.
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

// MARK: - Race gap

/// The "how far to the next spotter" goal on the YOUR STANDING card in the
/// leaderboard's fixed header: "51 PTS TO PASS #10 @planespotter". One per
/// window (WEEK, MONTH, ALL TIME), each built from that window's own board —
/// no extra request.
///
/// Computed by POINTS and ROW POSITION, never by `me.rank`. The two ranks
/// mean different things: `me.rank` counts every device with points in the
/// window (handle-less and disabled ones included), while `entries[].rank`
/// is the row position among visible, handled spotters. Indexing
/// `entries[me.rank - 2]` would point at the wrong person whenever a hidden
/// device has points — so the target is the row above MY ROW, and the "#N"
/// printed is that row's own printed rank (see `StandingCard`).
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
        case makeBoard
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

        let myIndex = myHandle.flatMap { handle in
            entries.firstIndex { $0.isHandle(handle) }
        }
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
            // of points earns a row. Being ON the board (the branch above)
            // already proves the server has it, so only this path checks.
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
            target = .makeBoard
            let boardFull = entries.count >= LeaderboardResponse.displayLimit
                || (response.totalCatchers ?? 0) >= LeaderboardResponse.displayLimit
            if boardFull {
                gap = entries[entries.count - 1].points - myPoints + 1
            } else {
                gap = 1 - myPoints
            }
        }
        guard gap >= 1 else { return nil }
        return RaceGap(target: target, points: gap)
    }

    /// The whole line: "51 PTS TO PASS #10 @planespotter" / "1 PT TO MAKE
    /// THE BOARD". "To pass" (not "behind") because the number already
    /// includes the +1 a tie needs. Names both the place and the person.
    /// Fits one line at default type; wraps at large Dynamic Type.
    var headline: String {
        let goal: String
        switch target {
        case .pass(let handle, let rank): goal = "TO PASS #\(rank) @\(handle)"
        case .makeBoard:                  goal = "TO MAKE THE BOARD"
        }
        return "\(Self.pts(points)) \(goal)"
    }

    /// VoiceOver prose for `headline`: "51 points to pass planespotter, at
    /// number 10".
    var spoken: String {
        let goal: String
        switch target {
        case .pass(let handle, let rank): goal = "to pass \(handle), at number \(rank)"
        case .makeBoard:                  goal = "to make the board"
        }
        return "\(Self.spokenPoints(points)) \(goal)"
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

    static func spokenPoints(_ value: Int) -> String {
        "\(value.formatted(.number)) point\(value == 1 ? "" : "s")"
    }

    static func pts(_ value: Int) -> String {
        value == 1 ? "1 PT" : "\(value.formatted(.number)) PTS"
    }
}

// MARK: - Your standing card

/// The YOUR STANDING card in the leaderboard's fixed header (Noah,
/// 2026-10-22: "it should include your standing … and the number of points
/// to the person / place in the standing above you"):
///
///     18  @noah                         100  YOU
///     11 PTS TO PASS #17 @randy98
///
/// RANK CONSISTENCY: when I'm a row on the board, the card prints MY ROW's
/// rank and points, and the goal names the row above by ITS printed rank —
/// so every number on the card matches a number in the list. `me.rank`
/// (which also counts hidden handle-less/disabled devices; see `RaceGap`)
/// is used only when I'm not a row, where there is no row to disagree with.
nonisolated struct StandingCard: Equatable, Sendable {

    enum GoalLine: Equatable, Sendable {
        /// Points to the row above (or to make the board).
        case gap(RaceGap)
        /// I'm first: my lead over the row below. `points` is 0 when I
        /// hold #1 on the registration-time tiebreak.
        case leading(handle: String, points: Int)
    }

    /// Rank to print; 0 = unranked ("—").
    let rank: Int
    /// My handle as the card prints it, nil for a handle-less device
    /// ("(you)" plus the claim-a-handle hint, no goal line).
    let handle: String?
    let points: Int
    let goal: GoalLine?

    /// The card for this window's response, or nil when there's no `me`
    /// (not registered, or a disabled device).
    ///
    /// The goal line is left out on the pre-windows backend (its board is
    /// all-time even when filed under `.week`), for a handle-less device,
    /// and wherever `RaceGap.compute` hides (stranded handle, empty board…).
    static func compute(response: LeaderboardResponse,
                        window: LeaderboardWindow,
                        myHandle: String?,
                        handleConfirmed: Bool) -> StandingCard? {
        guard let me = response.me else { return nil }
        let entries = response.displayedEntries
        let myIndex = myHandle.flatMap { handle in
            entries.firstIndex { $0.isHandle(handle) }
        }

        let rank = myIndex.map { entries[$0].rank } ?? me.rank
        let points = myIndex.map { entries[$0].points } ?? me.points

        let goal: GoalLine?
        if myHandle == nil || response.window != window.rawValue {
            goal = nil
        } else if myIndex == 0 {
            // First on the board: a positive line about the row below.
            // Alone on the board → nothing to lead (the "1" says it).
            goal = entries.count > 1
                ? .leading(handle: entries[1].handle, points: max(0, points - entries[1].points))
                : nil
        } else {
            goal = RaceGap.compute(response: response, window: window,
                                   myHandle: myHandle, handleConfirmed: handleConfirmed)
                .map(GoalLine.gap)
        }
        return StandingCard(rank: rank, handle: myHandle, points: points, goal: goal)
    }

    /// The race gap, when the goal line is one (telemetry reports these).
    var raceGap: RaceGap? {
        if case .gap(let gap) = goal { return gap }
        return nil
    }

    /// "18" or "—" (unranked).
    var rankText: String { rank >= 1 ? "\(rank)" : "—" }

    /// The second line of the card, or nil.
    var goalText: String? {
        switch goal {
        case .gap(let gap)?:
            return gap.headline
        case .leading(let handle, let lead)?:
            return lead == 0
                ? "AHEAD OF @\(handle) ON THE TIEBREAK"
                : "LEADING @\(handle) BY \(RaceGap.pts(lead))"
        case nil:
            return nil
        }
    }

    /// VoiceOver for the whole card: "Your standing: rank 18, 100 points.
    /// 11 points to pass randy98, at number 17."
    var spoken: String {
        var text = "Your standing: "
            + (rank >= 1 ? "rank \(rank)" : "not ranked yet")
            + ", \(RaceGap.spokenPoints(points))."
        switch goal {
        case .gap(let gap)?:
            text += " \(gap.spoken.prefix(1).uppercased())\(gap.spoken.dropFirst())."
        case .leading(let handle, let lead)?:
            text += lead == 0
                ? " Ahead of \(handle) on the tiebreak."
                : " Leading \(handle) by \(RaceGap.spokenPoints(lead))."
        case nil:
            break
        }
        return text
    }
}

extension LeaderboardEntry {
    /// Case-insensitive handle match — the one "is this row me?" rule shared
    /// by the board's highlight and `RaceGap`.
    nonisolated func isHandle(_ handle: String) -> Bool {
        self.handle.lowercased() == handle.lowercased()
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
