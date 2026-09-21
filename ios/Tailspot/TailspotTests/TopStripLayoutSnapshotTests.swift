//
//  TopStripLayoutSnapshotTests.swift
//  TailspotTests
//
//  Visual pass for the AR view's top strip in a DEBUG build: the compass
//  caution banner (the real `CautionBadge`) in its 16-leading / 60-trailing
//  region, with the top-trailing chrome beside it.
//
//  BEFORE the 2026-09-21 fix the wrench sat to the LEFT of the account
//  button, putting a 44 pt hit region over the banner's right end and
//  eating "tap to calibrate" taps in every build Noah field-tests. AFTER,
//  the wrench is stacked below the account button, so the top row is the
//  account button alone and the Release layout is unchanged.
//
//  The banner is the shipping view. The two chrome discs are rebuilt here
//  from ContentView's documented geometry (44 pt account circle; 32 pt
//  wrench disc with a 44 pt hit region; 10 pt spacing; 12 pt trailing
//  padding) because they are private to ContentView — this harness is about
//  WHERE they land, not what they look like. Writes PNGs to
//  /private/tmp/tailspot_snaps and passes; the assertion below is the part
//  that gates.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("AR top strip layout (visual pass)")
struct TopStripLayoutSnapshotTests {

    private static let width: CGFloat = 393      // iPhone 16 / 17 points
    private static let height: CGFloat = 150

    /// ContentView's geometry, named so the numbers in the assertion and in
    /// the render can't drift apart.
    private static let trailingPadding: CGFloat = 12
    private static let accountDiameter: CGFloat = 44
    private static let wrenchHitSize: CGFloat = 44       // 32 pt disc + 6 pt inset a side
    private static let controlSpacing: CGFloat = 10
    private static let bannerLeading: CGFloat = 16
    private static let bannerTrailing: CGFloat = 60

    /// The banner's right edge on a 393 pt phone.
    private static var bannerRight: CGFloat { width - bannerTrailing }

    private func accountDisc() -> some View {
        ZStack {
            Circle()
                .fill(Brand.Color.bgPrimary.opacity(0.7))
                .overlay(Circle().strokeBorder(Brand.Color.textPrimary.opacity(0.08), lineWidth: 1))
                .frame(width: Self.accountDiameter, height: Self.accountDiameter)
            Image(systemName: "person.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.Color.textPrimary.opacity(0.9))
        }
    }

    private func wrenchDisc() -> some View {
        Image(systemName: "wrench")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Brand.Color.textPrimary.opacity(0.45))
            .padding(8)
            .background(Brand.Color.bgPrimary.opacity(0.20), in: .circle)
    }

    /// `stacked: false` is the old side-by-side layout, `true` the shipping
    /// column.
    private func strip(stacked: Bool) -> some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(hex: 0x9FC4E8), Color(hex: 0xD8E8F4)],
                           startPoint: .top, endPoint: .bottom)
            VStack {
                CautionBadge(accuracyText: "±40°", animated: false)
                    .padding(.leading, Self.bannerLeading)
                    .padding(.trailing, Self.bannerTrailing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(.top, 12)
            VStack {
                HStack {
                    Spacer()
                    if stacked {
                        VStack(alignment: .trailing, spacing: Self.controlSpacing) {
                            accountDisc()
                            wrenchDisc()
                        }
                    } else {
                        HStack(spacing: Self.controlSpacing) {
                            wrenchDisc()
                            accountDisc()
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.trailing, Self.trailingPadding)
                Spacer()
            }
        }
        .frame(width: Self.width, height: Self.height)
        .environment(\.colorScheme, .dark)
    }

    /// The fix, as arithmetic: with the wrench stacked, the only control on
    /// the banner's row starts at or right of the banner's right edge.
    @Test func topRowChromeClearsTheBannerRegion() {
        let accountLeft = Self.width - Self.trailingPadding - Self.accountDiameter
        #expect(accountLeft >= Self.bannerRight,
                "the account button starts at \(accountLeft), the banner ends at \(Self.bannerRight)")

        // And the old layout really did overlap — pins why the wrench moved.
        let sideBySideWrenchLeft = accountLeft - Self.controlSpacing - Self.wrenchHitSize
        #expect(sideBySideWrenchLeft < Self.bannerRight,
                "if the wrench now fits beside the button it can go back")
    }

    @Test func renderTopStripBeforeAndAfter() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, stacked) in [("top_strip_debug_before", false), ("top_strip_debug_after", true)] {
            let renderer = ImageRenderer(content: strip(stacked: stacked))
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
