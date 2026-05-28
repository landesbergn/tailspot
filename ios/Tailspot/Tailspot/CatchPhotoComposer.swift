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
    static let bracketScreenBoxSize: CGFloat = 56
    static let bracketScreenLineWidth: CGFloat = 2.5

    /// Cyan from `Brand.Color.cyan` (0x00D4FF). Duplicated here as a
    /// UIColor so the composer is independent of SwiftUI.
    static let bracketColor = UIColor(
        red: 0.0,
        green: 212.0 / 255.0,
        blue: 255.0 / 255.0,
        alpha: 1.0
    )

    /// Compose the JPEG with a cyan bracket drawn around the plane at
    /// `overlay.screenPosition`. Returns nil if the JPEG can't be
    /// decoded or if the dimensions are unusable; callers should fall
    /// back to the original `jpegData` in that case.
    static func compose(jpegData: Data, overlay: BracketOverlay) -> Data? {
        guard let image = UIImage(data: jpegData) else { return nil }
        let photoSize = image.size
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

        // Render at the photo's native pixel resolution (not the
        // device scale). A 12MP photo blown up 3× would be 36MP for no
        // visual gain after re-encoding to JPEG.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: photoSize, format: format)
        let composed = renderer.image { ctx in
            image.draw(in: CGRect(origin: .zero, size: photoSize))
            drawCornerBrackets(
                in: ctx.cgContext,
                center: center,
                boxSize: photoBoxSize,
                armLength: photoArm,
                lineWidth: photoLineWidth,
                color: bracketColor
            )
        }
        return composed.jpegData(compressionQuality: 0.9)
    }

    private static func drawCornerBrackets(
        in cg: CGContext,
        center: CGPoint,
        boxSize: CGFloat,
        armLength: CGFloat,
        lineWidth: CGFloat,
        color: UIColor
    ) {
        let half = boxSize / 2
        let left = center.x - half
        let right = center.x + half
        let top = center.y - half
        let bottom = center.y + half

        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

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
struct AspectFillTransform: Equatable {
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
}
