//
//  HangarRarityTests.swift
//  TailspotTests
//
//  Pure-function tests for HangarRarity.tier(for:). The token list
//  is curated and small; tests pin the common-case "everyday airliner"
//  classification + spot-check each of the rare buckets so a typo or
//  an over-eager substring (e.g. accidentally matching "747" inside
//  a non-747 model) can't silently demote / promote things.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Hangar rarity classification")
@MainActor
struct HangarRarityTests {

    /// Convenience factory. Only the `model` field matters for rarity.
    private func makeCatch(model: String?) -> Catch {
        Catch(
            icao24: "abc",
            callsign: nil,
            model: model,
            manufacturer: nil,
            operatorName: nil,
            caughtAt: Date(),
            observerLat: 0,
            observerLon: 0,
            slantDistanceMeters: 0
        )
    }

    @Test func everydayAirlinersAreCommon() {
        #expect(HangarRarity.tier(for: makeCatch(model: "737-800")) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "A320")) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "A321-271NX")) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "E175")) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "CRJ-700")) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "777-300ER")) == .common)
    }

    @Test func nilModelIsCommon() {
        #expect(HangarRarity.tier(for: makeCatch(model: nil)) == .common)
        #expect(HangarRarity.tier(for: makeCatch(model: "")) == .common)
    }

    @Test func passengerJumboJetsAreRare() {
        #expect(HangarRarity.tier(for: makeCatch(model: "747-400")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "747-8")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "A380-800")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "A340-600")) == .rare)
    }

    @Test func militaryTransportsAndBombersAreRare() {
        #expect(HangarRarity.tier(for: makeCatch(model: "C-130J")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "C-17")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "C-5M")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "KC-135")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "KC-46")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "B-52H")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "B-1B")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "B-2")) == .rare)
    }

    @Test func attackHelicoptersAreRare() {
        #expect(HangarRarity.tier(for: makeCatch(model: "AH-64")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "AH-1Z")) == .rare)
    }

    @Test func classificationIsCaseInsensitive() {
        // OpenSky returns model strings in caps; users might see
        // mixed case from other paths. Either way → same outcome.
        #expect(HangarRarity.tier(for: makeCatch(model: "BOEING 747-400")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "boeing 747-400")) == .rare)
        #expect(HangarRarity.tier(for: makeCatch(model: "Airbus A380-800")) == .rare)
    }
}
