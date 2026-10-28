//
//  CardFlipTests.swift
//  TailspotTests
//
//  Pins the card flip's pure decisions (CardFlipMath): the face switch at
//  exactly 90°, which way a swipe or tap turns the card, swipe
//  classification against vertical scrolling, the sheen, the peek's
//  policy, the turn-over button's VoiceOver label, and when a tap inside
//  the card counts as the tail of a swipe.
//

import Testing
import CoreGraphics
import Foundation
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

    // MARK: Sheen

    @Test func sheenIsInvisibleAtRestAndPeaksEdgeOn() {
        #expect(abs(CardFlipMath.sheenOpacity(angle: 0)) < 1e-9)
        #expect(abs(CardFlipMath.sheenOpacity(angle: 180)) < 1e-9)
        #expect(abs(CardFlipMath.sheenOpacity(angle: 90) - CardFlipMath.sheenPeak) < 1e-9)
        let quarter = CardFlipMath.sheenOpacity(angle: 45)
        #expect(quarter > 0 && quarter < CardFlipMath.sheenPeak)
    }

    /// The sheen sweeps across the face the same way whichever way, and
    /// however many times, the card has turned.
    @Test func halfTurnProgressCountsInTheTurnsDirection() {
        #expect(CardFlipMath.halfTurnProgress(angle: 0) == 0)
        #expect(CardFlipMath.halfTurnProgress(angle: 45) == 0.25)
        #expect(CardFlipMath.halfTurnProgress(angle: 225) == 0.25)
        #expect(CardFlipMath.halfTurnProgress(angle: -45) == 0.75)
        #expect(CardFlipMath.halfTurnProgress(angle: -135) == 0.25)
    }

    // MARK: Turn direction

    /// Swipe right, or tap the right half: the right edge goes away and
    /// the angle grows. Left is the mirror.
    @Test func swipeAndTapSidePickTheTurnsDirection() {
        #expect(CardFlipMath.turnedAngle(from: 0, direction: .right) == 180)
        #expect(CardFlipMath.turnedAngle(from: 0, direction: .left) == -180)
        #expect(CardFlipMath.turnedAngle(from: 180, direction: .right) == 360)
        #expect(CardFlipMath.tapDirection(x: 300, width: 353) == .right)
        #expect(CardFlipMath.tapDirection(x: 20, width: 353) == .left)
        #expect(CardFlipMath.tapDirection(x: 176.5, width: 353) == .right)
    }

    /// Turning the same way twice keeps going round: back, then the front
    /// again, never a snap backwards.
    @Test func turningTheSameWayKeepsGoingRound() {
        var angle = 0.0
        angle = CardFlipMath.turnedAngle(from: angle, direction: .left)
        #expect(CardFlipMath.visibleFace(angle: angle) == .back)
        angle = CardFlipMath.turnedAngle(from: angle, direction: .left)
        #expect(angle == -360)
        #expect(CardFlipMath.visibleFace(angle: angle) == .front)
    }

    /// With no gesture to say which way (VoiceOver, the screen), the card
    /// unwinds toward 0 — back the way it came.
    @Test func defaultDirectionUnwinds() {
        #expect(CardFlipMath.defaultDirection(from: 0) == .right)
        #expect(CardFlipMath.defaultDirection(from: 180) == .left)
        #expect(CardFlipMath.defaultDirection(from: -180) == .right)
        #expect(CardFlipMath.turnedAngle(from: 180, direction: CardFlipMath.defaultDirection(from: 180)) == 0)
    }

    // MARK: Peek

    @Test func peekShowsUntilACardIsTurnedOrItHasRunItsCourse() {
        #expect(CardFlipTease.shouldTease(hasTurnedACard: false, timesShown: 0))
        #expect(CardFlipTease.shouldTease(hasTurnedACard: false, timesShown: CardFlipTease.maxShows - 1))
        #expect(!CardFlipTease.shouldTease(hasTurnedACard: false, timesShown: CardFlipTease.maxShows))
        #expect(!CardFlipTease.shouldTease(hasTurnedACard: true, timesShown: 0))
    }

    /// The peek tilts far enough for the sheen to catch, never far enough
    /// to show the back.
    @Test func peekNeverShowsTheBack() {
        #expect(CardFlipMath.visibleFace(angle: CardFlipTease.peakDegrees) == .front)
        #expect(CardFlipMath.visibleFace(angle: -CardFlipTease.peakDegrees) == .front)
        #expect(CardFlipMath.sheenOpacity(angle: CardFlipTease.peakDegrees) > CardFlipMath.sheenPeak / 2)
    }

    // MARK: Button label

    @Test func turnOverButtonReadsInSentenceCase() {
        #expect(CardTurnOverButton.accessibilityLabel(for: "ABOUT THIS PLANE") == "About this plane")
        #expect(CardTurnOverButton.accessibilityLabel(for: "BACK TO CATCH") == "Back to catch")
        #expect(CardTurnOverButton.accessibilityLabel(for: "") == "")
    }

    /// The one control under the card names where the next turn goes.
    @Test func turnRowLabelFollowsTheFace() {
        #expect(CardTurnRow.title(flipped: false) == "ABOUT THIS PLANE")
        #expect(CardTurnRow.title(flipped: true) == "BACK TO CATCH")
    }

    /// The wrench panel's reset puts a tester back to a new user's state:
    /// the next card peeks again.
    @MainActor @Test func resettingThePeekMakesCardsPeekAgain() {
        let savedTurned = CardFlipTeaseStore.hasTurnedACard
        let savedShown = CardFlipTeaseStore.timesShown
        defer {
            CardFlipTeaseStore.hasTurnedACard = savedTurned
            CardFlipTeaseStore.timesShown = savedShown
        }
        CardFlipTeaseStore.hasTurnedACard = true
        CardFlipTeaseStore.timesShown = CardFlipTease.maxShows
        CardFlipTeaseStore.debugReset()
        #expect(!CardFlipTeaseStore.hasTurnedACard)
        #expect(CardFlipTeaseStore.timesShown == 0)
        #expect(CardFlipTease.shouldTease(hasTurnedACard: CardFlipTeaseStore.hasTurnedACard,
                                          timesShown: CardFlipTeaseStore.timesShown))
    }

    @Test func aTapDuringOrJustAfterASwipeIsPartOfIt() {
        let end = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(CardFlipMath.tapIsPartOfSwipe(dragging: true, swipeEndedAt: nil, now: end))
        #expect(CardFlipMath.tapIsPartOfSwipe(dragging: false, swipeEndedAt: end,
                                              now: end.addingTimeInterval(0.1)))
        #expect(!CardFlipMath.tapIsPartOfSwipe(dragging: false, swipeEndedAt: end,
                                               now: end.addingTimeInterval(CardFlipMath.swipeTapGrace + 0.01)))
        #expect(!CardFlipMath.tapIsPartOfSwipe(dragging: false, swipeEndedAt: nil, now: end))
    }

    @MainActor @Test func guardSwallowsTapsOnlyAroundADrag() {
        let guard_ = CardSwipeGuard()
        #expect(!guard_.swallowsTap)
        guard_.dragChanged()
        #expect(guard_.swallowsTap)
        guard_.dragEnded()
        #expect(guard_.swallowsTap, "the tap that lifts with the swipe is still swallowed")
    }
}
