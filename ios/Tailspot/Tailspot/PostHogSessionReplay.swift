//
//  PostHogSessionReplay.swift
//  Tailspot
//
//  Configures the PostHog iOS SDK — `setup()` plus the launch-time identify.
//  The SDK is now the SINGLE analytics pipeline: session replay AND every
//  product event/identify go through it (capture/identify live in
//  Analytics.swift; this file owns one-time SDK configuration). Screen-view
//  autocapture stays off; application-lifecycle events stay ON because session
//  replay needs app-state awareness to flush reliably.
//
//  Called once from TailspotApp.init (skipped under unit tests). No-op when
//  the PostHog key is absent — same key + key-name (PostHogAPIKey, Info.plist)
//  as the rest of the analytics facade.
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

        PostHogSDK.shared.setup(makeConfig(projectToken: key))
        // Launch-time identify (self-heal): re-affiliate a returning, registered
        // user with their canonical person. The real first identify happens at
        // registration (TailspotAccountClient.ensureRegistered) and handle claim;
        // this only re-asserts the server id + re-`$set`s the handle on launch so
        // a profile missing the handle self-heals. We read the id with
        // `DeviceID.currentIfPresent()` (NEVER mints) and gate on a claimed
        // handle, so a genuine first launch doesn't identify before registration
        // establishes the canonical id. `identify` is idempotent (posthog-ios
        // dedupes an identical repeat), and for a device whose SDK is pinned to
        // a stale pre-#76 local id — where posthog-ios silently DROPS the
        // identify — the sink falls back to `$set`ting the handle on the pinned
        // person (see AnalyticsIdentity.identifyRoute).
        let handle = UserDefaults.standard.string(forKey: SpotterHandle.storageKey)
        let hasHandle = AnalyticsIdentity.isClaimedHandle(handle, placeholder: SpotterHandle.defaultPlaceholder)
        if let id = AnalyticsIdentity.launchIdentity(deviceId: DeviceID.currentIfPresent(),
                                                     hasClaimedHandle: hasHandle) {
            Analytics.identify(id, handle: hasHandle ? handle : nil)
        }
        Log.analytics.notice("PostHog session replay: enabled")
    }

    /// The one SDK configuration. Split from `start()` only so
    /// `PostHogConfigTests` can pin the replay/privacy/flush posture without
    /// touching the process-global `PostHogSDK.shared`.
    static func makeConfig(projectToken: String) -> PostHogConfig {
        // `projectToken:` replaces the deprecated `apiKey:` label (posthog-ios
        // ≥ 3.x); same value, just the renamed initializer.
        let config = PostHogConfig(projectToken: projectToken, host: host)
        config.sessionReplay = true
        // Screenshot mode (NOT wireframe). PostHog's wireframe mode rebuilds the
        // replay from the UIKit view hierarchy, which a SwiftUI app on Xcode 26 /
        // iOS 26 doesn't expose the way it expects — SwiftUI now backs views with
        // sublayers instead of subviews, so wireframe traversal records blank
        // screens (posthog-ios#408). Declarative UI (SwiftUI, like Compose on
        // Android) therefore *requires* screenshot mode to record anything usable.
        // Privacy in screenshot mode (GA posture, 2026-07-11):
        //   - The LIVE CAMERA VIEW records as black STRUCTURALLY: screenshot
        //     capture (drawHierarchy) cannot read AVCaptureVideoPreviewLayer's
        //     out-of-process video surface, so camera frames never reach
        //     PostHog. There is deliberately NO `.postHogMask()` on
        //     CameraPreview — it spans the whole window, and PostHog redacts by
        //     drawing masked-view rects over the flat screenshot, so a
        //     full-window mask blacks every replay frame (the 2026-06
        //     all-black-replay bug). The guarantee is pinned by
        //     SessionReplayPrivacyTests + the note in ContentView.
        //   - USER CATCH PHOTOS are masked at every ON-SCREEN render site
        //     via `.catchPhotoReplayMask()` (a scoped `.postHogMask()` —
        //     see CatchPhotoReplayMask.swift): RevealPhoto (reveal +
        //     SettledCatchCard hero, incl. the Hangar detail screen),
        //     CatchCardView's photo (card reveal / multi-catch / model-slot
        //     detail), and FocusThumbnail (Hangar list rows). Only the photo
        //     rect is redacted — the surrounding card/UI chrome still
        //     records. Planespotters stock photos (public airframe imagery,
        //     not user content) stay visible. The OFFSCREEN share render
        //     (`CatchShare.uiImage`) drops the mask structurally — the tag
        //     views ImageRenderer can't draw were masking shared cards with
        //     a yellow placeholder — which loses no privacy: those pixels
        //     never appear on screen, so replay can't capture them.
        //   - Text inputs are unmasked below (non-sensitive game data).
        config.sessionReplayConfig.screenshotMode = true
        // On iOS this flag masks ALL text (labels, not just editable fields), so
        // leaving it on blacks out every label in the replay. Tailspot's on-screen
        // text is non-sensitive game data (callsigns, models, dates, place names,
        // handles), so unmask it for legible recordings. If a genuinely sensitive
        // field ever appears, mask that ONE view with `.postHogMask()` rather than
        // re-masking everything (and never a full-screen view — that blacks the
        // whole window; see the camera note in ContentView).
        config.sessionReplayConfig.maskAllTextInputs = false
        // Keep false: images are masked SELECTIVELY (user catch photos carry a
        // scoped .postHogMask(); see the privacy note above). Blanket image
        // masking would also black out card art, badges, and icons — gutting
        // replay usefulness without adding privacy.
        config.sessionReplayConfig.maskAllImages = false
        // Flush BATCHED, not per-event (v1.1 battery item R9 — the 2026-07-17
        // audit's biggest deferred drain: flushAt = 1 woke the radio for a
        // network POST on every single event AND every replay snapshot, i.e.
        // continuously for the whole time the app was open). flushAt = 1 dates
        // from the 2026-06 replay-reliability fix, when short sessions were
        // losing recordings ("never hit a flush trigger"). On the SDK we pin
        // today (3.60.1, Package.resolved) batching no longer risks that:
        //   - Both queues — events (/batch) and replay snapshots (/snapshot,
        //     a separate queue since 3.x) — are FILE-BACKED on disk
        //     (PostHogFileBackedQueue): anything unsent when the app dies is
        //     sent on next launch, not lost.
        //   - The SDK force-flushes both queues on didEnterBackground,
        //     unconditionally (independent of the lifecycle-events flag), so
        //     a normally-closed session ships before suspension.
        //   - Remaining loss window: killed mid-session and NEVER relaunched.
        // So: flushAt 10 events / 30 s timer. 10 is Noah's middle-ground call
        // (2026-08-25) over the SDK-default 20: battery isn't a live complaint,
        // so bias toward a smaller crash-loss window and fresher live data —
        // with replay snapshotting at ~1/s that's a POST roughly every 10 s,
        // still ~10× fewer radio wakes than the old per-event flushAt = 1.
        // Posture pinned by PostHogConfigTests. If recordings go missing
        // again, check PostHog live data FIRST (whole sessions can be absent
        // for other reasons — see the field-debugging notes) before touching
        // these numbers.
        config.flushAt = 10
        config.flushIntervalSeconds = 30
        // Lifecycle events stay ON: the SDK needs app-state awareness to draw
        // session boundaries. (It emits a few extra "Application
        // Opened/Backgrounded" events — distinct names from our `app_opened`,
        // so no double-count of our funnels.)
        config.captureApplicationLifecycleEvents = true
        // Still suppress the SDK's screen-view autocapture — our screens aren't
        // UIViewControllers it can name, and we don't want $screen noise.
        config.captureScreenViews = false
        // Verbose SDK logging in dev builds only, so a still-flaky capture can be
        // diagnosed from the Xcode console instead of guessing. Never in Release.
        #if DEBUG
        config.debug = true
        #endif

        return config
    }
}
