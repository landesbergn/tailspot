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
    private func tempJPEG(_ cg: CGImage, orientation: CGImagePropertyOrientation,
                          name: String? = nil) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name ?? "thumb-\(orientation.rawValue)-\(cg.width)x\(cg.height).jpg")
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

    // MARK: - Disk cache + cancellation (the 6k-catch Recent-list report)

    /// A uniquely named temp JPEG, so parallel tests and old runs' cached
    /// thumbnails never collide.
    private func uniqueJPEG(_ color: UIColor) -> URL {
        tempJPEG(solid(CGSize(width: 600, height: 1000), color), orientation: .up,
                 name: "thumbtest-\(UUID().uuidString).jpg")
    }

    /// The centre pixel's dominant channel: "r", "g" or "b".
    private func dominant(_ image: UIImage?) -> String? {
        guard let cg = image?.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2, y: -CGFloat(cg.height) / 2,
                                width: CGFloat(cg.width), height: CGFloat(cg.height)))
        let (r, g, b) = (px[0], px[1], px[2])
        return r > g && r > b ? "r" : (g > b ? "g" : "b")
    }

    @Test func writesAndReusesTheDiskThumbnail() throws {
        let url = uniqueJPEG(.blue)
        let thumb = try #require(PhotoThumbnailLoader.diskURL(for: url, maxPixel: 228))
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: thumb) }
        #expect(dominant(PhotoThumbnailLoader.load(url: url, maxPixel: 228)) == "b")
        #expect(FileManager.default.fileExists(atPath: thumb.path), "first load writes the disk thumbnail")
        // Swap the cached thumbnail for a red one: a reload that shows red
        // came from disk, not from re-decoding the (blue) photo.
        let red = tempJPEG(solid(CGSize(width: 100, height: 160), .red), orientation: .up,
                           name: "thumbtest-red-\(UUID().uuidString).jpg")
        try FileManager.default.removeItem(at: thumb)
        try FileManager.default.moveItem(at: red, to: thumb)
        PhotoThumbnailLoader.clearMemoryCache()
        #expect(dominant(PhotoThumbnailLoader.load(url: url, maxPixel: 228)) == "r")
    }

    @Test func aNewerPhotoReplacesAStaleThumbnail() throws {
        let url = uniqueJPEG(.blue)
        let thumb = try #require(PhotoThumbnailLoader.diskURL(for: url, maxPixel: 228))
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: thumb) }
        _ = PhotoThumbnailLoader.load(url: url, maxPixel: 228)
        // Rewrite the photo green, stamped newer than the thumbnail.
        let green = tempJPEG(solid(CGSize(width: 600, height: 1000), .green), orientation: .up,
                             name: "thumbtest-green-\(UUID().uuidString).jpg")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: green, to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
        PhotoThumbnailLoader.clearMemoryCache()
        #expect(dominant(PhotoThumbnailLoader.load(url: url, maxPixel: 228)) == "g")
    }

    @Test func aMissingPhotoIsNilEvenWithACachedThumbnail() throws {
        let url = uniqueJPEG(.blue)
        let thumb = try #require(PhotoThumbnailLoader.diskURL(for: url, maxPixel: 228))
        defer { try? FileManager.default.removeItem(at: thumb) }
        _ = PhotoThumbnailLoader.load(url: url, maxPixel: 228)
        try FileManager.default.removeItem(at: url)
        PhotoThumbnailLoader.clearMemoryCache()
        #expect(PhotoThumbnailLoader.load(url: url, maxPixel: 228) == nil)
    }

    /// A row scrolled away cancels its `.task`; the load must then skip the
    /// decode entirely (no image, no thumbnail written).
    @Test func aCancelledLoadSkipsTheDecode() async throws {
        let url = uniqueJPEG(.blue)
        let thumb = try #require(PhotoThumbnailLoader.diskURL(for: url, maxPixel: 228))
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: thumb) }
        let task = Task { () -> UIImage? in
            withUnsafeCurrentTask { $0?.cancel() }      // cancelled before the load starts
            return await PhotoThumbnailLoader.loadAsync(url: url, maxPixel: 228)
        }
        #expect(await task.value == nil)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    @Test func deletingACatchRemovesItsThumbnail() throws {
        let url = uniqueJPEG(.blue)
        let thumb = try #require(PhotoThumbnailLoader.diskURL(for: url, maxPixel: 228))
        defer { try? FileManager.default.removeItem(at: url) }
        _ = PhotoThumbnailLoader.load(url: url, maxPixel: 228)
        #expect(FileManager.default.fileExists(atPath: thumb.path))
        PhotoThumbnailLoader.removeDiskThumbnails(forFilename: url.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: thumb.path))
    }

    @Test func fileURLSkipsTheExistenceCheck() {
        let url = CatchPhotoStore.fileURL(forFilename: "nope_0.jpg")
        #expect(url?.lastPathComponent == "nope_0.jpg")
        #expect(CatchPhotoStore.url(forFilename: "nope_0.jpg") == nil)
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
