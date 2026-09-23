//
//  TailspotApp.swift
//  Tailspot
//

import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import os

@main
struct TailspotApp: App {
    /// The SwiftData persistence container for `Catch` rows. Created
    /// once at app launch and injected into the view hierarchy via
    /// `.modelContainer(_:)`. Views read it via `@Environment(\.modelContext)`
    /// or query catches with `@Query`.
    ///
    /// If creation fails (corrupt store, schema-migration failure),
    /// we crash early — a broken persistence layer is not something
    /// the app can usefully recover from. A "real" launch in the
    /// field would surface a UI message; for v1 a fatalError suffices.
    let container: ModelContainer

    /// Upload queue — fires once per foreground transition (scenePhase →
    /// .active). Per-catch immediate upload is a follow-up (PLAN §9).
    private let uploader = CatchUploader()

    /// Durable handle sync — re-claims the locally-chosen handle on the
    /// backend until it's confirmed. Fires alongside the uploader on every
    /// foreground. Without this, a handle claim that failed once (offline /
    /// token-not-ready / cold-start) was lost forever and the user never
    /// appeared on the leaderboard (the babyjoda bug).
    private let handleSyncer = HandleSyncer()

    /// Reminder-tap → camera-toast channel. Owned here (the delegate is
    /// app-level), handed to the delegate in `init` and injected into the
    /// environment for `ContentView` to observe.
    private let streakToastRelay = StreakToastRelay()
    /// One Challenges model for the whole app (see ChallengesAppModel.make).
    /// `@State` in an App is how SwiftUI keeps one instance alive for the
    /// scene's lifetime; the property is read from `body` and the
    /// scene-phase handler.
    @State private var challenges = ChallengesAppModel.make()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.ui.notice("Tailspot launched")
        // The Tailspot backend is the only ADS-B source (OpenSky + the mock
        // source were removed in the 2026-06-21 cutover), so there's no
        // source default to register any more.
        do {
            container = try ModelContainer(for: Catch.self)
        } catch {
            fatalError("Failed to create ModelContainer for Catch: \(error)")
        }
        // Register MetricKit subscriber once at launch. The subscriber
        // lives as a singleton so MetricKit retains the weak reference correctly.
        MetricsSubscriber.shared.register()
        // Configure the PostHog SDK (session replay + the single analytics
        // pipeline — see Analytics.swift). No-op without a key. Skipped under
        // unit tests for the same reason as the register above.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            PostHogSessionReplay.start()
        }
        // Seed the Bold Text mirror for B612 Mono (custom fonts get no
        // automatic Bold Text adaptation — Brand.Font.mono maps every
        // weight to the Bold face while this is true) and keep it fresh
        // if the user flips the setting mid-session. System-text-style
        // tokens adapt on their own and don't consult this.
        Brand.Font.boldTextPreferred = UIAccessibility.isBoldTextEnabled
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.boldTextStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                Brand.Font.boldTextPreferred = UIAccessibility.isBoldTextEnabled
            }
        }
        // Streak reminders: the delegate must be set before launch finishes
        // or a cold-start tap and foreground delivery are both dropped by
        // iOS. It decides foreground presentation (silent on the camera,
        // banner elsewhere) and relays the tap line back to the view.
        StreakReminderCenter.shared.toastRelay = streakToastRelay
        UNUserNotificationCenter.current().delegate = StreakReminderCenter.shared
        // A timezone change moves "today" and the 18:00 target — recompute
        // the pending reminder against the new zone (frozen per-catch day
        // labels keep the streak history itself stable; Streaks.swift rule 1).
        let streakContainer = container
        NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await StreakReminderCenter.shared.sync(
                    context: streakContainer.mainContext)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            // RootView gates ContentView behind first-launch
            // onboarding (latched in @AppStorage). After the user
            // finishes onboarding once, RootView renders ContentView
            // directly on every subsequent launch.
            RootView()
                .modelContainer(container)
                .environment(streakToastRelay)
                // The app-wide Challenges model (phase 2). Sheets and
                // pushes inherit the environment from the presenting view,
                // so injecting it once here reaches the Profile tile, the
                // Leaders flag and strip, and every Challenges screen.
                .environment(challenges)
                // The app is locked to dark (Noah, 2026-07-10 polish
                // sweep): the Brand palette is a fixed dark HUD and every
                // light-mode rendering of it is a bug, not a mode.
                // `preferredColorScheme` here sets the WINDOW's style, so
                // onboarding, the main app, sheets/fullScreenCovers,
                // alerts/confirmationDialogs, and the share sheet all
                // inherit dark regardless of the device setting. The
                // light-mode compensations sprinkled through views
                // (`scrollContentBackground(.hidden)` + Brand backgrounds)
                // stay as belt-and-suspenders.
                .preferredColorScheme(.dark)
                // Challenge invite links — https://tailspot.app/c/CODE.
                // Explain-as-we-go: a universal link can reach the app two
                // ways. A COLD launch hands it to the scene as a user
                // activity (`NSUserActivityTypeBrowsingWeb`); a tap while
                // the app is already running arrives through `onOpenURL`.
                // SwiftUI routes most cases to `onOpenURL`, but not all of
                // them, so both are wired to the same handler — it's
                // idempotent (parking the same code twice is a no-op in
                // effect), and missing one of the two is the classic
                // "works from Notes, not from Messages on a cold start".
                // Anything that isn't an invite link is ignored, which is
                // what keeps this from swallowing future URL types.
                .onOpenURL { url in handleIncoming(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { handleIncoming(url) }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // Sync backend state on every foreground. Both steps are
                // idempotent and non-throwing; per-item failures are logged
                // and retried on the next foreground transition.
                let ctx = container.mainContext
                Task {
                    // Register ONCE up front so the handle sync and catch upload
                    // below can't race two POST /v1/devices calls on a fresh
                    // install (ensureRegistered short-circuits on the stored token
                    // thereafter). It also fires the one-time
                    // `Analytics.identify(serverId)` that ties this install to its
                    // canonical PostHog person. Errors here are non-fatal — each
                    // step re-attempts registration and aborts cleanly.
                    _ = try? await TailspotAccountClient().ensureRegistered()
                    // App-open analytics come from the PostHog SDK's lifecycle
                    // autocapture ("Application Opened", with $app_version /
                    // $app_build auto-attached) — we no longer fire a custom
                    // app_opened, so there's exactly one app-open event per open.
                    // Handle first: cheap, and it unblocks leaderboard visibility
                    // without waiting behind a catch backlog.
                    await handleSyncer.syncIfNeeded()
                    await uploader.uploadPending(context: ctx)
                    // Streak reminder re-plan on every foreground: repairs
                    // whatever the last run couldn't know (a day rolled over,
                    // permission changed in iOS Settings, a force-kill raced
                    // the post-catch sync). Cheap — one Hangar fetch + a pure
                    // decision — and idempotent like the two steps above.
                    await StreakReminderCenter.shared.sync(context: ctx)
                    // Challenges: config first (kill switch, min build),
                    // then my open + finished challenges, which also
                    // re-plans the local challenge reminders. Both are
                    // best-effort; the screens render their own error
                    // states when these fail.
                    await challenges.refreshConfig()
                    if challenges.isAvailable {
                        await challenges.refreshList()
                    }
                }
            }
        }
    }

    /// Parse an incoming URL as a challenge invite and park the code on
    /// the app-wide model. Everything after this — which screen to show,
    /// or which "no" to say — is `ChallengesModel.inviteRoute` and
    /// `ChallengeInviteRouter`; the App layer only decides whether the URL
    /// is ours at all.
    ///
    /// `challenge_invite_opened` is NOT fired here on the happy path: the
    /// join sheet already fires it with the challenge id and the
    /// joinability status once the preview comes back (spec §12, `via:
    /// universal_link`), and two events per link would double-count the
    /// funnel. The blocked routes fire it from the router, where they're
    /// the only signal that link ever existed.
    private func handleIncoming(_ url: URL) {
        guard let code = InviteCode.parse(url: url) else {
            Log.ui.notice("Ignoring URL that isn't a challenge invite")
            return
        }
        Task { await challenges.openInvite(code: code) }
    }
}
