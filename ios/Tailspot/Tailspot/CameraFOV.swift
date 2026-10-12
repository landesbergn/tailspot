//
//  CameraFOV.swift
//  Tailspot
//
//  The camera's field of view AS SEEN ON SCREEN, which depends on the
//  screen's shape, not just the lens.
//
//  Why this exists: the projection math used fixed 56° × 72° (H × V)
//  constants, tuned by eye on an iPhone 16 in portrait. Those numbers are
//  only right for that screen shape. The preview uses `.resizeAspectFill`
//  (CameraPreview), so the video is scaled until it covers the screen and
//  the overflow is cropped: a tall, narrow iPhone crops the SIDES of the
//  9:16 video, while a wider screen — iPhone Duo's inner display is about
//  9:12.8 — crops the TOP AND BOTTOM instead. Same lens, different visible
//  slice of sky. Feeding the iPhone 16 numbers to an iPhone Duo would put
//  AR labels several degrees off toward the screen edges.
//
//  Model: a pinhole camera, so the visible half-extents scale as tan(half
//  angle). We keep the iPhone 16 calibration exactly (including whatever
//  H/V anisotropy the hand-tuned constants carry — factor `k`), and only
//  re-crop it for other aspect ratios. At the reference aspect this
//  returns 56 × 72 to floating-point precision, so existing iPhones are
//  unchanged.
//

import CoreGraphics
import Foundation

nonisolated enum CameraFOV {
    /// Hand-tuned 1× FOV on the reference device (iPhone 16, portrait,
    /// full-screen preview). Unchanged from the old ContentView constants.
    static let referenceHfovDeg: Double = 56
    static let referenceVfovDeg: Double = 72

    /// iPhone 16 full-screen portrait size in points (393 × 852) — the
    /// screen the reference constants were tuned on.
    static let referenceAspect: Double = 393.0 / 852.0

    /// Width / height of the preview video in portrait. The `.high`
    /// session preset delivers a 16:9 (1080p) format; rotated to portrait
    /// that is 9:16.
    static let previewAspect: Double = 9.0 / 16.0

    /// 1× field of view (degrees) for a full-screen preview of this size.
    /// A degenerate size (zero/negative) falls back to the reference.
    static func base(for screenSize: CGSize) -> (hfovDeg: Double, vfovDeg: Double) {
        guard screenSize.width > 0, screenSize.height > 0 else {
            return (referenceHfovDeg, referenceVfovDeg)
        }
        let aspect = Double(screenSize.width / screenSize.height)

        let tanH0 = tan(referenceHfovDeg / 2 * .pi / 180)
        let tanV0 = tan(referenceVfovDeg / 2 * .pi / 180)
        // Calibration anisotropy: how far the tuned constants sit from a
        // pure pinhole at the reference aspect. Preserved for every shape.
        let k = (tanH0 / tanV0) / referenceAspect

        let tanH: Double
        let tanV: Double
        if aspect <= previewAspect {
            // Screen narrower than the video (every slab iPhone): the
            // video's full height is visible, the sides are cropped.
            tanV = tanV0
            tanH = tanV0 * aspect * k
        } else {
            // Screen wider than the video (iPhone Duo inner display): the
            // full width is visible, the top and bottom are cropped.
            tanH = tanV0 * previewAspect * k
            tanV = tanH / (aspect * k)
        }
        return (2 * atan(tanH) * 180 / .pi, 2 * atan(tanV) * 180 / .pi)
    }

    /// Effective FOV at a digital zoom factor — the base FOV divided by
    /// zoom, matching how the projection math has always applied zoom.
    static func effective(for screenSize: CGSize, zoom: CGFloat) -> (hfovDeg: Double, vfovDeg: Double) {
        let b = base(for: screenSize)
        let z = Double(max(zoom, 1))
        return (b.hfovDeg / z, b.vfovDeg / z)
    }
}
