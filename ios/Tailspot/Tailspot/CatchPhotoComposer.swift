//
//  CatchPhotoComposer.swift
//  Tailspot
//
//  Draws the cyan lock-on corner brackets onto a freshly captured catch
//  photo so the saved JPEG records *which plane* the user caught at that
//  moment. The brackets the user sees in the AR view at capture time are
//  re-rendered into the photo's pixel space; if a tester later opens the
//  catch in their Hangar, the photo shows the same framing they saw on
//  the screen.
//
//  Pure-ish: takes JPEG bytes + screen-space context, returns JPEG bytes.
//  No SwiftUI, no model context. The screen-space → photo-pixel transform
//  assumes the camera preview uses `.resizeAspectFill` (which it does in
//  `CameraPreview`) — the photo's larger image is cropped on whichever
//  dimension overflows the screen, and the visible center maps 1:1
//  through a single uniform scale.
//

import UIKit
import CoreGraphics

nonisolated enum CatchPhotoComposer {
    /// The bracket overlay to draw on a photo. `screenPosition` is the
    /// projected plane location in the AR view's coordinate space at
    /// capture time; `screenSize` is the AR view's size in the same
    /// coordinate space. Together they pin down the photo-pixel target.
    struct BracketOverlay: Equatable {
        let screenPosition: CGPoint
        let screenSize: CGSize
    }

    /// Visual constants matched to the on-screen pinned `LockBrackets`
    /// in `ContentView` so the drawn-on-photo bracket reads the same
    /// size as what the user saw in the AR view. Scaled to photo pixels
    /// by 1 / aspectFillScale inside `compose(...)`.
    static let bracketScreenBoxSize: CGFloat = 140
    static let bracketScreenLineWidth: CGFloat = 2.5

    /// Cyan from `Brand.Color.cyan` (0x00D4FF). Duplicated here as a
    /// UIColor so the composer is independent of SwiftUI.
    static let bracketColor = UIColor(
        red: 0.0,
        green: 212.0 / 255.0,
        blue: 255.0 / 255.0,
        alpha: 1.0
    )

    /// Dark halo drawn behind the cyan bracket so it stays legible against a
    /// bright sky. Matches `Brand.Color.hudBracketHalo` (0x050810) on the
    /// SwiftUI side — keep the two in sync.
    static let bracketHaloColor = UIColor(
        red: 5.0 / 255.0,
        green: 8.0 / 255.0,
        blue: 16.0 / 255.0,
        alpha: 1.0
    )

    /// On-screen halo half-width in points; matches `LockBrackets.haloWidth`.
    /// Scaled to photo pixels by 1 / aspectFillScale inside `compose(...)`.
    static let bracketScreenHaloWidth: CGFloat = 1.5

    /// Saved photos are capped at this long side. Stills now come off the
    /// sensor at ~12 MP (full-res capture so the snap detector can see
    /// distant planes); saving that verbatim would triple-plus per-catch
    /// storage and make Hangar grids decode 12 MP images. 3072 keeps
    /// ~2.8× the pixel detail of the old 1080-wide photos (plenty for the
    /// share-card plane crop) at roughly a quarter of the full-res bytes.
    /// The snap SEARCH runs on the uncapped bytes before compose.
    static let maxSavedLongSidePixels: CGFloat = 3072

    /// The size a photo is actually saved at: source size, uniformly
    /// scaled down if the long side exceeds `maxSavedLongSidePixels`.
    static func savedPhotoSize(for photoSize: CGSize) -> CGSize {
        let longSide = max(photoSize.width, photoSize.height)
        guard longSide > maxSavedLongSidePixels else { return photoSize }
        let r = maxSavedLongSidePixels / longSide
        return CGSize(width: (photoSize.width * r).rounded(),
                      height: (photoSize.height * r).rounded())
    }

    /// A composed catch photo: the bracketed JPEG plus WHERE the plane sits
    /// in it (normalized 0…1 photo coordinates, top-left origin — the
    /// bracket center). The focus is persisted on `Catch` so photo displays
    /// can anchor their aspect-fill crop on the plane instead of the frame
    /// center.
    struct Composed {
        let jpegData: Data
        let normalizedFocus: CGPoint
    }

    /// The bracket center in NORMALIZED photo coordinates, clamped to 0…1
    /// (the projected point can land a hair outside the photo when the
    /// plane sits at the aspect-fill crop edge). Pure math, unit-testable
    /// without decoding an image.
    static func normalizedFocus(overlay: BracketOverlay, photoSize: CGSize) -> CGPoint {
        let transform = AspectFillTransform(
            screenSize: overlay.screenSize,
            photoSize: photoSize
        )
        let p = transform.photoPoint(fromScreenPoint: overlay.screenPosition)
        return CGPoint(
            x: min(1, max(0, p.x / photoSize.width)),
            y: min(1, max(0, p.y / photoSize.height))
        )
    }

    /// Compose the JPEG with a cyan bracket drawn around the plane at
    /// `overlay.screenPosition`. Returns nil if the JPEG can't be
    /// decoded or if the dimensions are unusable; callers should fall
    /// back to the original `jpegData` (with no focus) in that case.
    static func compose(jpegData: Data, overlay: BracketOverlay) -> Composed? {
        guard let image = UIImage(data: jpegData) else { return nil }
        // All geometry runs in the CAPPED output space — the transform,
        // bracket center, and stroke widths all reference the pixels
        // actually being written.
        let photoSize = savedPhotoSize(for: image.size)
        guard photoSize.width > 0, photoSize.height > 0,
              overlay.screenSize.width > 0, overlay.screenSize.height > 0
        else { return nil }

        let transform = AspectFillTransform(
            screenSize: overlay.screenSize,
            photoSize: photoSize
        )
        let center = transform.photoPoint(fromScreenPoint: overlay.screenPosition)
        let photoBoxSize = bracketScreenBoxSize / transform.scale
        let photoLineWidth = bracketScreenLineWidth / transform.scale
        let photoArm = max(8.0, bracketScreenBoxSize * 0.22) / transform.scale
        // Floor the scaled halo so it never collapses to nothing when the photo
        // is small relative to the screen (transform.scale > 1).
        let photoHaloWidth = max(0.5, bracketScreenHaloWidth / transform.scale)

        // Render at the (capped) photo pixel resolution, not the device
        // scale — blowing a photo up by the screen scale would multiply
        // pixels for no visual gain after re-encoding to JPEG.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: photoSize, format: format)
        let composed = renderer.image { ctx in
            ctx.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: photoSize))
            drawCornerBrackets(
                in: ctx.cgContext,
                center: center,
                boxSize: photoBoxSize,
                armLength: photoArm,
                lineWidth: photoLineWidth,
                color: bracketColor,
                haloColor: bracketHaloColor,
                haloWidth: photoHaloWidth
            )
        }
        guard let outData = composed.jpegData(compressionQuality: 0.9) else { return nil }
        return Composed(
            jpegData: outData,
            normalizedFocus: normalizedFocus(overlay: overlay, photoSize: photoSize)
        )
    }

    /// Re-render WITHOUT a bracket: upright pixel order + the same
    /// long-side cap as `compose`. Used when a catch saves a photo but no
    /// bracket should be baked (no recorded position, or the target was
    /// off-frame at exposure) — otherwise the raw sensor-landscape 12 MP
    /// bytes would land in the Hangar verbatim. Returns nil when the JPEG
    /// can't be decoded; callers fall back to the raw bytes.
    static func normalizedWithoutBracket(jpegData: Data) -> Data? {
        guard let image = UIImage(data: jpegData) else { return nil }
        let photoSize = savedPhotoSize(for: image.size)
        guard photoSize.width > 0, photoSize.height > 0 else { return nil }
        // Skip the decode→re-encode when the photo is already saved-size
        // and upright — legacy 1080p captures pass through untouched.
        if photoSize == image.size, image.imageOrientation == .up {
            return jpegData
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: photoSize, format: format)
            .image { ctx in
                ctx.cgContext.interpolationQuality = .high
                image.draw(in: CGRect(origin: .zero, size: photoSize))
            }
        return rendered.jpegData(compressionQuality: 0.9)
    }

    private static func drawCornerBrackets(
        in cg: CGContext,
        center: CGPoint,
        boxSize: CGFloat,
        armLength: CGFloat,
        lineWidth: CGFloat,
        color: UIColor,
        haloColor: UIColor,
        haloWidth: CGFloat
    ) {
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        // Halo pass: wider dark under-stroke so the bracket reads against a
        // bright sky. Drawn first, beneath the colored pass.
        strokeBracketPaths(in: cg, center: center, boxSize: boxSize,
                           armLength: armLength, color: haloColor,
                           lineWidth: lineWidth + 2 * haloWidth)
        // Colored pass on top.
        strokeBracketPaths(in: cg, center: center, boxSize: boxSize,
                           armLength: armLength, color: color,
                           lineWidth: lineWidth)
    }

    /// Strokes the four L-shaped corner brackets in one color + width. Shared
    /// by the halo and colored passes; line cap/join are set by the caller.
    private static func strokeBracketPaths(
        in cg: CGContext,
        center: CGPoint,
        boxSize: CGFloat,
        armLength: CGFloat,
        color: UIColor,
        lineWidth: CGFloat
    ) {
        let half = boxSize / 2
        let left = center.x - half
        let right = center.x + half
        let top = center.y - half
        let bottom = center.y + half

        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)

        // top-left
        cg.move(to: CGPoint(x: left, y: top + armLength))
        cg.addLine(to: CGPoint(x: left, y: top))
        cg.addLine(to: CGPoint(x: left + armLength, y: top))
        cg.strokePath()

        // top-right
        cg.move(to: CGPoint(x: right - armLength, y: top))
        cg.addLine(to: CGPoint(x: right, y: top))
        cg.addLine(to: CGPoint(x: right, y: top + armLength))
        cg.strokePath()

        // bottom-left
        cg.move(to: CGPoint(x: left, y: bottom - armLength))
        cg.addLine(to: CGPoint(x: left, y: bottom))
        cg.addLine(to: CGPoint(x: left + armLength, y: bottom))
        cg.strokePath()

        // bottom-right
        cg.move(to: CGPoint(x: right - armLength, y: bottom))
        cg.addLine(to: CGPoint(x: right, y: bottom))
        cg.addLine(to: CGPoint(x: right, y: bottom - armLength))
        cg.strokePath()
    }
}

/// Pure coordinate transform between the on-screen camera preview (which
/// uses `.resizeAspectFill`) and the captured photo's pixel space.
///
/// AVCaptureVideoPreviewLayer with `.resizeAspectFill` scales the photo
/// to fully cover the preview view — `scale = max(W_s/W_p, H_s/H_p)` —
/// so the photo's smaller-aspect dimension is cropped equally on both
/// sides. The inverse (screen → photo) divides by that scale after
/// undoing the centering offset.
///
/// Factored out and made internal so the math is unit-testable without
/// spinning up UIImage / CoreGraphics.
///
/// `nonisolated` because it's pure geometry (CGFloat/CGPoint/CGSize, no
/// main-thread state) called from `CatchPhotoComposer.compose` — which
/// runs off-main on the photo-capture path. Without this, Xcode 26's
/// default MainActor isolation makes `scale`/`photoPoint` main-isolated
/// and the nonisolated `compose` call site warns (and would hard-error
/// under Swift 6 language mode). Same pattern as `Aircraft`/`Geo`.
nonisolated struct AspectFillTransform: Equatable {
    let screenSize: CGSize
    let photoSize: CGSize

    /// The factor used to scale photo pixels up to screen points so the
    /// photo covers the screen. Always ≥ max(W_s/W_p, H_s/H_p).
    var scale: CGFloat {
        max(
            screenSize.width / photoSize.width,
            screenSize.height / photoSize.height
        )
    }

    /// Convert a point in screen coordinates (top-left origin) to the
    /// corresponding point in photo-pixel coordinates.
    func photoPoint(fromScreenPoint screenPoint: CGPoint) -> CGPoint {
        let s = scale
        let offsetX = (screenSize.width - photoSize.width * s) / 2.0
        let offsetY = (screenSize.height - photoSize.height * s) / 2.0
        return CGPoint(
            x: (screenPoint.x - offsetX) / s,
            y: (screenPoint.y - offsetY) / s
        )
    }

    /// Inverse of `photoPoint(fromScreenPoint:)`: photo-pixel → screen
    /// point. Used by visual confirmation to map a detector hit (found in
    /// camera-buffer pixels) back onto the AR overlay's coordinate space.
    func screenPoint(fromPhotoPoint photoPoint: CGPoint) -> CGPoint {
        let s = scale
        let offsetX = (screenSize.width - photoSize.width * s) / 2.0
        let offsetY = (screenSize.height - photoSize.height * s) / 2.0
        return CGPoint(
            x: photoPoint.x * s + offsetX,
            y: photoPoint.y * s + offsetY
        )
    }
}
