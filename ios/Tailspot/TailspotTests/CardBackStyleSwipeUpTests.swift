//
//  CardBackStyleSwipeUpTests.swift
//  TailspotTests
//
//  Pins the "Swipe up" card-back style's pure decisions (PullUpMath): the
//  drag → progress mapping, the release decision (distance vs flick), the
//  Reduce Motion threshold, the tucked-back geometry that keeps the slot
//  height fixed, and the front's recede curve.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Card back: swipe up")
struct CardBackStyleSwipeUpTests {
    let h: CGFloat = 500
    var travel: CGFloat { h - PullUpMath.tuck }

    // MARK: Progress

    @Test func restingProgressWithoutDrag() {
        #expect(PullUpMath.progress(startShown: false, translationY: 0, frontHeight: h) == 0)
        #expect(PullUpMath.progress(startShown: true, translationY: 0, frontHeight: h) == 1)
    }

    @Test func dragUpRaisesProgressProportionally() {
        let p = PullUpMath.progress(startShown: false, translationY: -travel / 2, frontHeight: h)
        #expect(abs(p - 0.5) < 1e-9)
    }

    @Test func dragDownFromShownLowersProgress() {
        let p = PullUpMath.progress(startShown: true, translationY: travel / 4, frontHeight: h)
        #expect(abs(p - 0.75) < 1e-9)
    }

    @Test func progressClampsAtBothEnds() {
        #expect(PullUpMath.progress(startShown: false, translationY: 200, frontHeight: h) == 0)
        #expect(PullUpMath.progress(startShown: true, translationY: -200, frontHeight: h) == 1)
        #expect(PullUpMath.progress(startShown: false, translationY: -5000, frontHeight: h) == 1)
    }

    @Test func unmeasuredFrontKeepsTheRestingProgress() {
        #expect(PullUpMath.progress(startShown: false, translationY: -100, frontHeight: 0) == 0)
        #expect(PullUpMath.progress(startShown: true, translationY: 100, frontHeight: 0) == 1)
    }

    // MARK: Release decision

    @Test func shortSlowPullTucksBack() {
        #expect(!PullUpMath.shouldShow(startShown: false, translationY: -60,
                                       velocityY: -100, frontHeight: h))
    }

    @Test func pullPastHalfwayShows() {
        #expect(PullUpMath.shouldShow(startShown: false, translationY: -travel * 0.6,
                                      velocityY: 0, frontHeight: h))
    }

    @Test func upwardFlickShowsWhateverTheDistance() {
        #expect(PullUpMath.shouldShow(startShown: false, translationY: -20,
                                      velocityY: -900, frontHeight: h))
    }

    @Test func downwardFlickTucksEvenFromPastHalfway() {
        #expect(!PullUpMath.shouldShow(startShown: false, translationY: -travel * 0.8,
                                       velocityY: 900, frontHeight: h))
    }

    @Test func shownBackStaysUpOnASmallDragDown() {
        #expect(PullUpMath.shouldShow(startShown: true, translationY: 40,
                                      velocityY: 100, frontHeight: h))
        #expect(!PullUpMath.shouldShow(startShown: true, translationY: travel * 0.6,
                                       velocityY: 0, frontHeight: h))
    }

    @Test func reduceMotionUsesDirectionPastThreshold() {
        #expect(PullUpMath.reduceMotionShouldShow(startShown: false, translationY: -40))
        #expect(!PullUpMath.reduceMotionShouldShow(startShown: true, translationY: 40))
        #expect(!PullUpMath.reduceMotionShouldShow(startShown: false, translationY: -10))
        #expect(PullUpMath.reduceMotionShouldShow(startShown: true, translationY: 10))
    }

    // MARK: Geometry

    @Test func tuckedBackPeeksExactlyTheTeaseBelowTheFront() {
        let top = PullUpMath.backTop(progress: 0, frontHeight: h)
        #expect(top == h - PullUpMath.tuck)
        // Visible portion of the back ends at the slot's bottom edge.
        let visible = PullUpMath.visibleHeight(progress: 0, frontHeight: h)
        #expect(top + visible == PullUpMath.slotHeight(frontHeight: h))
        #expect(visible == PullUpMath.tuck + PullUpMath.teaseHeight)
    }

    @Test func shownBackCoversTheFrontAndIsFullyVisible() {
        #expect(PullUpMath.backTop(progress: 1, frontHeight: h) == 0)
        #expect(PullUpMath.visibleHeight(progress: 1, frontHeight: h) >= h)
    }

    @Test func slotHeightDoesNotDependOnProgress() {
        for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            let bottom = PullUpMath.backTop(progress: p, frontHeight: h)
                + PullUpMath.visibleHeight(progress: p, frontHeight: h)
            #expect(bottom == PullUpMath.slotHeight(frontHeight: h))
        }
    }

    // MARK: Front recede, z-order, fades

    @Test func frontRecedesAndDimsWithProgress() {
        #expect(PullUpMath.frontScale(progress: 0) == 1)
        #expect(abs(PullUpMath.frontScale(progress: 1) - PullUpMath.recededFrontScale) < 1e-9)
        #expect(PullUpMath.frontDim(progress: 0) == 0)
        #expect(PullUpMath.frontDim(progress: 1) == PullUpMath.maxFrontDim)
        // Spring overshoot never over-shrinks or over-dims.
        #expect(PullUpMath.frontScale(progress: 1.2) == PullUpMath.frontScale(progress: 1))
        #expect(PullUpMath.frontDim(progress: -0.1) == 0)
    }

    @Test func backGrowsFromStackedScaleToFull() {
        #expect(PullUpMath.backScale(progress: 0) == PullUpMath.restBackScale)
        #expect(abs(PullUpMath.backScale(progress: 1) - 1) < 1e-9)
    }

    @Test func backDrawsAboveFrontOnlyOnceMoving() {
        #expect(!PullUpMath.backIsAboveFront(progress: 0))
        #expect(!PullUpMath.backIsAboveFront(progress: -0.02))
        #expect(PullUpMath.backIsAboveFront(progress: 0.05))
        #expect(PullUpMath.backIsAboveFront(progress: 1))
    }

    @Test func stripAndGrabberFadeAtOppositeEnds() {
        #expect(PullUpMath.stripOpacity(progress: 0) == 1)
        #expect(PullUpMath.stripOpacity(progress: 0.5) == 0)
        #expect(PullUpMath.grabberOpacity(progress: 0.5) == 0)
        #expect(abs(PullUpMath.grabberOpacity(progress: 1) - 1) < 1e-9)
    }
}
