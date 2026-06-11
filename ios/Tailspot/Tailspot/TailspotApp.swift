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

    @Environment(\.scenePhase) private var scenePhase

    init() {
        Log.ui.notice("Tailspot launched")
        do {
            container = try ModelContainer(for: Catch.self)
        } catch {
            fatalError("Failed to create ModelContainer for Catch: \(error)")
        }
        // Register MetricKit subscriber once at launch. The subscriber
        // lives as a singleton so MetricKit retains the weak reference correctly.
        MetricsSubscriber.shared.register()
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
                // Upload any pending catches when the app comes to the
                // foreground. `uploadPending` is idempotent and non-throwing
                // at the top level; failures per-row are logged and retried
                // on the next foreground transition.
                let ctx = container.mainContext
                Task { await uploader.uploadPending(context: ctx) }

                // app_opened fires on every foreground activation (cold launch
                // and background→foreground). Version + build let us correlate
                // events to the exact binary.
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
                Analytics.capture("app_opened", [
                    "app_version": .string(version),
                    "app_build":   .string(build),
                ])
            }
        }
    }
}
