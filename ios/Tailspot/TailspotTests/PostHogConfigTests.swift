//
//  PostHogConfigTests.swift
//  TailspotTests
//
//  Pins the deliberate parts of the PostHog SDK configuration
//  (PostHogSessionReplay.makeConfig). Two postures live here:
//
//  - Replay/privacy (GA gate, 2026-07-11): screenshot mode ON (wireframe
//    records blank screens on SwiftUI), text + images UNMASKED (masking is
//    scoped per-view via .postHogMask(); a blanket mask blacks the replay).
//    The camera-never-recorded guarantee is structural and pinned separately
//    by SessionReplayPrivacyTests.
//
//  - Flush batching (v1.1 battery item R9, 2026-08-25): flushAt 10 / 30 s
//    timer, NOT the old flushAt = 1 — per-event flushing woke the radio for
//    a POST on every event and replay snapshot for the whole session. Safe
//    on the pinned SDK (3.60.1) because both queues are file-backed and the
//    SDK force-flushes on background; see the comment in makeConfig before
//    changing these numbers.
//

import Testing
import PostHog
@testable import Tailspot

@Suite("PostHog SDK configuration")
struct PostHogConfigTests {

    @Test("Flush is batched, never per-event")
    func flushBatching() {
        let config = PostHogSessionReplay.makeConfig(projectToken: "test-token")
        #expect(config.flushAt == 10,
                "flushAt must stay batched (10 — Noah's middle-ground call, 2026-08-25). flushAt = 1 POSTs per event + per replay snapshot — the 2026-07-17 audit's biggest deferred battery drain. If replay capture regresses, verify against PostHog live data before lowering this.")
        #expect(config.flushIntervalSeconds == 30)
    }

    @Test("Replay + privacy posture")
    func replayPosture() {
        let config = PostHogSessionReplay.makeConfig(projectToken: "test-token")
        #expect(config.sessionReplay)
        #expect(config.sessionReplayConfig.screenshotMode,
                "Wireframe mode records blank screens on SwiftUI (posthog-ios#408) — replay requires screenshot mode.")
        #expect(!config.sessionReplayConfig.maskAllTextInputs)
        #expect(!config.sessionReplayConfig.maskAllImages,
                "Masking is scoped per-view (.catchPhotoReplayMask()); blanket masks black out the replay.")
        #expect(config.captureApplicationLifecycleEvents,
                "The SDK needs app-state awareness for session boundaries.")
        #expect(!config.captureScreenViews)
    }
}
