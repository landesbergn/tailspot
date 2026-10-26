//
//  CardBackStyleSwipeLeftTests.swift
//  TailspotTests
//
//  Pins the "Swipe left" card-back carousel's pure decisions
//  (SwipePeekMath): page offsets, where a released swipe lands, when the
//  scroll counts as resting on a page, and the scale / dim curves with and
//  without Reduce Motion.
//

import Testing
import CoreGraphics
import SwiftUI
@testable import Tailspot

@Suite("Swipe-left card back math")
struct CardBackStyleSwipeLeftTests {
    /// A 357 pt card (393 pt screen − 2 × 18) plus the gap.
    let step: CGFloat = 357 + SwipePeekMath.gap

    // MARK: Pages and offsets

    @Test func bindingMapsToPages() {
        #expect(SwipePeekMath.page(showingBack: false) == .front)
        #expect(SwipePeekMath.page(showingBack: true) == .back)
    }

    @Test func pageOffsets() {
        #expect(SwipePeekMath.offset(for: .front, step: step) == 0)
        #expect(SwipePeekMath.offset(for: .back, step: step) == step)
    }

    // MARK: Snapping

    @Test func shortDragSpringsBack() {
        let small = step * SwipePeekMath.commitFraction - 1
        #expect(SwipePeekMath.targetPage(from: .front, projectedOffset: small, step: step) == .front)
        #expect(SwipePeekMath.targetPage(from: .back, projectedOffset: step - small, step: step) == .back)
    }

    @Test func quarterPageOrFlickTurnsThePage() {
        let enough = step * SwipePeekMath.commitFraction + 1
        #expect(SwipePeekMath.targetPage(from: .front, projectedOffset: enough, step: step) == .back)
        #expect(SwipePeekMath.targetPage(from: .back, projectedOffset: step - enough, step: step) == .front)
        // A hard flick projects far past the end: still just one page.
        #expect(SwipePeekMath.targetPage(from: .front, projectedOffset: step * 3, step: step) == .back)
        #expect(SwipePeekMath.targetPage(from: .back, projectedOffset: -step * 2, step: step) == .front)
    }

    @Test func swipingTowardTheEdgeStaysPut() {
        // Swiping right on the front (rubber-band) or left on the back.
        #expect(SwipePeekMath.targetPage(from: .front, projectedOffset: -200, step: step) == .front)
        #expect(SwipePeekMath.targetPage(from: .back, projectedOffset: step + 200, step: step) == .back)
    }

    @Test func unmeasuredCardNeverPages() {
        #expect(SwipePeekMath.targetPage(from: .front, projectedOffset: 500, step: 0) == .front)
    }

    // MARK: Resting

    @Test func restingPageOnlyAtAPage() {
        #expect(SwipePeekMath.restingPage(offset: 0, step: step) == .front)
        #expect(SwipePeekMath.restingPage(offset: 0.5, step: step) == .front)
        #expect(SwipePeekMath.restingPage(offset: step, step: step) == .back)
        #expect(SwipePeekMath.restingPage(offset: step - 0.5, step: step) == .back)
        #expect(SwipePeekMath.restingPage(offset: step / 2, step: step) == nil)
        #expect(SwipePeekMath.restingPage(offset: -20, step: step) == nil)
        #expect(SwipePeekMath.restingPage(offset: step + 20, step: step) == nil)
    }

    // MARK: Scale and dim

    @Test func scaleRampsToPeekScale() {
        #expect(SwipePeekMath.scale(progress: 0, reduceMotion: false) == 1)
        #expect(SwipePeekMath.scale(progress: 1, reduceMotion: false) == SwipePeekMath.peekScale)
        #expect(SwipePeekMath.scale(progress: -1, reduceMotion: false) == SwipePeekMath.peekScale)
        #expect(SwipePeekMath.scale(progress: 2, reduceMotion: false) == SwipePeekMath.peekScale)
        let half = SwipePeekMath.scale(progress: 0.5, reduceMotion: false)
        #expect(abs(half - (1 + SwipePeekMath.peekScale) / 2) < 0.0001)
    }

    @Test func opacityRampsToPeekOpacity() {
        #expect(SwipePeekMath.opacity(progress: 0, reduceMotion: false) == 1)
        #expect(SwipePeekMath.opacity(progress: 1, reduceMotion: false) == SwipePeekMath.peekOpacity)
        #expect(SwipePeekMath.opacity(progress: -1, reduceMotion: false) == SwipePeekMath.peekOpacity)
        let half = SwipePeekMath.opacity(progress: 0.5, reduceMotion: false)
        #expect(abs(half - (1 + SwipePeekMath.peekOpacity) / 2) < 0.0001)
    }

    @Test func reduceMotionHasNoScaleAndAStepDim() {
        for p in [-1.0, -0.4, 0, 0.3, 0.6, 1] {
            #expect(SwipePeekMath.scale(progress: p, reduceMotion: true) == 1)
        }
        #expect(SwipePeekMath.opacity(progress: 0.49, reduceMotion: true) == 1)
        #expect(SwipePeekMath.opacity(progress: 0.5, reduceMotion: true) == SwipePeekMath.peekOpacity)
        #expect(SwipePeekMath.opacity(progress: -0.8, reduceMotion: true) == SwipePeekMath.peekOpacity)
    }

    @Test func scaleAnchorsOnTheEdgeNearestTheSlot() {
        // Card to the right shrinks toward its leading edge (the peeking one).
        #expect(SwipePeekMath.scaleAnchor(progress: 1) == .leading)
        #expect(SwipePeekMath.scaleAnchor(progress: -1) == .trailing)
    }
}
