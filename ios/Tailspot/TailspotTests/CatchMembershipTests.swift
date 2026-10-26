//
//  CatchMembershipTests.swift
//  TailspotTests
//
//  Pure-function tests for the frame-is-the-catch selection rules:
//  `chooseCatchMembers` (membership + ranking + cap) and
//  `resolveSnapConflicts` (catch-time unique bracket assignment).
//  The membership scenarios mirror the worked examples signed off in
//  the decision record (docs/plans/2026-08-28-frame-is-the-catch.md).
//

import Testing
import CoreGraphics
@testable import Tailspot

@Suite("Catch membership")
struct CatchMembershipTests {

    private func cand(
        _ icao: String, arcmin: Double,
        fullTier: Bool = true, asserted: Bool = false, occluded: Bool = false
    ) -> MembershipCandidate {
        MembershipCandidate(
            icao24: icao, arcmin: arcmin,
            isFullTier: fullTier, isAsserted: asserted, isOccluded: occluded
        )
    }

    // MARK: - Scenario A: the normal case

    @Test func oneOrTwoBrightPlanesAreAllChosen() {
        let one = chooseCatchMembers([cand("aaa", arcmin: 12)])
        #expect(one.chosen == ["aaa"])
        #expect(one.overflow.isEmpty)

        let two = chooseCatchMembers([
            cand("aaa", arcmin: 12), cand("bbb", arcmin: 20),
        ])
        #expect(two.chosen == ["bbb", "aaa"])   // larger first
        #expect(two.overflow.isEmpty)
    }

    @Test func emptyFrameHasNoMembers() {
        #expect(chooseCatchMembers([]) == .empty)
    }

    // MARK: - Scenario B: five bright under an approach path

    @Test func fiveBrightPlanesCapAtThreeLargest() {
        // The artifact's worked example: 21′ A320, 13′ 737, 9′ C172 chosen;
        // 5′ and 4′ distant jets step down to overflow.
        let m = chooseCatchMembers([
            cand("a320", arcmin: 21),
            cand("b738", arcmin: 13),
            cand("c172", arcmin: 9),
            cand("a321", arcmin: 5),
            cand("b77f", arcmin: 4),
        ])
        #expect(m.chosen == ["a320", "b738", "c172"])
        #expect(m.overflow == ["a321", "b77f"])
    }

    // MARK: - Scenario C: the skyline (occlusion demote)

    @Test func confidentlyOccludedPlaneDemotesOutOfMembership() {
        // A big plane behind a tower loses its slot to a smaller open-sky
        // plane.
        let m = chooseCatchMembers([
            cand("tower", arcmin: 25, occluded: true),
            cand("open1", arcmin: 10),
            cand("open2", arcmin: 8),
            cand("open3", arcmin: 6),
            cand("open4", arcmin: 5),
        ])
        #expect(!m.chosen.contains("tower"))
        #expect(m.chosen == ["open1", "open2", "open3"])
    }

    @Test func faintTierNeedsAnAssertion() {
        let unasserted = chooseCatchMembers([cand("faint1", arcmin: 9, fullTier: false)])
        #expect(unasserted.chosen.isEmpty)

        let asserted = chooseCatchMembers([
            cand("faint1", arcmin: 9, fullTier: false, asserted: true)
        ])
        #expect(asserted.chosen == ["faint1"])
    }

    // MARK: - Scenario D: tap promotion is guaranteed a slot

    @Test func assertedPlaneOutranksSizeAndBumpsSmallestChosen() {
        // Full frame of three big planes + a small asserted one: the
        // assertion takes a slot; the smallest unasserted plane steps down.
        let m = chooseCatchMembers([
            cand("big1", arcmin: 22),
            cand("big2", arcmin: 18),
            cand("big3", arcmin: 15),
            cand("mine", arcmin: 4, fullTier: false, asserted: true),
        ])
        #expect(m.chosen.first == "mine")
        #expect(m.chosen.contains("big1"))
        #expect(m.chosen.contains("big2"))
        #expect(m.overflow == ["big3"])
    }

    @Test func assertionBeatsTheOcclusionDemote() {
        // The user can't be argued with about what they see: an asserted
        // plane stays a member even when the grid reads not-sky under it.
        let m = chooseCatchMembers([
            cand("mine", arcmin: 8, asserted: true, occluded: true)
        ])
        #expect(m.chosen == ["mine"])
    }

    // MARK: - Determinism

    @Test func equalSizesTieBreakByIcaoForStability() {
        // A frame of identical specks must not flicker its chosen set
        // between frames — ties order by icao24.
        let m = chooseCatchMembers([
            cand("ccc", arcmin: 5), cand("aaa", arcmin: 5),
            cand("bbb", arcmin: 5), cand("ddd", arcmin: 5),
        ])
        #expect(m.chosen == ["aaa", "bbb", "ccc"])
        #expect(m.overflow == ["ddd"])
    }

    @Test func zoomInvariance() {
        // Apparent size is angular — the ranking key does not change with
        // zoom, so the same arcmin inputs always rank identically. (The
        // membership INPUT set changes with zoom via what projects onto
        // the frame; the ranking never reorders.)
        let candidates = [cand("aaa", arcmin: 12), cand("bbb", arcmin: 7)]
        #expect(chooseCatchMembers(candidates) == chooseCatchMembers(candidates))
    }
}

@Suite("Catch-time snap assignment")
struct SnapAssignmentTests {

    private func snap(_ icao: String, predicted: CGPoint, snapped: CGPoint?) -> TargetSnap {
        TargetSnap(icao24: icao, predicted: predicted, snapped: snapped)
    }

    // MARK: - Clean pair (worked example 1)

    @Test func separateDetectionsBothKeepTheirSnaps() {
        let resolved = resolveSnapConflicts([
            snap("aaa", predicted: CGPoint(x: 100, y: 100), snapped: CGPoint(x: 110, y: 105)),
            snap("bbb", predicted: CGPoint(x: 300, y: 400), snapped: CGPoint(x: 290, y: 395)),
        ])
        #expect(resolved[0].snapped == CGPoint(x: 110, y: 105))
        #expect(resolved[1].snapped == CGPoint(x: 290, y: 395))
    }

    // MARK: - Cross-assignment (worked example 2)

    @Test func twoSnapsOnOneDetectionKeepOnlyTheCloserPrediction() {
        // Both ring searches locked the same physical plane (points 8 px
        // apart). The bracket whose prediction was nearer keeps it; the
        // other falls back to geometry.
        let resolved = resolveSnapConflicts([
            snap("near", predicted: CGPoint(x: 200, y: 200), snapped: CGPoint(x: 210, y: 200)),
            snap("far",  predicted: CGPoint(x: 340, y: 210), snapped: CGPoint(x: 214, y: 204)),
        ])
        #expect(resolved[0].snapped != nil)
        #expect(resolved[1].snapped == nil)
        #expect(resolved[1].predicted == CGPoint(x: 340, y: 210))
    }

    // MARK: - Dropout (worked example 3)

    @Test func missingDetectionLeavesOthersUntouched() {
        let resolved = resolveSnapConflicts([
            snap("seen", predicted: CGPoint(x: 100, y: 100), snapped: CGPoint(x: 104, y: 98)),
            snap("hazy", predicted: CGPoint(x: 300, y: 150), snapped: nil),
        ])
        #expect(resolved[0].snapped != nil)
        #expect(resolved[1].snapped == nil)
    }

    @Test func resultPreservesInputOrder() {
        let resolved = resolveSnapConflicts([
            snap("b", predicted: CGPoint(x: 300, y: 400), snapped: CGPoint(x: 290, y: 395)),
            snap("a", predicted: CGPoint(x: 100, y: 100), snapped: CGPoint(x: 110, y: 105)),
        ])
        #expect(resolved.map(\.icao24) == ["b", "a"])
    }

    @Test func justBeyondSeparationBothSurvive() {
        // Two detections `snapConflictSeparation` apart are two planes.
        let resolved = resolveSnapConflicts([
            snap("aaa", predicted: CGPoint(x: 100, y: 100), snapped: CGPoint(x: 100, y: 100)),
            snap("bbb", predicted: CGPoint(x: 170, y: 100), snapped: CGPoint(x: 100 + snapConflictSeparation, y: 100)),
        ])
        #expect(resolved[0].snapped != nil)
        #expect(resolved[1].snapped != nil)
    }
}
