//
//  TargetSelectionTests.swift
//  TailspotTests
//
//  Plausibility-weighted catch-target selection (2026-07-13), the fix for the
//  A319 field mis-catch: a 12.9 km cruise jet nearly overhead was caught
//  instead of the closer, lower plane the user aimed at, because selection
//  ranked purely by screen-pixel distance to the crosshair.
//
//  Pins the two pure helpers in LockOnEngine.swift:
//    - dominantAimTarget: catch the visually-dominant plane (single) when one
//      clearly dominates the zone; keep multi for comparable clusters.
//    - aimConfidence: the post-catch uncertain-aim flag's score.
//  plus the CatchCaptureDiagnostics round-trip.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Plausibility catch-target selection")
@MainActor
struct TargetSelectionTests {

    private func cand(_ icao: String, offsetDeg: Double, arcmin: Double, slantKm: Double) -> CatchCandidate {
        CatchCandidate(icao24: icao, offsetDeg: offsetDeg, offsetPx: CGFloat(offsetDeg * 10),
                       arcmin: arcmin, slantMeters: slantKm * 1000)
    }

    // The A319 scene: a far overhead jet nearest the crosshair, plus a closer,
    // lower, much larger plane a little further off. Numbers from the spike.
    private var a319: CatchCandidate { cand("A319", offsetDeg: 6.4, arcmin: 10.7, slantKm: 12.9) }
    private var closer: CatchCandidate { cand("CLOSER", offsetDeg: 9.2, arcmin: 43.0, slantKm: 3.2) }

    // MARK: - dominantAimTarget

    @Test func badCompassPrefersTheCloserBiggerPlane() {
        // ±15° compass (NYC): the reticle is untrustworthy, so the far jet's
        // slight edge in crosshair proximity loses to the closer plane's
        // overwhelming prominence — the fix for the reported mis-catch.
        #expect(dominantAimTarget([a319, closer], headingAccuracyDeg: 15) == "CLOSER")
    }

    @Test func goodCompassDoesNotForceASingleWinner() {
        // With a trusted compass (±4°) neither plane dominates (crosshair
        // proximity is decisive and they're comparable) → nil, so the caller
        // keeps its existing single/multi logic. Behavior is unchanged when the
        // compass is good — the graceful-degradation property.
        #expect(dominantAimTarget([a319, closer], headingAccuracyDeg: 4) == nil)
    }

    @Test func comparableClusterStaysMulti() {
        // A formation / approach pair: two comparable planes straddling the
        // crosshair. Neither dominates → nil → multi-catch preserved (mirrors
        // CatchZoneTests.tightClusterOfTwoNearCenterIsStillMulti).
        let l = cand("L", offsetDeg: 5, arcmin: 8, slantKm: 5)
        let r = cand("R", offsetDeg: 5, arcmin: 8, slantKm: 5)
        #expect(dominantAimTarget([l, r], headingAccuracyDeg: 20) == nil)
    }

    @Test func singleOrEmptyCandidateYieldsNoDominant() {
        // The one-candidate case is already `.single` upstream; dominant only
        // fires when there's a genuine choice to make.
        #expect(dominantAimTarget([a319], headingAccuracyDeg: 20) == nil)
        #expect(dominantAimTarget([], headingAccuracyDeg: 20) == nil)
    }

    @Test func closerPlaneNotACandidateCannotBeRescued() {
        // The residual honesty: if the plane the user meant was never labelable
        // (not in feed / filtered), only the A319 is a candidate → single →
        // dominant isn't consulted. Selection can't rescue what it can't see;
        // that's what the stored diagnostics are for.
        #expect(dominantAimTarget([a319], headingAccuracyDeg: 15) == nil)
    }

    // MARK: - aimConfidence (the uncertain-aim flag)

    @Test func farSmallOffCenterUnderPoorCompassIsLowConfidence() {
        // A speck off the crosshair with a bad compass → flagged (< 0.3 floor).
        let conf = aimConfidence(offsetDeg: 12, arcmin: 3, headingAccuracyDeg: 20)
        #expect(conf < 0.3)
    }

    @Test func centeredOrProminentCatchIsHighConfidence() {
        // A resolvable plane near the crosshair is confident even with a
        // mediocre compass → never flagged (fail-open).
        #expect(aimConfidence(offsetDeg: 2, arcmin: 11, headingAccuracyDeg: 10) > 0.5)
        #expect(aimConfidence(offsetDeg: 2, arcmin: 11, headingAccuracyDeg: 20) > 0.5)
    }

    @Test func resolvableWrongPlaneNearCenterIsNotCaughtByTheFlag() {
        // The documented limitation: an 11′ jet near the (compass-rotated)
        // center reads high-confidence even when it's the wrong plane. The
        // confidence flag catches marginal specks, not resolvable-but-wrong
        // targets — prominence selection + metadata own that case.
        #expect(aimConfidence(offsetDeg: 3, arcmin: 11, headingAccuracyDeg: 18) > 0.3)
    }

    @Test func goodCompassRaisesConfidence() {
        // Same geometry, better compass → higher confidence (monotone in
        // compass trust).
        let bad = aimConfidence(offsetDeg: 8, arcmin: 6, headingAccuracyDeg: 25)
        let good = aimConfidence(offsetDeg: 8, arcmin: 6, headingAccuracyDeg: 8)
        #expect(good > bad)
    }

    // MARK: - catchCandidates projection

    @Test func catchCandidatesFindsCenteredExcludesOffAxis() {
        let screen = CGSize(width: 393, height: 852)
        func obs(_ icao: String, bearingDeg: Double) -> ObservedAircraft {
            let a = Aircraft(icao24: icao, callsign: nil, originCountry: "X",
                             longitude: 0, latitude: 0, altitudeMeters: 3000,
                             velocityMps: nil, trackDeg: nil, onGround: false, positionTimestamp: nil)
            return ObservedAircraft(aircraft: a, bearingDeg: bearingDeg, elevationDeg: 20,
                                    groundDistanceMeters: 5_000, slantDistanceMeters: 5_100)
        }
        let cands = catchCandidates(
            in: [obs("CENTER", bearingDeg: 0), obs("OFF", bearingDeg: 30)],
            phoneHeadingDeg: 0, cameraElevationDeg: 20, screenSize: screen,
            zoneRadius: 100
        )
        #expect(cands.map(\.icao24) == ["CENTER"])
        #expect(cands.first!.offsetDeg < 2)          // dead-ahead ≈ 0° offset
        #expect(cands.first!.arcmin > 0)
    }

    // MARK: - CatchCaptureDiagnostics round-trip

    @Test func diagnosticsRoundTripsThroughJSON() {
        let d = CatchCaptureDiagnostics(
            headingDeg: 200.0, cameraElevationDeg: 64.0, rollDeg: 1.0, zoom: 1.0,
            headingAccuracyDeg: 15.0, targetOffsetDeg: 6.4, targetArcmin: 10.7,
            wasTapped: false, candidateCount: 2,
            alternatives: [.init(icao24: "CLOSER", offsetDeg: 9.2, slantKm: 3.2, arcmin: 43.0)],
            selector: "prominence-v1"
        )
        let json = d.jsonString()
        #expect(json != nil)
        #expect(CatchCaptureDiagnostics.from(json: json) == d)
    }
}
