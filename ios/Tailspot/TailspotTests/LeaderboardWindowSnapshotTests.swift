//
//  LeaderboardWindowSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the windowed leaderboard (dynamic-leaderboards
//  PR2): tabs per window, the reset countdown, the champion-banner variants
//  (1 / 2 / 3+ / anonymous / none), the fail-soft old-backend board, and the
//  Profile champion summary. NOT an assertion test: writes PNGs to the test
//  runner's temporary `tailspot_snaps` directory — review them after running.
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

    private static let snapDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tailspot_snaps", isDirectory: true)

    /// `height` defaults to an iPhone 17 screen; the race-gap renders pass a
    /// taller canvas so the YOUR STANDING row below a 12-row board is in
    /// frame without scrolling the List.
    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat = 852) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
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
        try! png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
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

        // Month: countdown date line + last month's champion banner.
        let month = LeaderboardResponse(
            entries: entries,
            me: MyStanding(rank: 2, points: 315, weeklyWins: 3, monthlyWins: 1,
                           everToppedAllTime: false),
            window: "month",
            resetsAt: monthResetsAt,
            champions: nil,
            monthlyChampions: [
                LeaderboardChampion(handle: "maia", points: 1850,
                                     monthStart: "2026-06-01")
            ])
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

    /// Weekly race-gap line under YOUR STANDING ("N PTS TO PASS @X …").
    /// The board mirrors the live 2026-10-21 week shape (two whales, then a
    /// tight pack), and `me.rank` is deliberately inflated past the row
    /// position to stand in for hidden handle-less/disabled devices.
    @Test func renderRaceGapBoards() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedConfirmed = defaults.object(forKey: SpotterHandle.confirmedKey)
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedConfirmed, forKey: SpotterHandle.confirmedKey)
        }
        let container = try emptyContainer()

        let points = [3705, 1360, 985, 460, 405, 230, 220, 215, 165, 145, 95, 45]
        let handles = ["chemtrails", "flydelta", "maia", "ellabella", "skykid", "contrail",
                       "heavywatcher", "dotbali", "jordan", "planespotter", "noah", "rookie"]
        let pack: [LeaderboardEntry] = zip(handles, points).enumerated().map { i, pair in
            .init(rank: i + 1, handle: pair.0, points: pair.1, catches: max(1, pair.1 / 30))
        }
        func week(_ me: MyStanding?) -> LeaderboardResponse {
            LeaderboardResponse(entries: pack, me: me, window: "week",
                                resetsAt: weekResetsAt, champions: nil,
                                totalCatchers: pack.count)
        }
        let tall: CGFloat = 1500

        // Mid-pack, outside the named Top 10: pass @planespotter (51 pts).
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        snapshot(board([.week: week(MyStanding(rank: 13, points: 95))],
                       selected: .week, container: container),
                 as: "racegap_week_midpack", height: tall)
        snapshot(board([.week: week(MyStanding(rank: 13, points: 95))],
                       selected: .week, container: container)
                    .dynamicTypeSize(.accessibility2),
                 as: "racegap_week_midpack_a11y2", height: 2400)

        // Last row: pass @noah AND a separate Top 10 goal.
        defaults.set("rookie", forKey: SpotterHandle.storageKey)
        snapshot(board([.week: week(MyStanding(rank: 14, points: 45))],
                       selected: .week, container: container),
                 as: "racegap_week_topten_line", height: tall)

        // Inside the Top 10: pass @heavywatcher (6 pts).
        defaults.set("dotbali", forKey: SpotterHandle.storageKey)
        snapshot(board([.week: week(MyStanding(rank: 8, points: 215))],
                       selected: .week, container: container),
                 as: "racegap_week_top10", height: tall)

        // #2 whale: 2,346 pts behind → over the ceiling, line hidden.
        defaults.set("flydelta", forKey: SpotterHandle.storageKey)
        snapshot(board([.week: week(MyStanding(rank: 2, points: 1360))],
                       selected: .week, container: container),
                 as: "racegap_week_whale_hidden", height: tall)

        // Handled (server-confirmed), nothing caught this week →
        // "1 PT TO MAKE THE BOARD".
        defaults.set("notlisted", forKey: SpotterHandle.storageKey)
        defaults.set("notlisted", forKey: SpotterHandle.confirmedKey)
        snapshot(board([.week: week(MyStanding(rank: 0, points: 0))],
                       selected: .week, container: container),
                 as: "racegap_week_makeboard", height: tall)

        // Same, but the handle never synced (stranded) → no promise.
        defaults.removeObject(forKey: SpotterHandle.confirmedKey)
        snapshot(board([.week: week(MyStanding(rank: 0, points: 0))],
                       selected: .week, container: container),
                 as: "racegap_week_stranded", height: tall)

        // No handle → no gap line; the "claim a handle" hint stands alone.
        defaults.set(SpotterHandle.defaultPlaceholder, forKey: SpotterHandle.storageKey)
        snapshot(board([.week: week(MyStanding(rank: 0, points: 0))],
                       selected: .week, container: container),
                 as: "racegap_week_nohandle", height: tall)
        #expect(true)
    }

    /// Profile hub with offline-cached weekly/monthly wins folded into the
    /// identity hero. Render every visibility combination so a visual pass
    /// covers the absent footer, both single-period layouts, and both periods.
    @Test func renderProfileChampionSummary() throws {
        let defaults = UserDefaults.standard
        let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
        let savedPoints = defaults.object(forKey: "tailspot.standing.points")
        let savedRank = defaults.object(forKey: "tailspot.standing.rank")
        let savedWins = defaults.object(forKey: "tailspot.standing.weeklyWins")
        let savedMonthlyWins = defaults.object(forKey: "tailspot.standing.monthlyWins")
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defaults.set(1370, forKey: "tailspot.standing.points")
        defaults.set(1, forKey: "tailspot.standing.rank")
        defer {
            defaults.set(savedHandle, forKey: SpotterHandle.storageKey)
            defaults.set(savedPoints, forKey: "tailspot.standing.points")
            defaults.set(savedRank, forKey: "tailspot.standing.rank")
            defaults.set(savedWins, forKey: "tailspot.standing.weeklyWins")
            defaults.set(savedMonthlyWins, forKey: "tailspot.standing.monthlyWins")
        }
        let container = try emptyContainer()

        defaults.set(0, forKey: "tailspot.standing.weeklyWins")
        defaults.set(0, forKey: "tailspot.standing.monthlyWins")
        snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_no_wins")

        defaults.set(3, forKey: "tailspot.standing.weeklyWins")
        snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_weekly_only")

        defaults.set(0, forKey: "tailspot.standing.weeklyWins")
        defaults.set(2, forKey: "tailspot.standing.monthlyWins")
        snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_monthly_only")

        defaults.set(3, forKey: "tailspot.standing.weeklyWins")
        snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_both")
        snapshot(ProfileScreen().modelContainer(container).dynamicTypeSize(.accessibility2),
                 as: "profile_champion_summary_both_a11y2")
        #expect(true)
    }
}
#endif
