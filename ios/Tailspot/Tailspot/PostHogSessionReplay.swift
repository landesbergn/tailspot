//
//  PostHogSessionReplay.swift
//  Tailspot
//
//  Sets up the PostHog iOS SDK. Its original and primary job is **session
//  replay** (screen recordings have no REST path). Most product events still
//  flow through our own SDK-free REST pipeline (Analytics.swift), but we now
//  also call PostHogSDK.capture directly for things the REST path can't express
//  today — notably person-property `$set` (e.g. the claimed handle, via
//  `capture(_:userProperties:)`). The SDK's autocapture (lifecycle + screen
//  views) stays disabled so it never double-counts the REST funnels, and the
//  SDK's distinct_id is aligned to the same anonymous device id the REST events
//  use, so recordings, REST events, and SDK events resolve to one person.
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

    /// Capture a product event through the SDK and optionally `$set` person
    /// properties on the profile. Used sparingly — most product events go via
    /// the SDK-free REST pipeline (Analytics.swift); this is for what the REST
    /// path can't express today, like setting the claimed handle as a person
    /// property. No-op when the PostHog key is absent (same guard as `start()`),
    /// so keyless / CI / unit-test builds never touch the SDK.
    static func capture(_ event: String, userProperties: [String: String] = [:]) {
        guard Analytics.apiKey?.isEmpty == false else { return }
        PostHogSDK.shared.capture(event, properties: [:], userProperties: userProperties)
    }

    /// Tie the SDK (session replay + SDK-captured events) to `distinctId` — the
    /// canonical, server-minted device id. No-op when the PostHog key is absent.
    ///
    /// PostHog's `identify()` is meant to be called once; once the SDK has an
    /// identified distinct_id it will NOT switch to a different one. The goal is
    /// therefore to make the SDK's *first* identify use the canonical server id —
    /// either at launch for an already-registered user (`start()`), or right
    /// after the handle is claimed for a first-time user (registration is awaited
    /// there). Calling it again later with the same id is a harmless no-op.
    static func identify(_ distinctId: String) {
        guard Analytics.apiKey?.isEmpty == false, !distinctId.isEmpty else { return }
        PostHogSDK.shared.identify(distinctId)
    }

    static func start() {
        guard let key = Analytics.apiKey, !key.isEmpty else {
            Log.analytics.notice("PostHog session replay: no PostHogAPIKey — disabled")
            return
        }

        // `projectToken:` replaces the deprecated `apiKey:` label (posthog-ios
        // ≥ 3.x); same value, just the renamed initializer.
        let config = PostHogConfig(projectToken: key, host: host)
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
        // Identify ONLY a returning, registered user — one who already has a
        // canonical (server-minted, keychain-backed) device id AND a claimed
        // handle. We read the id with `DeviceID.currentIfPresent()` (NEVER
        // mints), so a first launch no longer pins the SDK to a throwaway local
        // id that registration immediately replaces — the bug that fragmented
        // one device into two persons (an identified SDK profile + an anonymous
        // REST profile). A first-time user is identified after the handle is
        // claimed (where registration is awaited), so the SDK's first identify
        // still lands on the server id. See AnalyticsIdentity.
        let handle = UserDefaults.standard.string(forKey: SpotterHandle.storageKey)
        let hasHandle = AnalyticsIdentity.isClaimedHandle(handle, placeholder: SpotterHandle.defaultPlaceholder)
        if let id = AnalyticsIdentity.launchIdentity(deviceId: DeviceID.currentIfPresent(),
                                                     hasClaimedHandle: hasHandle) {
            PostHogSDK.shared.identify(id)
        }
        Log.analytics.notice("PostHog session replay: enabled")
    }
}
