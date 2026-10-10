//
//  CompassWarningSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the LOUD compass-caution banner
//  (TailCardSnapshotTests pattern): renders the banner over a bright-sky
//  and a dark backdrop, so contrast can be eyeballed off-device. NOT an
//  assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps and passes — review the images after running.
//
//  Renders the SHIPPING badge (`CautionBadge`, used by
//  ContentView.cautionBadge) rather than a hand-copied duplicate — the
//  width assertion below is only meaningful if it measures the real view.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Compass caution banner (visual pass)")
struct CompassWarningSnapshotTests {

    /// The shipping badge, with the repeating pulse off so a render is
    /// deterministic.
    private func banner(accuracyText: String) -> some View {
        CautionBadge(accuracyText: accuracyText, animated: false)
    }

    // Backdrop approximating the live camera behind the HUD.
    private func scene(sky: [Color], accuracyText: String) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: sky, startPoint: .top, endPoint: .bottom)
            banner(accuracyText: accuracyText)
                .padding(.top, 24)
        }
        .frame(width: 390, height: 180)
    }

    /// The AR view's top-centre stack gives the banner 317 pt on a 393 pt
    /// phone (16 leading + 60 trailing, the trailing side reserved for the
    /// account button since the 2026-09-15 navigation change). The badge
    /// must fit that at default type or it wraps on every device. The
    /// rendered image's point width IS the badge's intrinsic width.
    @Test func bannerFitsBesideAccountButtonAtDefaultType() {
        // The budget comes from the insets ContentView lays out with, not a
        // number typed here.
        let budget = TopStripLayout.bannerWidth(screenWidth: 393)
        let renderer = ImageRenderer(content: banner(accuracyText: "±40°").environment(\.colorScheme, .dark))
        renderer.scale = 1
        let width = renderer.uiImage?.size.width ?? .infinity
        #expect(width <= budget, "badge is \(width) pt wide; the top stack only has \(budget) pt beside the account button")
        // And the old symmetric-60 layout really was too narrow — pins the
        // reason the inset is asymmetric, so nobody "tidies" it back.
        #expect(width > 273, "if the badge now fits in 273 pt the inset can go back to symmetric")
    }

    @Test func renderCompassBanner() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let cases: [(String, [Color])] = [
            ("compass_banner_daysky", [Color(hex: 0x9Fc4E8), Color(hex: 0xD8E8F4)]),
            ("compass_banner_dark",   [Color(hex: 0x0A0E1A), Color(hex: 0x1A2030)]),
        ]
        for (name, sky) in cases {
            let view = scene(sky: sky, accuracyText: "±40°")
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Issue.record("render failed for \(name)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
#endif
