//
//  PostHogSessionReplay.swift
//  Tailspot
//
//  Sets up PostHog iOS **session replay only**. Product events still flow
//  through our own SDK-free REST pipeline (Analytics.swift) — this is the
//  first third-party SDK in the app and it's here purely for screen
//  recordings, which have no REST path. To avoid double-counting, the SDK's
//  autocapture (lifecycle + screen views) is disabled; we never call
//  PostHogSDK.capture. distinct_id is aligned to the same anonymous device id
//  the REST events use, so a recording and its events resolve to one person.
//
//  Called once from TailspotApp.init (skipped under unit tests). No-op when
//  the PostHog key is absent — same key + key-name (PostHogAPIKey, Info.plist)
//  as the REST pipeline.
//

import Foundation
import os
import PostHog

enum PostHogSessionReplay {
    /// PostHog US ingestion host — matches the REST endpoint in Analytics.swift.
    private static let host = "https://us.i.posthog.com"

    static func start() {
        guard let key = Analytics.apiKey, !key.isEmpty else {
            Log.analytics.notice("PostHog session replay: no PostHogAPIKey — disabled")
            return
        }

        let config = PostHogConfig(apiKey: key, host: host)
        config.sessionReplay = true
        // Wireframe mode (NOT screenshot): replays render structural wireframes,
        // never screen pixels — so the live camera / AR view is never recorded.
        // The camera view is ALSO explicitly masked via `.postHogMask()` in
        // ContentView, so it stays excluded even if screenshot mode is ever
        // turned on later.
        config.sessionReplayConfig.screenshotMode = false
        config.sessionReplayConfig.maskAllTextInputs = true
        // Events are sent by our REST Analytics pipeline; don't let the SDK
        // autocapture them too (it would double-count). Replay only.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false

        PostHogSDK.shared.setup(config)
        // Tie recordings to the same anonymous device id as the REST events.
        PostHogSDK.shared.identify(Analytics.distinctId())
        Log.analytics.notice("PostHog session replay: enabled")
    }
}
