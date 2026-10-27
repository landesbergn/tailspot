//
//  CardBackStylesSnapshotTests.swift
//  TailspotTests
//
//  Visual pass for the card-back style experiment (CardBackStyles.swift):
//  every style at rest (front + its tease) and with the back showing, as
//  PNGs in /private/tmp/tailspot_snaps. Not assertions about pixels; they
//  exist so a person looks at each style before it goes on a phone.
//

import Testing
import SwiftUI
import UIKit
@testable import Tailspot

#if DEBUG
@MainActor
@Suite("Card back styles (visual pass)", .serialized)
struct CardBackStylesSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
    private static let canvas = CGRect(x: 0, y: 0, width: 393, height: 1100)
    private static let cardWidth: CGFloat = 353

    private static let plane = CardPlane(
        callsign: "UAL1532", model: "Boeing 737-800", carrier: "United Airlines",
        rarity: .common, type: .narrow,
        altText: "11,250 ft", speedText: "342 mph", distText: "3.1 mi",
        originIcao: "SFO", destIcao: "DEN",
        originName: "San Francisco", destName: "Denver",
        isFirstOfType: false, icao24: "a4f2c1")

    /// The detail screen's card slot, as CatchDetailView builds it.
    private struct Slot: View {
        let style: CardBackStyle
        @State var showingBack: Bool

        var body: some View {
            // A ScrollView like the detail screen's: unbounded height, so
            // the slot is laid out as it is there.
            ScrollView {
            VStack(spacing: 14) {
                CardBackPresenter(style: style, showingBack: $showingBack) { showBack in
                    SettledCatchCard(plane: CardBackStylesSnapshotTests.plane,
                                     isFirstOfType: false,
                                     width: CardBackStylesSnapshotTests.cardWidth,
                                     onPhotoTap: nil,
                                     onTurnOver: style.frontShowsTurnOverButton ? showBack : nil,
                                     caughtAt: Date(timeIntervalSince1970: 1_793_040_000))
                } back: {
                    CatchCardBack(model: BackFixtures.b738,
                                  width: CardBackStylesSnapshotTests.cardWidth,
                                  onOpenURL: { _ in }, onTurnBack: { showingBack = false })
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 56)
            }
        }
    }

    private func render(_ style: CardBackStyle, back: Bool) async throws {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = Self.canvas
        let host = UIHostingController(rootView:
            Slot(style: style, showingBack: back)
                .frame(width: bounds.width, height: bounds.height, alignment: .top)
                .background(Brand.Color.bgPrimary)
                .environment(\.replayMaskingDisabled, true))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        // Measure-then-layout containers need a couple of passes, and a
        // style may settle with an animation.
        try await Task.sleep(for: .milliseconds(900))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try png.write(to: Self.snapDir.appendingPathComponent(
            "style_\(style.rawValue)_\(back ? "back" : "front").png"))
        window.isHidden = true
        #expect(!png.isEmpty)
    }

    @Test(arguments: CardBackStyle.allCases)
    func front(_ style: CardBackStyle) async throws {
        try await render(style, back: false)
    }

    @Test(arguments: CardBackStyle.allCases)
    func back(_ style: CardBackStyle) async throws {
        try await render(style, back: true)
    }

    @Test func styleFlagsMatchTheDesign() {
        #expect(CardBackStyle.allCases == [.flip, .realFlip, .swipeLeft, .swipeUp])
        #expect(CardBackStyle.allCases.filter { !$0.frontShowsTurnOverButton }
                == [.swipeLeft, .swipeUp])
    }
}
#endif
