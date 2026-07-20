//
//  EmptySkyTapSubjectTests.swift
//
//  Field regression 2026-07-19 (Noah, driving the Dumbarton bridge watching
//  SFO arrivals): repeated "Nearest plane is 30–90 km out — beyond eyeshot"
//  toasts while an arrival was plainly in sight and near the top of the
//  debug list. Mechanism: in a moving car the compass error rotates the sky
//  model tens of degrees, so the close visible plane projects far from the
//  tap (or behind the camera → synthetic 180° offset) while some far
//  hidden-tier plane in the 50 km bbox lands angularly nearer, classifies
//  `filtered-far`, and the toast quotes ITS distance as "nearest".
//
//  RESOLUTION, two layers:
//    1. `chooseEmptySkyTapSubject` — a `filtered-far` angular winner is
//       rescued by the angular-nearest actionable plane (airborne AND
//       visible-tier-or-revealable) in the tap cone, which then classifies
//       and routes normally (reveal / ripple).
//    2. `farTapToastSlantMeters` — the toast only shows when NO airborne
//       in-data plane is within plausible reveal reach, and it reports the
//       distance-nearest slant, so "Nearest plane is X km out" is literally
//       true whenever shown.
//
//  The NYC couch protection (TapRevealPlausibilityTests) must survive both:
//  with nothing revealable anywhere, the rescue finds no alternative and
//  the toast still fires.
//

import Foundation
import Testing

@testable import Tailspot

@Suite("Empty-sky-tap subject selection")
struct EmptySkyTapSubjectTests {

    private func cand(
        index: Int, offsetDeg: Double,
        onScreen: Bool = false, grounded: Bool = false,
        tier: ObservedAircraft.VisibilityTier = .hidden,
        revealable: Bool = false
    ) -> EmptySkyTapCandidate {
        EmptySkyTapCandidate(
            index: index, offsetDeg: offsetDeg, onScreen: onScreen,
            grounded: grounded, tier: tier, plausiblyRevealable: revealable
        )
    }

    // MARK: - Baseline: no candidates / plain nearest

    @Test func emptyDataReturnsNil() {
        #expect(chooseEmptySkyTapSubject([]) == nil)
    }

    @Test func plainNearestWinsWhenNotFilteredFar() {
        // A revealable hidden plane 8° off is the subject, un-rescued.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 8, revealable: true),
            cand(index: 1, offsetDeg: 20, onScreen: true, tier: .full),
        ])
        #expect(choice?.candidate.index == 0)
        #expect(choice?.reason == "filtered")
        #expect(choice?.rescued == false)
    }

    // MARK: - The Dumbarton rescue

    @Test func filteredFarLosesToRevealablePlaneInCone() {
        // The driving case: a 52 km hidden stranger 12° off the tap beats the
        // visible 6 km arrival (25° off after the heading error) on angle
        // alone — the rescue must hand the tap to the arrival.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 12),                       // far stranger
            cand(index: 1, offsetDeg: 25, revealable: true),      // the arrival
        ])
        #expect(choice?.candidate.index == 1)
        #expect(choice?.reason == "filtered")
        #expect(choice?.rescued == true)
    }

    @Test func filteredFarLosesToVisibleOffFramePlaneInCone() {
        // Visible-tier plane projected off-screen (the DAL972 compass-error
        // class) also rescues — and routes to the off-frame reveal.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 5),
            cand(index: 1, offsetDeg: 30, onScreen: false, tier: .full),
        ])
        #expect(choice?.candidate.index == 1)
        #expect(choice?.reason == "off-frame")
        #expect(choice?.rescued == true)
        #expect(shouldTapReveal(reason: choice?.reason ?? ""))
    }

    @Test func rescuePicksAngularNearestAlternative() {
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 3),                        // filtered-far
            cand(index: 1, offsetDeg: 35, revealable: true),
            cand(index: 2, offsetDeg: 18, revealable: true),      // nearer alt
        ])
        #expect(choice?.candidate.index == 2)
        #expect(choice?.rescued == true)
    }

    // MARK: - Rescues that must NOT happen

    @Test func couchCaseStaysFilteredFar() {
        // NYC couch: everything hidden and beyond reach — no alternative
        // exists, the honest toast path stands.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 6),
            cand(index: 1, offsetDeg: 15),
            cand(index: 2, offsetDeg: 33),
        ])
        #expect(choice?.candidate.index == 0)
        #expect(choice?.reason == "filtered-far")
        #expect(choice?.rescued == false)
    }

    @Test func alternativeOutsideConeDoesNotRescue() {
        // The arrival computes BEHIND the camera (synthetic 180°) under a
        // gross heading error — outside the 40° cone, so no rescue; the
        // toast-honesty guard is what protects this case.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 12),
            cand(index: 1, offsetDeg: 180, tier: .full, revealable: true),
        ])
        #expect(choice?.candidate.index == 0)
        #expect(choice?.reason == "filtered-far")
        #expect(choice?.rescued == false)
    }

    @Test func groundedPrimaryIsNeverRescued() {
        // A deliberate tap on a parked plane keeps the grounded toast (and
        // the Ground Stop easter egg) even with a revealable plane in cone.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 2, grounded: true),
            cand(index: 1, offsetDeg: 20, revealable: true),
        ])
        #expect(choice?.candidate.index == 0)
        #expect(choice?.reason == "grounded")
        #expect(choice?.rescued == false)
    }

    @Test func groundedPlaneNeverServesAsRescueAlternative() {
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 4),
            cand(index: 1, offsetDeg: 10, grounded: true, revealable: false),
        ])
        #expect(choice?.candidate.index == 0)
        #expect(choice?.reason == "filtered-far")
    }

    @Test func nothingNearbyIsNotRescued() {
        // Angular winner outside the cone → nothing-nearby, untouched.
        let choice = chooseEmptySkyTapSubject([
            cand(index: 0, offsetDeg: 55, revealable: true)
        ])
        #expect(choice?.reason == "nothing-nearby")
        #expect(choice?.rescued == false)
    }
}

@Suite("Beyond-eyeshot toast honesty guard")
struct FarTapToastGuardTests {

    @Test func suppressedWhenAnyAirbornePlaneIsWithinReach() {
        // The Dumbarton lie: a 6 km revealable arrival in data (even outside
        // the tap cone / behind the camera) forbids "nearest is 52 km out".
        let slant = farTapToastSlantMeters(airborne: [
            (slantMeters: 52_000, plausiblyRevealable: false),
            (slantMeters: 6_000, plausiblyRevealable: true),
        ])
        #expect(slant == nil)
    }

    @Test func firesWithDistanceNearestWhenSkyIsGenuinelyFar() {
        // The NYC couch: everything beyond reach → toast, quoting the
        // DISTANCE-nearest plane (27 km), not whichever won on angle.
        let slant = farTapToastSlantMeters(airborne: [
            (slantMeters: 64_800, plausiblyRevealable: false),
            (slantMeters: 27_200, plausiblyRevealable: false),
            (slantMeters: 51_800, plausiblyRevealable: false),
        ])
        #expect(slant == 27_200)
    }

    @Test func emptyAirborneSetSuppresses() {
        #expect(farTapToastSlantMeters(airborne: []) == nil)
    }
}
