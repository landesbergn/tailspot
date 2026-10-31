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

extension StandardDefaultsSnapshotSuites {
    @MainActor
    @Suite("Leaderboard window snapshots (visual pass)", .serialized)
    struct LeaderboardWindowSnapshotTests {

        private static let snapDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailspot_snaps", isDirectory: true)

        /// Defaults to the legacy 393 × 852 canvas; the standing-line passes
        /// pass device sizes.
        private func snapshot<V: View>(_ view: V, as name: String,
                                       width: CGFloat = 393, height: CGFloat = 852) async {
            try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(frame: bounds)
            window.rootViewController = host
            window.overrideUserInterfaceStyle = .dark
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try? await Task.sleep(for: .seconds(0.3))
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

        @Test func renderWindowedBoards() async throws {
            let defaults = UserDefaults.standard
            let savedHandle = defaults.object(forKey: SpotterHandle.storageKey)
            defaults.set("noah", forKey: SpotterHandle.storageKey)
            defer { defaults.set(savedHandle, forKey: SpotterHandle.storageKey) }
            let container = try emptyContainer()

            // Week: tabs + countdown + single champion + podium + me row.
            let oneChamp = [LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29")]
            await snapshot(board([.week: weekResponse(champions: oneChamp)],
                                 selected: .week, container: container),
                           as: "leaderboard_week")

            // Shared crown: two champions side by side.
            let twoChamps = [
                LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29"),
                LeaderboardChampion(handle: "contrail", points: 840, weekStart: "2026-06-29"),
            ]
            await snapshot(board([.week: weekResponse(champions: twoChamps)],
                                 selected: .week, container: container),
                           as: "leaderboard_week_champs2")

            // 3+ champions with an anonymous one → "@a, anonymous spotter +1 more".
            let threeChamps = [
                LeaderboardChampion(handle: "skykid", points: 840, weekStart: "2026-06-29"),
                LeaderboardChampion(handle: nil, points: 840, weekStart: "2026-06-29"),
                LeaderboardChampion(handle: "contrail", points: 840, weekStart: "2026-06-29"),
            ]
            await snapshot(board([.week: weekResponse(champions: threeChamps)],
                                 selected: .week, container: container),
                           as: "leaderboard_week_champs3_anon")

            // Fresh week: nobody crowned last week AND nothing caught yet.
            let quiet = LeaderboardResponse(
                entries: [], me: nil, window: "week",
                resetsAt: weekResetsAt, champions: [])
            await snapshot(board([.week: quiet], selected: .week, container: container),
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
            await snapshot(board([.month: month], selected: .month, container: container),
                           as: "leaderboard_month")

            // All time: tabs, no countdown, no banner.
            let allTime = LeaderboardResponse(
                entries: entries,
                me: MyStanding(rank: 2, points: 315, weeklyWins: 3, everToppedAllTime: true),
                window: "all",
                resetsAt: nil,
                champions: nil)
            await snapshot(board([.all: allTime], selected: .all, container: container),
                           as: "leaderboard_all")

            // FAIL-SOFT: old-backend payload (no window key) → tabs hidden,
            // plain all-time board.
            let old = LeaderboardResponse(entries: entries, me: MyStanding(rank: 2, points: 315))
            await snapshot(board([.week: old], selected: .week, container: container),
                           as: "leaderboard_failsoft_oldbackend")
            #expect(true)
        }

        /// The standing line in the fixed header, under the switcher ("You're
        /// 11th this week" / "50 points behind @planespotter · resets in 2d 14h").
        /// Rendered at iPhone 17 size with the status bar and tab bar simulated
        /// (62 pt top, 83 pt bottom) so "visible without scrolling" and "the
        /// podium starts on the first screen" can be judged from the PNG. The
        /// board mirrors the live 2026-10-21 week shape (two whales, then a
        /// tight pack), and `me.rank` is deliberately inflated past the row
        /// position to stand in for hidden handle-less/disabled devices — the
        /// heading must still print the ROW's rank.
        @Test func renderStandingLineBoards() async throws {
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
            func pack(scale: Int) -> [LeaderboardEntry] {
                zip(handles, points).enumerated().map { i, pair in
                    .init(rank: i + 1, handle: pair.0, points: pair.1 * scale,
                          catches: max(1, pair.1 * scale / 30))
                }
            }
            func week(_ me: MyStanding?) -> LeaderboardResponse {
                LeaderboardResponse(entries: pack(scale: 1), me: me, window: "week",
                                    resetsAt: weekResetsAt, champions: nil,
                                    totalCatchers: handles.count)
            }
            /// iPhone 17 with the status bar and tab bar blocked out.
            func phone<V: View>(_ view: V) -> some View {
                VStack(spacing: 0) {
                    Color.black.frame(height: 62)
                    view
                    Color(white: 0.12).frame(height: 83)
                }
                .ignoresSafeArea()
            }
            func shoot<V: View>(_ view: V, _ name: String) async {
                await snapshot(phone(view), as: name, width: 402, height: 874)
            }

            // Week, mid-pack: row 11 (me.rank 13), 50 points behind #10.
            defaults.set("noah", forKey: SpotterHandle.storageKey)
            await shoot(board([.week: week(MyStanding(rank: 13, points: 95))],
                              selected: .week, container: container),
                        "standing_week_midpack")
            await shoot(board([.week: week(MyStanding(rank: 13, points: 95))],
                              selected: .week, container: container)
                          .dynamicTypeSize(.accessibility2),
                        "standing_week_midpack_a11y2")

            // Month, mid-pack: its own board (twice the week's points).
            let month = LeaderboardResponse(entries: pack(scale: 2), me: MyStanding(rank: 13, points: 190),
                                            window: "month", resetsAt: monthResetsAt,
                                            totalCatchers: handles.count)
            await shoot(board([.month: month], selected: .month, container: container),
                        "standing_month_midpack")

            // All time, #2 behind a whale: a big gap still shows (no cap).
            defaults.set("flydelta", forKey: SpotterHandle.storageKey)
            defaults.set("flydelta", forKey: SpotterHandle.confirmedKey)
            let all = LeaderboardResponse(entries: pack(scale: 6), me: MyStanding(rank: 2, points: 8160),
                                          window: "all", totalCatchers: handles.count)
            await shoot(board([.all: all], selected: .all, container: container),
                        "standing_all_bigGap")

            // #1 → "2,345 points ahead of @flydelta".
            defaults.set("chemtrails", forKey: SpotterHandle.storageKey)
            defaults.set("chemtrails", forKey: SpotterHandle.confirmedKey)
            await shoot(board([.week: week(MyStanding(rank: 1, points: 3705))],
                              selected: .week, container: container),
                        "standing_week_leading")

            // Handled (server-confirmed), nothing caught this week →
            // "You're not on the board yet" / "1 catch to get on the board".
            defaults.set("notlisted", forKey: SpotterHandle.storageKey)
            defaults.set("notlisted", forKey: SpotterHandle.confirmedKey)
            await shoot(board([.week: week(MyStanding(rank: 0, points: 0))],
                              selected: .week, container: container),
                        "standing_week_makeboard")

            // No handle → "not on the board yet" with the claim-a-handle hint.
            defaults.set(SpotterHandle.defaultPlaceholder, forKey: SpotterHandle.storageKey)
            await shoot(board([.week: week(MyStanding(rank: 14, points: 160))],
                              selected: .week, container: container),
                        "standing_week_nohandle")
            await shoot(board([.week: week(MyStanding(rank: 14, points: 160))],
                              selected: .week, container: container)
                          .dynamicTypeSize(.accessibility2),
                        "standing_week_nohandle_a11y2")

            // Old backend (no window key): "You're 11th" above the board, no goal.
            defaults.set("noah", forKey: SpotterHandle.storageKey)
            await shoot(NavigationStack {
                            LeaderboardScreen(_debugEntries: pack(scale: 6), me: MyStanding(rank: 13, points: 570))
                        }.modelContainer(container),
                        "standing_oldBackend")
            #expect(true)
        }

        /// The standing line on the two widths that matter: iPhone SE (375 ×
        /// 667, 20 pt status bar, 49 pt tab bar) and iPhone 16 (393 × 852,
        /// 59 / 83). Four states: week mid-pack, all time, #1, and handled but
        /// off the board. SE also gets accessibility3, where the prose must wrap,
        /// never truncate.
        @Test func renderStandingDeviceMatrix() async throws {
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
                           "heavywatcher", "dotbali", "jordan", "randy98", "noah", "rookie"]
            func pack(scale: Int) -> [LeaderboardEntry] {
                zip(handles, points).enumerated().map { i, pair in
                    .init(rank: i + 1, handle: pair.0, points: pair.1 * scale,
                          catches: max(1, pair.1 * scale / 30))
                }
            }
            let week = { (me: MyStanding) in
                LeaderboardResponse(entries: pack(scale: 1), me: me, window: "week",
                                    resetsAt: self.weekResetsAt, champions: nil,
                                    totalCatchers: handles.count)
            }
            struct Device { let name: String; let w: CGFloat; let h: CGFloat; let top: CGFloat; let bottom: CGFloat }
            let devices = [Device(name: "se", w: 375, h: 667, top: 20, bottom: 49),
                           Device(name: "16", w: 393, h: 852, top: 59, bottom: 83)]
            func shoot<V: View>(_ view: V, _ name: String, size: DynamicTypeSize = .large) async {
                for d in devices {
                    await snapshot(VStack(spacing: 0) {
                                       Color.black.frame(height: d.top)
                                       view.dynamicTypeSize(size)
                                       Color(white: 0.12).frame(height: d.bottom)
                                   }.ignoresSafeArea(),
                                   as: "standingD_\(name)_\(d.name)", width: d.w, height: d.h)
                }
            }

            defaults.set("noah", forKey: SpotterHandle.storageKey)
            defaults.set("noah", forKey: SpotterHandle.confirmedKey)
            let midpack = board([.week: week(MyStanding(rank: 13, points: 95))],
                                selected: .week, container: container)
            await shoot(midpack, "week")
            await shoot(midpack, "week_a11y3", size: .accessibility3)

            defaults.set("flydelta", forKey: SpotterHandle.storageKey)
            defaults.set("flydelta", forKey: SpotterHandle.confirmedKey)
            let all = LeaderboardResponse(entries: pack(scale: 6), me: MyStanding(rank: 2, points: 8160),
                                          window: "all", totalCatchers: handles.count)
            await shoot(board([.all: all], selected: .all, container: container), "alltime")

            defaults.set("chemtrails", forKey: SpotterHandle.storageKey)
            defaults.set("chemtrails", forKey: SpotterHandle.confirmedKey)
            await shoot(board([.week: week(MyStanding(rank: 1, points: 3705))],
                              selected: .week, container: container), "first")

            // A full 50-row board I'm under: points to make it.
            defaults.set("notlisted", forKey: SpotterHandle.storageKey)
            defaults.set("notlisted", forKey: SpotterHandle.confirmedKey)
            let full = (1...50).map { LeaderboardEntry(rank: $0, handle: "s\($0)", points: 400 - $0 * 5, catches: 3) }
            let offBoard = LeaderboardResponse(entries: full, me: MyStanding(rank: 63, points: 120),
                                               window: "week", resetsAt: weekResetsAt, champions: nil,
                                               totalCatchers: 70)
            await shoot(board([.week: offBoard], selected: .week, container: container), "offboard")
            #expect(true)
        }

        /// Profile hub with offline-cached weekly/monthly wins folded into the
        /// identity hero. Render every visibility combination so a visual pass
        /// covers the absent footer, both single-period layouts, and both periods.
        @Test func renderProfileChampionSummary() async throws {
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
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_no_wins")

            defaults.set(3, forKey: "tailspot.standing.weeklyWins")
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_weekly_only")

            defaults.set(0, forKey: "tailspot.standing.weeklyWins")
            defaults.set(2, forKey: "tailspot.standing.monthlyWins")
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_monthly_only")

            defaults.set(3, forKey: "tailspot.standing.weeklyWins")
            await snapshot(ProfileScreen().modelContainer(container), as: "profile_champion_summary_both")
            await snapshot(ProfileScreen().modelContainer(container).dynamicTypeSize(.accessibility2),
                           as: "profile_champion_summary_both_a11y2")
            #expect(true)
        }
    }
}
#endif
