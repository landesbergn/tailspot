//
//  CatchPhotoFocusRecovery.swift
//  Tailspot
//
//  Recovers a catch photo's focus point (where the plane sits, normalized
//  0…1, top-left origin — `Catch.photoFocus`) from the cyan lock-on
//  bracket already baked into the saved JPEG by `CatchPhotoComposer`.
//
//  Why this exists: `photoFocus` is only written at catch time when a
//  bracket is composed, so the ~80 catches taken before that field
//  existed (and any whose bracket was later re-drawn onto the real plane
//  by the offline heal) have a nil or stale focus — the Hangar then
//  center-crops the tall photo and the plane lands at the frame edge.
//  The bracket IS the focus: its centroid is exactly where the crop
//  should center. So we re-derive focus from the pixels that are already
//  on disk — no network, works for any user's back-catalog, and stays
//  correct-by-construction (heal moved the bracket → this follows it).
//
//  Pure + `nonisolated`: decodes bytes and scans a downsampled copy, no
//  main-actor state. `CatchBackfill.backfillPhotoFocus` calls it off the
//  MainActor and writes the result back through the model context.
//

import CoreGraphics
import Foundation
import UIKit

nonisolated enum CatchPhotoFocusRecovery {
    /// Long side the photo is downsampled to before scanning. Big enough
    /// that the thin (~1–2 px at full res × scale) bracket stroke survives
    /// the resample, small enough to stay cheap (~150k px). Paired with
    /// nearest-neighbor sampling (below) so saturated cyan line pixels are
    /// preserved verbatim instead of being blended toward the sky.
    static let scanLongSide: CGFloat = 384

    /// Minimum cyan pixels (in the downsampled image) to trust a bracket.
    /// A composed bracket lights up ~100+ px at this scale; below this is
    /// JPEG noise / a stray blue and we leave focus untouched.
    static let minBracketPixels = 24

    /// Reject when the cyan spans most of the frame: a single bracket box
    /// is ≈0.3×0.16 of the frame, so a span this wide means two+ brackets
    /// (a multi-catch photo) or scattered false matches — ambiguous, so
    /// we don't guess a center.
    static let maxSpanFractionW: CGFloat = 0.72
    static let maxSpanFractionH: CGFloat = 0.60

    /// The bracket centroid as a normalized point (0…1, top-left origin),
    /// or nil when no single confident bracket is found (leave the crop
    /// centered). `data` is a saved catch JPEG.
    static func recoverFocus(fromJPEG data: Data) -> CGPoint? {
        // Orientation-aware decode → upright, matching how the composer
        // wrote the file and how `photoFocus` is interpreted downstream.
        guard let image = UIImage(data: data) else { return nil }
        let longSide = max(image.size.width, image.size.height)
        guard longSide > 0 else { return nil }
        let ratio = min(1, scanLongSide / longSide)
        let w = max(1, Int((image.size.width * ratio).rounded()))
        let h = max(1, Int((image.size.height * ratio).rounded()))

        // Orientation-baked source CGImage (catch photos are already
        // upright, but a rotated one gets normalized first so the scan
        // matches how the photo is displayed).
        let source: CGImage
        if image.imageOrientation == .up, let cg = image.cgImage {
            source = cg
        } else {
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
            let upright = UIGraphicsImageRenderer(size: image.size, format: fmt)
                .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
            guard let cg = upright.cgImage else { return nil }
            source = cg
        }

        // Downsample into a small RGBA8 buffer. Drawing a CGImage into a
        // bitmap context lays out row 0 = image TOP (top-left origin),
        // matching the `photoFocus` convention — no manual flip.
        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // Nearest-neighbor: keep the bracket's saturated cyan pixels at
            // full strength. Averaging resamplers blend the thin stroke into
            // the sky, dropping it below the strict cyan gate.
            ctx.interpolationQuality = .none
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        var sumX = 0, sumY = 0, count = 0
        var minX = w, maxX = 0, minY = h, maxY = 0
        for y in 0..<h {
            let row = y * bytesPerRow
            for x in 0..<w {
                let i = row + x * 4
                let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
                // Brand cyan 0x00D4FF, the exact tone `CatchPhotoComposer`
                // strokes. Same strict gate as the offline heal: strong
                // green+blue, low red, blue clearly above red — excludes
                // pale sky (high red) and the dark halo.
                guard r < 120, g > 150, b > 190, b > r + 100, g > r + 60 else { continue }
                sumX += x; sumY += y; count += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard count >= minBracketPixels else { return nil }
        let spanW = CGFloat(maxX - minX) / CGFloat(w)
        let spanH = CGFloat(maxY - minY) / CGFloat(h)
        guard spanW <= maxSpanFractionW, spanH <= maxSpanFractionH else { return nil }

        return CGPoint(
            x: min(1, max(0, CGFloat(sumX) / CGFloat(count) / CGFloat(w))),
            y: min(1, max(0, CGFloat(sumY) / CGFloat(count) / CGFloat(h)))
        )
    }
}
