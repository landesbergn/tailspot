//
//  CardBackStyleRealFlipTests.swift
//  TailspotTests
//
//  Pins the "Real card flip" style's pure math (`RealFlipMath`): drag →
//  angle, release → resting side, the short-way-round resting angle, the
//  edge slices' order, and the lift / shadow / glare curves.
//

import Testing
import SwiftUI
@testable import Tailspot

@Suite("Real card flip math")
struct CardBackStyleRealFlipTests {

    // MARK: Angles

    @Test func wrappedLandsInHalfOpenRange() {
        #expect(RealFlipMath.wrapped(0) == 0)
        #expect(RealFlipMath.wrapped(180) == -180)
        #expect(RealFlipMath.wrapped(-180) == -180)
        #expect(RealFlipMath.wrapped(270) == -90)
        #expect(RealFlipMath.wrapped(450) == 90)
        #expect(RealFlipMath.wrapped(-450) == -90)
    }

    @Test func localAngleIsZeroForTheFaceShowing() {
        #expect(RealFlipMath.localAngle(angle: 0, isBack: false) == 0)
        #expect(RealFlipMath.localAngle(angle: 180, isBack: true) == 0)
        #expect(RealFlipMath.localAngle(angle: -180, isBack: true) == 0)
        #expect(RealFlipMath.localAngle(angle: 360, isBack: false) == 0)
        #expect(RealFlipMath.localAngle(angle: 60, isBack: false) == 60)
        #expect(RealFlipMath.localAngle(angle: 120, isBack: true) == -60)
    }

    @Test func restingAngleTakesTheShortWayAndTurnsForwardOnATie() {
        // From the front at rest, a tap turns forward to 180 (not -180).
        #expect(RealFlipMath.restingAngle(showingBack: true, near: 0) == 180)
        // From the back at rest, forward again to 360 — no spin back.
        #expect(RealFlipMath.restingAngle(showingBack: false, near: 180) == 360)
        // A card resting at -180 (dragged left) goes back to 0, the short way.
        #expect(RealFlipMath.restingAngle(showingBack: false, near: -180) == 0)
        // Already there: unchanged.
        #expect(RealFlipMath.restingAngle(showingBack: true, near: 540) == 540)
        #expect(RealFlipMath.restingAngle(showingBack: false, near: 720) == 720)
        // Mid-turn: nearest.
        #expect(RealFlipMath.restingAngle(showingBack: true, near: 100) == 180)
        #expect(RealFlipMath.restingAngle(showingBack: false, near: 100) == 0)
    }

    // MARK: Drag

    @Test func dragAngleFollowsTheFinger() {
        // A full card width is a half turn, in the drag's direction.
        #expect(RealFlipMath.dragAngle(start: 0, translation: 300, cardWidth: 300) == 180)
        #expect(RealFlipMath.dragAngle(start: 0, translation: -150, cardWidth: 300) == -90)
        #expect(RealFlipMath.dragAngle(start: 180, translation: 75, cardWidth: 300) == 225)
        #expect(RealFlipMath.dragAngle(start: 0, translation: 0, cardWidth: 300) == 0)
    }

    @Test func dragAngleRubberBandsPastHalfATurn() {
        // 400 pt on a 200 pt card = 360° raw → 180 + 180 × 0.25.
        #expect(RealFlipMath.dragAngle(start: 0, translation: 400, cardWidth: 200) == 225)
        #expect(RealFlipMath.dragAngle(start: 0, translation: -400, cardWidth: 200) == -225)
    }

    @Test func dragAngleSurvivesAnUnmeasuredCard() {
        let angle = RealFlipMath.dragAngle(start: 0, translation: 10, cardWidth: 0)
        #expect(angle.isFinite)
    }

    @Test func settleCompletesPastAQuarterTurn() {
        #expect(RealFlipMath.settleAngle(start: 0, projected: 95) == 180)
        #expect(RealFlipMath.settleAngle(start: 0, projected: -120) == -180)
        #expect(RealFlipMath.settleAngle(start: 180, projected: 60) == 0)
        #expect(RealFlipMath.settleAngle(start: 180, projected: 300) == 360)
    }

    @Test func settleFallsBackShortOfAQuarterTurn() {
        #expect(RealFlipMath.settleAngle(start: 0, projected: 89) == 0)
        #expect(RealFlipMath.settleAngle(start: 0, projected: -40) == 0)
        #expect(RealFlipMath.settleAngle(start: 180, projected: 200) == 180)
    }

    @Test func aHugeFlickStillTurnsOnlyOnce() {
        // A fling projecting 2.5 turns is clamped to one half turn.
        #expect(RealFlipMath.settleAngle(start: 0, projected: 900) == 180)
        #expect(RealFlipMath.settleAngle(start: 0, projected: -900) == -180)
    }

    @Test func settledSideMatchesTheVisibleFace() {
        let rest = RealFlipMath.settleAngle(start: 0, projected: 130)
        #expect(CardFlipMath.visibleFace(angle: rest) == .back)
        let back = RealFlipMath.settleAngle(start: rest, projected: rest - 130)
        #expect(CardFlipMath.visibleFace(angle: back) == .front)
    }

    @Test func onlyClearlyHorizontalDragsTurn() {
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: 30, height: 5), startX: 100) == .turn)
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: -30, height: 10), startX: 100) == .turn)
        // Diagonal-ish and vertical drags belong to the scroll view.
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: 20, height: 18), startX: 100) == .ignore)
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: 2, height: 40), startX: 100) == .ignore)
    }

    @Test func dragsFromTheLeadingEdgeAreLeftToSwipeBack() {
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: 40, height: 0), startX: 10) == .ignore)
        #expect(RealFlipMath.dragIntent(translation: CGSize(width: 40, height: 0),
                                        startX: RealFlipMath.leadingEdgeGuard) == .turn)
    }

    // MARK: Lift, shadow, light

    @Test func liftPeaksEdgeOnAndRestsFlat() {
        #expect(RealFlipMath.lift(angle: 0, hold: 0) == 0)
        #expect(abs(RealFlipMath.lift(angle: 180, hold: 0)) < 1e-9)
        #expect(abs(RealFlipMath.lift(angle: 90, hold: 0) - 1) < 1e-9)
        #expect(abs(RealFlipMath.lift(angle: -90, hold: 0) - 1) < 1e-9)
    }

    @Test func holdingTheCardPicksItUp() {
        #expect(RealFlipMath.lift(angle: 0, hold: 1) == RealFlipMath.holdLift)
        // Turning further lifts more than the hold alone.
        #expect(RealFlipMath.lift(angle: 60, hold: 1) > RealFlipMath.holdLift)
    }

    @Test func shadowGrowsSoftensAndDropsWithLift() {
        let rest = RealFlipMath.shadow(angle: 0, lift: 0)
        let up = RealFlipMath.shadow(angle: 90, lift: 1)
        #expect(up.radius > rest.radius)
        #expect(up.y > rest.y)
        #expect(up.opacity < rest.opacity)
        #expect(rest.x == 0)
        // Slides sideways, opposite ways for opposite turns.
        let left = RealFlipMath.shadow(angle: -90, lift: 1)
        #expect(up.x != 0)
        #expect(up.x == -left.x)
    }

    @Test func glareIsDarkAtRestAndEdgeOnAndPeaksMidTilt() {
        #expect(RealFlipMath.glare(localAngle: 0).opacity == 0)
        #expect(RealFlipMath.glare(localAngle: 90).opacity < 1e-9)
        let mid = RealFlipMath.glare(localAngle: 45)
        #expect(abs(mid.opacity - RealFlipMath.glarePeak) < 1e-9)
        #expect(RealFlipMath.glare(localAngle: 20).opacity < mid.opacity)
    }

    @Test func glareSweepsAcrossTheFace() {
        #expect(RealFlipMath.glare(localAngle: 0).center == 0.5)
        #expect(RealFlipMath.glare(localAngle: 60).center < 0.5)
        #expect(RealFlipMath.glare(localAngle: -60).center > 0.5)
    }

    @Test func faceDarkensAsItTiltsAway() {
        #expect(RealFlipMath.shade(localAngle: 0) == 0)
        #expect(abs(RealFlipMath.shade(localAngle: 90) - RealFlipMath.shadePeak) < 1e-9)
        #expect(RealFlipMath.shade(localAngle: 30) < RealFlipMath.shade(localAngle: 60))
    }

    // MARK: Thickness

    @Test func facesSitHalfTheThicknessOutAndShiftOppositeWays() {
        #expect(RealFlipMath.faceOffset(angle: 0, isBack: false) == 0)
        let front = RealFlipMath.faceOffset(angle: 90, isBack: false)
        let back = RealFlipMath.faceOffset(angle: 90, isBack: true)
        #expect(abs(front - RealFlipMath.thickness / 2) < 1e-9)
        #expect(abs(front + back) < 1e-9)
    }

    @Test func slicesLieBetweenTheFacesAndDrawBackToFront() {
        let t = RealFlipMath.thickness
        let frontUp = RealFlipMath.sliceDepths(angle: 30)
        #expect(frontUp.count == RealFlipMath.sliceCount)
        #expect(frontUp.allSatisfy { abs($0) < t / 2 })
        // Front up: the front-face side (positive depth) is nearest → last.
        #expect(frontUp == frontUp.sorted())
        // Back up: reversed.
        let backUp = RealFlipMath.sliceDepths(angle: 150)
        #expect(backUp == backUp.sorted(by: >))
        #expect(RealFlipMath.sliceDepths(angle: 0, count: 0).isEmpty)
    }

    @Test func slabHasALighterCore() {
        #expect(RealFlipMath.isCore(depth: 0))
        #expect(!RealFlipMath.isCore(depth: RealFlipMath.thickness / 2 * 0.9))
    }

    @Test func slabHidesAtRestAndShowsMidTurn() {
        #expect(!RealFlipMath.slabVisible(angle: 0))
        #expect(!RealFlipMath.slabVisible(angle: 180))
        #expect(!RealFlipMath.slabVisible(angle: 360))
        #expect(RealFlipMath.slabVisible(angle: 45))
        #expect(RealFlipMath.slabVisible(angle: 90))
    }

    @Test func slabNeverRendersExactlyEdgeOn() {
        let nudge = RealFlipMath.slabEdgeOnNudge
        for edgeOn in [90.0, 270, -90, 450] {
            for delta in [0.0, 0.3, -0.3] {
                let a = RealFlipMath.slabAngle(edgeOn + delta)
                var r = (a - 90).truncatingRemainder(dividingBy: 180)
                if r < 0 { r += 180 }
                let distance = min(r, 180 - r)
                #expect(distance >= nudge - 1e-9, "angle \(edgeOn + delta) → \(a)")
            }
        }
        // Away from edge-on it's untouched.
        #expect(RealFlipMath.slabAngle(45) == 45)
        #expect(RealFlipMath.slabAngle(135) == 135)
    }

    // MARK: Reduce Motion

    @Test func crossfadeDissolvesFrontToBack() {
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: 0, isBack: false) - 1) < 1e-9)
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: 0, isBack: true)) < 1e-9)
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: 180, isBack: true) - 1) < 1e-9)
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: 90, isBack: true) - 0.5) < 1e-9)
        // Any resting angle works (cards turned the "other" way rest at -180).
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: -180, isBack: true) - 1) < 1e-9)
        #expect(abs(RealFlipMath.crossfadeOpacity(angle: 360, isBack: false) - 1) < 1e-9)
    }

    // MARK: Snapshot hook

    @Test @MainActor func snapshotHookRendersAMidTurnFrame() {
        let card = RealisticFlipCard(showingBack: .constant(false)) {
            Color.blue.frame(width: 200, height: 280)
        } back: {
            Color.green
        }
        ._snapshotAngle(60)
        let renderer = ImageRenderer(content: card.frame(width: 260, height: 340))
        renderer.scale = 1
        #expect(renderer.cgImage != nil)
    }
}
