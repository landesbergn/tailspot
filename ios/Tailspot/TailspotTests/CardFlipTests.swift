//
//  CardFlipTests.swift
//  TailspotTests
//
//  Pins the card flip's pure decisions (CardFlipMath): the face switch at
//  exactly 90°, swipe classification against vertical scrolling, the sheen
//  and Reduce Motion crossfade curves, and the turn-over button's VoiceOver
//  label.
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Card flip math")
struct CardFlipTests {

    // MARK: Visible face

    @Test func restingAnglesShowTheRightFace() {
        #expect(CardFlipMath.restingAngle(isFlipped: false) == 0)
        #expect(CardFlipMath.restingAngle(isFlipped: true) == 180)
        #expect(CardFlipMath.visibleFace(angle: 0) == .front)
        #expect(CardFlipMath.visibleFace(angle: 180) == .back)
    }

    @Test func faceSwitchesAtExactlyNinetyDegrees() {
        #expect(CardFlipMath.visibleFace(angle: 45) == .front)
        #expect(CardFlipMath.visibleFace(angle: 89.999) == .front)
        #expect(CardFlipMath.visibleFace(angle: 90) == .back)
        #expect(CardFlipMath.visibleFace(angle: 135) == .back)
    }

    @Test func faceSwitchesBackAtTwoSeventyAndWraps() {
        #expect(CardFlipMath.visibleFace(angle: 269.9) == .back)
        #expect(CardFlipMath.visibleFace(angle: 270) == .front)
        #expect(CardFlipMath.visibleFace(angle: 360) == .front)
        #expect(CardFlipMath.visibleFace(angle: 540) == .back)
        #expect(CardFlipMath.visibleFace(angle: -45) == .front)
        #expect(CardFlipMath.visibleFace(angle: -135) == .back)
        // Spring overshoot past the resting angle keeps the same face.
        #expect(CardFlipMath.visibleFace(angle: 192) == .back)
        #expect(CardFlipMath.visibleFace(angle: -8) == .front)
    }

    // MARK: Swipe

    @Test func horizontalSwipePastThresholdFlips() {
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: -60, height: 10)) == .left)
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: 60, height: -10)) == .right)
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: 40, height: 0)) == .right)
    }

    @Test func shortOrVerticalDragsDoNotFlip() {
        // Too short.
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: 39, height: 0)) == nil)
        // A vertical scroll that drifts sideways belongs to the ScrollView.
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: 50, height: 120)) == nil)
        #expect(CardFlipMath.swipeDirection(translation: CGSize(width: -80, height: -80)) == nil)
        #expect(CardFlipMath.swipeDirection(translation: .zero) == nil)
    }

    @Test func thresholdIsFortyPoints() {
        #expect(CardFlipMath.swipeThreshold == 40)
    }

    // MARK: Sheen + crossfade

    @Test func sheenIsInvisibleAtRestAndPeaksEdgeOn() {
        #expect(abs(CardFlipMath.sheenOpacity(angle: 0)) < 1e-9)
        #expect(abs(CardFlipMath.sheenOpacity(angle: 180)) < 1e-9)
        #expect(abs(CardFlipMath.sheenOpacity(angle: 90) - CardFlipMath.sheenPeak) < 1e-9)
        let quarter = CardFlipMath.sheenOpacity(angle: 45)
        #expect(quarter > 0 && quarter < CardFlipMath.sheenPeak)
    }

    @Test func reduceMotionCrossfadeIsLinearAndClamped() {
        #expect(CardFlipMath.crossfadeOpacity(angle: 0, face: .front) == 1)
        #expect(CardFlipMath.crossfadeOpacity(angle: 0, face: .back) == 0)
        #expect(CardFlipMath.crossfadeOpacity(angle: 90, face: .front) == 0.5)
        #expect(CardFlipMath.crossfadeOpacity(angle: 90, face: .back) == 0.5)
        #expect(CardFlipMath.crossfadeOpacity(angle: 180, face: .back) == 1)
        #expect(CardFlipMath.crossfadeOpacity(angle: 200, face: .back) == 1)
        #expect(CardFlipMath.crossfadeOpacity(angle: -20, face: .front) == 1)
    }

    // MARK: Button label

    @Test func turnOverButtonReadsInSentenceCase() {
        #expect(CardTurnOverButton.accessibilityLabel(for: "ABOUT THIS PLANE") == "About this plane")
        #expect(CardTurnOverButton.accessibilityLabel(for: "BACK TO CATCH") == "Back to catch")
        #expect(CardTurnOverButton.accessibilityLabel(for: "") == "")
    }
}
