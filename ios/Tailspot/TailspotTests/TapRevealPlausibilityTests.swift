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
            offsetDeg: 10, grounded: false, tier: .hidden, onScreen: false,
            plausiblyRevealable: true
        ) == "filtered")
        #expect(classifyEmptySkyTapNearest(
            offsetDeg: 10, grounded: false, tier: .hidden, onScreen: false,
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
}
