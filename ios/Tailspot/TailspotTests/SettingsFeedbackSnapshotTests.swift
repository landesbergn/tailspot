//
//  SettingsFeedbackSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the Settings ABOUT rows (Rate Tailspot, Send
//  feedback) and the notification re-offer card. NOT an assertion test:
//  writes PNGs to /private/tmp/tailspot_snaps/w2-settings and passes.
//  Review the images after running.
//
//  The window is taller than a phone so the whole List (ABOUT sits at the
//  bottom) lands in one image; the a11y2 render needs more height still.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import UserNotifications
@testable import Tailspot

@MainActor
@Suite("Settings feedback rows snapshots (visual pass)", .serialized)
struct SettingsFeedbackSnapshotTests {

    private static let snapDir = URL(
        fileURLWithPath: "/private/tmp/tailspot_snaps/w2-settings", isDirectory: true)

    private func snapshot<V: View>(_ view: V, as name: String, height: CGFloat) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: height)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try? await Task.sleep(for: .seconds(0.4))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    @Test func renderSettingsWholeList() async {
        let defaults = UserDefaults.standard
        let keys = [SpotterHandle.storageKey, StreakReminders.enabledKey,
                    ChallengeReminderScheduler.enabledKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set("noah", forKey: SpotterHandle.storageKey)
        defaults.set(true, forKey: StreakReminders.enabledKey)
        defaults.set(true, forKey: ChallengeReminderScheduler.enabledKey)
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }

        var screen = SettingsScreen()
        screen._notifStatusOverride = .authorized
        await snapshot(NavigationStack { screen }, as: "settings_full_default", height: 1300)
        await snapshot(NavigationStack { screen }.dynamicTypeSize(.accessibility2),
                       as: "settings_full_a11y2", height: 2600)
        #expect(true)
    }

    /// The pre-prompt card: the first ask, and the re-offer to someone iOS
    /// denied (only the button label differs). Over a dark stand-in for the
    /// viewfinder.
    @Test func renderStreakAskCards() async {
        let variants: [(String, Int, String)] = [
            ("streak_ask_first", 1, "Notify me"),
            ("streak_reoffer_settings", 3, "Open Settings"),
        ]
        for (name, days, label) in variants {
            let card = ZStack {
                Color(white: 0.18).ignoresSafeArea()
                StreakAskCard(days: days, acceptLabel: label, onAccept: {}, onDecline: {})
            }
            await snapshot(card, as: "\(name)_default", height: 852)
            await snapshot(card.dynamicTypeSize(.accessibility2), as: "\(name)_a11y2", height: 852)
        }
        #expect(true)
    }
}
#endif
