//
//  TailspotApp.swift
//  Tailspot
//

import SwiftUI
import SwiftData
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
        // PostHog session replay (recordings only — product events still go
        // through the SDK-free REST Analytics pipeline). No-op without a key.
        // Skipped under unit tests for the same reason as the register above.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            PostHogSessionReplay.start()
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
                }
            }
        }
    }
}
