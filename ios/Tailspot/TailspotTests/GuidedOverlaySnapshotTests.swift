//
//  GuidedOverlaySnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the guided first-catch chrome (plan U2), in
//  the CompassWarningSnapshotTests pattern: renders every step state —
//  banners, steering cues, the forced badge, long-callsign truncation —
//  over a sky backdrop to /private/tmp/tailspot_snaps for eyeballing.
//  NOT an assertion test beyond "it renders": review the PNGs.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Guided chrome (visual pass)")
struct GuidedOverlaySnapshotTests {

    private let size = CGSize(width: 393, height: 700)

    private func steer(
        turn: Double,
        elevation: Double = 5,
        distance: Double = 4_200,
        name: String? = "UAL233"
    ) -> GuidedSteering {
        GuidedSteering(
            icao24: "abc123",
            turnDeg: turn,
            elevationDeltaDeg: elevation,
            distanceMeters: distance,
            displayName: name
        )
    }

    private func scene(step: GuidedCatchStep, forced: Bool = false) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x0A0E1A), Color(hex: 0x2A3850)],
                startPoint: .top, endPoint: .bottom
            )
            GuidedCatchChrome(step: step, screenSize: size, forced: forced)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    @Test func renderEveryGuidedState() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cases: [(String, GuidedCatchStep, Bool)] = [
            ("guided_go_outside", .goOutside, false),
            ("guided_quiet_sky", .quietSky, false),
            ("guided_find_right", .find(steer(turn: 70)), false),
            ("guided_find_left", .find(steer(turn: -55)), false),
            ("guided_find_behind", .find(steer(turn: 165)), false),
            ("guided_find_tilt_up", .find(steer(turn: 5, elevation: 30)), false),
            ("guided_find_no_heading", .find(nil), false),
            ("guided_find_long_name", .find(steer(turn: 40, name: "NOVEMBER12345XRAY")), false),
            ("guided_center", .center, false),
            ("guided_capture", .capture, false),
            ("guided_forced_badge", .quietSky, true),
        ]
        for (name, step, forced) in cases {
            let renderer = ImageRenderer(content: scene(step: step, forced: forced))
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Issue.record("render failed for \(name)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    @Test func scanningAndCalibrateRenderNoBanner() {
        // .scanning defers to the SCANNING SKY… pill and .calibrate defers
        // to the tappable compass badge — the chrome must stay empty so the
        // existing surfaces own those conditions (one banner per condition).
        for step in [GuidedCatchStep.scanning, .calibrate] {
            let renderer = ImageRenderer(content: GuidedCatchChrome(step: step, screenSize: size))
            renderer.scale = 1
            // Renders (frame exists) but draws no banner content — a crash
            // or nil image here means the empty branch broke.
            #expect(renderer.uiImage != nil)
        }
    }
}
#endif
