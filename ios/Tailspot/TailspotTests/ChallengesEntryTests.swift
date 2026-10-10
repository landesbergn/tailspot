//
//  ChallengesEntryTests.swift
//  TailspotTests
//
//  The entry points into Challenges that live on other screens: the
//  count badge on the Profile tile and the Leaders flag (its count and
//  label asserted here), and the three surfaces that host them — Profile,
//  the Leaders sheet, Settings — are
//  rendered with a fixture-backed ChallengesModel injected, in the
//  ProfileSettingsSnapshotTests hosted-window pattern, for the visual pass
//  (PNGs in /private/tmp/tailspot_snaps). The hosted tests assert only the
//  navigation title: toolbar and row text is not reliably in the UIKit view
//  tree on CI's simulator runtime.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@Suite("Challenges entry count")
struct ChallengesEntryCountTests {

    @Test func flagLabelSaysHowManyAreActive() {
        #expect(ChallengesFlagButton.accessibilityLabel(active: 2, hubSeen: true) == "Challenges, 2 active")
        #expect(ChallengesFlagButton.accessibilityLabel(active: 0, hubSeen: false) == "Challenges, new")
        #expect(ChallengesFlagButton.accessibilityLabel(active: 0, hubSeen: true) == "Challenges")
    }

    @Test func countWinsThenDiscoveryDotThenNothing() {
        #expect(ChallengeEntryIndicator(active: 2, hubSeen: false) == .count(2))
        #expect(ChallengeEntryIndicator(active: 2, hubSeen: true) == .count(2))
        #expect(ChallengeEntryIndicator(active: 0, hubSeen: false) == .discovery)
        #expect(ChallengeEntryIndicator(active: 0, hubSeen: true) == ChallengeEntryIndicator.none)
    }

    @Test func profileTileValueSaysNewUntilHubOpened() {
        #expect(ChallengeEntryIndicator.count(3).accessibilityValue == "3 active")
        #expect(ChallengeEntryIndicator.discovery.accessibilityValue == "new")
        #expect(ChallengeEntryIndicator.none.accessibilityValue == "")
    }

    /// The catch screen's Leaders dot: discovery only. On for a fresh user
    /// with the feature available; off once the hub is opened, off while in
    /// any challenge (no counts on the AR view), off before config arrives.
    @MainActor
    @Test func barDotIsDiscoveryOnly() async {
        func model(_ name: String, state: FixtureChallengesService.State) -> ChallengesModel {
            let defaults = UserDefaults(suiteName: "ChallengesBarDot.\(name)")!
            defaults.removePersistentDomain(forName: "ChallengesBarDot.\(name)")
            return ChallengesModel(service: FixtureChallengesService(state: state),
                                   currentBuild: Int.max, defaults: defaults)
        }

        let fresh = model("fresh", state: ChallengeFixtures.emptyState())
        #expect(!fresh.showsBarDiscoveryDot)  // config not fetched yet
        await fresh.refreshConfig()
        await fresh.refreshList()
        #expect(fresh.showsBarDiscoveryDot)
        fresh.markHubSeen()
        #expect(!fresh.showsBarDiscoveryDot)

        let busy = model("busy", state: ChallengeFixtures.demoState())
        await busy.refreshConfig()
        await busy.refreshList()
        #expect(busy.activeCount > 0)
        #expect(!busy.showsBarDiscoveryDot)
    }

    @MainActor
    @Test func activeCountIsLivePlusUpcoming() async {
        let defaults = UserDefaults(suiteName: "ChallengesEntryCountTests")!
        defaults.removePersistentDomain(forName: "ChallengesEntryCountTests")
        let model = ChallengesModel(service: FixtureChallengesService(), currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.activeCount == model.live.count + model.upcoming.count)
        #expect(model.activeCount > 0)
        #expect(model.history.allSatisfy { h in !model.open.contains { $0.id == h.id } })
    }
}

@MainActor
@Suite("Challenges entry points (visual pass)", .serialized)
struct ChallengesEntrySnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private func host<V: View>(_ view: V, snapshotAs name: String) -> UIWindow {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let hostVC = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = hostVC
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        hostVC.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            hostVC.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        return window
    }

    private func titles(in view: UIView) -> Set<String> {
        var out = Set<String>()
        func walk(_ v: UIView) {
            if let label = v as? UILabel, let t = label.text, !t.isEmpty { out.insert(t) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    private func container() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let c = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(c)
        return c
    }

    /// A model already holding the demo world, with the hub never opened
    /// (discovery dot on) and the config marked available.
    private func demoModel(hubSeen: Bool) async -> ChallengesModel {
        let defaults = UserDefaults(suiteName: "ChallengesEntrySnapshotTests.\(hubSeen)")!
        defaults.removePersistentDomain(forName: "ChallengesEntrySnapshotTests.\(hubSeen)")
        let model = ChallengesModel(service: FixtureChallengesService(), currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        if hubSeen { model.markHubSeen() }
        return model
    }

    @Test func profileTileShowsLiveHeadline() async throws {
        let model = await demoModel(hubSeen: true)
        let window = host(ProfileScreen().modelContainer(try container()).environment(model),
                          snapshotAs: "challenges_entry_profile_live")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Profile"))
    }

    /// A user who has never opened Challenges and is in none: the tile
    /// carries the discovery dot (no count to show).
    @Test func profileTileShowsDiscoveryDotOnFirstRun() async throws {
        let defaults = UserDefaults(suiteName: "ChallengesEntrySnapshotTests.profileCold")!
        defaults.removePersistentDomain(forName: "ChallengesEntrySnapshotTests.profileCold")
        let model = ChallengesModel(service: FixtureChallengesService(state: ChallengeFixtures.emptyState()),
                                    currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        #expect(ChallengeEntryIndicator(active: model.activeCount, hubSeen: model.hubSeen) == .discovery)
        let window = host(ProfileScreen().modelContainer(try container()).environment(model),
                          snapshotAs: "challenges_entry_profile_first_run")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Profile"))
    }

    /// The catch screen with a fresh Challenges user: the bottom bar's
    /// Leaders chip carries the discovery dot. PNG only (the simulator has
    /// no camera, so the AR view behind the bar is its fallback).
    @Test func catchScreenLeadersShowsDiscoveryDot() async throws {
        let defaults = UserDefaults(suiteName: "ChallengesEntrySnapshotTests.catchScreen")!
        defaults.removePersistentDomain(forName: "ChallengesEntrySnapshotTests.catchScreen")
        let model = ChallengesModel(service: FixtureChallengesService(state: ChallengeFixtures.emptyState()),
                                    currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.showsBarDiscoveryDot)
        let window = host(ContentView()
                            .modelContainer(try container())
                            .environment(StreakToastRelay())
                            .environment(model),
                          snapshotAs: "challenges_entry_catch_screen_dot")
        defer { window.isHidden = true }
    }

    @Test func leadersSheetShowsFlagWithCount() async throws {
        let model = await demoModel(hubSeen: false)
        let entries = [
            LeaderboardEntry(rank: 1, handle: "skykid", points: 4210, catches: 61),
            LeaderboardEntry(rank: 2, handle: "noah", points: 2755, catches: 43),
            LeaderboardEntry(rank: 3, handle: "contrail", points: 1980, catches: 35),
        ]
        let screen = LeaderboardScreen(
            _debugWindows: [.week: LeaderboardResponse(entries: entries, me: MyStanding(rank: 2, points: 2755), window: "week")]
        )
        let window = host(LeadersSheet(screen: screen).modelContainer(try container()).environment(model),
                          snapshotAs: "challenges_entry_leaders_count")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Leaderboard"))
    }

    @Test func leadersSheetColdStateHasNoCount() async throws {
        let defaults = UserDefaults(suiteName: "ChallengesEntrySnapshotTests.cold")!
        defaults.removePersistentDomain(forName: "ChallengesEntrySnapshotTests.cold")
        let model = ChallengesModel(service: FixtureChallengesService(state: ChallengeFixtures.emptyState()),
                                    currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.headline == .none)
        #expect(model.activeCount == 0)
        let window = host(LeadersSheet().modelContainer(try container()).environment(model),
                          snapshotAs: "challenges_entry_leaders_cold")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Leaderboard"))
    }

    @Test func settingsShowsChallengeRemindersToggle() throws {
        let window = host(NavigationStack { SettingsScreen() }.modelContainer(try container()),
                          snapshotAs: "challenges_entry_settings_toggle")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Settings"))
    }
}
#endif
