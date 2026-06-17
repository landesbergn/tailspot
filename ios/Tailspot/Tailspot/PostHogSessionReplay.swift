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
        // Screenshot mode (NOT wireframe). PostHog's wireframe mode rebuilds the
        // replay from the UIKit view hierarchy, which a SwiftUI app on Xcode 26 /
        // iOS 26 doesn't expose the way it expects — SwiftUI now backs views with
        // sublayers instead of subviews, so wireframe traversal records blank
        // screens (posthog-ios#408). Declarative UI (SwiftUI, like Compose on
        // Android) therefore *requires* screenshot mode to record anything usable.
        // Privacy is preserved by masking instead of by mode: the live camera /
        // AR preview is explicitly excluded via `.postHogMask()` in ContentView
        // (the AR overlays layered on top still record), and text inputs are
        // masked below. Aircraft card art isn't sensitive, so images stay visible
        // for useful recordings.
        config.sessionReplayConfig.screenshotMode = true
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = false
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
