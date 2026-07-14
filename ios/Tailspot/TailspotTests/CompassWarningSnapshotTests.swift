//
//  CompassWarningSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the LOUD compass-caution banner
//  (TailCardSnapshotTests pattern): renders the banner over a bright-sky
//  and a dark backdrop so the amber pop + dark-on-amber contrast can be
//  eyeballed off-device. NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps and passes — review the images after running.
//
//  Mirrors ContentView.cautionBadge's label markup. If that banner's look
//  changes, update this copy (it exists only to look at, not to gate).
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Compass caution banner (visual pass)")
struct CompassWarningSnapshotTests {

    // Faithful copy of ContentView.cautionBadge's label (the visual part;
    // the button action is ContentView-state-bound and not visual).
    private func banner(accuracyText: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
            VStack(alignment: .leading, spacing: 1) {
                Text("COMPASS OFF \(accuracyText)")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .tracking(1.0)
                Text("Labels may be wrong — tap to calibrate")
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .opacity(0.85)
            }
        }
        .foregroundStyle(Brand.Color.bgSurface)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.Color.alertCaution,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.Color.bgSurface.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Brand.Color.alertCaution.opacity(0.5), radius: 12, y: 2)
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
