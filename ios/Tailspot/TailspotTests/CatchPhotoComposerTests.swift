//
//  CatchPhotoComposerTests.swift
//  TailspotTests
//
//  The screen→photo coordinate transform is the easy thing to get wrong:
//  off-by-half-an-image lands the bracket nowhere near the plane. Covers
//  the aspect-fill math directly (no UIImage needed) plus a smoke test
//  for the full compose path.
//

import Testing
import CoreGraphics
import UIKit
@testable import Tailspot

@Suite("CatchPhotoComposer")
struct CatchPhotoComposerTests {

    // MARK: AspectFillTransform

    /// Screen and photo share the same aspect ratio → scale is the simple
    /// ratio, no offset, and the screen center maps to the photo center.
    @Test func sameAspectRatioMapsCenterToCenter() {
        let t = AspectFillTransform(
            screenSize: CGSize(width: 300, height: 400),
            photoSize:  CGSize(width: 600, height: 800)
        )
        #expect(abs(t.scale - 0.5) < 1e-9)
        let center = t.photoPoint(
            fromScreenPoint: CGPoint(x: 150, y: 200)
        )
        #expect(abs(center.x - 300) < 1e-9)
        #expect(abs(center.y - 400) < 1e-9)
    }

    /// Photo is wider than the screen (after aspect fill the photo is
    /// cropped on the sides). Screen-center maps to photo-center; screen
    /// edges map inward (cropped portion isn't on screen).
    @Test func wideAspectPhotoCropsSidesAndCentersVertically() {
        // Screen 400×800 (tall portrait), photo 3000×4000 (4:3 portrait).
        // Photo aspect (0.75) < screen aspect (0.5)? Actually photo
        // aspect 3000/4000 = 0.75 > screen 400/800 = 0.5, so to fill,
        // we scale by H_s/H_p = 800/4000 = 0.2; photo width on screen
        // becomes 3000×0.2 = 600 > 400, so it crops the sides.
        let t = AspectFillTransform(
            screenSize: CGSize(width: 400, height: 800),
            photoSize:  CGSize(width: 3000, height: 4000)
        )
        // scale = max(400/3000, 800/4000) = max(0.133, 0.2) = 0.2
        #expect(abs(t.scale - 0.2) < 1e-9)
        // Screen center (200, 400) → photo center (1500, 2000)
        let c = t.photoPoint(fromScreenPoint: CGPoint(x: 200, y: 400))
        #expect(abs(c.x - 1500) < 1e-6)
        #expect(abs(c.y - 2000) < 1e-6)
        // Screen top-left (0, 0): photo-pixel is offset to the cropped
        // edge. offsetX = (400 - 3000×0.2)/2 = (400 - 600)/2 = -100.
        // So (0,0) screen → ((0 - (-100))/0.2, 0/0.2) = (500, 0).
        let topLeft = t.photoPoint(fromScreenPoint: .zero)
        #expect(abs(topLeft.x - 500) < 1e-6)
        #expect(abs(topLeft.y - 0) < 1e-6)
    }

    /// Photo is taller-aspect than screen — fill clamps width, crops top
    /// and bottom. (Inverse of the previous case.)
    @Test func tallAspectPhotoCropsTopAndBottom() {
        // Screen 400×800 (portrait), photo 400×1600 (very tall).
        // scale = max(400/400, 800/1600) = max(1.0, 0.5) = 1.0
        // Photo width on screen = 400×1 = 400 = screen width (exact fit).
        // Photo height on screen = 1600×1 = 1600 > 800 → crops top/bottom.
        let t = AspectFillTransform(
            screenSize: CGSize(width: 400, height: 800),
            photoSize:  CGSize(width: 400, height: 1600)
        )
        #expect(abs(t.scale - 1.0) < 1e-9)
        // Screen center (200, 400) → photo (200, 800).
        let c = t.photoPoint(fromScreenPoint: CGPoint(x: 200, y: 400))
        #expect(abs(c.x - 200) < 1e-6)
        #expect(abs(c.y - 800) < 1e-6)
        // Screen top-left (0,0): offsetY = (800 - 1600×1)/2 = -400.
        // photoY = (0 - (-400))/1.0 = 400.
        let topLeft = t.photoPoint(fromScreenPoint: .zero)
        #expect(abs(topLeft.x - 0) < 1e-6)
        #expect(abs(topLeft.y - 400) < 1e-6)
    }

    /// Realistic iPhone scenario: 393×852 screen, 3024×4032 portrait
    /// photo (12MP back camera rotated to portrait). Sanity-check that
    /// a tap at screen center lands at the photo's center.
    @Test func iPhonePortraitGeometrySanityCheck() {
        let t = AspectFillTransform(
            screenSize: CGSize(width: 393, height: 852),
            photoSize:  CGSize(width: 3024, height: 4032)
        )
        // scale = max(393/3024, 852/4032) = max(0.1299, 0.2113) ≈ 0.2113
        #expect(t.scale > 0.21)
        #expect(t.scale < 0.22)
        let center = t.photoPoint(
            fromScreenPoint: CGPoint(x: 196.5, y: 426)
        )
        #expect(abs(center.x - 1512) < 0.5)
        #expect(abs(center.y - 2016) < 0.5)
    }

    // MARK: compose() smoke

    /// End-to-end: feed a generated JPEG through `compose` and make sure
    /// we get JPEG bytes back. Doesn't verify pixel-level output (the
    /// transform tests already pin the math) but exercises the full
    /// UIImage → CG draw → JPEG re-encode pipeline.
    @Test func composeReturnsNewJPEGForValidInput() {
        let imageBytes = makeSolidJPEG(
            size: CGSize(width: 600, height: 800),
            color: .black
        )
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: CGPoint(x: 100, y: 200),
            screenSize: CGSize(width: 300, height: 400)
        )
        let result = CatchPhotoComposer.compose(
            jpegData: imageBytes, overlay: overlay
        )
        #expect(result != nil)
        // JPEG magic: starts with 0xFF 0xD8.
        if let result, result.count >= 2 {
            #expect(result[0] == 0xFF)
            #expect(result[1] == 0xD8)
        }
    }

    /// Invalid JPEG bytes should return nil rather than crash.
    @Test func composeReturnsNilForInvalidJPEG() {
        let bogus = Data([0x00, 0x01, 0x02, 0x03])
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: CGPoint(x: 10, y: 10),
            screenSize: CGSize(width: 100, height: 100)
        )
        #expect(CatchPhotoComposer.compose(jpegData: bogus, overlay: overlay) == nil)
    }

    /// Zero-area screen size should return nil (no transform to compute).
    @Test func composeReturnsNilForZeroScreenSize() {
        let imageBytes = makeSolidJPEG(
            size: CGSize(width: 200, height: 200),
            color: .black
        )
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: .zero,
            screenSize: .zero
        )
        #expect(CatchPhotoComposer.compose(jpegData: imageBytes, overlay: overlay) == nil)
    }

    // MARK: helpers

    /// Synthesize a tiny solid-color JPEG for tests.
    private func makeSolidJPEG(size: CGSize, color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
