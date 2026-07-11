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

// MARK: - Payload decoding

@Suite("Leaderboard windowed payload decoding")
struct LeaderboardWindowDecodingTests {

    /// The pinned backend-PR1 contract, verbatim shape.
    @Test func decodesWindowedWeekPayload() throws {
        let json = """
        {
          "entries": [{ "rank": 1, "handle": "skykid", "points": 840, "catches": 12 }],
          "me": { "rank": 2, "points": 315, "weeklyWins": 3, "everToppedAllTime": true },
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
    }
}
