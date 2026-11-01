//
//  RevealShareSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness (RevealSnapshotTests pattern) for the reveal's Share
//  CTA, the multi-catch receipt, and the share card footer. NOT an assertion
//  test: writes PNGs to /private/tmp/tailspot_snaps/reveal_share and passes.
//  Every case renders at the default text size and at .accessibility2.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Reveal share + multi-catch snapshots (visual pass)")
struct RevealShareSnapshotTests {

    private static let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/reveal_share",
                                 isDirectory: true)

    private static let sizes: [(String, DynamicTypeSize)] = [
        ("default", .large), ("a11y2", .accessibility2),
    ]

    private func write(_ view: some View, _ name: String, scale: CGFloat = 3) {
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        let renderer = ImageRenderer(content: view.environment(\.replayMaskingDisabled, true))
        renderer.scale = scale
        guard let data = renderer.uiImage?.pngData() else { return }
        try? data.write(to: Self.dir.appendingPathComponent("\(name).png"))
    }

    private let rare = CardPlane(
        callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
        rarity: .rare, type: .wide,
        altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
        originIcao: "SFO", destIcao: "HKG",
        originName: "San Francisco", destName: "Hong Kong",
        isFirstOfType: true)

    @Test func renderRevealCTARow() {
        let screen = CGSize(width: 393, height: 852)
        let se = CGSize(width: 375, height: 647)
        for (tag, dts) in Self.sizes {
            let settled = CatchRevealView(plane: rare, entryNumber: 62, onDismiss: {}, onViewInHangar: {})
            write(settled._snapshotScreen(width: screen.width - 28, size: screen)
                    .dynamicTypeSize(dts),
                  "reveal_settled_\(tag)")
            write(settled._snapshotScreen(width: se.width - 28, size: se)
                    .dynamicTypeSize(dts),
                  "reveal_settled_se_\(tag)", scale: 2)

            guard let route = routeQuestion() else {
                Issue.record("route question fixture failed to build")
                return
            }
            let question = GuessRoundQuestion(route: route)
            let withGuess = CatchRevealView(plane: rare, entryNumber: 62, onDismiss: {},
                                            onViewInHangar: {}, guess: question)
            let popped = CatchRevealView.GuessSnapshotState(
                render: .init(question: question, resolution: nil, chipsInLayout: true, popClock: 1),
                bt: 0)
            write(withGuess._snapshotScreen(width: screen.width - 28, size: screen, guessState: popped)
                    .dynamicTypeSize(dts),
                  "reveal_bonusround_\(tag)")
        }
    }

    @Test func renderMultiCatchReveal() {
        let entries: [MultiCatchReveal.Entry] = [
            .init(plane: rare, isDuplicate: false),
            .init(plane: .init(callsign: "DAL2104", model: "Airbus A320", carrier: "Delta",
                               rarity: .common, type: .narrow), isDuplicate: false),
            .init(plane: .init(callsign: "ASA1276", model: "Boeing 737 MAX", carrier: "Alaska",
                               rarity: .uncommon, type: .narrow), isDuplicate: true),
        ]
        for (tag, dts) in Self.sizes {
            // The run's summary page, settled (each plane's page is the
            // single reveal, covered by the reveal snapshots above).
            var multi = MultiCatchReveal(entries: entries, lastEntryNumber: 48,
                                         onDismiss: {}, onViewInHangar: {})
            multi._snapshotPage = entries.count
            write(multi.frame(width: 393, height: 852).dynamicTypeSize(dts),
                  "multi_2fresh_1dup_\(tag)")
            write(multi.frame(width: 375, height: 667).dynamicTypeSize(dts),
                  "multi_2fresh_1dup_se_\(tag)", scale: 2)
        }
    }

    @Test func renderShareCardFooters() {
        let photo = syntheticPhoto()
        let plane = CardPlane(
            callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
            rarity: .rare, type: .wide,
            altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
            photoURL: photo, photoFocus: CGPoint(x: 0.5, y: 0.4),
            originIcao: "SFO", destIcao: "HKG",
            originName: "San Francisco", destName: "Hong Kong",
            isFirstOfType: true)
        for (tag, dts) in Self.sizes {
            write(CatchShareCard(plane: plane).dynamicTypeSize(dts), "share_card_\(tag)")
            write(CatchShareCompactCard(plane: plane, format: .post)
                    .frame(width: 360, height: 450).dynamicTypeSize(dts),
                  "share_post_\(tag)")
        }
        // The pipeline renders (what actually leaves the phone): square, and
        // the story with the transparent sticker over its backdrop.
        for format in [ShareFormat.square, .story] {
            if let data = CatchShare.uiImage(for: plane, format: format)?.pngData() {
                try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                try? data.write(to: Self.dir.appendingPathComponent("share_\(format.rawValue)_default.png"))
            }
        }
    }

    // MARK: - Fixtures

    private func routeQuestion() -> GuessOptions.RouteQuestion? {
        var rng = SeededRNG(seed: 7)
        return GuessOptions.routeQuestion(
            originIcao: "KSFO", destIcao: "VHHH",
            observerLat: 37.87, observerLon: -122.27, using: &rng)
    }

    /// Sky-gradient stand-in for a catch photo (only local file URLs render
    /// into a share image).
    private func syntheticPhoto() -> URL? {
        let size = CGSize(width: 900, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(red: 0.09, green: 0.23, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: 0, y: size.height), options: [])
            UIColor.black.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 420, y: 470, width: 70, height: 26))
        }
        let url = Self.dir.appendingPathComponent("synthetic_photo.jpg")
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        try? data.write(to: url)
        return url
    }
}
#endif
