//
//  LeadersSheetSnapshotTests.swift
//  TailspotTests
//
//  Tests for the Leaderboard as a ROOT sheet (the bottom-bar Leaders button,
//  2026-09-15 navigation change) and the `PrimarySheet` enum that drives
//  the catch screen's single `.sheet(item:)`.
//
//  Two kinds of test here. The hosted-window tests ASSERT: they mount the
//  sheet in a real UIWindow (the ProfileSettingsSnapshotTests technique —
//  List/NavigationStack can't render under ImageRenderer) and walk the
//  UIKit hierarchy for the chrome the root presentation must add (Done)
//  and the screen it must show (Leaderboard). They also write a PNG to
//  /private/tmp/tailspot_snaps for the visual pass. The enum test pins the
//  `Identifiable` contract `.sheet(item:)` depends on.
//

#if DEBUG
import Testing
import SwiftUI
import SwiftData
import UIKit
@testable import Tailspot

@MainActor
@Suite("Leaders sheet (root presentation)", .serialized)
struct LeadersSheetSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// Host `view` in a real window, let the NavigationStack lay out, write
    /// a PNG, and return the window so callers can inspect the hierarchy.
    private func host<V: View>(_ view: V, snapshotAs name: String) -> UIWindow {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let hostVC = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = hostVC
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        hostVC.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            hostVC.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        return window
    }

    /// Every visible string in the hierarchy: UILabel text plus accessibility
    /// labels (SwiftUI toolbar buttons expose their title through the
    /// latter). Good enough to prove "Done" and "Leaderboard" are on screen
    /// without coupling to SwiftUI's private view classes.
    private func visibleStrings(in view: UIView) -> Set<String> {
        var out = Set<String>()
        func walk(_ v: UIView) {
            if let label = v as? UILabel, let t = label.text, !t.isEmpty { out.insert(t) }
            if let a = v.accessibilityLabel, !a.isEmpty { out.insert(a) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }

    private func emptyContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        return container
    }

    /// The root-sheet wrapper adds a Done button and shows the Leaderboard
    /// title. The no-arg LeaderboardScreen fetches on appear, so the body
    /// renders the loading state — the chrome is what this pins.
    @Test func rootSheetShowsDoneAndLeaderboard() throws {
        let container = try emptyContainer()
        let window = host(LeadersSheet().modelContainer(container), snapshotAs: "leaders_sheet_root")
        defer { window.isHidden = true }
        let strings = visibleStrings(in: window)
        #expect(strings.contains("Done"), "root presentation must add a Done button: \(strings)")
        #expect(strings.contains("Leaderboard"), "the wrapped screen must keep its title: \(strings)")
    }

    /// `.sheet(item:)` keys the presentation on `id`; the three cases must
    /// stay distinct and stable (they are also the wire form nothing else
    /// reads yet, but the raw value is what a future deep link would map).
    @Test func primarySheetIdsAreDistinctAndStable() {
        let all: [PrimarySheet] = [.hangar, .profile, .leaders]
        #expect(Set(all.map(\.id)).count == 3)
        #expect(PrimarySheet.hangar.id == "hangar")
        #expect(PrimarySheet.profile.id == "profile")
        #expect(PrimarySheet.leaders.id == "leaders")
    }
}
#endif
