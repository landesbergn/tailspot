//
//  FocusThumbnail.swift
//  Tailspot
//
//  The list-thumbnail counterpart to `RevealPhoto`: a small square catch
//  photo that crops toward the plane instead of the frame center. The
//  Hangar's `TailCard` used a plain aspect-fill `AsyncImage`, which
//  center-cropped the tall portrait and hid the plane at the top/bottom
//  edge — the same defect the settled card had before `photoFocus`.
//
//  Two differences from `RevealPhoto`, both because this renders in a
//  scrolling list of many rows (not one hero at a time):
//    - The image is decoded at THUMBNAIL size via ImageIO
//      (`kCGImageSourceThumbnailMaxPixelSize`), never the full ~12 MP
//      still, and cached — decoding full frames per row would thrash
//      memory and stutter the scroll.
//    - The decode runs off the MainActor (`@concurrent`), driven by a
//      `.task(id:)` keyed on the file path, so it is cancelled when the
//      row scrolls away; the thumbnail is also cached on disk.
//
//  Focus + edge-zoom come from the shared `FocusFill.layout`, so the
//  thumbnail and the big card frame the plane identically.
//

import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// Thumbnail decoder with two cache layers. Decodes an orientation-baked
/// thumbnail (`kCGImageSourceCreateThumbnailWithTransform`) so the pixels
/// are upright, matching how `photoFocus` is interpreted. `nonisolated` —
/// pure ImageIO on file URLs, run off the main actor.
///
/// Why two layers (2026-10-25, a ~6,000-catch tester: "quickly scrolling
/// through the Recent list does still cause brief pauses to load photos"):
///  • memory (`NSCache`), for rows scrolled back and forth this session;
///  • disk (`Caches/catch-thumbs/`), so after a relaunch a row reads a
///    ~30 KB thumbnail instead of decoding the full ~12 MP camera JPEG
///    again. Caches is purgeable by the OS; a purged thumbnail is simply
///    re-made from the photo.
nonisolated enum PhotoThumbnailLoader {
    /// Capped by decoded bytes (~64 MB, about 300 thumbnails at 228 px), so
    /// a fling through thousands of rows can't grow it without bound.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    /// The pixel caps in use (the Hangar row: 76 pt @3x). `removeDiskThumbnails`
    /// deletes these sizes; a size added later should be listed here too.
    static let diskSizes: [Int] = [228]

    private static let diskDirectory: URL? = {
        guard let caches = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        let dir = caches.appendingPathComponent("catch-thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The cached thumbnail file for `url` at `maxPixel`.
    static func diskURL(for url: URL, maxPixel: CGFloat) -> URL? {
        diskDirectory?.appendingPathComponent("\(url.lastPathComponent)@\(Int(maxPixel)).jpg")
    }

    /// The row's entry point. `@concurrent` runs it on the global executor
    /// (under Approachable Concurrency a plain `nonisolated async` func runs
    /// on its caller's actor, here the MainActor). Unlike the old
    /// `Task.detached`, it is a child of the row's `.task`, so scrolling the
    /// row away cancels it, and a cancelled load returns before decoding.
    /// A fast fling used to queue a full-size decode for every row it
    /// passed, and the rows actually on screen waited behind them.
    @concurrent
    static func loadAsync(url: URL, maxPixel: CGFloat) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        return load(url: url, maxPixel: maxPixel)
    }

    static func load(url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        // A missing photo is nil, even if an old thumbnail is still on disk:
        // the row then shows the placeholder, as it always did.
        guard let sourceDate = modificationDate(of: url) else { return nil }
        let thumbURL = diskURL(for: url, maxPixel: maxPixel)
        let image: UIImage
        if let thumbURL,
           let thumbDate = modificationDate(of: thumbURL), thumbDate >= sourceDate,
           let cg = decodeFull(thumbURL) {
            image = UIImage(cgImage: cg)
        } else {
            guard let cg = decodeThumbnail(url, maxPixel: maxPixel) else { return nil }
            if let thumbURL { writeJPEG(cg, to: thumbURL) }
            image = UIImage(cgImage: cg)
        }
        cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        return image
    }

    /// Delete `filename`'s cached thumbnails (called when its catch is deleted).
    static func removeDiskThumbnails(forFilename filename: String) {
        guard let diskDirectory else { return }
        for size in diskSizes {
            try? FileManager.default.removeItem(
                at: diskDirectory.appendingPathComponent("\(filename)@\(size).jpg"))
        }
    }

    #if DEBUG
    /// Tests only: forget the memory layer so the next load exercises disk.
    static func clearMemoryCache() { cache.removeAllObjects() }
    #endif

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func decodeThumbnail(_ url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Decode a small cached thumbnail NOW, off the main actor.
    /// `ShouldCacheImmediately` matters: without it ImageIO (like
    /// `UIImage(contentsOfFile:)`) defers the decode to first draw, which
    /// happens on the main thread.
    private static func decodeFull(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Best effort: a failed write only means the next launch decodes the
    /// photo again. Written to a temp file and moved into place, so a
    /// reader never sees a half-written thumbnail.
    private static func writeJPEG(_ cg: CGImage, to url: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }
        try? (data as Data).write(to: url, options: .atomic)
    }
}

/// Square catch-photo thumbnail cropped toward `focus` (normalized 0…1,
/// `Catch.photoFocus`); nil focus → plain center fill (pre-focus rows /
/// remote photos). Renders the shared `SlotPlaceholder` until decoded and
/// when there's no local photo.
struct FocusThumbnail: View {
    let url: URL?
    var focus: CGPoint? = nil
    var side: CGFloat = 76

    @State private var image: UIImage?

    var body: some View {
        content
            .frame(width: side, height: side)
            .clipped()
            // Decorative in every current call site — the row's text names
            // the catch; a bare "image" announcement adds nothing.
            .accessibilityHidden(true)
            .task(id: url?.path) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            FocusedImage(image: image, focus: focus)
                // PRIVACY: these thumbnails are always the user's own catch
                // photos (CatchPhotoStore file URLs) — mask them from PostHog
                // session replay. Scoped to the image rect; the row's text
                // still records. Via CatchPhotoReplayMask so offscreen
                // renders can drop the mask (ImageRenderer draws PostHog's
                // tag views as the yellow no-entry placeholder).
                .catchPhotoReplayMask()
        } else {
            SlotPlaceholder()
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        // @3x for the on-screen point size; decoded off the main actor, and
        // cancelled with this row's `.task` when it scrolls away.
        image = await PhotoThumbnailLoader.loadAsync(url: url, maxPixel: side * 3)
    }
}

/// The plane-centered crop of an already-loaded image, shared by
/// `FocusThumbnail` and the big-card `RevealPhoto` vocabulary via
/// `FocusFill`. Split out so it can be rendered synchronously (an
/// `ImageRenderer` snapshot can't await `FocusThumbnail`'s decode task).
struct FocusedImage: View {
    let image: UIImage
    var focus: CGPoint? = nil

    var body: some View {
        if let focus {
            GeometryReader { geo in
                let layout = FocusFill.layout(
                    imageSize: image.size, frameSize: geo.size, focus: focus
                )
                Image(uiImage: image)
                    .resizable()
                    .frame(width: layout.size.width, height: layout.size.height)
                    .offset(x: layout.origin.x, y: layout.origin.y)
            }
        } else {
            Color.clear.overlay(
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            )
        }
    }
}
