//
//  ShareCardSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness (RevealSnapshotTests pattern) for the two changes
//  of 2026-07-05: the share artboard restyled around SettledCatchCard,
//  and the focus-anchored photo crop. Renders PNGs to
//  /private/tmp/tailspot_snaps; NOT an assertion test.
//
//  The photo case uses a SYNTHETIC catch photo — sky gradient with a
//  small dark "plane" marker at normalized (0.72, 0.22) — so the render
//  makes the crop behavior obvious: with focus, the marker sits centered
//  in the hero; without (legacy nil), the top-anchored marker is cropped
//  away by the center fill.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Share card + focus crop snapshots (visual pass)")
struct ShareCardSnapshotTests {

    private static let markerFocus = CGPoint(x: 0.72, y: 0.22)

    /// Paint a portrait 1200×1600 "catch photo": vertical sky gradient,
    /// a horizon band near the bottom, and a plane-sized dark marker with
    /// bracket-cyan ring at `markerFocus` so the crop anchor is unmistakable.
    private func makeSyntheticPhoto() -> URL? {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.09, green: 0.23, blue: 0.42, alpha: 1).cgColor,
                          UIColor(red: 0.55, green: 0.75, blue: 0.92, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(grad, start: .zero,
                                  end: CGPoint(x: 0, y: size.height), options: [])
            UIColor(white: 0.25, alpha: 1).setFill()
            cg.fill(CGRect(x: 0, y: size.height - 180, width: size.width, height: 180))
            let c = CGPoint(x: Self.markerFocus.x * size.width,
                            y: Self.markerFocus.y * size.height)
            UIColor(red: 0, green: 212 / 255.0, blue: 1, alpha: 1).setStroke()
            cg.setLineWidth(6)
            cg.strokeEllipse(in: CGRect(x: c.x - 70, y: c.y - 70, width: 140, height: 140))
            UIColor.black.setFill()
            cg.fillEllipse(in: CGRect(x: c.x - 28, y: c.y - 12, width: 56, height: 24))
        }
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        let url = URL(fileURLWithPath: "/private/tmp/tailspot_snaps/synthetic_catch.jpg")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
        return url
    }

    @Test func renderShareAndFocusCards() {
        let dir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photoURL = makeSyntheticPhoto()

        func plane(focus: CGPoint?) -> CardPlane {
            CardPlane(
                callsign: "UAL1175", model: "Boeing 777-200",
                carrier: "United Airlines",
                rarity: .rare, type: .wide,
                altText: "32,000 ft", speedText: "465 kt", distText: "18.2 km",
                photoURL: photoURL, photoFocus: focus,
                originIcao: "SFO", destIcao: "HNL",
                originName: "San Francisco", destName: "Honolulu",
                isFirstOfType: true)
        }

        let cases: [(String, AnyView)] = [
            ("focus_card_anchored", AnyView(
                SettledCatchCard(plane: plane(focus: Self.markerFocus),
                                 isFirstOfType: true, width: 357))),
            ("focus_card_legacy_center", AnyView(
                SettledCatchCard(plane: plane(focus: nil),
                                 isFirstOfType: true, width: 357))),
            ("share_artboard", AnyView(
                CatchShareCard(plane: plane(focus: Self.markerFocus)))),
            ("share_artboard_noroute_common", AnyView(
                CatchShareCard(plane: CardPlane(
                    callsign: "N4521C", model: "Cessna 172", carrier: "Private",
                    rarity: .common, type: .ga,
                    altText: "3,609 ft", speedText: "101 kt", distText: "3.8 km")))),
        ]

        for (name, view) in cases {
            let wrapped = view
                .padding(12)
                .background(Brand.Color.bgPrimary)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: wrapped)
            renderer.scale = 3
            guard let ui = renderer.uiImage, let png = ui.pngData() else {
                Log.ui.error("Share/focus snapshot render failed: \(name, privacy: .public)")
                continue
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(true)
    }
}
#endif
