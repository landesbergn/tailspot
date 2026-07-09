//
//  FocusThumbnailTests.swift
//  TailspotTests
//
//  Pins the list-thumbnail loader: it must downsample (never hand a full
//  ~12 MP still to a scrolling row) and bake EXIF orientation so the
//  thumbnail is upright — the same orientation trap the focus recovery
//  hit. Plus a visual before/after of the plane-centered crop.
//

import CoreGraphics
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Tailspot

@Suite("FocusThumbnail loader")
struct FocusThumbnailLoaderTests {

    private func solid(_ size: CGSize, _ color: UIColor) -> CGImage {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }

    /// Write `cg` to a temp JPEG with an explicit EXIF orientation tag.
    private func tempJPEG(_ cg: CGImage, orientation: CGImagePropertyOrientation) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(orientation.rawValue)-\(cg.width)x\(cg.height).jpg")
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
        try? (data as Data).write(to: url, options: .atomic)
        return url
    }

    @Test func downsamplesPreservingAspect() {
        let url = tempJPEG(solid(CGSize(width: 600, height: 1000), .blue), orientation: .up)
        let img = PhotoThumbnailLoader.load(url: url, maxPixel: 200)
        #expect(img != nil)
        let s = img?.size ?? .zero
        #expect(max(s.width, s.height) <= 201)          // downsampled to the cap
        #expect(abs(s.width / s.height - 0.6) < 0.02)    // aspect preserved (portrait)
    }

    @Test func bakesEXIFOrientationUpright() {
        // Landscape pixels (1000×600) tagged .right (a portrait capture stored
        // sensor-landscape) must load as an UPRIGHT portrait thumbnail — else
        // the whole crop space is rotated 90°.
        let url = tempJPEG(solid(CGSize(width: 1000, height: 600), .green), orientation: .right)
        let img = PhotoThumbnailLoader.load(url: url, maxPixel: 240)
        #expect(img != nil)
        let s = img?.size ?? .zero
        #expect(s.height > s.width)                       // portrait after transform
    }
}

#if DEBUG
import SwiftUI
import os

@MainActor
@Suite("Focus thumbnail snapshots (visual pass)")
struct FocusThumbnailSnapshotTests {

    private let cases: [(String, String)] = [
        ("a4c592.jpg", "JBU1770"), ("c010cb.jpg", "ACA708"),
        ("a1863b.jpg", "DAL405"), ("a198ed.jpg", "JBU1770"),
    ]

    @Test func renderThumbnailBeforeAfter() {
        let reviewDir = URL(fileURLWithPath: "/private/tmp/tailspot_focus_review", isDirectory: true)
        let outDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for (file, _) in cases {
            let url = reviewDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  let img = PhotoThumbnailLoader.load(url: url, maxPixel: 228) else { continue }
            let focus = CatchPhotoFocusRecovery.recoverFocus(fromJPEG: data)

            func thumb(_ f: CGPoint?) -> some View {
                FocusedImage(image: img, focus: f)
                    .frame(width: 76, height: 76)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            let view = HStack(spacing: 14) {
                VStack(spacing: 4) { thumb(nil); Text("before").font(.system(size: 9)).foregroundStyle(.secondary) }
                VStack(spacing: 4) { thumb(focus); Text("after").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .padding(16)
            .background(Brand.Color.bgPrimary)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let png = renderer.uiImage?.pngData() else { continue }
            let stem = file.replacingOccurrences(of: ".jpg", with: "")
            try? png.write(to: outDir.appendingPathComponent("thumb_\(stem).png"))
        }
        #expect(true)
    }
}
#endif
