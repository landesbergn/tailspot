//
//  NotificationCoordinator.swift
//  Tailspot
//
//  UNUserNotificationCenter delegate + the app→view toast relay for streak
//  reminders (streaks plan U4 / KTD6).
//
//  Why this exists: without a delegate installed before launch finishes,
//  iOS silently suppresses a local notification delivered while the app is
//  foregrounded, and tap responses are dropped entirely. The delegate is
//  assigned in `TailspotApp.init()`.
//
//  Why the relay: the camera root's toasts are private `ContentView` state,
//  so the delegate (app-level) hands the streak line across the boundary via
//  a small `@Observable` object injected through the environment. ContentView
//  folds it into the shared one-toast-at-a-time banner state.
//

import Foundation
import Observation
import UserNotifications
import os

/// App→view channel for the reminder-tap streak line. `ContentView` observes
/// it, shows the line as a toast, and clears it.
@Observable
final class StreakToastRelay {
    var streakLine: String?
}

final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private let relay: StreakToastRelay

    init(relay: StreakToastRelay) {
        self.relay = relay
        super.init()
    }

    /// Foreground delivery: show the banner + sound anyway (the reminder is
    /// timely; suppressing it in-app would silently eat the nudge).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tap: land on the camera root (the app's root state — nothing to
    /// navigate) and surface the streak line as a toast so the payoff is
    /// visible over the viewfinder.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.identifier == StreakReminders.requestIdentifier else { return }
        let streak = response.notification.request.content.userInfo["streak"] as? Int
        await MainActor.run {
            if let streak {
                relay.streakLine = "\(streak)-day streak — catch one before midnight"
            } else {
                relay.streakLine = "Streak at risk — catch one before midnight"
            }
            Analytics.capture(StreakReminders.openedEvent, streak.map { ["streak": .int($0)] } ?? [:])
            Log.ui.info("StreakReminders: reminder tapped, streak \(streak ?? -1, privacy: .public)")
        }
    }
}
