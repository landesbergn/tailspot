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
//    - The decode runs off the MainActor (`Task.detached`), driven by a
//      `.task(id:)` keyed on the file path.
//
//  Focus + edge-zoom come from the shared `FocusFill.layout`, so the
//  thumbnail and the big card frame the plane identically.
//

import SwiftUI
import UIKit
import ImageIO
import PostHog   // .postHogMask() on catch-photo thumbnails (session replay)

/// Thumbnail decoder + tiny in-memory cache. Decodes an orientation-baked
/// thumbnail (`kCGImageSourceCreateThumbnailWithTransform`) so the pixels
/// are upright, matching how `photoFocus` is interpreted. `nonisolated` —
/// pure ImageIO on a file URL, called from a detached task.
nonisolated enum PhotoThumbnailLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func load(url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.path)#\(Int(maxPixel))" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
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
            .task(id: url?.path) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            FocusedImage(image: image, focus: focus)
                // PRIVACY: these thumbnails are always the user's own catch
                // photos (CatchPhotoStore file URLs) — mask them from PostHog
                // session replay. Scoped to the image rect; the row's text
                // still records. Inert under ImageRenderer (snapshot tests).
                .postHogMask()
        } else {
            SlotPlaceholder()
        }
    }

    private func load() async {
        guard let url else { image = nil; return }
        // @3x for the on-screen point size; decoded off the main actor.
        let maxPixel = side * 3
        image = await Task.detached(priority: .utility) {
            PhotoThumbnailLoader.load(url: url, maxPixel: maxPixel)
        }.value
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
