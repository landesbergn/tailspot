//
//  OnboardingSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the onboarding re-do (PLAN §9 #3 phase 2).
//  Renders every onboarding step and every permission-recovery variant to
//  PNGs via ImageRenderer so the layout can be eyeballed off-device.
//  NOT an assertion test: it writes images to /private/tmp/tailspot_snaps
//  and passes. Review the PNGs after running.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Onboarding snapshots (visual pass)")
struct OnboardingSnapshotTests {

    private let screen = CGSize(width: 393, height: 852)
    private let smallScreen = CGSize(width: 375, height: 667)   // SE-class height

    private func write(_ view: some View, _ name: String) {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.uiImage, let png = image.pngData() {
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    @Test func renderOnboardingSteps() {
        for step in 0...3 {
            let view = OnboardingFlow(onFinish: {}, initialStep: step)
                ._snapshotScreen(size: screen)
            write(view, "onboarding_step\(step)_\(ActivationTelemetry.stepName(step))")
        }
        // The calibration step on an SE-class height — the class of device
        // that clipped the old fixed-VStack flow (issue #36).
        let view = OnboardingFlow(onFinish: {}, initialStep: 3)
            ._snapshotScreen(size: smallScreen)
        write(view, "onboarding_step3_calibration_se")
    }

    @Test func renderPermissionRecoveryVariants() {
        let variants: [(String, Bool, Bool)] = [
            ("camera", true, false),
            ("location", false, true),
            ("both", true, true),
        ]
        for (name, cam, loc) in variants {
            let view = ZStack {
                Brand.Color.bgPrimary
                PermissionRecoveryCard(cameraDenied: cam, locationDenied: loc)
            }
            .frame(width: screen.width, height: screen.height)
            write(view, "recovery_\(name)_denied")
        }
    }
}
#endif
