//
//  GuessOptionsTests.swift
//  TailspotTests
//
//  Pins the ROUTE bonus-round option builder (plan 2026-07-09-001 §A5/§B;
//  route-only per Noah 2026-07-09): every set contains the correct answer
//  among 4 unique display strings; route distractors come from the correct
//  answer's broad region and are plausibility-weighted by
//  distance-from-observer. All sampling is seeded (SeededRNG) — assertions
//  are exact replays.
//

import Foundation
import Testing
@testable import Tailspot

// Berkeley — the home-base observer for the fixtures.
private let observerLat = 37.87
private let observerLon = -122.27

@Suite("GuessOptions — airport table")
struct GuessAirportTableTests {

    @Test func bundledTableLoadsAndLooksSane() {
        let airports = GuessOptions.airports
        #expect(airports.count > 200, "curated pool should be ~250+ airports")
        // Unique idents (the option values) and unique displays (the chips).
        #expect(Set(airports.map(\.icao)).count == airports.count)
        #expect(Set(airports.map(\.display)).count == airports.count)
        // Every continent bucket is deep enough to source 3 distractors.
        let byContinent = Dictionary(grouping: airports, by: \.continent)
        for (continent, group) in byContinent {
            #expect(group.count >= GuessOptions.optionCount - 1,
                    "continent \(continent) too thin (\(group.count))")
        }
        // Spot-check a known row.
        let sfo = GuessOptions.airportsByIcao["KSFO"]
        #expect(sfo?.iata == "SFO")
        #expect(sfo?.continent == "NA")
        #expect(sfo?.display == "SFO · San Francisco")
    }

    @Test func routeAvailability() {
        #expect(GuessOptions.routeAvailable(originIcao: "KSFO", destIcao: "VHHH"))
        // One known endpoint is enough (the question asks about it).
        #expect(GuessOptions.routeAvailable(originIcao: "KSFO", destIcao: "K0X9"))
        // Case/whitespace-insensitive.
        #expect(GuessOptions.routeAvailable(originIcao: " ksfo ", destIcao: nil))
        // No route / unknown fields / degenerate same-airport hop → unavailable.
        #expect(!GuessOptions.routeAvailable(originIcao: nil, destIcao: nil))
        #expect(!GuessOptions.routeAvailable(originIcao: "K0X9", destIcao: "K1X1"))
        #expect(!GuessOptions.routeAvailable(originIcao: "KSFO", destIcao: "KSFO"))
    }

    @Test func majorFlagSplitsResolutionFromDistractors() {
        // The table now serves two roles: comprehensive US resolution rows
        // (major == false) plus recognizable distractor-eligible hubs
        // (major == true). Both populations must be non-empty.
        let airports = GuessOptions.airports
        let major = airports.filter(\.major)
        let resolutionOnly = airports.filter { !$0.major }
        #expect(major.count > 200, "curated hubs + US large airports")
        #expect(!resolutionOnly.isEmpty, "US regional coverage should exist")
        // A hub is major; a regional field near the test base is resolution-only.
        #expect(GuessOptions.airportsByIcao["KSFO"]?.major == true)
        #expect(GuessOptions.airportsByIcao["KMRY"]?.major == false)
        // Every continent's MAJOR bucket is deep enough to source 3 distractors
        // (the distractor pool is major-only).
        let majorByContinent = Dictionary(grouping: major, by: \.continent)
        for (continent, group) in majorByContinent {
            #expect(group.count >= GuessOptions.optionCount - 1,
                    "major continent \(continent) too thin (\(group.count))")
        }
    }

    @Test func regionalUsFieldsNowResolve() {
        // The coverage gap this change closes: a non-curated US regional field
        // (KMRY / Monterey) — previously absent, so KMRY-only routes could
        // never fire a round — now resolves.
        #expect(GuessOptions.airportsByIcao["KMRY"] != nil)
        #expect(GuessOptions.routeAvailable(originIcao: "KMRY", destIcao: nil))
        #expect(GuessOptions.routeAvailable(originIcao: "KSFO", destIcao: "KMRY"))
        // Generally: every resolution-only (non-major) field resolves a route.
        let sample = GuessOptions.airports.first { !$0.major }
        if let sample {
            #expect(GuessOptions.routeAvailable(originIcao: sample.icao, destIcao: "KSFO"))
        }
    }

    @Test func emptyIataDisplayHasNoLeadingSeparator() {
        // Many small resolution-only fields carry no IATA — the chip must lead
        // with the ICAO ident, never a bare "· City".
        let kmry = GuessOptions.airportsByIcao["KMRY"]
        #expect(kmry?.display == "MRY · Monterey")
        for airport in GuessOptions.airports where airport.iata.isEmpty {
            #expect(airport.display == "\(airport.icao) · \(airport.city)")
            #expect(!airport.display.hasPrefix("·"))
            #expect(!airport.display.hasPrefix(" "))
        }
    }
}

@Suite("GuessOptions — route questions")
struct GuessOptionsRouteTests {

    private func question(
        origin: String? = "KSFO",
        dest: String? = "VHHH",
        seed: UInt64 = 1
    ) -> GuessOptions.RouteQuestion? {
        var rng = SeededRNG(seed: seed)
        return GuessOptions.routeQuestion(
            originIcao: origin, destIcao: dest,
            observerLat: observerLat, observerLon: observerLon,
            using: &rng
        )
    }

    @Test func correctIncludedAmongFourUniqueOptions() throws {
        let q = try #require(question())
        #expect(q.options.count == GuessOptions.optionCount)
        #expect(q.options.contains { $0.value == q.correctValue })
        #expect(Set(q.options.map(\.value)).count == q.options.count)
        #expect(Set(q.options.map(\.display)).count == q.options.count)
    }

    @Test func asksAboutTheEndpointFartherFromTheObserver() throws {
        // Observer in Berkeley: KSFO → VHHH must ask the destination (HKG);
        // the reverse filing must ask the origin.
        let outbound = try #require(question(origin: "KSFO", dest: "VHHH"))
        #expect(outbound.endpoint == .destination)
        #expect(outbound.correctValue == "VHHH")

        let inbound = try #require(question(origin: "VHHH", dest: "KSFO"))
        #expect(inbound.endpoint == .origin)
        #expect(inbound.correctValue == "VHHH")
    }

    @Test func distractorsShareTheCorrectAnswersRegion() throws {
        for seed in UInt64(1)...20 {
            let q = try #require(question(seed: seed))
            let correct = try #require(GuessOptions.airportsByIcao[q.correctValue])
            for option in q.options where option.value != q.correctValue {
                let airport = try #require(GuessOptions.airportsByIcao[option.value])
                #expect(airport.continent == correct.continent,
                        "distractor \(option.value) outside \(correct.continent)")
            }
        }
    }

    @Test func theOtherTrueEndpointIsNeverADistractor() throws {
        // The server verifies a route guess against EITHER endpoint — a chip
        // for the other true endpoint would be locally "wrong" but
        // server-correct, guaranteeing verdict drift. VHHH→RJTT keeps both
        // endpoints in the same region (AS) so the exclusion actually bites.
        for seed in UInt64(1)...50 {
            var rng = SeededRNG(seed: seed)
            let q = try #require(GuessOptions.routeQuestion(
                originIcao: "VHHH", destIcao: "RJTT",
                observerLat: observerLat, observerLon: observerLon,
                using: &rng
            ))
            let asked = q.correctValue
            let other = asked == "VHHH" ? "RJTT" : "VHHH"
            #expect(!q.options.contains { $0.value == other })
        }
    }

    @Test func distractorsArePlausibilityWeightedByObserverDistance() throws {
        // The correct answer (VHHH) is ~11,100 km from Berkeley. Weighted
        // sampling should pull distractors toward that range: their mean
        // |distance-from-observer − correct's| must beat the unweighted mean
        // over the same candidate pool by a wide margin.
        let correct = try #require(GuessOptions.airportsByIcao["VHHH"])
        let correctDistance = Geo.distance(
            fromLat: observerLat, lon: observerLon, toLat: correct.lat, lon: correct.lon)

        func observerDelta(_ icao: String) throws -> Double {
            let a = try #require(GuessOptions.airportsByIcao[icao])
            let d = Geo.distance(fromLat: observerLat, lon: observerLon, toLat: a.lat, lon: a.lon)
            return abs(d - correctDistance)
        }

        let pool = GuessOptions.airports.filter {
            $0.continent == correct.continent && $0.icao != "VHHH" && $0.icao != "KSFO"
        }
        let poolMeanDelta = try pool.map { try observerDelta($0.icao) }
            .reduce(0, +) / Double(pool.count)

        var chosenDeltas: [Double] = []
        for seed in UInt64(1)...100 {
            let q = try #require(question(seed: seed))
            for option in q.options where option.value != q.correctValue {
                chosenDeltas.append(try observerDelta(option.value))
            }
        }
        let chosenMeanDelta = chosenDeltas.reduce(0, +) / Double(chosenDeltas.count)
        #expect(chosenMeanDelta < poolMeanDelta * 0.8,
                "weighted mean Δ \(chosenMeanDelta) not clearly under pool mean \(poolMeanDelta)")
    }

    @Test func distractorsAreAllMajorAirports() throws {
        // Distractors are sampled ONLY from major (recognizable) airports —
        // the comprehensive US resolution-only fields must never surface as an
        // obscure wrong answer. Covers an international correct answer (VHHH,
        // AS) and a US one (KSFO, NA).
        for (origin, dest) in [("KSFO", "VHHH"), ("KMRY", "KSFO")] {
            for seed in UInt64(1)...20 {
                let q = try #require(question(origin: origin, dest: dest, seed: seed))
                for option in q.options where option.value != q.correctValue {
                    let airport = try #require(GuessOptions.airportsByIcao[option.value])
                    #expect(airport.major,
                            "distractor \(option.value) is not major (\(origin)→\(dest))")
                }
            }
        }
    }

    @Test func asksAboutTheMajorEndpoint() throws {
        // KMRY (non-major, ~145 km from Berkeley) → KSFO (major, ~28 km). The
        // OLD rule (farther endpoint) would ask about KMRY; the major
        // preference must win and ask about SFO instead.
        for seed in UInt64(1)...20 {
            let q = try #require(question(origin: "KMRY", dest: "KSFO", seed: seed))
            #expect(q.endpoint == .destination)
            #expect(q.correctValue == "KSFO")
            let correct = try #require(GuessOptions.airportsByIcao[q.correctValue])
            #expect(correct.major)
        }
    }

    @Test func allNonMajorEndpointsStillBuildAQuestion() throws {
        // Both endpoints are non-major US regional fields (KMRY, KAPC). A round
        // can still fire: the correct chip is the (non-major) asked endpoint,
        // and the 3 distractors are drawn from the major pool.
        for seed in UInt64(1)...20 {
            let q = try #require(question(origin: "KMRY", dest: "KAPC", seed: seed))
            #expect(q.options.count == GuessOptions.optionCount)
            #expect(["KMRY", "KAPC"].contains(q.correctValue))
            let correct = try #require(GuessOptions.airportsByIcao[q.correctValue])
            #expect(!correct.major, "the asked endpoint is a resolution-only field")
            let other = q.correctValue == "KMRY" ? "KAPC" : "KMRY"
            #expect(!q.options.contains { $0.value == other })
            for option in q.options where option.value != q.correctValue {
                let airport = try #require(GuessOptions.airportsByIcao[option.value])
                #expect(airport.major)
            }
        }
    }

    @Test func degenerateNonMajorRouteReturnsNil() {
        // Same non-major field both ends → no honest question, graceful nil.
        #expect(question(origin: "KMRY", dest: "KMRY") == nil)
    }

    @Test func singleKnownEndpointDegradesToAskingAboutIt() throws {
        // Destination is a small field outside the curated pool — the
        // question gracefully asks about the known origin instead.
        let q = try #require(question(origin: "KSFO", dest: "K0X9"))
        #expect(q.endpoint == .origin)
        #expect(q.correctValue == "KSFO")
    }

    @Test func unbuildableRoutesReturnNil() {
        #expect(question(origin: nil, dest: nil) == nil)
        #expect(question(origin: "K0X9", dest: "K1X1") == nil)
        #expect(question(origin: "KSFO", dest: "KSFO") == nil)
    }

    @Test func seededDeterminism() throws {
        let a = try #require(question(seed: 7))
        let b = try #require(question(seed: 7))
        #expect(a == b)
        let c = try #require(question(seed: 8))
        #expect(a != c, "different seeds should (in practice) differ")
    }
}
