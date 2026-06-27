//
//  CatchSizeFloorTests.swift
//  TailspotTests
//
//  Lever 3 — the catch-time angular-size floor. A plane too small-and-distant
//  to resolve by eye isn't a real catch, independent of occlusion. These pin
//  the wingspan-by-class estimate, the apparent-size math, and the floor
//  verdict against John's actual NYC cheat cases + the marginal field
//  sightings the floor must NOT block.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch size floor (Lever 3)")
@MainActor
struct CatchSizeFloorTests {

    /// Build an aircraft with a given emitter category / callsign.
    private func aircraft(category: String?, callsign: String? = nil) -> Aircraft {
        Aircraft(
            icao24: "abc123", callsign: callsign, originCountry: "X",
            longitude: 0, latitude: 0, altitudeMeters: 3_000,
            velocityMps: nil, trackDeg: nil, onGround: false,
            positionTimestamp: nil, category: category
        )
    }

    /// Build an observed aircraft at a given slant distance (km). Elevation /
    /// bearing are irrelevant to the size floor (it's decoupled from
    /// visibility on purpose).
    private func obs(category: String?, callsign: String? = nil, slantKm: Double) -> ObservedAircraft {
        ObservedAircraft(
            aircraft: aircraft(category: category, callsign: callsign),
            bearingDeg: 0, elevationDeg: 10,
            groundDistanceMeters: slantKm * 1_000,
            slantDistanceMeters: slantKm * 1_000
        )
    }

    // MARK: - Wingspan by class

    @Test func wingspanFollowsEmitterCategory() {
        #expect(aircraft(category: "A5").estimatedWingspanMeters == 60)  // heavy / widebody
        #expect(aircraft(category: "A3").estimatedWingspanMeters == 34)  // narrowbody
        #expect(aircraft(category: "A2").estimatedWingspanMeters == 16)  // regional / bizjet
        #expect(aircraft(category: "A1").estimatedWingspanMeters == 11)  // GA
        #expect(aircraft(category: "A7").estimatedWingspanMeters == 14)  // rotorcraft
    }

    @Test func unknownClassFailsOpenToLarge() {
        // No category + airline callsign → assume a medium-large airframe so the
        // floor never blocks a catch we can't confidently size.
        #expect(aircraft(category: nil, callsign: "UAL123").estimatedWingspanMeters == 40)
        // No category + GA tail-number callsign → small.
        #expect(aircraft(category: nil, callsign: "N12345").estimatedWingspanMeters == 12)
    }

    // MARK: - The floor, on real cases

    @Test func johnsCitationAt28kmIsBlocked() {
        // The headline cheat: a small bizjet (A2, ~16 m) at 28.7 km reads ~1.9′,
        // below the 2.5′ floor — a speck no one could identify.
        let citation = obs(category: "A2", slantKm: 28.7)
        #expect(citation.apparentSizeArcminutes < 2.5)
        #expect(citation.clearsCatchSizeFloor == false)
    }

    @Test func widebodyContrailAt19kmIsKept() {
        // The Sea Ranch ANA179 case the visibility band was widened for: a
        // widebody (A5, 60 m) at 19 km reads ~11′ — comfortably catchable.
        let wide = obs(category: "A5", slantKm: 19)
        #expect(wide.apparentSizeArcminutes > 10)
        #expect(wide.clearsCatchSizeFloor)
    }

    @Test func marginalRegionalAt18kmIsKept() {
        // SKW5480 — confirmed visible at 18 km. A regional jet (A2-ish, but
        // model it as the larger A3 a SkyWest E175 broadcasts) must survive the
        // floor; even at the conservative 16 m bizjet span it clears it.
        let regional = obs(category: "A3", slantKm: 18)
        #expect(regional.clearsCatchSizeFloor)
    }

    @Test func closeNarrowbodyIsKept() {
        // Every confirmed naked-eye sighting was ≤ 5.8 km — must never block.
        let narrow = obs(category: "A3", slantKm: 5.8)
        #expect(narrow.clearsCatchSizeFloor)
    }

    @Test func unknownAirlinerFarOutFailsOpen() {
        // Feed carried no category but an airline callsign → 40 m assumption →
        // still resolvable at 25 km, so it is NOT blocked (fail open).
        let unknown = obs(category: nil, callsign: "DAL99", slantKm: 25)
        #expect(unknown.clearsCatchSizeFloor)
    }

    @Test func gaSpeckFarOutIsBlocked() {
        // A GA single (N-number, ~12 m) at 20 km reads ~2.1′ → below the floor.
        let ga = obs(category: nil, callsign: "N73291", slantKm: 20)
        #expect(ga.clearsCatchSizeFloor == false)
    }

    @Test func zeroSlantIsInfiniteSizeAndAlwaysClears() {
        // Degenerate guard: a 0 m slant must not divide-by-zero into NaN.
        let overhead = obs(category: "A2", slantKm: 0)
        #expect(overhead.apparentSizeArcminutes == .infinity)
        #expect(overhead.clearsCatchSizeFloor)
    }
}
