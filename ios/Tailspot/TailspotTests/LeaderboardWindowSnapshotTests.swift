//
//  LeaderboardWindowSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the windowed leaderboard (dynamic-leaderboards
//  PR2): tabs per window, the reset countdown, the champion-banner variants
//  (1 / 2 / 3+ / anonymous / none), the fail-soft old-backend board, and the
//  Profile weekly-champion laurel. NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps and passes — review the images after running.
//
//  LeaderboardScreen is List-based, which ImageRenderer can't render, so this
//  hosts each screen in a real UIWindow and snapshots via drawHierarchy
//  (the ProfileSettingsSnapshotTests pattern).
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Leaderboard window snapshots (visual pass)", .serialized)
struct LeaderboardWindowSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func emptyContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        return container
    }

    // MARK: - Fixtures

    private var entries: [LeaderboardEntry] {
        [
            .init(rank: 1, handle: "skykid", points: 840, catches: 12),
            .init(rank: 2, handle: "noah", points: 315, catches: 7),
            .init(rank: 3, handle: "contrail", points: 210, catches: 5),
            .init(rank: 4, handle: "heavywatcher", points: 140, catches: 3),
            .init(rank: 5, handle: "dotbali", points: 60, catches: 2),
        ]
    }

    /// A reset ~2d 14h out so the week countdown reads a real value.
    private var weekResetsAt: String {
        iso(Date().addingTimeInterval(2 * 86_400 + 14 * 3_600 + 600))
    }

    private var monthResetsAt: String {
        iso(Date().addingTimeInterval(19 * 86_400))
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func weekResponse(champions: [LeaderboardChampion]?,
                              entries: [LeaderboardEntry]? = nil) -> LeaderboardResponse {
        LeaderboardResponse(
            entries: entries ?? self.entries,
            me: MyStanding(rank: 2, points: 315, weeklyWins: 3, everToppedAllTime: false),
            window: "week",
            resetsAt: weekResetsAt,
            champions: champions
        )
    }

    private func board(_ responses: [LeaderboardWindow: LeaderboardResponse],
                       selected: LeaderboardWindow,
                       container: ModelContainer) -> some View {
        NavigationStack {
            LeaderboardScreen(_debugWindows: responses, selected: selected)
        }
        .modelContainer(container)
    }

    // MARK: - Renders

    @Test func renderWindowedBoards() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defer { defaults.set(savedHandle, forKey: SpotterHandle.storageKey) }
        let container = try emptyContainer()

        // Week: tabs + countdown + single champion + podium + me row.
        let oneChamp = [LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29")]
        snapshot(board([.week: weekResponse(champions: oneChamp)],
                       selected: .week, container: container),
                 as: "leaderboard_week")

        // Shared crown: two champions side by side.
        let twoChamps = [
            LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29"),
            LeaderboardChampion(handle: "contrail", points: 840, weekStart: "2026-06-29"),
        ]
        snapshot(board([.week: weekResponse(champions: twoChamps)],
                       selected: .week, container: container),
                 as: "leaderboard_week_champs2")

        // 3+ champions with an anonymous one → "@a, anonymous spotter +1 more".
        let threeChamps = [
            LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29"),
            LeaderboardChampion(handle: nil, points: 840, weekStart: "2026-06-29"),
            LeaderboardChampion(handle: "contrail", points: 840, weekStart: "2026-06-29"),
        ]
        snapshot(board([.week: weekResponse(champions: threeChamps)],
                       selected: .week, container: container),
                 as: "leaderboard_week_champs3_anon")

        // Fresh week: nobody crowned last week AND nothing caught yet.
        let quiet = LeaderboardResponse(
            entries: [], me: nil, window: "week",
            resetsAt: weekResetsAt, champions: [])
        snapshot(board([.week: quiet], selected: .week, container: container),
                 as: "leaderboard_week_empty_nochamp")

        // Month: countdown date line, no champion banner.
        let month = LeaderboardResponse(
            entries: entries,
            me: MyStanding(rank: 2, points: 315, weeklyWins: 3, everToppedAllTime: false),
            window: "month",
            resetsAt: monthResetsAt,
            champions: nil)
        snapshot(board([.month: month], selected: .month, container: container),
                 as: "leaderboard_month")

        // All time: tabs, no countdown, no banner.
        let allTime = LeaderboardResponse(
            entries: entries,
            me: MyStanding(rank: 2, points: 315, weeklyWins: 3, everToppedAllTime: true),
            window: "all",
            resetsAt: nil,
            champions: nil)
        snapshot(board([.all: allTime], selected: .all, container: container),
                 as: "leaderboard_all")

        // FAIL-SOFT: old-backend payload (no window key) → tabs hidden,
        // plain all-time board.
        let old = LeaderboardResponse(entries: entries, me: MyStanding(rank: 2, points: 315))
        snapshot(board([.week: old], selected: .week, container: container),
                 as: "leaderboard_failsoft_oldbackend")
        #expect(true)
    }

    /// Profile hub with the weekly-champion laurel (L6): cached weeklyWins
    /// renders the gold row under the identity header, offline-capable.
    @Test func renderProfileLaurel() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedPoints = defaults.object(forKey: "tailspot.standing.points")
        let savedRank = defaults.object(forKey: "tailspot.standing.rank")
        let savedWins = defaults.object(forKey: "tailspot.standing.weeklyWins")
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defaults.set(1370, forKey: "tailspot.standing.points")
        defaults.set(1, forKey: "tailspot.standing.rank")
        defaults.set(3, forKey: "tailspot.standing.weeklyWins")
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedPoints, forKey: "tailspot.standing.points")
            defaults.set(savedRank, forKey: "tailspot.standing.rank")
            defaults.set(savedWins, forKey: "tailspot.standing.weeklyWins")
        }
        let container = try emptyContainer()
        snapshot(ProfileScreen().modelContainer(container), as: "profile_laurel_x3")

        // Single win: no "×1" suffix.
        defaults.set(1, forKey: "tailspot.standing.weeklyWins")
        snapshot(ProfileScreen().modelContainer(container), as: "profile_laurel_x1")
        #expect(true)
    }
}
#endif
