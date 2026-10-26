//
//  CardBackStyleUnfoldTests.swift
//  TailspotTests
//
//  Pins the "Unfold" card-back style's pure decisions (UnfoldMath): the
//  drag → progress mapping, the commit decision by distance and by flick,
//  the hinge angle that keeps the tilted panel inside its slot, and the
//  fold shading / fade curves.
//

import Testing
import CoreGraphics
import Foundation
@testable import Tailspot

@Suite("Card back: unfold math")
struct CardBackStyleUnfoldTests {

    private let h: CGFloat = 500

    // MARK: Resting + drag

    @Test func restingProgressFollowsTheBinding() {
        #expect(UnfoldMath.restingProgress(isOpen: false) == 0)
        #expect(UnfoldMath.restingProgress(isOpen: true) == 1)
    }

    @Test func dragDownOpensInProportionToPanelHeight() {
        #expect(UnfoldMath.dragProgress(start: 0, translation: 250, panelHeight: h) == 0.5)
        #expect(UnfoldMath.dragProgress(start: 0, translation: 125, panelHeight: h) == 0.25)
    }

    @Test func dragUpFoldsAnOpenPanel() {
        #expect(abs(UnfoldMath.dragProgress(start: 1, translation: -100, panelHeight: h) - 0.8) < 1e-12)
    }

    @Test func dragIsClampedToTheFoldRange() {
        #expect(UnfoldMath.dragProgress(start: 0, translation: -80, panelHeight: h) == 0)
        #expect(UnfoldMath.dragProgress(start: 1, translation: 300, panelHeight: h) == 1)
        #expect(UnfoldMath.dragProgress(start: 0, translation: 2_000, panelHeight: h) == 1)
    }

    @Test func zeroHeightPanelDoesNotMove() {
        #expect(UnfoldMath.dragProgress(start: 0, translation: 200, panelHeight: 0) == 0)
        #expect(UnfoldMath.dragProgress(start: 1, translation: -200, panelHeight: 0) == 1)
    }

    // MARK: Commit

    @Test func longSlowPullCommitsPastHalfway() {
        #expect(UnfoldMath.shouldOpen(start: 0, predictedTranslation: 260, panelHeight: h))
        #expect(!UnfoldMath.shouldOpen(start: 0, predictedTranslation: 240, panelHeight: h))
    }

    @Test func shortFastFlickCommitsViaPrediction() {
        // A 40 pt pull flicked hard: momentum carries it well past halfway.
        #expect(UnfoldMath.shouldOpen(start: 0, predictedTranslation: 400, panelHeight: h))
        // Folding: a quick upward flick from open.
        #expect(!UnfoldMath.shouldOpen(start: 1, predictedTranslation: -350, panelHeight: h))
    }

    @Test func pullThatFlicksBackDoesNotCommit() {
        // Dragged 300 pt down, then flicked back up at release.
        #expect(!UnfoldMath.shouldOpen(start: 0, predictedTranslation: 60, panelHeight: h))
    }

    @Test func smallNudgeOnAnOpenPanelStaysOpen() {
        #expect(UnfoldMath.shouldOpen(start: 1, predictedTranslation: -60, panelHeight: h))
    }

    // MARK: Hinge

    @Test func foldAngleEndpoints() {
        #expect(abs(UnfoldMath.foldAngle(progress: 0) - -90) < 1e-9)
        #expect(abs(UnfoldMath.foldAngle(progress: 1)) < 1e-9)
        // Clamped outside 0…1 (spring overshoot never over-rotates).
        #expect(abs(UnfoldMath.foldAngle(progress: 1.2)) < 1e-9)
        #expect(abs(UnfoldMath.foldAngle(progress: -0.3) - -90) < 1e-9)
    }

    @Test func foldAngleUnfoldsMonotonically() {
        var last = UnfoldMath.foldAngle(progress: 0)
        for step in 1...20 {
            let a = UnfoldMath.foldAngle(progress: Double(step) / 20)
            #expect(a > last)
            last = a
        }
    }

    @Test func tiltedPanelProjectsExactlyOntoItsSlot() {
        for p in [0.0, 0.1, 0.33, 0.5, 0.75, 0.9, 1.0] {
            let angle = UnfoldMath.foldAngle(progress: p) * .pi / 180
            let projected = Double(h) * cos(angle)
            let slot = Double(UnfoldMath.slotHeight(progress: p, panelHeight: h))
            #expect(abs(projected - slot) < 1e-6)
        }
    }

    @Test func slotHeightGrowsFromNothingToThePanel() {
        #expect(UnfoldMath.slotHeight(progress: 0, panelHeight: h) == 0)
        #expect(UnfoldMath.slotHeight(progress: 0.5, panelHeight: h) == 250)
        #expect(UnfoldMath.slotHeight(progress: 1, panelHeight: h) == h)
        #expect(UnfoldMath.slotHeight(progress: 1.3, panelHeight: h) == h)
    }

    // MARK: Shading + fade

    @Test func shadeIsDarkestFoldedAndGoneFlat() {
        #expect(UnfoldMath.shadeOpacity(progress: 0) == UnfoldMath.shadePeak)
        #expect(UnfoldMath.shadeOpacity(progress: 1) == 0)
        #expect(UnfoldMath.shadeOpacity(progress: 0.25) > UnfoldMath.shadeOpacity(progress: 0.75))
    }

    @Test func panelIsInvisibleFoldedAndOpaqueOnceUnderway() {
        #expect(UnfoldMath.panelOpacity(progress: 0) == 0)
        #expect(UnfoldMath.panelOpacity(progress: UnfoldMath.fadeInEnd) == 1)
        #expect(UnfoldMath.panelOpacity(progress: 0.5) == 1)
        #expect(UnfoldMath.panelOpacity(progress: 0.02) > 0)
        #expect(UnfoldMath.panelOpacity(progress: 0.02) < 1)
    }
}
