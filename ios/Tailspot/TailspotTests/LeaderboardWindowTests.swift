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

    @Test func weekLabel_daysAndHours() {
        // 2 days, 14 hours, 30 minutes out → floors to 2D 14H.
        let now = secondsBeforeReset(days: 2, hours: 14, minutes: 30)
        let label = LeaderboardCountdown.weekLabel(
            resetsAt: mondayResetUTC, now: now, locale: enUS, timeZone: utc)
        #expect(label == "RESETS MONDAY · 2D 14H LEFT")
    }

    /// The weekday is the LOCAL weekday of the reset instant — Monday
    /// 00:00 UTC is still Sunday evening in California. Never "UTC".
    @Test func weekLabel_usesDeviceTimezoneForWeekday() {
        let now = secondsBeforeReset(days: 2, hours: 14)
        let label = LeaderboardCountdown.weekLabel(
            resetsAt: mondayResetUTC, now: now, locale: enUS, timeZone: losAngeles)
        #expect(label == "RESETS SUNDAY · 2D 14H LEFT")
        #expect(!label.contains("UTC"))
    }

    @Test func weekLabel_underOneDay() {
        let now = secondsBeforeReset(hours: 14, minutes: 1)
        let label = LeaderboardCountdown.weekLabel(
            resetsAt: mondayResetUTC, now: now, locale: enUS, timeZone: utc)
        #expect(label == "RESETS MONDAY · 14H LEFT")
    }

    @Test func weekLabel_underOneHour() {
        let now = secondsBeforeReset(minutes: 30)
        let label = LeaderboardCountdown.weekLabel(
            resetsAt: mondayResetUTC, now: now, locale: enUS, timeZone: utc)
        #expect(label == "RESETS MONDAY · UNDER 1H LEFT")
    }

    /// A reset instant already passed (stale cached response) must not go
    /// negative — clamps to the under-an-hour line.
    @Test func weekLabel_pastResetClamps() {
        let now = secondsBeforeReset(hours: -1)
        let label = LeaderboardCountdown.weekLabel(
            resetsAt: mondayResetUTC, now: now, locale: enUS, timeZone: utc)
        #expect(label == "RESETS MONDAY · UNDER 1H LEFT")
    }

    @Test func monthLabel_simple() {
        let aug1 = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        let label = LeaderboardCountdown.monthLabel(
            resetsAt: aug1, locale: enUS, timeZone: utc)
        #expect(label == "RESETS AUG 1")
    }

    /// Month boundary in the device's timezone: an Aug-1-UTC reset is still
    /// July 31 in Los Angeles — the label says the honest local date.
    @Test func monthLabel_monthWrapAcrossTimezone() {
        let aug1 = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        let label = LeaderboardCountdown.monthLabel(
            resetsAt: aug1, locale: enUS, timeZone: losAngeles)
        #expect(label == "RESETS JUL 31")
    }

    /// Year wrap: a December board resets Jan 1 of NEXT year.
    @Test func monthLabel_yearWrap() {
        let jan1 = ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
        let label = LeaderboardCountdown.monthLabel(
            resetsAt: jan1, locale: enUS, timeZone: utc)
        #expect(label == "RESETS JAN 1")
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

// MARK: - Weekly race gap

@Suite("Weekly race gap")
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

    /// Outside the visible Top 10: pass the row directly above, plus the
    /// separate Top 10 clause.
    @Test func midPack_passesRowAbove_andReportsTopTen() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 12, points: 45)),
            window: .week, myHandle: "s12"))
        #expect(gap.target == .pass(handle: "s11"))
        #expect(gap.points == 51)            // 95 − 45 + 1
        #expect(gap.catchesEquivalent == 6)  // ⌈51 / 10⌉
        #expect(gap.topTenPoints == 101)     // 145 − 45 + 1
        #expect(gap.headline == "51 PTS TO PASS @s11")
        #expect(gap.topTenLine == "101 PTS TO THE TOP 10")
        #expect(gap.detail(resetWeekday: "SUNDAY") == "≈ 6 COMMON CATCHES · RESETS SUNDAY")
        #expect(gap.detail(resetWeekday: nil) == "≈ 6 COMMON CATCHES")
    }

    /// Directly below the tenth: the Top 10 IS the pass target, so the
    /// clause is not repeated.
    @Test func eleventh_topTenClauseNotRepeated() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 11, points: 95)),
            window: .week, myHandle: "s11"))
        #expect(gap.target == .pass(handle: "s10"))
        #expect(gap.points == 51)
        #expect(gap.topTenPoints == nil)
        #expect(gap.topTenLine == nil)
    }

    /// The trap the scope warns about: `me.rank` counts handle-less and
    /// disabled devices, so it runs ahead of my row position. Indexing by
    /// rank (`entries[rank − 2]`) would name the wrong spotter.
    @Test func hiddenDevicesInflatingMyRank_doNotChangeTheTarget() throws {
        // Row 11 on the board, but three hidden devices rank above me.
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 14, points: 95)),
            window: .week, myHandle: "s11"))
        #expect(gap.target == .pass(handle: "s10"))
        #expect(gap.points == 51)
        #expect(!gap.headline.contains("#"))
        #expect(!gap.headline.contains("14"))
    }

    /// Ties break by registration time, so a tied spotter above me needs
    /// exactly one more point, not zero.
    @Test func tieWithRowAbove_needsOnePoint() throws {
        let entries = board([300, 200, 200, 100])
        let gap = try #require(RaceGap.compute(
            response: week(entries, me: MyStanding(rank: 3, points: 200)),
            window: .week, myHandle: "s3"))
        #expect(gap.target == .pass(handle: "s2"))
        #expect(gap.points == 1)
        #expect(gap.catchesEquivalent == 1)
        #expect(gap.headline == "1 PT TO PASS @s2")
        #expect(gap.detail(resetWeekday: nil) == "≈ 1 COMMON CATCH")
    }

    @Test func handleMatchIsCaseInsensitive() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 11, points: 95)),
            window: .week, myHandle: "S11"))
        #expect(gap.target == .pass(handle: "s10"))
    }

    @Test func iAmFirst_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 1, points: 3705)),
            window: .week, myHandle: "s1") == nil)
    }

    /// Inside the Top 10: pass the row above, no Top 10 clause.
    @Test func insideTopTen_noTopTenClause() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 8, points: 215)),
            window: .week, myHandle: "s8"))
        #expect(gap.target == .pass(handle: "s7"))
        #expect(gap.points == 6)
        #expect(gap.topTenPoints == nil)
    }

    /// #2 trails the whale by 2,345 pts: far past 20 common catches, so the
    /// line hides instead of showing a hopeless goal.
    @Test func hugeGap_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 2, points: 1360)),
            window: .week, myHandle: "s2") == nil)
    }

    @Test func gapCeilingBoundary() throws {
        // 200 pts = exactly 20 common catches → shown; 201 → hidden.
        let shown = try #require(RaceGap.compute(
            response: week(board([300, 101]), me: MyStanding(rank: 2, points: 101)),
            window: .week, myHandle: "s2"))
        #expect(shown.points == 200)
        #expect(RaceGap.compute(
            response: week(board([300, 100]), me: MyStanding(rank: 2, points: 100)),
            window: .week, myHandle: "s2") == nil)
    }

    /// The Top 10 clause has its own ceiling: hidden when out of reach even
    /// though the row-above goal is shown.
    @Test func topTenClauseHiddenPastCeiling() throws {
        let points = [900, 800, 700, 600, 500, 450, 420, 400, 390, 380, 60, 50]
        let gap = try #require(RaceGap.compute(
            response: week(board(points), me: MyStanding(rank: 12, points: 50)),
            window: .week, myHandle: "s12"))
        #expect(gap.points == 11)
        #expect(gap.topTenPoints == nil)  // 331 pts away
    }

    /// No handle and nothing caught this week: one point earns a row.
    @Test func noHandle_zeroPoints_makeTheBoard() throws {
        let gap = try #require(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: nil))
        #expect(gap.target == .makeBoard)
        #expect(gap.points == 1)
        #expect(gap.topTenPoints == nil)
        #expect(gap.headline == "1 PT TO MAKE THE BOARD")
    }

    /// No handle but already holding points: the gap is zero, so the line
    /// hides and the existing "claim a handle" hint carries the message.
    @Test func noHandle_withPoints_hidden() {
        #expect(RaceGap.compute(
            response: week(board(), me: MyStanding(rank: 9, points: 160)),
            window: .week, myHandle: nil) == nil)
    }

    /// A handled spotter off a FULL board (50 rows) must beat the last row.
    @Test func offFullBoard_beatTheLastRow() throws {
        let full = board((0..<LeaderboardResponse.displayLimit).map { 600 - $0 * 10 })  // last = 110
        let gap = try #require(RaceGap.compute(
            response: week(full, me: MyStanding(rank: 60, points: 95)),
            window: .week, myHandle: "notlisted"))
        #expect(gap.target == .makeBoard)
        #expect(gap.points == 16)
    }

    @Test func emptyBoard_hidden() {
        #expect(RaceGap.compute(
            response: week([], me: MyStanding(rank: 0, points: 0)),
            window: .week, myHandle: "noah") == nil)
    }

    @Test func notRegistered_hidden() {
        #expect(RaceGap.compute(response: week(board(), me: nil),
                                window: .week, myHandle: "s11") == nil)
    }

    @Test func monthAndAllTime_hidden() {
        let me = MyStanding(rank: 11, points: 95)
        let month = LeaderboardResponse(entries: board(), me: me, window: "month",
                                        resetsAt: "2026-11-01T00:00:00.000Z")
        let all = LeaderboardResponse(entries: board(), me: me, window: "all")
        #expect(RaceGap.compute(response: month, window: .month, myHandle: "s11") == nil)
        #expect(RaceGap.compute(response: all, window: .all, myHandle: "s11") == nil)
    }

    /// FAIL-SOFT: the pre-windows backend sends no `window` key and its
    /// board is ALL-TIME, even though the screen files it under `.week`.
    @Test func oldBackendWithoutWindowKey_hidden() {
        let old = LeaderboardResponse(entries: board(), me: MyStanding(rank: 11, points: 95))
        #expect(RaceGap.compute(response: old, window: .week, myHandle: "s11") == nil)
    }
}
