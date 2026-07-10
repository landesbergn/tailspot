//
//  GuessOptionsTests.swift
//  TailspotTests
//
//  Pins the bonus-round option builder (plan 2026-07-09-001 §A5/§B):
//  every set contains the correct answer among 4 unique display strings;
//  route distractors come from the correct answer's broad region and are
//  plausibility-weighted by distance-from-observer; type distractors share
//  the answer's AircraftType class within ±1 rarity tier and never collapse
//  to the answer's display name (the E75L/E75S "Embraer 175" trap).
//  All sampling is seeded (SeededRNG) — assertions are exact replays.
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

@Suite("GuessOptions — type questions")
struct GuessOptionsTypeTests {

    private func question(typecode: String?, seed: UInt64 = 1) -> GuessOptions.TypeQuestion? {
        var rng = SeededRNG(seed: seed)
        return GuessOptions.typeQuestion(typecode: typecode, using: &rng)
    }

    @Test func correctIncludedAmongFourUniqueOptions() throws {
        let q = try #require(question(typecode: "B738"))
        #expect(q.correctValue == "B738")
        #expect(q.options.count == GuessOptions.optionCount)
        #expect(q.options.contains { $0.value == "B738" })
        #expect(Set(q.options.map(\.value)).count == q.options.count)
        #expect(Set(q.options.map { $0.display.lowercased() }).count == q.options.count)
        // The correct chip shows the canonical name.
        let correctOption = try #require(q.options.first { $0.value == "B738" })
        #expect(correctOption.display == "Boeing 737-800")
    }

    @Test func distractorsShareClassWithinOneRarityTier() throws {
        // B738: narrow / common. Distractors must be narrowbodies within
        // ±1 tier (common/uncommon) — "737-800 / A320 / A220" confusable,
        // never "737-800 / B-52 / Cessna 172".
        for seed in UInt64(1)...30 {
            let q = try #require(question(typecode: "B738", seed: seed))
            for option in q.options where option.value != "B738" {
                let entry = try #require(AircraftNaming.table[option.value])
                #expect(entry.type == .narrow, "\(option.value) not a narrowbody")
                let ordinal = (entry.rarity ?? .common).ordinal
                #expect(abs(ordinal - Rarity.common.ordinal) <= 1,
                        "\(option.value) rarity \(String(describing: entry.rarity)) beyond ±1 tier")
            }
        }
    }

    @Test func collapsedDisplayNamesAreNeverOffered() throws {
        // E75L and E75S BOTH render "Embraer 175" — the classic collapse.
        // Whichever is the answer, the other must never appear: two chips
        // with identical text where one is "wrong" is a coin-flip trap.
        for answer in ["E75L", "E75S"] {
            for seed in UInt64(1)...50 {
                let q = try #require(question(typecode: answer, seed: seed))
                let displays = q.options.map { $0.display.lowercased() }
                #expect(displays.filter { $0 == "embraer 175" }.count == 1)
                let twin = answer == "E75L" ? "E75S" : "E75L"
                #expect(!q.options.contains { $0.value == twin })
            }
        }
    }

    @Test func unresolvableTypecodesReturnNil() {
        #expect(question(typecode: nil) == nil)
        #expect(question(typecode: "") == nil)
        #expect(question(typecode: "ZZZ9") == nil)
        #expect(GuessOptions.typeAvailable(typecode: nil) == false)
        #expect(GuessOptions.typeAvailable(typecode: "ZZZ9") == false)
        #expect(GuessOptions.typeAvailable(typecode: "B738") == true)
        // Case/whitespace-normalized like the route path.
        #expect(GuessOptions.typeAvailable(typecode: " b738 ") == true)
    }

    @Test func rareClassesStillBuildFullSets() throws {
        // A legendary military type (A-10) exercises the ±1-tier bucket at
        // the ladder's top edge — and, if starved, the same-class widening.
        let q = try #require(question(typecode: "A10"))
        #expect(q.options.count == GuessOptions.optionCount)
        for option in q.options where option.value != "A10" {
            let entry = try #require(AircraftNaming.table[option.value])
            #expect(entry.type == AircraftNaming.table["A10"]?.type)
        }
    }

    @Test func seededDeterminism() throws {
        let a = try #require(question(typecode: "B738", seed: 7))
        let b = try #require(question(typecode: "B738", seed: 7))
        #expect(a == b)
        let c = try #require(question(typecode: "B738", seed: 8))
        #expect(a != c, "different seeds should (in practice) differ")
    }
}
