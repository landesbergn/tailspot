//
//  CardBackStyleZoomTests.swift
//  TailspotTests
//
//  Pins the "Zoom in" card-back style's pure decisions (PhotoZoomMath): the
//  page lays the back out at the front's size, clamped to the screen, and
//  the haptic fires on open only.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Card back zoom math")
struct CardBackStyleZoomTests {

    @Test func unmeasuredFrontHasNoPageSize() {
        #expect(PhotoZoomMath.pageCardSize(frontSize: .zero, containerWidth: 393) == nil)
        #expect(PhotoZoomMath.pageCardSize(frontSize: CGSize(width: 361, height: 0),
                                           containerWidth: 393) == nil)
    }

    @Test func frontThatFitsKeepsItsSize() {
        let size = PhotoZoomMath.pageCardSize(frontSize: CGSize(width: 361, height: 620),
                                              containerWidth: 393)
        #expect(size == CGSize(width: 361, height: 620))
    }

    @Test func widerFrontIsClampedToThePageButKeepsItsHeight() {
        // 393 − 2 × 16 = 361 available.
        let size = PhotoZoomMath.pageCardSize(frontSize: CGSize(width: 393, height: 640),
                                              containerWidth: 393)
        #expect(size == CGSize(width: 361, height: 640))
    }

    @Test func customInsetIsHonoured() {
        let size = PhotoZoomMath.pageCardSize(frontSize: CGSize(width: 400, height: 600),
                                              containerWidth: 400, inset: 20)
        #expect(size?.width == 360)
    }

    @Test func unmeasuredContainerFallsBackToTheFrontWidth() {
        let size = PhotoZoomMath.pageCardSize(frontSize: CGSize(width: 361, height: 620),
                                              containerWidth: 0)
        #expect(size == CGSize(width: 361, height: 620))
    }

    @Test func hapticOnOpenOnly() {
        #expect(PhotoZoomMath.playsOpenHaptic(old: false, new: true))
        #expect(!PhotoZoomMath.playsOpenHaptic(old: true, new: false))
        #expect(!PhotoZoomMath.playsOpenHaptic(old: false, new: false))
    }
}
