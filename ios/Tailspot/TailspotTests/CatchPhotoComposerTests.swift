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
        if let data = result?.jpegData, data.count >= 2 {
            #expect(data[0] == 0xFF)
            #expect(data[1] == 0xD8)
        }
        // Screen and photo share the aspect here (300×400 vs 600×800), so
        // screen (100, 200) → photo (200, 400) → normalized (1/3, 1/2).
        if let focus = result?.normalizedFocus {
            #expect(abs(focus.x - 1.0 / 3.0) < 1e-6)
            #expect(abs(focus.y - 0.5) < 1e-6)
        }
    }

    // MARK: normalizedFocus

    /// Same-aspect screen/photo: normalization is the plain screen ratio.
    @Test func normalizedFocusMapsSameAspectDirectly() {
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: CGPoint(x: 75, y: 300),
            screenSize: CGSize(width: 300, height: 400)
        )
        let f = CatchPhotoComposer.normalizedFocus(
            overlay: overlay, photoSize: CGSize(width: 600, height: 800)
        )
        #expect(abs(f.x - 0.25) < 1e-6)
        #expect(abs(f.y - 0.75) < 1e-6)
    }

    /// A screen point projected outside the photo (possible when the plane
    /// sits at the aspect-fill crop edge) clamps to 0…1 instead of leaking
    /// an out-of-range focus into the store.
    @Test func normalizedFocusClampsToUnitRange() {
        // Photo much wider than the screen: screen x=0 maps INTO the photo
        // (cropped region), but a negative-x screen point maps before it.
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: CGPoint(x: -500, y: -500),
            screenSize: CGSize(width: 400, height: 800)
        )
        let f = CatchPhotoComposer.normalizedFocus(
            overlay: overlay, photoSize: CGSize(width: 3000, height: 4000)
        )
        #expect(f.x >= 0 && f.x <= 1)
        #expect(f.y >= 0 && f.y <= 1)
        #expect(f.y == 0)
    }

    // MARK: FocusFill.layout

    /// Center focus reproduces plain aspect-fill: image centered, symmetric
    /// negative origin on the overflowing axis.
    @Test func focusFillCenterMatchesPlainFill() {
        let l = FocusFill.layout(
            imageSize: CGSize(width: 4000, height: 3000),
            frameSize: CGSize(width: 300, height: 168),
            focus: CGPoint(x: 0.5, y: 0.5)
        )
        // scale = max(300/4000, 168/3000) = 0.075 → 300×225
        #expect(abs(l.size.width - 300) < 1e-6)
        #expect(abs(l.size.height - 225) < 1e-6)
        #expect(abs(l.origin.x - 0) < 1e-6)
        #expect(abs(l.origin.y - (-28.5)) < 1e-6)   // (168 − 225)/2
    }

    /// An off-center focus slides the crop so the focus point lands at the
    /// frame center (when the image has room to slide).
    @Test func focusFillCentersTheFocusPoint(){
        let l = FocusFill.layout(
            imageSize: CGSize(width: 1000, height: 3000),
            frameSize: CGSize(width: 300, height: 168),
            focus: CGPoint(x: 0.5, y: 0.25)
        )
        // scale = max(0.3, 0.056) = 0.3 → 300×900; focus y in scaled = 225.
        // origin.y = 168/2 − 225 = −141 (within clamp range [−732, 0]).
        #expect(abs(l.origin.y - (-141)) < 1e-6)
        #expect(abs(l.origin.x - 0) < 1e-6)
    }

    /// A focus near the image edge clamps so the fill never exposes
    /// background past the image's own edge.
    @Test func focusFillClampsAtImageEdges() {
        let tall = CGSize(width: 1000, height: 3000)
        let frame = CGSize(width: 300, height: 168)
        let top = FocusFill.layout(imageSize: tall, frameSize: frame,
                                   focus: CGPoint(x: 0.5, y: 0.0))
        #expect(top.origin.y == 0)                    // can't slide above the top edge
        let bottom = FocusFill.layout(imageSize: tall, frameSize: frame,
                                      focus: CGPoint(x: 0.5, y: 1.0))
        #expect(abs(bottom.origin.y - (168 - 900)) < 1e-6)  // flush with the bottom edge
    }

    /// Degenerate inputs (zero-size image or frame) fall back to a no-op
    /// layout instead of dividing by zero.
    @Test func focusFillHandlesDegenerateSizes() {
        let l = FocusFill.layout(imageSize: .zero,
                                 frameSize: CGSize(width: 300, height: 168),
                                 focus: CGPoint(x: 0.5, y: 0.5))
        #expect(l.size == CGSize(width: 300, height: 168))
        #expect(l.origin == .zero)
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

    // MARK: saved-size cap + bracket-less normalization

    /// Small photos save at their own size; a 12 MP still caps at 3072 on
    /// the long side, preserving aspect.
    @Test func savedPhotoSizeCapsOnlyOversizedPhotos() {
        let legacy = CGSize(width: 1080, height: 1920)
        #expect(CatchPhotoComposer.savedPhotoSize(for: legacy) == legacy)
        let full = CatchPhotoComposer.savedPhotoSize(
            for: CGSize(width: 3024, height: 4032))
        #expect(full == CGSize(width: 2304, height: 3072))
    }

    /// Composing a photo bigger than the cap writes the capped size (and
    /// the focus normalization stays cap-independent).
    @Test func composeCapsOversizedOutput() {
        let imageBytes = makeSolidJPEG(
            size: CGSize(width: 3200, height: 6400), color: .black)
        let overlay = CatchPhotoComposer.BracketOverlay(
            screenPosition: CGPoint(x: 100, y: 200),
            screenSize: CGSize(width: 300, height: 600)
        )
        let result = CatchPhotoComposer.compose(jpegData: imageBytes, overlay: overlay)
        let saved = result.flatMap { UIImage(data: $0.jpegData) }
        #expect(saved?.size == CGSize(width: 1536, height: 3072))
        // Same aspect as the screen → focus is the plain screen ratio,
        // unaffected by the cap.
        if let focus = result?.normalizedFocus {
            #expect(abs(focus.x - 1.0 / 3.0) < 1e-6)
            #expect(abs(focus.y - 1.0 / 3.0) < 1e-6)
        }
    }

    /// Bracket-less normalization: an EXIF-rotated "sensor" JPEG comes out
    /// upright and capped; an already-upright, already-small JPEG passes
    /// through byte-identical (no needless re-encode of legacy captures).
    @Test func normalizedWithoutBracketUprightsAndCaps() {
        // Landscape pixels tagged .right → portrait content 3024×4032 → capped.
        let landscape = makeSolidJPEG(
            size: CGSize(width: 4032, height: 3024), color: .black, orientation: .right)
        let out = CatchPhotoComposer.normalizedWithoutBracket(jpegData: landscape)
        let img = out.flatMap { UIImage(data: $0) }
        #expect(img?.imageOrientation == .up)
        #expect(img?.size == CGSize(width: 2304, height: 3072))

        let small = makeSolidJPEG(size: CGSize(width: 1080, height: 1920), color: .black)
        #expect(CatchPhotoComposer.normalizedWithoutBracket(jpegData: small) == small)
    }

    // MARK: helpers

    /// Synthesize a tiny solid-color JPEG for tests. A non-.up
    /// `orientation` writes the EXIF tag the way AVFoundation does for
    /// sensor-landscape stills.
    private func makeSolidJPEG(size: CGSize, color: UIColor,
                               orientation: UIImage.Orientation = .up) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        if orientation != .up, let cg = image.cgImage {
            image = UIImage(cgImage: cg, scale: 1, orientation: orientation)
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
