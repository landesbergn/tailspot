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
//  What this actually pins, stated honestly: the banner is the shipping
//  `CautionBadge`, and every measurement comes from `TopStripLayout` — the
//  same constants `ContentView` lays the strip out with. It pins THOSE
//  CONSTANTS, not the frames SwiftUI ends up rendering: nothing here proves
//  the view honoured them (the two chrome discs are rebuilt locally, since
//  the real buttons are private to ContentView). The PNGs it writes to
//  /private/tmp/tailspot_snaps are what show the actual result; the
//  assertions are what go red if someone puts a second control back on the
//  banner's row.
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

    /// Every number below comes from `TopStripLayout`, which is what
    /// ContentView lays the strip out with. A test that declared its own
    /// copy of "44" and "60" would stay green after someone moved the
    /// wrench back — that is exactly the failure this alias prevents.
    private typealias L = TopStripLayout

    private func accountDisc() -> some View {
        ZStack {
            Circle()
                .fill(Brand.Color.bgPrimary.opacity(0.7))
                .overlay(Circle().strokeBorder(Brand.Color.textPrimary.opacity(0.08), lineWidth: 1))
                .frame(width: L.controlDiameter, height: L.controlDiameter)
            Image(systemName: "person.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Brand.Color.textPrimary.opacity(0.9))
        }
    }

    private func wrenchDisc() -> some View {
        Image(systemName: "wrench")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Brand.Color.textPrimary.opacity(0.45))
            .frame(width: L.wrenchDiameter, height: L.wrenchDiameter)
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
                    .padding(.leading, L.bannerLeading)
                    .padding(.trailing, L.bannerTrailing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
            }
            .padding(.top, 12)
            VStack {
                HStack {
                    Spacer()
                    if stacked {
                        VStack(alignment: .trailing, spacing: L.controlSpacing) {
                            accountDisc()
                            wrenchDisc()
                        }
                    } else {
                        HStack(spacing: L.controlSpacing) {
                            wrenchDisc()
                            accountDisc()
                        }
                    }
                }
                .padding(.top, L.controlsTopPadding)
                .padding(.trailing, L.controlsTrailingPadding)
                Spacer()
            }
        }
        .frame(width: Self.width, height: Self.height)
        .environment(\.colorScheme, .dark)
    }

    /// The fix, as arithmetic over the constants ContentView reads: with
    /// the wrench stacked, the only control on the banner's row starts at
    /// or right of the banner's right edge. Change `TopStripLayout` (or
    /// put a second control back on that row) and this goes red.
    @Test func topRowChromeClearsTheBannerRegion() {
        let accountLeft = L.topRowControlLeft(screenWidth: Self.width)
        let bannerRight = L.bannerRight(screenWidth: Self.width)
        #expect(accountLeft >= bannerRight,
                "the top-row control starts at \(accountLeft), the banner ends at \(bannerRight)")

        // And a second control beside it really would overlap — pins why
        // the wrench had to move rather than just being nudged.
        #expect(L.secondControlLeftIfSideBySide(screenWidth: Self.width) < bannerRight,
                "if a second control now fits beside the button the wrench can go back")
    }

    /// The badge's own width budget comes from the same constants, so the
    /// 317 pt in `CompassWarningSnapshotTests` can't drift from the insets.
    @Test func bannerWidthBudgetMatchesTheInsets() {
        #expect(L.bannerWidth(screenWidth: Self.width) == 317)
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
