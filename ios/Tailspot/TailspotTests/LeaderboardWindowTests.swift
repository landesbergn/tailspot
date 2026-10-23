//
//  LeaderboardWindowTests.swift
//  TailspotTests
//
//  Dynamic-leaderboards PR2: decoding of the windowed /v1/leaderboard
//  payload (new + OLD backend shapes — the fail-soft contract), the reset
//  countdown math (device-local timezone, month/year wrap), and the
//  champion-banner copy rules (1 / 2 / 3+ / anonymous / none).
//
//  Swift Testing (@Test / #expect / @Suite) — NOT XCTest. Pure fixtures,
//  no network (the TailspotAccountClientTests decode-fixture seam).
//

import Foundation
import Testing
@testable import Tailspot

/// Exact pre-monthly-winners response model. Keeping this fixture local makes
/// the compatibility test exercise what an already-shipped app decodes, rather
/// than the current model's new optional properties.
private struct LegacyLeaderboardResponse: Decodable {
    struct Entry: Decodable {
        let rank: Int
        let handle: String
        let points: Int
        let catches: Int
    }

    struct Standing: Decodable {
        let rank: Int
        let points: Int
        let weeklyWins: Int?
        let everToppedAllTime: Bool?
    }

    struct Champion: Decodable {
        let handle: String?
        let points: Int
        let weekStart: String
    }

    let entries: [Entry]
    let me: Standing?
    let window: String?
    let resetsAt: String?
    let champions: [Champion]?
}

// MARK: - Payload decoding

@Suite("Leaderboard windowed payload decoding")
struct LeaderboardWindowDecodingTests {

    /// A build shipped before monthly winners must ignore the two additive
    /// keys and continue rendering the month board with its legacy fields.
    @Test func newMonthlyPayloadDecodesWithLegacyAppModel() throws {
        let json = """
        {
          "entries": [{ "rank": 1, "handle": "maia", "points": 100, "catches": 8 }],
          "me": {
            "rank": 1, "points": 100, "weeklyWins": 2,
            "monthlyWins": 1, "everToppedAllTime": true
          },
          "window": "month",
          "resetsAt": "2026-10-01T00:00:00.000Z",
          "champions": null,
          "monthlyChampions": [
            { "handle": "maia", "points": 1850, "monthStart": "2026-08-01" }
          ]
        }
        """.data(using: .utf8)!

        let legacy = try JSONDecoder().decode(LegacyLeaderboardResponse.self, from: json)
        #expect(legacy.entries.count == 1)
        #expect(legacy.entries[0].handle == "maia")
        #expect(legacy.entries[0].catches == 8)
        #expect(legacy.me?.rank == 1)
        #expect(legacy.me?.weeklyWins == 2)
        #expect(legacy.me?.everToppedAllTime == true)
        #expect(legacy.window == "month")
        #expect(legacy.resetsAt == "2026-10-01T00:00:00.000Z")
        #expect(legacy.champions == nil)
    }

    /// The pinned backend-PR1 contract, verbatim shape.
    @Test func decodesWindowedWeekPayload() throws {
        let json = """
        {
          "entries": [{ "rank": 1, "handle": "skykid", "points": 840, "catches": 12 }],
          "me": { "rank": 2, "points": 315, "weeklyWins": 3, "monthlyWins": 2, "everToppedAllTime": true },
          "window": "week",
          "resetsAt": "2026-07-13T00:00:00.000Z",
          "champions": [{ "handle": "skykid", "points": 840, "weekStart": "2026-06-29" }]
        }
        """.data(using: .utf8)!

        let r = try JSONDecoder().decode(LeaderboardResponse.self, from: json)
        #expect(r.entries.count == 1)
        #expect(r.window == "week")
        #expect(r.supportsWindows)
        #expect(r.me?.rank == 2)
        #expect(r.me?.weeklyWins == 3)
        #expect(r.me?.monthlyWins == 2)
        #expect(r.me?.everToppedAllTime == true)
        #expect(r.champions?.count == 1)
        #expect(r.champions?.first?.handle == "skykid")
        #expect(r.champions?.first?.points == 840)
        #expect(r.champions?.first?.weekStart == "2026-06-29")
        // resetsAt parses to the exact UTC instant.
        let expected = ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z")
        #expect(r.resetsAtDate == expected)
    }

    /// FAIL-SOFT REGRESSION: the OLD backend's payload (no window/resetsAt/
    /// champions keys, me without weeklyWins) must keep decoding — the new
    /// keys come back nil, `supportsWindows` is false (tabs hide), and the
    /// board renders as the all-time board it always was.
    @Test func decodesOldBackendPayload_failSoft() throws {
        let json = """
        {
          "entries": [
            { "rank": 1, "handle": "vapor_trail", "points": 38420, "catches": 142 }
          ],
          "me": { "rank": 3, "points": 28910 }
        }
        """.data(using: .utf8)!

        let r = try JSONDecoder().decode(LeaderboardResponse.self, from: json)
        #expect(r.entries.count == 1)
        #expect(r.window == nil)
        #expect(!r.supportsWindows)
        #expect(r.resetsAt == nil)
        #expect(r.resetsAtDate == nil)
        #expect(r.champions == nil)
        #expect(r.me?.rank == 3)
        #expect(r.me?.weeklyWins == nil)
        #expect(r.me?.monthlyWins == nil)
        #expect(r.me?.everToppedAllTime == nil)
    }

    /// All-time window: resetsAt and champions are explicit JSON null.
    @Test func decodesAllTimeWindow_nullResetsAt() throws {
        let json = """
        {
          "entries": [],
          "me": null,
          "window": "all",
          "resetsAt": null,
          "champions": null
        }
        """.data(using: .utf8)!

        let r = try JSONDecoder().decode(LeaderboardResponse.self, from: json)
        #expect(r.supportsWindows)
        #expect(r.window == "all")
        #expect(r.resetsAtDate == nil)
        #expect(r.champions == nil)
        #expect(r.monthlyChampions == nil)
    }

    @Test func decodesMonthlyChampionPayload() throws {
        let json = """
        {
          "entries": [],
          "me": { "rank": 1, "points": 100, "weeklyWins": 0, "monthlyWins": 1, "everToppedAllTime": false },
          "window": "month",
          "resetsAt": "2026-08-01T00:00:00.000Z",
          "champions": null,
          "monthlyChampions": [{ "handle": "maia", "points": 1850, "monthStart": "2026-06-01" }]
        }
        """.data(using: .utf8)!

        let r = try JSONDecoder().decode(LeaderboardResponse.self, from: json)
        #expect(r.me?.monthlyWins == 1)
        #expect(r.champions == nil)
        #expect(r.monthlyChampions?.first?.handle == "maia")
        #expect(r.monthlyChampions?.first?.points == 1850)
        #expect(r.monthlyChampions?.first?.monthStart == "2026-06-01")
        #expect(r.monthlyChampions?.first?.weekStart == nil)
    }

    /// An anonymous champion (null handle) decodes; empty champions array
    /// stays a NON-nil empty array (the "nobody crowned" state, distinct
    /// from nil = no banner).
    @Test func decodesAnonymousAndEmptyChampions() throws {
        let anon = """
        {
          "entries": [], "me": null, "window": "week",
          "resetsAt": "2026-07-13T00:00:00.000Z",
          "champions": [{ "handle": null, "points": 120, "weekStart": "2026-06-29" }]
        }
        """.data(using: .utf8)!
        let r1 = try JSONDecoder().decode(LeaderboardResponse.self, from: anon)
        #expect(r1.champions?.count == 1)
        #expect(r1.champions?.first?.handle == nil)

        let empty = """
        {
          "entries": [], "me": null, "window": "week",
          "resetsAt": "2026-07-13T00:00:00.000Z",
          "champions": []
        }
        """.data(using: .utf8)!
        let r2 = try JSONDecoder().decode(LeaderboardResponse.self, from: empty)
        #expect(r2.champions != nil)
        #expect(r2.champions?.isEmpty == true)
    }

    /// resetsAt parses both with and without fractional seconds.
    @Test func resetsAtParsesBothISO8601Variants() {
        let expected = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")
        let fractional = LeaderboardResponse(
            entries: [], me: nil, window: "month",
            resetsAt: "2026-08-01T00:00:00.000Z")
        #expect(fractional.resetsAtDate == expected)

        let plain = LeaderboardResponse(
            entries: [], me: nil, window: "month",
            resetsAt: "2026-08-01T00:00:00Z")
        #expect(plain.resetsAtDate == expected)

        let garbage = LeaderboardResponse(
            entries: [], me: nil, window: "month", resetsAt: "not-a-date")
        #expect(garbage.resetsAtDate == nil)
    }

    /// The wire raw values for the window query param are pinned.
    @Test func windowRawValuesArePinned() {
        #expect(LeaderboardWindow.week.rawValue == "week")
        #expect(LeaderboardWindow.month.rawValue == "month")
        #expect(LeaderboardWindow.all.rawValue == "all")
        #expect(LeaderboardWindow.allCases == [.week, .month, .all])
    }
}

@Suite("Leaderboard catcher totals")
struct LeaderboardCatcherCountTests {
    @Test func decodesTotalAndRemainsCompatibleWithLegacyPayloads() throws {
        let json = """
        {"entries": [], "me": null, "window": "week", "totalCatchers": 86}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(LeaderboardResponse.self, from: json)
        #expect(response.totalCatchers == 86)
        #expect(response.additionalCatchers == 36)
        _ = try JSONDecoder().decode(LegacyLeaderboardResponse.self, from: json)

        let old = """
        {"entries": [], "me": null, "window": "week"}
        """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(LeaderboardResponse.self, from: old)
        #expect(legacy.totalCatchers == nil)
        #expect(legacy.additionalCatchers == 0)
    }

    @Test(arguments: [0, 49, 50, 51, 1284])
    func remainderOnlyAppearsAboveFifty(total: Int) {
        let response = LeaderboardResponse(entries: [], me: nil, totalCatchers: total)
        #expect(response.additionalCatchers == max(0, total - 50))
    }

    @Test func capsDisplayAtFiftyAndExcludesZeroPointEntries() {
        let entries = (1...60).map { rank in
            LeaderboardEntry(rank: rank, handle: "catcher_\(rank)",
                             points: rank == 1 ? 0 : 10, catches: 1)
        }
        let response = LeaderboardResponse(entries: entries, me: nil, totalCatchers: 59)
        #expect(response.displayedEntries.count == 50)
        #expect(response.displayedEntries.first?.handle == "catcher_2")
        #expect(response.displayedEntries.last?.handle == "catcher_51")
        #expect(response.displayedEntries.allSatisfy { $0.points > 0 })
    }
}

// MARK: - Countdown math

@Suite("Leaderboard reset countdown")
struct LeaderboardCountdownTests {

    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    /// 2026-07-13T00:00:00Z is a Monday (the pinned contract's example reset).
    private let mondayResetUTC = ISO8601DateFormatter().date(from: "2026-07-13T00:00:00Z")!

    /// Seconds are pre-typed Double so the interval arithmetic never sends
    /// the type checker exploring Int/Double overload combinations — CI's
    /// older toolchain timed out type-checking the inline expressions.
    private func secondsBeforeReset(days: Double = 0, hours: Double = 0, minutes: Double = 0, seconds: Double = 0) -> Date {
        let offset: TimeInterval = days * 86_400 + hours * 3_600 + minutes * 60 + seconds
        return mondayResetUTC.addingTimeInterval(-offset)
    }

    @Test func week_daysAndHours() {
        // 2 days, 14 hours, 30 minutes out → floors to 2d 14h.
        let now = secondsBeforeReset(days: 2, hours: 14, minutes: 30)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in 2d 14h")
        #expect(LeaderboardCountdown.weekSpoken(resetsAt: mondayResetUTC, now: now)
                == "resets in 2 days, 14 hours")
    }

    @Test func week_singularUnitsSpoken() {
        let now = secondsBeforeReset(days: 1, hours: 1, minutes: 5)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in 1d 1h")
        #expect(LeaderboardCountdown.weekSpoken(resetsAt: mondayResetUTC, now: now)
                == "resets in 1 day, 1 hour")
    }

    /// Whole days: no "0h" tail.
    @Test func week_wholeDays_noZeroHours() {
        let now = secondsBeforeReset(days: 2, hours: 0, minutes: 20)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in 2d")
        #expect(LeaderboardCountdown.weekSpoken(resetsAt: mondayResetUTC, now: now) == "resets in 2 days")
    }

    @Test func week_underOneDay() {
        let now = secondsBeforeReset(hours: 14, minutes: 1)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in 14h")
        #expect(LeaderboardCountdown.weekSpoken(resetsAt: mondayResetUTC, now: now) == "resets in 14 hours")
    }

    @Test func week_underOneHour() {
        let now = secondsBeforeReset(minutes: 30)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in under 1h")
        #expect(LeaderboardCountdown.weekSpoken(resetsAt: mondayResetUTC, now: now)
                == "resets in under an hour")
    }

    /// A reset instant already passed (stale cached response) must not go
    /// negative — clamps to the under-an-hour line.
    @Test func week_pastResetClamps() {
        let now = secondsBeforeReset(hours: -1)
        #expect(LeaderboardCountdown.weekProse(resetsAt: mondayResetUTC, now: now) == "resets in under 1h")
    }

    @Test func month_simple() {
        let aug1 = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        #expect(LeaderboardCountdown.monthProse(resetsAt: aug1, locale: enUS, timeZone: utc)
                == "resets Aug 1")
    }

    /// Month boundary in the device's timezone: an Aug-1-UTC reset is still
    /// July 31 in Los Angeles — the line says the honest local date.
    @Test func month_monthWrapAcrossTimezone() {
        let aug1 = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        #expect(LeaderboardCountdown.monthProse(resetsAt: aug1, locale: enUS, timeZone: losAngeles)
                == "resets Jul 31")
    }

    /// Year wrap: a December board resets Jan 1 of NEXT year.
    @Test func month_yearWrap() {
        let jan1 = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        #expect(LeaderboardCountdown.monthProse(resetsAt: jan1, locale: enUS, timeZone: utc)
                == "resets Jan 1")
    }
}

// MARK: - Champion banner copy

@Suite("Champion banner copy")
struct ChampionBannerCopyTests {

    private func champ(_ handle: String?, points: Int = 840) -> LeaderboardChampion {
        LeaderboardChampion(handle: handle, points: points, weekStart: "2026-06-29")
    }

    @Test func eyebrowSingularPlural() {
        #expect(ChampionBanner.eyebrow(count: 1) == "LAST WEEK'S CHAMPION")
        #expect(ChampionBanner.eyebrow(count: 2) == "LAST WEEK'S CHAMPIONS")
        #expect(ChampionBanner.eyebrow(count: 5) == "LAST WEEK'S CHAMPIONS")
        #expect(ChampionBanner.eyebrow(count: 1, window: .month) == "LAST MONTH'S CHAMPION")
        #expect(ChampionBanner.eyebrow(count: 2, window: .month) == "LAST MONTH'S CHAMPIONS")
    }

    @Test func singleChampion() {
        #expect(ChampionBanner.names([champ("skykid")]) == "@skykid")
    }

    @Test func twoChampions_sideBySide() {
        #expect(ChampionBanner.names([champ("skykid"), champ("contrail")])
                == "@skykid & @contrail")
    }

    @Test func threeChampions_plusMore() {
        #expect(ChampionBanner.names([champ("a"), champ("b"), champ("c")])
                == "@a, @b +1 more")
    }

    @Test func fiveChampions_plusMore() {
        #expect(ChampionBanner.names([champ("a"), champ("b"), champ("c"), champ("d"), champ("e")])
                == "@a, @b +3 more")
    }

    /// A null handle renders as "anonymous spotter" — never a bare "@".
    @Test func anonymousChampion() {
        #expect(ChampionBanner.names([champ(nil)]) == "anonymous spotter")
        #expect(ChampionBanner.names([champ(nil), champ("skykid")])
                == "anonymous spotter & @skykid")
    }

    @Test func emptyChampions() {
        #expect(ChampionBanner.names([]) == "")
        #expect(ChampionBanner.noChampionSubtitle(window: .week) == "The sky was quiet last week.")
        #expect(ChampionBanner.noChampionSubtitle(window: .month) == "The sky was quiet last month.")
    }
}

// MARK: - Race gap

@Suite("Race gap")
struct RaceGapTests {

    /// The live 2026-10-21 week board shape: two whales, then a tight pack.
    private static let livePoints = [3705, 1360, 985, 460, 405, 230, 220, 215, 165, 145, 95, 45]

    private func board(_ points: [Int] = livePoints) -> [LeaderboardEntry] {
        points.enumerated().map { i, p in
            LeaderboardEntry(rank: i + 1, handle: "s\(i + 1)", points: p, catches: 1)
        }
    }

    private func week(_ entries: [LeaderboardEntry], me: MyStanding?) -> LeaderboardResponse {
        LeaderboardResponse(entries: entries, me: me, window: "week",
                            resetsAt: "2026-10-26T00:00:00.000Z", champions: nil)
    }

    @Test func commonCatchYardstickIsPinnedToScoring() {
        #expect(RaceGap.commonCatchPoints == Rarity.common.basePoints)
        #expect(RaceGap.commonCatchPoints == 10)
    }

    /// Mid-pack: pass the row directly above.
    @Test func midPack_passesRowAbove() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 12, points: 45)),
            window: .week, myHandle: "s12", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s11", rank: 11))
        #expect(gap.points == 51)            // 95 − 45 + 1
        #expect(gap.catchesEquivalent == 6)  // ⌈51 / 10⌉ (telemetry)
        #expect(gap.prose == "50 points behind @s11")
    }

    /// The trap the scope warns about: `me.rank` counts handle-less and
    /// disabled devices, so it runs ahead of my row position. Indexing by
    /// rank (`entries[rank − 2]`) would name the wrong spotter.
    @Test func hiddenDevicesInflatingMyRank_doNotChangeTheTarget() throws {
        // Row 11 on the board, but three hidden devices rank above me.
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 14, points: 95)),
            window: .week, myHandle: "s11", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s10", rank: 10))
        #expect(gap.points == 51)
        // The place printed is the target ROW's rank, never me.rank − 1.
        #expect(gap.target == .pass(handle: "s10", rank: 10))
        #expect(gap.prose == "50 points behind @s10")
    }

    /// Ties break by registration time, so a tied spotter above me needs
    /// exactly one more point, not zero.
    @Test func tieWithRowAbove_needsOnePoint() throws {
        let entries = board([300, 200, 200, 100])
        let gap = try #require(RaceGap.compute(
            response: week(entries, me: MyStanding(rank: 3, points: 200)),
            window: .week, myHandle: "s3", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s2", rank: 2))
        #expect(gap.points == 1)
        #expect(gap.catchesEquivalent == 1)
        #expect(gap.prose == "1 point to pass @s2")
    }

    @Test func handleMatchIsCaseInsensitive() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 11, points: 95)),
            window: .week, myHandle: "S11", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s10", rank: 10))
    }

    @Test func iAmFirst_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 1, points: 3705)),
            window: .week, myHandle: "s1", handleConfirmed: true) == nil)
    }

    @Test func insideTopTen_passesRowAbove() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 8, points: 215)),
            window: .week, myHandle: "s8", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s7", rank: 7))
        #expect(gap.points == 6)
    }

    /// #2 trails the whale by 2,345 pts. Big gaps are no longer hidden:
    /// Noah wants to see who is ahead and by how much (2026-10-22).
    @Test func hugeGap_shown() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 2, points: 1360)),
            window: .week, myHandle: "s2", handleConfirmed: true))
        #expect(gap.target == .pass(handle: "s1", rank: 1))
        #expect(gap.points == 2346)
        #expect(gap.prose == "2,345 points behind @s1")
    }

    /// No handle and nothing caught this week: one point earns a row.
    @Test func handled_zeroPoints_makeTheBoard() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "notlisted", handleConfirmed: true))
        #expect(gap.target == .makeBoard(full: false))
        #expect(gap.points == 1)
        #expect(gap.prose == "1 point to get on the board")
    }

    /// No handle, nothing caught: hidden. The backend lists only handled
    /// devices, so "1 PT TO MAKE THE BOARD" would be a false promise — one
    /// catch later the line would vanish and still no row would appear.
    /// The "claim a handle" hint is the only call to action.
    @Test func noHandle_zeroPoints_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: nil, handleConfirmed: true) == nil)
    }

    /// No handle, off a FULL board (50 rows) with points below the last
    /// row: still hidden — earning the gap wouldn't earn a row either.
    @Test func noHandle_offFullBoard_hidden() {
        let full = board((0..<LeaderboardResponse.displayLimit).map { 600 - $0 * 10 })  // last = 110
        #expect(RaceGap.compute(
            response: week(full, me: MyStanding(rank: 60, points: 40)),
            window: .week, myHandle: nil, handleConfirmed: true) == nil)
    }

    /// No handle but already holding points: the gap is zero, so the line
    /// hides and the existing "claim a handle" hint carries the message.
    @Test func noHandle_withPoints_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 9, points: 160)),
            window: .week, myHandle: nil, handleConfirmed: true) == nil)
    }

    /// A handled spotter off a FULL board (50 rows) must beat the last row.
    @Test func offFullBoard_beatTheLastRow() throws {
        let full = board((0..<LeaderboardResponse.displayLimit).map { 600 - $0 * 10 })  // last = 110
        let gap = try #require(RaceGap.compute(
            response: week(full, me: MyStanding(rank: 60, points: 95)),
            window: .week, myHandle: "notlisted", handleConfirmed: true))
        #expect(gap.target == .makeBoard(full: true))
        #expect(gap.points == 16)
        #expect(gap.prose == "16 points to make the top 50")
    }

    @Test func emptyBoard_hidden() {
        #expect(RaceGap.compute(
            response: week([], me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "noah", handleConfirmed: true) == nil)
    }

    @Test func notRegistered_hidden() {
        #expect(RaceGap.compute(response: week(board(), me: nil),
                                window: .week, myHandle: "s11", handleConfirmed: true) == nil)
    }

    /// Month and all-time boards each get their own gap, from their own
    /// response — all-time gaps are large and that's fine.
    @Test func monthAndAllTime_shown() throws {
        let me = MyStanding(rank: 11, points: 95)
        let month = LeaderboardResponse(entries: board(), me: me, window: "month",
                                        resetsAt: "2026-11-01T00:00:00.000Z")
        let monthGap = try #require(RaceGap.compute(
            response: month, window: .month, myHandle: "s11", handleConfirmed: true))
        #expect(monthGap.target == .pass(handle: "s10", rank: 10))
        #expect(monthGap.points == 51)

        let allPoints = [48_210, 31_900, 12_400, 9_050]
        let all = LeaderboardResponse(entries: board(allPoints), me: MyStanding(rank: 2, points: 31_900),
                                      window: "all")
        let allGap = try #require(RaceGap.compute(
            response: all, window: .all, myHandle: "s2", handleConfirmed: true))
        #expect(allGap.points == 16_311)  // 48,210 − 31,900 + 1
        #expect(allGap.prose == "16,310 points behind @s1")
    }

    /// Each window reads only its own response: a week payload filed under
    /// the month tab (or vice versa) is not that window's board.
    @Test func responseFromAnotherWindow_hidden() {
        let me = MyStanding(rank: 11, points: 95)
        #expect(RaceGap.compute(response: week(board(), me: me), window: .month,
                                myHandle: "s11", handleConfirmed: true) == nil)
        let month = LeaderboardResponse(entries: board(), me: me, window: "month")
        #expect(RaceGap.compute(response: month, window: .all,
                                myHandle: "s11", handleConfirmed: true) == nil)
    }

    // MARK: Review fixes (2026-10-22)

    /// `me` comes from a separate server query; a catch uploading between
    /// the two can leave `me.points` ahead of my row. The gap must agree
    /// with the numbers printed on the board, so it uses my ROW's points.
    @Test func onBoard_usesMyRowPoints_notStaleMe() throws {
        // Row s12 shows 45; `me` already counts a fresh 30-pt catch.
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 12, points: 75)),
            window: .week, myHandle: "s12", handleConfirmed: true))
        #expect(gap.points == 51)         // 95 − 45 + 1, from the visible row
    }

    /// The server says more spotters qualify than the 50-row limit, even
    /// though this response is short: the board is full, so a 0-pt spotter
    /// must beat the last row, not "1 PT TO MAKE THE BOARD".
    @Test func shortResponse_serverCountSaysFull_noOnePointPromise() {
        let response = LeaderboardResponse(
            entries: board(), me: MyStanding(rank: 0, points: 0), window: "week",
            resetsAt: "2026-10-26T00:00:00.000Z", champions: nil, totalCatchers: 64)
        // Never "1 point to get on the board"; with only 12 of the 50 rows
        // there's no measurable gap either, so the goal hides.
        #expect(RaceGap.compute(response: response, window: .week,
                                myHandle: "notlisted", handleConfirmed: true) == nil)
    }

    /// Exactly 50 qualifying spotters: `additionalCatchers` is 0 but the
    /// board is still full.
    @Test func exactlyFullBoard_beatTheLastRow() throws {
        let full = board((0..<LeaderboardResponse.displayLimit).map { 600 - $0 * 10 })  // last = 110
        let response = LeaderboardResponse(
            entries: full, me: MyStanding(rank: 0, points: 0), window: "week",
            resetsAt: "2026-10-26T00:00:00.000Z", champions: nil,
            totalCatchers: LeaderboardResponse.displayLimit)
        #expect(response.additionalCatchers == 0)
        let gap = try #require(RaceGap.compute(
            response: response, window: .week, myHandle: "notlisted", handleConfirmed: true))
        #expect(gap.points == 111)
    }

    /// Room on the board per the server count: one point earns a row.
    @Test func serverCountSaysRoom_onePoint() throws {
        let response = LeaderboardResponse(
            entries: board(), me: MyStanding(rank: 0, points: 0), window: "week",
            resetsAt: "2026-10-26T00:00:00.000Z", champions: nil, totalCatchers: 12)
        let gap = try #require(RaceGap.compute(
            response: response, window: .week, myHandle: "notlisted", handleConfirmed: true))
        #expect(gap.points == 1)
    }

    /// Stranded handle (local handle the server never confirmed — the
    /// silent-409 case): no make-the-board promise.
    @Test func strandedHandle_makeBoardHidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "notlisted", handleConfirmed: false) == nil)
    }

    /// A stranded handle can match SOMEONE ELSE's row: the 409 means
    /// another device holds it. An unconfirmed handle never claims a row,
    /// so no goal is computed from their place.
    @Test func unconfirmedHandle_matchingARow_isNotMe() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "s12", handleConfirmed: false) == nil)
    }

    /// Full only by the server count, but fewer rows came back: the last
    /// row isn't #50, so there's no honest number to show.
    @Test func shortResponse_fullByCount_partialRows_hidden() {
        let response = LeaderboardResponse(
            entries: board(), me: MyStanding(rank: 0, points: 0), window: "week",
            resetsAt: "2026-10-26T00:00:00.000Z", champions: nil, totalCatchers: 64)
        #expect(RaceGap.compute(response: response, window: .week,
                                myHandle: "notlisted", handleConfirmed: true) == nil)
    }

    @Test func isMe_needsAConfirmedHandle() {
        let row = LeaderboardEntry(rank: 3, handle: "Blue_Hour", points: 10, catches: 1)
        #expect(LeaderboardEntry.isMe(row, myHandle: "blue_hour", handleConfirmed: true))
        #expect(!LeaderboardEntry.isMe(row, myHandle: "blue_hour", handleConfirmed: false))
        #expect(!LeaderboardEntry.isMe(row, myHandle: nil, handleConfirmed: true))
    }

    /// A strand the marker missed: points but no row on a board with room
    /// can't be listed — the gap is ≤ 0 and the line hides.
    @Test func handledWithPoints_notListed_roomOnBoard_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 9, points: 160)),
            window: .week, myHandle: "notlisted", handleConfirmed: true) == nil)
    }

    @Test func isConfirmed_matchesMarkerExactly() {
        #expect(SpotterHandle.isConfirmed("noah", confirmed: "noah"))
        #expect(!SpotterHandle.isConfirmed("noah", confirmed: nil))
        #expect(!SpotterHandle.isConfirmed("noah", confirmed: "babyjoda"))
        #expect(!SpotterHandle.isConfirmed(nil, confirmed: "noah"))
    }

    @Test func publicHandle_dropsPlaceholderAndEmpty() {
        #expect(SpotterHandle.publicHandle("noah") == "noah")
        #expect(SpotterHandle.publicHandle(SpotterHandle.defaultPlaceholder) == nil)
        #expect(SpotterHandle.publicHandle("") == nil)
        #expect(SpotterHandle.publicHandle(nil) == nil)
    }

    @Test func entryHandleMatch_isCaseInsensitive() {
        let entry = LeaderboardEntry(rank: 1, handle: "PlaneSpotter", points: 10, catches: 1)
        #expect(entry.isHandle("planespotter"))
        #expect(!entry.isHandle("planespotte"))
    }

    /// One point behind (two to pass) still reads "behind", singular.
    @Test func prose_onePointBehind_singular() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board([300, 201, 200]), me: MyStanding(rank: 3, points: 200)),
            window: .week, myHandle: "s3", handleConfirmed: true))
        #expect(gap.points == 2)
        #expect(gap.prose == "1 point behind @s2")
    }

    /// Telemetry dedup: one key per goal per window, handle case folded.
    @Test func reportKey_andAnalyticsTarget() throws {
        let pass = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 11, points: 95)),
            window: .week, myHandle: "s11", handleConfirmed: true))
        #expect(pass.reportKey(window: .week) == "week:pass:s10")
        #expect(pass.reportKey(window: .all) == "all:pass:s10")
        #expect(pass.analyticsTarget == "pass")
        let make = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "notlisted", handleConfirmed: true))
        #expect(make.reportKey(window: .month) == "month:make_board")
        #expect(make.analyticsTarget == "make_board")
    }

    /// FAIL-SOFT: the pre-windows backend sends no `window` key and its
    /// board is ALL-TIME, even though the screen files it under `.week`.
    @Test func oldBackendWithoutWindowKey_hidden() {
        let old = LeaderboardResponse(entries: board(), me: MyStanding(rank: 11, points: 95))
        #expect(RaceGap.compute(response: old, window: .week, myHandle: "s11", handleConfirmed: true) == nil)
    }
}

// MARK: - Your standing card

@Suite("Standing line")
struct StandingLineTests {

    private static let livePoints = [3705, 1360, 985, 460, 405, 230, 220, 215, 165, 145, 95, 45]

    private func board(_ points: [Int] = livePoints) -> [LeaderboardEntry] {
        points.enumerated().map { i, p in
            LeaderboardEntry(rank: i + 1, handle: "s\(i + 1)", points: p, catches: 1)
        }
    }

    private func response(_ entries: [LeaderboardEntry], me: MyStanding?,
                          window: LeaderboardWindow = .week,
                          totalCatchers: Int? = nil) -> LeaderboardResponse {
        LeaderboardResponse(entries: entries, me: me, window: window.rawValue,
                            resetsAt: window == .all ? nil : "2026-10-26T00:00:00.000Z",
                            champions: nil, totalCatchers: totalCatchers)
    }

    private func line(_ entries: [LeaderboardEntry], me: MyStanding?,
                      handle: String?, window: LeaderboardWindow = .week,
                      confirmed: Bool = true, totalCatchers: Int? = nil) throws -> StandingLine {
        try #require(StandingLine.compute(
            response: response(entries, me: me, window: window, totalCatchers: totalCatchers),
            window: window, myHandle: handle, handleConfirmed: confirmed))
    }

    /// Mid-pack: the ordinal is my row's rank; the gap is the honest
    /// distance to the row above.
    @Test func midPack_weekCopy() throws {
        let l = try line(board(), me: MyStanding(rank: 11, points: 95), handle: "s11")
        #expect(l.rank == 11)
        #expect(l.ordinal == "11th")
        #expect(l.heading == "You're 11th this week")
        #expect(l.headingSuffix == " this week")
        #expect(l.detail == "50 points behind @s10")
        #expect(l.raceGap?.target == .pass(handle: "s10", rank: 10))
        #expect(sub(l.detail, reset: "resets in 2d 9h")
                == "50 points behind @s10 · resets in 2d 9h")
        #expect(StandingLine.spoken(l, spokenReset: "resets in 2 days, 9 hours")
                == "You're 11th this week. 50 points behind s10. Resets in 2 days, 9 hours.")
    }

    @Test func windowWording() throws {
        let month = try line(board(), me: MyStanding(rank: 11, points: 95), handle: "s11", window: .month)
        #expect(month.heading == "You're 11th this month")
        let all = try line(board(), me: MyStanding(rank: 11, points: 95), handle: "s11", window: .all)
        #expect(all.heading == "You're 11th all time")
        // All time has no reset: the subtitle is just the gap.
        #expect(sub(all.detail, reset: nil) == "50 points behind @s10")
    }

    /// `me.rank` counts hidden devices and runs ahead of my row (14 vs
    /// row 11). The heading prints the ROW's rank so it matches the list.
    @Test func meRankInflated_headingShowsRowRank() throws {
        let l = try line(board(), me: MyStanding(rank: 14, points: 95), handle: "s11")
        #expect(l.heading == "You're 11th this week")
    }

    /// The server's printed row ranks win over list positions.
    @Test func usesPrintedRowRanks_notIndexes() throws {
        let entries = [
            LeaderboardEntry(rank: 16, handle: "a", points: 300, catches: 1),
            LeaderboardEntry(rank: 17, handle: "randy98", points: 110, catches: 1),
            LeaderboardEntry(rank: 18, handle: "noah", points: 100, catches: 1),
        ]
        let l = try line(entries, me: MyStanding(rank: 21, points: 100), handle: "noah")
        #expect(l.heading == "You're 18th this week")
        #expect(l.detail == "10 points behind @randy98")
    }

    /// The row's points win over a stale `me.points`.
    @Test func onBoard_usesRowPoints() throws {
        let l = try line(board(), me: MyStanding(rank: 12, points: 75), handle: "s12")
        #expect(l.detail == "50 points behind @s11")
    }

    /// Level with the row above: a pass takes one point (registration
    /// tiebreak), and the copy says so rather than "0 points behind".
    @Test func tieWithRowAbove_onePointToPass() throws {
        let l = try line(board([300, 200, 200, 100]), me: MyStanding(rank: 3, points: 200), handle: "s3")
        #expect(l.heading == "You're 3rd this week")
        #expect(l.detail == "1 point to pass @s2")
    }

    /// #1: a positive line about the row below.
    @Test func first_leadsRowBelow() throws {
        let l = try line(board(), me: MyStanding(rank: 1, points: 3705), handle: "s1")
        #expect(l.heading == "You're 1st this week")
        #expect(l.goal == .leading(handle: "s2", points: 2345))
        #expect(l.detail == "2,345 points ahead of @s2")
        #expect(l.raceGap == nil)   // a lead isn't reported as a gap
        #expect(StandingLine.spoken(l, spokenReset: nil)
                == "You're 1st this week. 2,345 points ahead of s2.")
    }

    @Test func first_leadOfOne_singular() throws {
        let l = try line(board([201, 200]), me: MyStanding(rank: 1, points: 201), handle: "s1")
        #expect(l.detail == "1 point ahead of @s2")
    }

    /// #1 on the tiebreak: level on points, ahead by registration time.
    @Test func first_tiedOnPoints_tiebreakLine() throws {
        let l = try line(board([200, 200, 100]), me: MyStanding(rank: 1, points: 200), handle: "s1")
        #expect(l.detail == "Tied with @s2, ahead on the tiebreak")
    }

    /// Alone on the board: heading only; the subtitle is the reset alone.
    @Test func first_aloneOnBoard_noGoal() throws {
        let l = try line(board([50]), me: MyStanding(rank: 1, points: 50), handle: "s1")
        #expect(l.heading == "You're 1st this week")
        #expect(l.detail == nil)
        #expect(sub(l.detail, reset: "resets in 9h") == "Resets in 9h")
    }

    /// Off a full board: never a place number (`me.rank` is never printed).
    @Test func offFullBoard_makeTheTop50() throws {
        let full = board((0..<LeaderboardResponse.displayLimit).map { 600 - $0 * 10 })  // last = 110
        let l = try line(full, me: MyStanding(rank: 63, points: 95), handle: "notlisted")
        #expect(!l.isOnBoard)
        #expect(l.ordinal == nil)
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == "16 points to make the top 50")
        #expect(!l.heading.contains("63"))
    }

    /// Nothing caught this week, room on the board.
    @Test func offBoard_roomLeft_onePoint() throws {
        let l = try line(board(), me: MyStanding(rank: 0, points: 0), handle: "notlisted")
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == "1 point to get on the board")
        #expect(StandingLine.spoken(l, spokenReset: "resets in 2 days, 9 hours")
                == "You're not on the board yet. 1 point to get on the board. Resets in 2 days, 9 hours.")
    }

    /// Handle-less: off the board, with the claim-a-handle hint as the
    /// detail; VoiceOver doesn't read the arrow.
    @Test func handleless_claimHint() throws {
        let l = try line(board(), me: MyStanding(rank: 9, points: 160), handle: nil, confirmed: false)
        #expect(l.handle == nil)
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == "Claim a handle in Profile → Settings to join")
        #expect(l.goal == nil)
        #expect(StandingLine.spoken(l, spokenReset: nil)
                == "You're not on the board yet. Claim a handle in Profile, Settings to join.")
    }

    /// Stranded handle (server never confirmed it): heading, no promise.
    @Test func stranded_noGoal() throws {
        let l = try line(board(), me: MyStanding(rank: 0, points: 0), handle: "notlisted", confirmed: false)
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == nil)
    }

    /// Stranded on someone else's row: never their rank in my heading.
    @Test func stranded_onAnotherSpottersRow_notMyRank() throws {
        let l = try line(board(), me: MyStanding(rank: 0, points: 0), handle: "s5", confirmed: false)
        #expect(!l.isOnBoard)
        #expect(l.heading == "You're not on the board yet")
        #expect(l.goal == nil)
    }

    /// Unregistered AND handle-less: the claim hint still shows (it was the
    /// old screen's only call to action for a new user).
    @Test func notRegistered_handleless_claimHint() throws {
        let l = try #require(StandingLine.compute(response: response(board(), me: nil), window: .week,
                                                  myHandle: nil, handleConfirmed: false))
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == StandingLine.claimHint)
    }

    /// Not registered: no line, but the reset still shows on its own.
    @Test func notRegistered_resetAlone() {
        #expect(StandingLine.compute(response: response(board(), me: nil), window: .week,
                                     myHandle: "s11", handleConfirmed: true) == nil)
        #expect(sub(nil, reset: "resets in 2d 9h") == "Resets in 2d 9h")
        #expect(StandingLine.spoken(nil, spokenReset: "resets in 2 days, 9 hours")
                == "Resets in 2 days, 9 hours.")
        #expect(sub(nil, reset: nil) == nil)
    }

    /// Old backend (no `window` key): the rank shows from the row with no
    /// window phrase (its board isn't any one window's) and no goal.
    @Test func oldBackend_noWindowPhraseNoGoal() throws {
        let old = LeaderboardResponse(entries: board(), me: MyStanding(rank: 14, points: 95))
        let l = try #require(StandingLine.compute(response: old, window: .week,
                                                  myHandle: "s11", handleConfirmed: true))
        #expect(l.heading == "You're 11th")
        #expect(l.goal == nil)
    }

    @Test func emptyBoard_noGoal() throws {
        let l = try line([], me: MyStanding(rank: 0, points: 0), handle: "noah")
        #expect(l.heading == "You're not on the board yet")
        #expect(l.detail == nil)
    }

    /// `StandingLine.subtitle` with its no-break spaces shown as plain
    /// spaces, so the copy assertions read naturally.
    private func sub(_ detail: String?, reset: String?) -> String? {
        StandingLine.subtitle(detail: detail, reset: reset)?
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The reset phrase never splits across lines, and the "·" stays
    /// with the text before it.
    @Test func subtitle_keepsResetPhraseTogether() throws {
        let raw = try #require(StandingLine.subtitle(detail: "50 points behind @s10",
                                                     reset: "resets in 2d 9h"))
        // Plain spaces inside the detail (it may wrap); no-break spaces in
        // the reset and before the "·"; a plain space after it.
        #expect(raw == "50 points behind @s10\u{00A0}· resets\u{00A0}in\u{00A0}2d\u{00A0}9h")
    }

    @Test(arguments: [
        (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"), (10, "10th"),
        (11, "11th"), (12, "12th"), (13, "13th"), (21, "21st"), (22, "22nd"),
        (23, "23rd"), (101, "101st"), (111, "111th"), (112, "112th"), (1001, "1,001st"),
    ])
    func ordinals(_ n: Int, _ expected: String) {
        #expect(Ordinal.english(n) == expected)
    }
}
