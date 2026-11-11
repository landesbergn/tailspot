//
//  WeeklyRecapTests.swift
//  TailspotTests
//
//  Pins the weekly recap (WeeklyRecap.swift): which week it covers, what
//  counts as new, the standout pick, points, and when the Hangar shows it.
//  Day membership comes from the frozen `caughtDayKey`, so every test sets
//  it explicitly and none depend on the wall clock or the device zone.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("WeeklyRecap")
@MainActor
struct WeeklyRecapTests {

    /// Noon UTC on a key, with a UTC zone passed alongside, so "today" is
    /// unambiguous.
    private static func noonUTC(_ key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 12
        return cal.date(from: c)!
    }

    private func mk(
        _ day: String,
        hour: Int = 12,
        icao: String = UUID().uuidString.prefix(6).lowercased(),
        typecode: String? = nil,
        altitude: Double? = nil,
        photo: String? = nil
    ) -> Catch {
        let c = Catch(
            icao24: icao,
            callsign: "TST\(hour)",
            model: nil,
            manufacturer: nil,
            photoFilename: photo,
            caughtAt: Self.noonUTC(day).addingTimeInterval(Double(hour - 12) * 3600),
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 2000,
            typecode: typecode,
            altitudeMeters: altitude
        )
        c.caughtDayKey = day
        return c
    }

    // MARK: - Which week

    @Test func daysSinceMondayCountsFromMonday() {
        // 2026-11-09 is a Monday; 2026-11-08 a Sunday.
        #expect(WeeklyRecap.daysSinceMonday(key: "2026-11-09") == 0)
        #expect(WeeklyRecap.daysSinceMonday(key: "2026-11-12") == 3)
        #expect(WeeklyRecap.daysSinceMonday(key: "2026-11-08") == 6)
        #expect(WeeklyRecap.daysSinceMonday(key: "garbage") == nil)
    }

    @Test func coversTheLastFullWeekFromAnyDayOfTheNextOne() {
        #expect(WeeklyRecap.lastWeekStartKey(todayKey: "2026-11-09") == "2026-11-02")
        #expect(WeeklyRecap.lastWeekStartKey(todayKey: "2026-11-15") == "2026-11-02")
        #expect(WeeklyRecap.lastWeekStartKey(todayKey: "2026-11-16") == "2026-11-09")
        // Across a month and a year.
        #expect(WeeklyRecap.lastWeekStartKey(todayKey: "2027-01-04") == "2026-12-28")
    }

    @Test func onlyLastWeeksCatchesCount() {
        let rows = [
            mk("2026-11-01"),               // Sunday before: out
            mk("2026-11-02"),               // Monday: in
            mk("2026-11-08", hour: 23),     // Sunday night: in
            mk("2026-11-09"),               // this week: out
        ]
        let r = WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-11"), timeZone: .gmt)
        #expect(r?.catchCount == 2)
        #expect(r?.dayCounts == [1, 0, 0, 0, 0, 0, 1])
        #expect(r?.dayKeys.first == "2026-11-02")
        #expect(r?.dayKeys.last == "2026-11-08")
    }

    @Test func noCatchesLastWeekMeansNoRecap() {
        let rows = [mk("2026-10-20"), mk("2026-11-10")]
        #expect(WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-11"), timeZone: .gmt) == nil)
        #expect(WeeklyRecap.lastWeek(catches: [], now: Self.noonUTC("2026-11-11"), timeZone: .gmt) == nil)
    }

    /// The frozen day key decides the day, not `caughtAt` in today's zone:
    /// a catch made late Sunday in Bali stays in that week after flying home.
    @Test func frozenDayKeyWins() {
        let c = mk("2026-11-08")
        c.caughtAt = Self.noonUTC("2026-11-09") // would be Monday if re-derived
        let r = WeeklyRecap.lastWeek(catches: [c], now: Self.noonUTC("2026-11-10"), timeZone: .gmt)
        #expect(r?.dayCounts.last == 1)
    }

    // MARK: - What's new

    @Test func newCountsFirstEverAirframesAndTypesOnce() {
        let rows = [
            mk("2026-10-15", icao: "aaaaaa", typecode: "B738"),   // known tail, known type
            mk("2026-11-03", icao: "aaaaaa", typecode: "B738"),   // re-catch: not new
            mk("2026-11-04", icao: "bbbbbb", typecode: "A359"),   // new tail, new type
            mk("2026-11-05", icao: "bbbbbb", typecode: "A359"),   // same tail again
            mk("2026-11-06", icao: "cccccc", typecode: "A359"),   // new tail, type already new this week
        ]
        let r = WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(r.catchCount == 4)
        #expect(r.newAirframes == 2)
        #expect(r.newTypes == 1)
        #expect(r.subline == "2 new to your Hangar")
    }

    @Test func allRepeatsSaySo() {
        let rows = [mk("2026-10-15", icao: "aaaaaa"), mk("2026-11-03", icao: "aaaaaa")]
        let r = WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(r.newAirframes == 0)
        #expect(r.subline == "All repeat visitors")
    }

    // MARK: - Standout, stats

    @Test func standoutPrefersTierThenPhoto() {
        // A388 is rare in the bundled table; B738 is common.
        let common = mk("2026-11-03", typecode: "B738", photo: "x.jpg")
        let rareNoPhoto = mk("2026-11-04", hour: 9, typecode: "A388")
        let rareWithPhoto = mk("2026-11-04", hour: 8, typecode: "A388", photo: "y.jpg")
        let r = WeeklyRecap.lastWeek(
            catches: [common, rareNoPhoto, rareWithPhoto], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(rareWithPhoto.resolvedRarity.basePoints > common.resolvedRarity.basePoints)
        #expect(r.rarest === rareWithPhoto)
    }

    @Test func pointsMatchTheHangarsDerivation() {
        let first = mk("2026-11-03", icao: "aaaaaa", typecode: "B738")
        let again = mk("2026-11-04", icao: "bbbbbb", typecode: "B738")
        again.guessKind = GuessKind.type.rawValue
        again.guessCorrect = true
        let r = WeeklyRecap.lastWeek(catches: [first, again], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        let base = first.resolvedRarity.basePoints
        let expected = base + ScoringBonuses.firstOfTypeBonus(base: base)
            + base + ScoringBonuses.guessBonus(base: base, kind: .type, caughtAt: again.caughtAt)
        #expect(r.points == expected)
    }

    @Test func streakIsTheLiveStreakAsOfNow() {
        // Caught Sat + Sun last week and Mon today: a 3-day live streak.
        let rows = [mk("2026-11-07"), mk("2026-11-08"), mk("2026-11-09")]
        let r = WeeklyRecap.lastWeek(catches: rows, now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(r.currentStreak == 3)
        // A broken streak reads 0 even though last week had catches.
        let gone = WeeklyRecap.lastWeek(catches: [mk("2026-11-03")], now: Self.noonUTC("2026-11-12"), timeZone: .gmt)!
        #expect(gone.currentStreak == 0)
    }

    @Test func standoutRowOpensTheStandoutCatch() {
        let older = mk("2026-10-01", icao: "aaaaaa", typecode: "A388")
        let standout = mk("2026-11-04", icao: "aaaaaa", typecode: "A388", photo: "p.jpg")
        let newer = mk("2026-11-10", icao: "aaaaaa", typecode: "A388")
        let r = WeeklyRecap.lastWeek(catches: [older, standout, newer], now: Self.noonUTC("2026-11-11"), timeZone: .gmt)!
        // The detail renders `mostRecent`, so it must be the standout, not
        // the airframe's newest catch.
        #expect(r.rarestRow.mostRecent === standout)
        #expect(r.rarestRow.count == 3)
    }

    // MARK: - Weekly rank

    private func board(resetsAt: String, lastWeekRank: Int?) -> LeaderboardResponse {
        LeaderboardResponse(
            entries: [],
            me: MyStanding(rank: 1, points: 10, lastWeekRank: lastWeekRank),
            window: "week",
            resetsAt: resetsAt
        )
    }

    @Test func rankIsUsedOnlyWhenTheBoardsWeekMatches() {
        // Board resets Mon Nov 16 → its last closed week began Nov 2.
        let matching = board(resetsAt: "2026-11-16T00:00:00.000Z", lastWeekRank: 4)
        #expect(WeeklyRecapRank.rank(from: matching, weekStart: "2026-11-02") == 4)
        // Early Monday east of UTC: the board's week hasn't closed yet.
        let early = board(resetsAt: "2026-11-09T00:00:00.000Z", lastWeekRank: 4)
        #expect(WeeklyRecapRank.rank(from: early, weekStart: "2026-11-02") == nil)
        // Unranked (0) or an old server (nil) shows no rank.
        #expect(WeeklyRecapRank.rank(from: board(resetsAt: "2026-11-16T00:00:00.000Z", lastWeekRank: 0), weekStart: "2026-11-02") == nil)
        #expect(WeeklyRecapRank.rank(from: board(resetsAt: "2026-11-16T00:00:00.000Z", lastWeekRank: nil), weekStart: "2026-11-02") == nil)
    }

    @Test func statsReadRankPointsTypesStreak() {
        let r = WeeklyRecap.lastWeek(catches: [mk("2026-11-03")], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        let ranked = WeeklyRecapStat.all(r, weeklyRank: 4).map(\.value)
        #expect(ranked.first == "#4")
        #expect(WeeklyRecapStat.all(r, weeklyRank: nil).first?.value == "—")
        #expect(WeeklyRecapStat.all(r, weeklyRank: 4).map(\.label) == ["WEEKLY RANK", "POINTS", "NEW TYPES", "STREAK"])
    }

    // MARK: - Copy

    @Test func headlineAndRangeLabel() {
        let r = WeeklyRecap.lastWeek(catches: [mk("2026-11-03")], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(r.headline == "1 plane caught")
        let en = Locale(identifier: "en_US")
        #expect(r.rangeLabel(locale: en) == "NOV 2 – 8")
        let spanning = WeeklyRecap.week(startingAt: "2026-10-26", catches: [mk("2026-10-27")], timeZone: .gmt)!
        #expect(spanning.rangeLabel(locale: en) == "OCT 26 – NOV 1")
        #expect(WeeklyRecap.weekdayLetters(locale: en) == ["M", "T", "W", "T", "F", "S", "S"])
    }

    @Test func shareMessageCarriesTheCampaignLink() {
        let r = WeeklyRecap.lastWeek(catches: [mk("2026-11-03")], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        let message = WeeklyRecapShareImage.message(r)
        #expect(message.contains("ct=Weekly%20Recap"))
        #expect(message.contains("1 plane caught"))
    }

    @Test func podiumPlaceOnlyForTheTopThree() {
        #expect(WeeklyRecapPlace(rank: 1) == .first)
        #expect(WeeklyRecapPlace(rank: 2) == .second)
        #expect(WeeklyRecapPlace(rank: 3) == .third)
        #expect(WeeklyRecapPlace(rank: 4) == nil)
        #expect(WeeklyRecapPlace(rank: 0) == nil)
        #expect(WeeklyRecapPlace(rank: nil) == nil)
        #expect(WeeklyRecapPlace.first.shareLabel == "Share my win")
        #expect(WeeklyRecapPlace.second.shareLabel == "Share my week")
    }

    @Test func podiumShareMessageLeadsWithTheFinish() {
        let r = WeeklyRecap.lastWeek(catches: [mk("2026-11-03")], now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        #expect(WeeklyRecapShareImage.message(r, place: .first).hasPrefix("I won the week on Tailspot: 1 plane caught"))
        #expect(WeeklyRecapShareImage.message(r, place: .third).hasPrefix("I took 3rd place on Tailspot this week:"))
        #expect(WeeklyRecapShareImage.message(r, place: .second).contains("ct=Weekly%20Recap"))
    }

    // MARK: - Presentation

    @Test func bannerHidesOnlyForTheClosedWeek() {
        #expect(WeeklyRecapPresentation.shouldShow(weekStartKey: "2026-11-02", dismissedWeek: ""))
        #expect(!WeeklyRecapPresentation.shouldShow(weekStartKey: "2026-11-02", dismissedWeek: "2026-11-02"))
        #expect(WeeklyRecapPresentation.shouldShow(weekStartKey: "2026-11-09", dismissedWeek: "2026-11-02"))
        #expect(!WeeklyRecapPresentation.shouldShow(weekStartKey: nil, dismissedWeek: ""))
    }

    @Test func telemetryProperties() {
        let r = WeeklyRecap.lastWeek(
            catches: [mk("2026-11-03"), mk("2026-11-03", hour: 13), mk("2026-11-05")],
            now: Self.noonUTC("2026-11-09"), timeZone: .gmt)!
        let p = WeeklyRecapTelemetry.properties(r)
        guard case .int(let count)? = p["catch_count"], case .int(let days)? = p["active_days"] else {
            Issue.record("missing properties"); return
        }
        #expect(count == 3)
        #expect(days == 2)
    }
}
