//
//  TapRevealPlausibilityTests.swift
//
//  Field regression 2026-07-12 (Noah, on a couch in Manhattan — replay
//  replay-2026-07-12T150351Z): with 110 airborne planes in the NYC data and
//  the ambient band correctly hiding ALL of them, tap-to-reveal turned every
//  empty tap into a reveal — 11 consecutive taps pinned planes 27–72 km out
//  at 0.4–9.6° elevation (through a wall, indoors), and a Piper Cherokee was
//  caught at 75.8 km. Reveal is explicit intent, but intent can't make a
//  76 km Cherokee visible.
//
//  RESOLUTION: `isPlausiblyRevealable` bounds the "filtered" reveal to
//  `revealReachMeters` — the faint band relaxed by `revealBandFactor` — and
//  refuses strictly-below-horizon planes. Beyond it the tap classifies as
//  "filtered-far": no reveal, no lock, an honest beyond-eyeshot toast.
//
//  The bound must NOT regress the confirmed-visible marginal cases the
//  reveal exists for: FDX1268 (10.9 km @ 3.6°), SKW5480 (18 km @ 12.1°),
//  N21866 (5.8 km @ ~5°, small airframe).
//

import CoreGraphics
import Foundation
import Testing

@testable import Tailspot

@Suite("Tap-reveal plausibility bound")
struct TapRevealPlausibilityTests {

    private func obs(
        slantKm: Double, elevationDeg: Double,
        callsign: String = "UAL123", grounded: Bool = false
    ) -> ObservedAircraft {
        let a = Aircraft(
            icao24: "abc123", callsign: callsign, originCountry: "US",
            longitude: 0, latitude: 0, altitudeMeters: 10_000,
            velocityMps: 200, trackDeg: 90, onGround: grounded,
            positionTimestamp: nil
        )
        var o = ObservedAircraft(
            aircraft: a, bearingDeg: 0, elevationDeg: elevationDeg,
            groundDistanceMeters: slantKm * 1000,
            slantDistanceMeters: slantKm * 1000
        )
        o.grounded = grounded
        return o
    }

    // MARK: - The confirmed-visible field cases must stay revealable

    @Test func fdx1268StaysRevealable() {
        // The original tap-reveal case: FedEx freighter, 10.9 km @ 3.6°,
        // clearly visible by eye, hidden by the precision band.
        #expect(obs(slantKm: 10.9, elevationDeg: 3.6, callsign: "FDX1268").isPlausiblyRevealable)
    }

    @Test func skw5480StaysRevealable() {
        // CONFIRMED VISIBLE at 18.0 km / 12.1° (2026-06-12 doctrine note) —
        // the marginal-recall class the band deliberately defers to reveal.
        #expect(obs(slantKm: 18.0, elevationDeg: 12.1, callsign: "SKW5480").isPlausiblyRevealable)
    }

    @Test func n21866SmallAirframeStaysRevealable() {
        // GA single at 5.8 km / ~5°: the small-airframe half-cap applies but
        // the relaxed reveal band must still admit it.
        #expect(obs(slantKm: 5.8, elevationDeg: 5.0, callsign: "N21866").isPlausiblyRevealable)
    }

    // MARK: - The NYC couch session must be refused (replay 2026-07-12T150351Z)

    @Test func couchSessionRevealsAllRefused() {
        // (callsign, slant km, elevation °) as recorded in the field replay —
        // every one was revealed and pinned; none was remotely visible.
        let couch: [(String, Double, Double)] = [
            ("GJS4184", 27.2, 0.71),
            ("AAL1820", 51.8, 1.68),
            ("AAL1046", 64.8, 2.67),
            ("N528MJ", 59.1, 1.76),
            ("N7571P", 45.7, 4.06),
            ("N523Q", 33.3, 3.66),
            ("N87KG", 60.9, 0.60),
            ("N734DY", 71.9, 0.40),
            ("JBU1447", 29.9, 9.59),
            ("MVJ54", 51.4, 4.16),
        ]
        for (cs, km, el) in couch {
            #expect(!obs(slantKm: km, elevationDeg: el, callsign: cs).isPlausiblyRevealable,
                    "\(cs) at \(km) km / \(el)° must be beyond reveal reach")
        }
    }

    @Test func caughtCherokeeAt76KmRefused() {
        // N8454H — the Piper Cherokee caught (and discarded) at 75.8 km.
        #expect(!obs(slantKm: 75.8, elevationDeg: 1.0, callsign: "N8454H").isPlausiblyRevealable)
    }

    @Test func belowHorizonNeverRevealable() {
        // N383TA, 6.4 km @ -0.45°: close enough for the distance band, but
        // strictly below the horizon — behind terrain/buildings by definition.
        #expect(!obs(slantKm: 6.4, elevationDeg: -0.45, callsign: "N383TA").isPlausiblyRevealable)
        // The 0–1° skyline gray zone stays revealable (ambient floor is 1°,
        // but a tap is explicit intent).
        #expect(obs(slantKm: 5.0, elevationDeg: 0.5).isPlausiblyRevealable)
    }

    @Test func groundedNeverPlausiblyRevealable() {
        #expect(!obs(slantKm: 2.0, elevationDeg: 5.0, grounded: true).isPlausiblyRevealable)
    }

    // MARK: - Classifier + reveal routing

    @Test func classifierSplitsFilteredByPlausibility() {
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, slantMeters: 5_000,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: true
        ) == "filtered")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, slantMeters: 5_000,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: false
        ) == "filtered-far")
    }

    @Test func filteredFarNeverReveals() {
        #expect(!shouldTapReveal(reason: "filtered-far"))
        // The two legitimate reveal reasons are untouched.
        #expect(shouldTapReveal(reason: "filtered"))
        #expect(shouldTapReveal(reason: "off-frame"))
    }

    // MARK: - Bound geometry sanity

    @Test func revealReachRelaxesButBoundsTheFaintBand() {
        let o = obs(slantKm: 10, elevationDeg: 3.6)
        let faint = min(o.visibilityCapMeters * ObservedAircraft.faintBandFactor,
                        ObservedAircraft.faintCeilingMeters)
        #expect(o.revealReachMeters == faint * ObservedAircraft.revealBandFactor)
        // A plane just inside the reach reveals; just past it doesn't.
        let reachKm = o.revealReachMeters / 1000
        #expect(obs(slantKm: reachKm - 0.1, elevationDeg: 3.6).isPlausiblyRevealable)
        #expect(!obs(slantKm: reachKm + 0.1, elevationDeg: 3.6).isPlausiblyRevealable)
    }

    // MARK: - Precision tap (2026-09-05, WGN211: a 747 freighter at 33 km / 18.7°)
    //
    // Six taps landed 0.5–3.5° from a hidden cruise-altitude 747 that sat
    // 4 km past reveal reach, and every one dead-ended in the empty ripple.
    // A tap that precise on an above-horizon plane now reveals it
    // ("filtered-precise"); the ambient band is untouched.

    @Test func precisionTapRevealsHiddenPlanePastReach() {
        let o = obs(slantKm: 33.1, elevationDeg: 18.7, callsign: "WGN211")
        #expect(!o.isPlausiblyRevealable, "the miss is real: WGN211 sits past reveal reach")
        #expect(o.visibilityTier == .hidden, "and the ambient band still hides it")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 1.0, grounded: false, slantMeters: o.slantDistanceMeters,
            tier: o.visibilityTier, onScreen: false,
            plausiblyRevealable: o.isPlausiblyRevealable, aboveHorizon: o.elevationDeg > 0
        ) == "filtered-precise")
        #expect(shouldTapReveal(reason: "filtered-precise"))
    }

    @Test func precisionTapBoundIsExact() {
        func classify(off: Double) -> String {
            classifyEmptySkyTapNearest(
                offsetDeg: off, grounded: false, slantMeters: 33_100,
                tier: .hidden, onScreen: false,
                plausiblyRevealable: false, aboveHorizon: true
            )
        }
        #expect(classify(off: precisionTapRevealMaxOffsetDeg) == "filtered-precise")
        #expect(classify(off: precisionTapRevealMaxOffsetDeg + 0.01) == "filtered-far")
    }

    @Test func precisionTapNeedsAnAboveHorizonAirbornePlane() {
        // Below the horizon (or elevation unknown → default false): no override.
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 0.5, grounded: false, slantMeters: 33_100,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: false, aboveHorizon: false
        ) == "filtered-far")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 0.5, grounded: false, slantMeters: 33_100,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: false
        ) == "filtered-far")
        // Grounded still wins outright — a parked plane is never revealed.
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 0.5, grounded: true, slantMeters: 400,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: false, aboveHorizon: true
        ) == "grounded")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 0.5, grounded: true, slantMeters: 18_000,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: false, aboveHorizon: true
        ) == "grounded-far")
    }

    @Test func precisionTapDoesNotRelabelAPlausibleReveal() {
        // Within reach the plain reveal path is unchanged.
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 0.5, grounded: false, slantMeters: 10_900,
            tier: .hidden, onScreen: false,
            plausiblyRevealable: true, aboveHorizon: true
        ) == "filtered")
    }

    @Test func couchTapsStayRefusedExceptTheOneDeadOn() {
        // The NYC couch taps with their RECORDED angular offsets (replay
        // 2026-07-12T150351Z). The precision radius admits exactly one —
        // N7571P at 1.8° — and refuses the other nine. That single admission
        // is the documented trade behind `precisionTapRevealMaxOffsetDeg`;
        // if this list changes, the threshold was retuned deliberately.
        let couch: [(String, Double, Double, Double)] = [
            ("GJS4184", 27.2, 0.71, 16.3),
            ("AAL1820", 51.8, 1.68, 5.3),
            ("AAL1046", 64.8, 2.67, 11.2),
            ("N528MJ", 59.1, 1.76, 6.3),
            ("N7571P", 45.7, 4.06, 1.8),
            ("N523Q", 33.3, 3.66, 20.4),
            ("N87KG", 60.9, 0.60, 13.4),
            ("N734DY", 71.9, 0.40, 8.7),
            ("JBU1447", 29.9, 9.59, 6.7),
            ("MVJ54", 51.4, 4.16, 7.3),
        ]
        var admitted: [String] = []
        for (cs, km, el, off) in couch {
            let o = obs(slantKm: km, elevationDeg: el, callsign: cs)
            let reason = classifyEmptySkyTapNearest(
                offsetDeg: off, grounded: false, slantMeters: o.slantDistanceMeters,
                tier: o.visibilityTier, onScreen: false,
                plausiblyRevealable: o.isPlausiblyRevealable,
                aboveHorizon: o.elevationDeg > 0
            )
            if reason == "filtered-precise" {
                admitted.append(cs)
            } else {
                #expect(reason == "filtered-far", "\(cs) at \(off)° off must stay refused (got \(reason))")
            }
        }
        #expect(admitted == ["N7571P"])
    }

    @Test func dumbartonTapsStayFilteredFar() {
        // The Dumbarton drive (replay 2026-07-19T221714Z): the car-corrupted
        // heading put every tap 9.6–12.8° from the far stranger. Nowhere near
        // the precision radius — the subject rescue, not this rule, owns
        // that case.
        let taps: [(String, Double, Double, Double)] = [
            ("SKW3789", 27.6, 11.0, 10.8), ("SKW3789", 27.5, 11.0, 9.6),
            ("SKW3789", 27.3, 11.1, 11.6), ("N20230", 10.2, 1.3, 10.7),
            ("N20230", 10.2, 1.3, 11.1), ("SKW3789", 26.9, 11.5, 12.8),
        ]
        for (cs, km, el, off) in taps {
            let o = obs(slantKm: km, elevationDeg: el, callsign: cs)
            #expect(classifyEmptySkyTapNearest(
                offsetDeg: off, grounded: false, slantMeters: o.slantDistanceMeters,
                tier: o.visibilityTier, onScreen: false,
                plausiblyRevealable: o.isPlausiblyRevealable,
                aboveHorizon: o.elevationDeg > 0
            ) == "filtered-far", "\(cs) at \(off)° must stay filtered-far")
        }
    }
}
