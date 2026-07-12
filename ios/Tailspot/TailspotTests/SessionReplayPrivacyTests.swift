//
//  SessionReplayPrivacyTests.swift
//  TailspotTests
//
//  Pins the structural privacy guarantee for PostHog session replay
//  (GA gate, 2026-07-11): the live camera view must never reach PostHog.
//
//  Replay's screenshot mode captures via drawHierarchy(afterScreenUpdates:
//  false), which cannot read an AVCaptureVideoPreviewLayer's out-of-process
//  video surface — the camera region records as black. That guarantee only
//  holds while PreviewView is BACKED by AVCaptureVideoPreviewLayer
//  (`layerClass` override). If the preview is ever reimplemented as a
//  drawable pipeline — blitting camera frames into a UIImageView, CALayer
//  contents, or a Metal/CoreImage view — drawHierarchy WOULD capture those
//  pixels and users' camera frames would leak into replays.
//
//  A `.postHogMask()` is NOT the fallback: CameraPreview spans the whole
//  window, and PostHog redacts by drawing masked-view rects over the flat
//  screenshot, so a full-window mask blacks every replay frame (the 2026-06
//  all-black-replay bug — see ContentView + PostHogSessionReplay.swift).
//  If this test fails, redesign the replay privacy story before shipping.
//

import Testing
import AVFoundation
import UIKit
@testable import Tailspot

@Suite("Session-replay privacy")
struct SessionReplayPrivacyTests {

    @Test("Camera preview stays backed by AVCaptureVideoPreviewLayer (screenshot-proof)")
    func cameraPreviewIsGPUBacked() {
        // Class-level check only — instantiating PreviewView would spin up an
        // AVCaptureSession, which the simulator can't provide.
        #expect(PreviewView.layerClass == AVCaptureVideoPreviewLayer.self,
                "PreviewView must keep AVCaptureVideoPreviewLayer as its backing layer: session-replay screenshots (drawHierarchy) can't read that surface, which is what keeps live camera frames out of PostHog. See PostHogSessionReplay.swift.")
    }
}
