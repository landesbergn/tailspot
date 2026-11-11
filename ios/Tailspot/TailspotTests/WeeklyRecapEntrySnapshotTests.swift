//
//  WeeklyRecapEntrySnapshotTests.swift
//  TailspotTests
//
//  Visual pass for the two doors into the weekly recap: the LAST WEEK card
//  on Profile and the LAST WEEK row on the weekly leaderboard. Writes PNGs
//  to /private/tmp/tailspot_snaps; asserts only that they rendered.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Weekly recap entry rows (visual pass)", .serialized)
struct WeeklyRecapEntrySnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
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

    /// Nine catches spread over LAST week (relative to the real today, since
    /// both screens compute "last week" from `Date()`).
    private func lastWeekContainer() throws -> (ModelContainer, String) {
        let container = try ModelContainer(
            for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        let start = try #require(WeeklyRecap.lastWeekStartKey(todayKey: Streaks.dayKey(for: Date())))
        let rows: [(Int, String, String)] = [
            (0, "SWA1598", "B738"), (0, "UAL2476", "B739"), (1, "ASA331", "A21N"),
            (2, "N700GX", "GLEX"), (2, "SKW5512", "E75L"), (2, "DAL88", "B77W"),
            (3, "UAL837", "B789"), (5, "SWA22", "B738"), (5, "AAL1", "A21N"),
        ]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        for (i, (offset, cs, tc)) in rows.enumerated() {
            let key = try #require(Streaks.key(byAdding: offset, to: start))
            let p = key.split(separator: "-").compactMap { Int($0) }
            let date = try #require(cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12)))
            let c = Catch(icao24: String(format: "a%05x", i), callsign: cs, model: nil, manufacturer: nil,
                          caughtAt: date, observerLat: 37.87, observerLon: -122.27,
                          slantDistanceMeters: 3000, typecode: tc)
            c.caughtDayKey = key
            container.mainContext.insert(c)
        }
        return (container, start)
    }

    @Test func renderEntryRows() async throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedRank = defaults.object(forKey: WeeklyRecapRank.cacheKey)
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedRank, forKey: WeeklyRecapRank.cacheKey)
        }
        defaults.set("noah", forKey: SpotterHandle.storageKey)

        let (container, weekStart) = try lastWeekContainer()
        defaults.set("\(weekStart)|4", forKey: WeeklyRecapRank.cacheKey)

        await snapshot(ProfileScreen().modelContainer(container), as: "weekly_recap_entry_profile")

        let entries: [LeaderboardEntry] = [
            .init(rank: 1, handle: "skykid", points: 410, catches: 6),
            .init(rank: 2, handle: "contrail", points: 275, catches: 4),
            .init(rank: 3, handle: "noah", points: 180, catches: 3),
            .init(rank: 4, handle: "heavywatcher", points: 120, catches: 2),
            .init(rank: 5, handle: "dotbali", points: 60, catches: 1),
        ]
        let champ = [LeaderboardChampion(handle: "Skidplate_73", points: 20_826, weekStart: weekStart, monthStart: nil)]
        await snapshot(
            NavigationStack {
                LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                    entries: entries, me: MyStanding(rank: 3, points: 180), window: "week",
                    champions: champ)])
            }
            .modelContainer(container),
            as: "weekly_recap_entry_leaderboard")
        // Monday morning: nobody on the new board yet, so the plaque stands alone.
        await snapshot(
            NavigationStack {
                LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                    entries: [], me: nil, window: "week", champions: champ)])
            }
            .modelContainer(container),
            as: "weekly_recap_entry_leaderboard_empty")
        // No catches last week: the plaque has no "you" row.
        let empty = try ModelContainer(for: Catch.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(empty)
        await snapshot(
            NavigationStack {
                LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                    entries: entries, me: MyStanding(rank: 3, points: 180), window: "week",
                    champions: champ)])
            }
            .modelContainer(empty),
            as: "weekly_recap_entry_leaderboard_norecap")
        // Rank not served yet: the chip is just a "Your week ›" button.
        defaults.removeObject(forKey: WeeklyRecapRank.cacheKey)
        await snapshot(
            NavigationStack {
                LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                    entries: entries, me: MyStanding(rank: 3, points: 180), window: "week",
                    champions: champ)])
            }
            .modelContainer(container),
            as: "weekly_recap_entry_leaderboard_norank")
        // Podium finishes: the plaque chip takes the medal colour, and the
        // recap screen + share image open with the medal.
        for (rank, name) in [(1, "gold"), (2, "silver"), (3, "bronze")] {
            defaults.set("\(weekStart)|\(rank)", forKey: WeeklyRecapRank.cacheKey)
            let recap = try #require(WeeklyRecap.lastWeek(catches: try container.mainContext.fetch(FetchDescriptor<Catch>())))
            await snapshot(WeeklyRecapScreen(recap: recap, weeklyRank: rank).modelContainer(container),
                           as: "weekly_recap_podium_\(name)")
            if rank == 1 {
                await snapshot(
                    NavigationStack {
                        LeaderboardScreen(_debugWindows: [.week: LeaderboardResponse(
                            entries: entries, me: MyStanding(rank: 3, points: 180), window: "week",
                            champions: champ)])
                    }
                    .modelContainer(container),
                    as: "weekly_recap_entry_leaderboard_gold")
                if let image = WeeklyRecapShareImage.render(recap, weeklyRank: rank),
                   let png = image.pngData() {
                    try? png.write(to: Self.snapDir.appendingPathComponent("weekly_recap_share_gold.png"))
                }
            }
        }
        #expect(true)
    }
}
#endif
