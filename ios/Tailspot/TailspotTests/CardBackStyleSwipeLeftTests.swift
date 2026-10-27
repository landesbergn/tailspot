//
//  CardBackStyleSwipeLeftTests.swift
//  TailspotTests
//
//  Pins the two swipe card-back styles' pure decisions: the shared two-page
//  pager (CardPagerMath — page offsets, when the scroll counts as resting
//  on a page, progress) and the swipe-left carousel's dim curve.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Card pager math")
struct CardPagerMathTests {
    /// A 357 pt card (393 pt screen − 2 × 18) plus the gap.
    let step: CGFloat = 357 + SwipePeekMath.gap

    @Test func bindingMapsToPages() {
        #expect(CardPagerMath.page(showingBack: false) == .front)
        #expect(CardPagerMath.page(showingBack: true) == .back)
    }

    @Test func pageOffsets() {
        #expect(CardPagerMath.offset(for: .front, step: step) == 0)
        #expect(CardPagerMath.offset(for: .back, step: step) == step)
    }

    @Test func restingOnlyWithinTolerance() {
        #expect(CardPagerMath.restingPage(offset: 0, step: step) == .front)
        #expect(CardPagerMath.restingPage(offset: 0.6, step: step) == .front)
        #expect(CardPagerMath.restingPage(offset: step - 0.6, step: step) == .back)
        #expect(CardPagerMath.restingPage(offset: step / 2, step: step) == nil)
        // Rubber-banding past either end isn't at rest.
        #expect(CardPagerMath.restingPage(offset: -20, step: step) == nil)
        #expect(CardPagerMath.restingPage(offset: step + 20, step: step) == nil)
    }

    @Test func unmeasuredPagerRestsOnTheFront() {
        #expect(CardPagerMath.restingPage(offset: 0, step: 0) == .front)
        #expect(CardPagerMath.progress(offset: 40, step: 0) == 0)
    }

    @Test func progressIsClampedFraction() {
        #expect(CardPagerMath.progress(offset: 0, step: step) == 0)
        #expect(abs(CardPagerMath.progress(offset: step / 4, step: step) - 0.25) < 1e-9)
        #expect(CardPagerMath.progress(offset: step, step: step) == 1)
        #expect(CardPagerMath.progress(offset: -30, step: step) == 0)
        #expect(CardPagerMath.progress(offset: step + 30, step: step) == 1)
    }
}

@Suite("Swipe-left card back math")
struct CardBackStyleSwipeLeftTests {
    @Test func dimsTheCardOffToTheSide() {
        #expect(SwipePeekMath.opacity(progress: 0, reduceMotion: false) == 1)
        #expect(SwipePeekMath.opacity(progress: 1, reduceMotion: false) == SwipePeekMath.peekOpacity)
        #expect(SwipePeekMath.opacity(progress: -1, reduceMotion: false) == SwipePeekMath.peekOpacity)
        let half = SwipePeekMath.opacity(progress: 0.5, reduceMotion: false)
        #expect(half < 1 && half > SwipePeekMath.peekOpacity)
        // Past the end (overscroll) stays at the peek opacity.
        #expect(SwipePeekMath.opacity(progress: 1.4, reduceMotion: false) == SwipePeekMath.peekOpacity)
    }

    @Test func reduceMotionStepsInsteadOfRamping() {
        #expect(SwipePeekMath.opacity(progress: 0.4, reduceMotion: true) == 1)
        #expect(SwipePeekMath.opacity(progress: 0.6, reduceMotion: true) == SwipePeekMath.peekOpacity)
    }
}
