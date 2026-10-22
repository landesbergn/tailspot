//
//  LegibilitySnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the 2026-10-22 accessibility/legibility pass
//  (RevealSnapshotTests pattern). NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps (all prefixed `a11y_`) and passes. The
//  contrast numbers themselves are pinned in BrandTests; these renders
//  are for eyeballing the faint-ink change on every surface that inherits
//  RP.faint — the live reveal (ALT/SPD/ROUTE labels, ENTRY #, "tap to
//  continue", the bonus round's SKIP), the settled Hangar card, and the
//  share artboard in all three formats, including the 9:16 story sticker
//  over a BRIGHT photo, where the faint labels sit on the blurred image
//  instead of the dark card.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Legibility pass snapshots (visual pass)")
struct LegibilitySnapshotTests {

    private static let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// A near-white overcast sky with a small dark plane — the worst case
    /// for light text on the story sticker's blurred photo backdrop.
    private func makeBrightPhoto() -> URL? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.80, green: 0.88, blue: 0.96, alpha: 1).cgColor,
                          UIColor(white: 0.97, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero,
                                  end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.15, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 600, y: 520, width: 70, height: 26))
        }
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        let url = Self.dir.appendingPathComponent("a11y_bright_sky.jpg")
        try? data.write(to: url)
        return url
    }

    private func write(_ view: some View, _ name: String, scale: CGFloat = 3) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let png = renderer.uiImage?.pngData() else { return }
        try? png.write(to: Self.dir.appendingPathComponent("\(name).png"))
    }

    @Test func renderFaintInkSurfaces() {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let photo = makeBrightPhoto()

        let epic = CardPlane(
            callsign: "RCH130", model: "Lockheed Martin C-130J Super Hercules",
            carrier: "U.S. Air Force", rarity: .epic, type: .mil,
            altText: "24,000 ft", speedText: "310 kt", distText: "9.2 km",
            photoURL: photo, photoFocus: CGPoint(x: 0.53, y: 0.33),
            originIcao: "SUU", destIcao: "HIK",
            originName: "Travis AFB", destName: "Hickam",
            isFirstOfType: true)
        let common = CardPlane(
            callsign: "N4521C", model: "Cessna 172", carrier: "Private",
            rarity: .common, type: .ga,
            altText: "3,609 ft", speedText: "101 kt", distText: "3.8 km")

        // Live reveal, full screen (card + "tap to continue" CTA).
        let screen = CGSize(width: 393, height: 852)
        let width = min(screen.width - 28, 420)
        for (name, plane) in [("a11y_reveal_epic", epic), ("a11y_reveal_common", common)] {
            write(CatchRevealView(plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {})
                    ._snapshotScreen(width: width, size: screen)
                    .environment(\.replayMaskingDisabled, true), name)
        }

        // Bonus round up: the chips' SKIP is faint ink too.
        var rng = SeededRNG(seed: 7)
        if let route = GuessOptions.routeQuestion(
            originIcao: "KSFO", destIcao: "VHHH",
            observerLat: 37.87, observerLon: -122.27, using: &rng
        ) {
            let q = GuessRoundQuestion(route: route)
            let plane = CardPlane(
                callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
                rarity: .rare, type: .wide,
                altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
                originIcao: "SFO", destIcao: "HKG")
            let popped = CatchRevealView.GuessSnapshotState(
                render: .init(question: q, resolution: nil, chipsInLayout: true, popClock: 1), bt: 0)
            write(CatchRevealView(plane: plane, entryNumber: 62, onDismiss: {}, onViewInHangar: {},
                                  guess: q)
                    ._snapshotScreen(width: width, size: screen, guessState: popped),
                  "a11y_reveal_chips")
        }

        // Settled Hangar card.
        write(SettledCatchCard(plane: epic, isFirstOfType: true, width: 357)
                .padding(12)
                .background(Brand.Color.bgPrimary)
                .environment(\.colorScheme, .dark)
                .environment(\.replayMaskingDisabled, true),
              "a11y_settled_epic")

        // Share artboard, every format; the photo plane's story is the
        // sticker over the bright blurred photo.
        for (pName, plane) in [("epic_brightphoto", epic), ("common_nophoto", common)] {
            for format in ShareFormat.allCases {
                guard let png = CatchShare.uiImage(for: plane, format: format)?.pngData() else { continue }
                try? png.write(to: Self.dir.appendingPathComponent("a11y_share_\(format.rawValue)_\(pName).png"))
            }
        }
        #expect(true)
    }
}
#endif
