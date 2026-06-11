//
//  VisibilityHysteresisTests.swift
//  TailspotTests
//
//  The visibility distance cap is a hard boundary; a plane hovering right
//  at it flickers in/out of the visible set frame-to-frame, which makes the
//  AR bracket blink and the lock-on drop (field report 2026-06-08: ASA733
//  oscillated False→True→False across ticks at ~9 km). Hysteresis (Schmitt
//  trigger): appear at the cap, stay until clearly past it (outer band).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Visibility hysteresis")
struct VisibilityHysteresisTests {

    /// An ObservedAircraft at a given slant. Elevation EXACTLY 30° — the
    /// joint of the haze ramp and the 2026-06-11 contrail segment — where
    /// the cap is exactly `maxVisibleDistanceMeters` under both curve
    /// halves. (35° used to sit on a flat plateau; the contrail segment
    /// made the cap grow past 30°, so these hysteresis fixtures anchor to
    /// the one elevation whose cap is pinned.)
    /// Non-N callsign so the small-airframe half-cap doesn't apply.
    private func obs(slant: Double, callsign: String = "UAL123", icao: String = "abc123") -> ObservedAircraft {
        let a = Aircraft(
            icao24: icao, callsign: callsign, originCountry: "US",
            longitude: 0, latitude: 0, altitudeMeters: 10_000,
            velocityMps: 200, trackDeg: 90, onGround: false, positionTimestamp: nil
        )
        return ObservedAircraft(
            aircraft: a, bearingDeg: 0, elevationDeg: 30,
            groundDistanceMeters: slant, slantDistanceMeters: slant
        )
    }

    @Test func planeJustPastCapHiddenUnlessAlreadyShown() {
        let cap = ObservedAircraft.maxVisibleDistanceMeters
        var a = obs(slant: cap + 500)         // just past the inner cap
        a.wasShownLastFrame = false
        #expect(a.isLikelyVisibleToObserver == false)   // appear gate: hidden
        a.wasShownLastFrame = true
        #expect(a.isLikelyVisibleToObserver == true)    // stay gate: held by hysteresis
    }

    @Test func planeFarPastOuterBandDropsEvenIfShown() {
        let cap = ObservedAircraft.maxVisibleDistanceMeters
        var a = obs(slant: cap * ObservedAircraft.visibilityHysteresisFactor + 500)
        a.wasShownLastFrame = true
        #expect(a.isLikelyVisibleToObserver == false)
    }

    @Test func planeWellInsideCapVisibleRegardless() {
        var a = obs(slant: 3_000)
        a.wasShownLastFrame = false
        #expect(a.isLikelyVisibleToObserver == true)
    }

    /// The state machine end-to-end via the shared helper: appear at the
    /// inner cap, stay within the outer band (no flicker), drop beyond it.
    @Test func stateMachineHoldsAtBoundaryThenDrops() {
        let cap = ObservedAircraft.maxVisibleDistanceMeters

        // frame 1: just past inner cap, nothing shown yet → does not appear
        var f1 = [obs(slant: cap + 200)]
        var shown = applyVisibilityHysteresis(&f1, previouslyShown: [])
        #expect(shown.isEmpty)

        // frame 2: inside inner cap → appears
        var f2 = [obs(slant: cap - 200)]
        shown = applyVisibilityHysteresis(&f2, previouslyShown: shown)
        #expect(shown.contains("abc123"))

        // frame 3: drifts just past inner but within outer band → STAYS
        // (this is the tick that used to flicker the bracket off)
        var f3 = [obs(slant: cap + 200)]
        shown = applyVisibilityHysteresis(&f3, previouslyShown: shown)
        #expect(shown.contains("abc123"))

        // frame 4: drifts clearly past the outer band → drops
        var f4 = [obs(slant: cap * ObservedAircraft.visibilityHysteresisFactor + 500)]
        shown = applyVisibilityHysteresis(&f4, previouslyShown: shown)
        #expect(shown.isEmpty)
    }

    @Test func helperSetsFlagFromPreviousShownSet() {
        var planes = [obs(slant: 3_000, icao: "shown1"), obs(slant: 3_000, icao: "new1")]
        _ = applyVisibilityHysteresis(&planes, previouslyShown: ["shown1"])
        #expect(planes[0].wasShownLastFrame == true)
        #expect(planes[1].wasShownLastFrame == false)
    }
}
