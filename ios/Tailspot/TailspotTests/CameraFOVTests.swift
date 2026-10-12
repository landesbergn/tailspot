//
//  CameraFOVTests.swift
//  TailspotTests
//
//  The aspect-aware FOV must (1) leave every slab iPhone exactly where the
//  hand-tuned 56° × 72° put it, and (2) re-crop correctly for iPhone Duo's
//  wider inner display, where aspect-fill trades the top/bottom of the
//  video for its full width.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("CameraFOV")
struct CameraFOVTests {

    private let iPhone16 = CGSize(width: 393, height: 852)
    /// iPhone Duo inner display, portrait (1878 × 2670 px — only the
    /// ratio matters here).
    private let duoInner = CGSize(width: 1878, height: 2670)
    /// iPhone Duo outer display, portrait (1398 × 2034 px).
    private let duoOuter = CGSize(width: 1398, height: 2034)

    @Test func referenceScreenIsUnchanged() {
        let fov = CameraFOV.base(for: iPhone16)
        #expect(abs(fov.hfovDeg - 56) < 1e-9)
        #expect(abs(fov.vfovDeg - 72) < 1e-9)
    }

    @Test func otherSlabIPhonesStayWithinADegree() {
        // 16 Pro Max (440 × 956) and 16e (390 × 844): same tall shape.
        for size in [CGSize(width: 440, height: 956), CGSize(width: 390, height: 844)] {
            let fov = CameraFOV.base(for: size)
            #expect(abs(fov.hfovDeg - 56) < 1)
            #expect(abs(fov.vfovDeg - 72) < 1e-9)
        }
    }

    @Test func narrowScreenKeepsFullVideoHeight() {
        // Anything narrower than the 9:16 video shows its full height, so
        // vertical FOV is pinned while horizontal follows the width.
        let narrow = CameraFOV.base(for: CGSize(width: 300, height: 900))
        #expect(abs(narrow.vfovDeg - 72) < 1e-9)
        #expect(narrow.hfovDeg < 56)
    }

    @Test func duoInnerTradesHeightForWidth() {
        // Wider than 9:16 → full video width visible, top/bottom cropped.
        let fov = CameraFOV.base(for: duoInner)
        #expect(fov.hfovDeg > 56)
        #expect(fov.vfovDeg < 72)
        // Pinned numbers (≈ 66° × 60°) so an accidental model change is loud.
        #expect(abs(fov.hfovDeg - 65.9) < 0.5)
        #expect(abs(fov.vfovDeg - 60.3) < 0.5)
    }

    @Test func widthCropSaturatesAtTheVideoEdge() {
        // Past 9:16 the horizontal FOV can't grow — there's no more video.
        let duo = CameraFOV.base(for: duoInner)
        let wider = CameraFOV.base(for: CGSize(width: 1000, height: 1100))
        #expect(abs(duo.hfovDeg - wider.hfovDeg) < 1e-9)
        #expect(wider.vfovDeg < duo.vfovDeg)
    }

    @Test func continuousAtTheVideoAspect() {
        // The two crop regimes must meet at exactly 9:16 — no jump.
        let below = CameraFOV.base(for: CGSize(width: 9 - 1e-6, height: 16))
        let above = CameraFOV.base(for: CGSize(width: 9 + 1e-6, height: 16))
        #expect(abs(below.hfovDeg - above.hfovDeg) < 1e-3)
        #expect(abs(below.vfovDeg - above.vfovDeg) < 1e-3)
    }

    @Test func duoOuterIsAlsoWiderThanTheVideo() {
        // The cover display (≈ 0.69) is wider than 9:16 too, so it gets
        // the width-limited crop, close to the inner display's.
        let outer = CameraFOV.base(for: duoOuter)
        let inner = CameraFOV.base(for: duoInner)
        #expect(outer.hfovDeg == inner.hfovDeg)
        #expect(abs(outer.vfovDeg - inner.vfovDeg) < 2)
    }

    @Test func degenerateSizeFallsBackToReference() {
        let fov = CameraFOV.base(for: .zero)
        #expect(fov.hfovDeg == 56)
        #expect(abs(fov.vfovDeg - 72) < 1e-9)
    }

    @Test func zoomDividesBothAxes() {
        let fov = CameraFOV.effective(for: iPhone16, zoom: 2)
        #expect(abs(fov.hfovDeg - 28) < 1e-9)
        #expect(abs(fov.vfovDeg - 36) < 1e-9)
    }

    // MARK: SpottingLayout

    @Test func portraitScreensAreNotSideways() {
        #expect(!SpottingLayout.isSideways(iPhone16))
        #expect(!SpottingLayout.isSideways(duoInner))
        #expect(!SpottingLayout.isSideways(duoOuter))
    }

    @Test func rotatedInnerDisplayIsSideways() {
        #expect(SpottingLayout.isSideways(CGSize(width: duoInner.height, height: duoInner.width)))
    }

    @Test func zeroSizeIsNotSideways() {
        #expect(!SpottingLayout.isSideways(.zero))
    }
}
