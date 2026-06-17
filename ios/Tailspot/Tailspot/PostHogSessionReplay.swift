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
        // On iOS this flag masks ALL text (labels, not just editable fields), so
        // leaving it on blacks out every label in the replay. Tailspot's on-screen
        // text is non-sensitive game data (callsigns, models, dates, place names,
        // handles), so unmask it for legible recordings. If a genuinely sensitive
        // field ever appears, mask that ONE view with `.postHogMask()` rather than
        // re-masking everything (and never a full-screen view — that blacks the
        // whole window; see the camera note in ContentView).
        config.sessionReplayConfig.maskAllTextInputs = false
        config.sessionReplayConfig.maskAllImages = false
        // Replay reliability. Snapshots ride the normal event queue, which only
        // flushes at flushAt (default 20) events, the flushIntervalSeconds (30s)
        // timer, or on app background. A short session (a few seconds, well under
        // 20 snapshots) that we DON'T background-flush is lost on next launch —
        // which is why only ~1 in N sessions was producing a recording.
        //   - flushAt = 1 sends each snapshot immediately, so nothing is stranded
        //     in the buffer when the app closes.
        //   - lifecycle events back ON: the SDK needs app-state awareness to draw
        //     session boundaries and flush on background. (It emits a few extra
        //     "Application Opened/Backgrounded" events — distinct names from our
        //     REST `app_opened`, so no double-count of our funnels.)
        config.flushAt = 1
        config.captureApplicationLifecycleEvents = true
        // Still suppress the SDK's screen-view autocapture — our screens aren't
        // UIViewControllers it can name, and we don't want $screen noise.
        config.captureScreenViews = false
        // Verbose SDK logging in dev builds only, so a still-flaky capture can be
        // diagnosed from the Xcode console instead of guessing. Never in Release.
        #if DEBUG
        config.debug = true
        #endif

        PostHogSDK.shared.setup(config)
        // Tie recordings to the same anonymous device id as the REST events.
        PostHogSDK.shared.identify(Analytics.distinctId())
        Log.analytics.notice("PostHog session replay: enabled")
    }
}
