//
//  ChallengesEntryTests.swift
//  TailspotTests
//
//  The entry points into Challenges that live on other screens: the
//  Profile tile subtitle and the Leaders strip share one pure copy
//  function (asserted here for every headline case), and the three
//  surfaces that host them — Profile, the Leaders sheet, Settings — are
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

@Suite("Challenges entry copy")
struct ChallengesEntryCopyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func summary(name: String, startsIn: TimeInterval, length: TimeInterval,
                         status: ChallengeStatus, myResult: ChallengeMyResult? = nil) -> ChallengeSummary {
        ChallengeFixtures.summary(
            id: "x", name: name, creator: "eli", code: "K7M4QD2X",
            startsAt: now.addingTimeInterval(startsIn), endsAt: now.addingTimeInterval(startsIn + length),
            preset: "24h", status: status, participantCount: 3, myResult: myResult)
    }

    @Test func coldStateSaysRaceAFriend() {
        let line = ChallengesEntryCopy.line(for: .none, now: now)
        #expect(line.state == nil)
        #expect(line.detail == "Race a friend")
        #expect(ChallengesEntryCopy.challengeId(for: .none) == nil)
    }

    @Test func liveLineCarriesNamePlacementAndCountdown() {
        let s = summary(name: "Weekend Flyoff", startsIn: -3600, length: 3600 + 48 * 60,
                        status: .live, myResult: ChallengeMyResult(placement: 2, points: 380, catches: 11))
        let line = ChallengesEntryCopy.line(for: .live(s), now: now)
        #expect(line.state == "IN FLIGHT")
        #expect(line.detail == "Weekend Flyoff · 2nd · 48M LEFT")
        #expect(ChallengesEntryCopy.challengeId(for: .live(s)) == "x")
    }

    @Test func liveLineWithoutMyResultSkipsPlacement() {
        let s = summary(name: "Weekend Flyoff", startsIn: -3600, length: 3600 + 90 * 60, status: .live)
        #expect(ChallengesEntryCopy.line(for: .live(s), now: now).detail == "Weekend Flyoff · 1H 30M LEFT")
    }

    @Test func liveLineUsesCachedDetailStandingWhenRowHasNone() {
        let s = summary(name: "Weekend Flyoff", startsIn: -3600, length: 3600 + 90 * 60, status: .live)
        let me = ChallengeMyResult(placement: 3, points: 120, catches: 4)
        #expect(ChallengesEntryCopy.line(for: .live(s), now: now, me: me).detail == "Weekend Flyoff · 3rd · 1H 30M LEFT")
    }

    @Test func upcomingLineSaysOnDeckWithStartsIn() {
        let s = summary(name: "Sunday Circuit", startsIn: 3 * 3600, length: 86_400, status: .upcoming)
        let line = ChallengesEntryCopy.line(for: .upcoming(s), now: now)
        #expect(line.state == "ON DECK")
        #expect(line.detail == "Sunday Circuit · STARTS IN 3H")
    }

    @Test func resultsReadyLinePointsAtResults() {
        let s = summary(name: "Golden Hour", startsIn: -7200, length: 3600, status: .finished,
                        myResult: ChallengeMyResult(placement: 1, points: 620, catches: 9))
        let line = ChallengesEntryCopy.line(for: .resultsReady(s), now: now)
        #expect(line.state == "FINISHED")
        #expect(line.detail == "Golden Hour · see results")
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

    @Test func leadersSheetShowsFlagWithDotAndStrip() async throws {
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
                          snapshotAs: "challenges_entry_leaders_strip")
        defer { window.isHidden = true }
        #expect(titles(in: window).contains("Leaderboard"))
    }

    @Test func leadersSheetColdStateHasNoStrip() async throws {
        let defaults = UserDefaults(suiteName: "ChallengesEntrySnapshotTests.cold")!
        defaults.removePersistentDomain(forName: "ChallengesEntrySnapshotTests.cold")
        let model = ChallengesModel(service: FixtureChallengesService(state: ChallengeFixtures.emptyState()),
                                    currentBuild: Int.max, defaults: defaults)
        await model.refreshConfig()
        await model.refreshList()
        #expect(model.headline == .none)
        #expect(ChallengesEntryCopy.challengeId(for: model.headline) == nil)
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
