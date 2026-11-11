//
//  WeeklyRecapStressSnapshotTests.swift
//  TailspotTests
//
//  Visual pass at the top of the leaderboard (Noah, 2026-11-11: "Skidplate
//  levels of catches"): ~470 catches in one week, a 140-catch day, dozens of
//  new types, a 300-day streak, a week that spans two months, five-digit
//  points, and a four-digit rank on the plaque. Writes PNGs to
//  /private/tmp/tailspot_snaps; asserts only the numbers it feeds in.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Weekly recap at scale (visual pass)", .serialized)
struct WeeklyRecapStressSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat = 852) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(0.5))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let png = UIGraphicsImageRenderer(bounds: bounds, format: format).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private static func noonUTC(_ key: String) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .gmt
        let p = key.split(separator: "-").compactMap { Int($0) }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    /// Typecodes from common airliners to rare military/bizjets, so the
    /// week has many first-of-type bonuses and a high-tier standout.
    private static let types = [
        "B738", "B739", "A320", "A321", "A21N", "A20N", "B38M", "B39M", "E75L", "CRJ9",
        "B77W", "B772", "B789", "B788", "B78X", "A359", "A35K", "A333", "A332", "B744",
        "B748", "B763", "B752", "A388", "MD11", "DC10", "B712", "E190", "CRJ2", "DH8D",
        "AT76", "C172", "C182", "SR22", "PC12", "C208", "BE20", "B350", "PA28", "DA40",
        "GLEX", "GLF6", "GLF5", "CL60", "C68A", "E55P", "FA7X", "F900", "LJ45", "C560",
        "C17", "C130", "C5M", "KC46", "K35R", "P8", "E3TF", "B52", "F18S", "V22",
        "H60", "EC35", "AS50", "R44", "B06", "A139", "S76", "EC45", "B429", "H47",
        "A400", "A124", "AN22", "IL76", "B74S", "A3ST", "BLCF", "CONC", "U2", "SR71",
        "A225", "B377", "DC3", "C46", "B17", "P51", "SPIT", "MOSQ", "AVRO", "VC10",
    ]

    /// Mon 2026-10-26 → Sun 11-01 (crosses a month, the longest range label).
    private static let weekStart = "2026-10-26"
    private static let perDay = [64, 140, 51, 97, 12, 88, 18]

    private func bigWeekCatches() -> [Catch] {
        var out: [Catch] = []
        var n = 0
        for (offset, count) in Self.perDay.enumerated() {
            let key = Streaks.key(byAdding: offset, to: Self.weekStart)!
            for i in 0..<count {
                let tc = Self.types[(n * 7 + i) % Self.types.count]
                let c = Catch(icao24: String(format: "b%05x", n), callsign: "SKD\(n)", model: nil,
                              manufacturer: nil, caughtAt: Self.noonUTC(key).addingTimeInterval(Double(i) * 60),
                              observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 3000,
                              registration: n == 3 ? "N700GX" : nil, typecode: tc)
                c.caughtDayKey = key
                out.append(c)
                n += 1
            }
        }
        return out
    }

    @Test func renderAtScale() async throws {
        let catches = bigWeekCatches()
        let recap = try #require(WeeklyRecap.week(startingAt: Self.weekStart, catches: catches,
                                                  currentStreak: 312, timeZone: .gmt))
        #expect(recap.catchCount == Self.perDay.reduce(0, +))
        print("stress recap: \(recap.catchCount) catches, \(recap.points) pts, headline=\(recap.headline), subline=\(recap.subline), range=\(recap.rangeLabel())")

        await snapshot(
            VStack(spacing: 0) {
                WeeklyRecapBanner(recap: recap, onOpen: {}, onDismiss: {})
                Spacer()
            }
            .background(Brand.Color.bgPrimary),
            as: "stress_banner", height: 160)

        await snapshot(WeeklyRecapScreen(recap: recap, weeklyRank: 1), as: "stress_recap_gold")
        await snapshot(WeeklyRecapScreen(recap: recap, weeklyRank: 1_234), as: "stress_recap_rank1234")
        await snapshot(NavigationStack {
            Color.clear.navigationDestination(isPresented: .constant(true)) {
                WeeklyRecapScreen(recap: recap, weeklyRank: 1, presentation: .pushed)
            }
        }, as: "stress_recap_pushed")

        let gold = try #require(WeeklyRecapShareImage.render(recap, weeklyRank: 1))
        try gold.pngData()?.write(to: Self.snapDir.appendingPathComponent("stress_share_gold.png"))
        let plain = try #require(WeeklyRecapShareImage.render(recap, weeklyRank: 1_234))
        try plain.pngData()?.write(to: Self.snapDir.appendingPathComponent("stress_share_rank1234.png"))

        // Plaque: a long champion handle with six-figure points, and the
        // viewer's four-digit rank in the chip.
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedRank = defaults.object(forKey: WeeklyRecapRank.cacheKey)
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedRank, forKey: WeeklyRecapRank.cacheKey)
        }
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        let container = try ModelContainer(for: Catch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        // Real last week (the screen computes it from Date()), same volume.
        let lastStart = try #require(WeeklyRecap.lastWeekStartKey(todayKey: Streaks.dayKey(for: Date())))
        for (i, c) in catches.enumerated() {
            let offset = Self.perDay.indices.first { d in Self.perDay[0...d].reduce(0, +) > i }!
            let key = Streaks.key(byAdding: offset, to: lastStart)!
            var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
            let p = key.split(separator: "-").compactMap { Int($0) }
            c.caughtAt = cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
            c.caughtDayKey = key
            container.mainContext.insert(c)
        }
        let entries: [LeaderboardEntry] = [
            .init(rank: 1, handle: "Skidplate_73", points: 21_406, catches: 471),
            .init(rank: 2, handle: "P40E", points: 9_050, catches: 212),
            .init(rank: 3, handle: "chemtrails_and_chill", points: 4_495, catches: 130),
            .init(rank: 4, handle: "heavywatcher", points: 1_120, catches: 42),
        ]
        let champ = [LeaderboardChampion(handle: "Skidplate_73_longhandle", points: 120_826,
                                         weekStart: lastStart, monthStart: nil)]
        for (rank, name) in [(1, "rank1"), (1_234, "rank1234")] {
            defaults.set("\(lastStart)|\(rank)", forKey: WeeklyRecapRank.cacheKey)
            await snapshot(
                NavigationStack {
                    LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                        entries: entries, me: MyStanding(rank: 1, points: 21_406), window: "week",
                        champions: champ)])
                }
                .modelContainer(container),
                as: "stress_leaderboard_\(name)")
        }
    }
}
#endif
