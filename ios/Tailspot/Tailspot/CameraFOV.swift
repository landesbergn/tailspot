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
//  Scope — only screens WIDER than the video change. Every slab iPhone
//  (iPhone SE's 16:9 included) is narrower than 9:16 and returns the
//  reference 56 × 72 exactly, so existing devices can't regress. Wider
//  screens (iPhone Duo, both displays) get a pinhole re-crop of the
//  iPhone 16 calibration: tan(half angle) scales with the visible extent.
//
//  Caveat: the hand-tuned reference constants don't fit a pure pinhole
//  (factor `k` ≈ 1.6, where 1 would be consistent), so the Duo numbers
//  are an estimate, not a measurement. They also assume the 9:16 preview
//  format; CameraPreview logs the real format at session start so that
//  assumption can be checked on device. See docs/iphone-duo.md.
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

        // Screen narrower than the video (every slab iPhone): keep the
        // field-tuned constants untouched.
        guard aspect > previewAspect else {
            return (referenceHfovDeg, referenceVfovDeg)
        }
        // Screen wider than the video (iPhone Duo): the full width is
        // visible, the top and bottom are cropped.
        let tanH = tanV0 * previewAspect * k
        let tanV = tanH / (aspect * k)
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
