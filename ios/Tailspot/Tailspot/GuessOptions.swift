//
//  GuessOptions.swift
//  Tailspot
//
//  Builds the 4-chip option set for the ROUTE bonus round (game-layer PR2,
//  plan 2026-07-09-001 §A5/§B; route-only per Noah 2026-07-09). Pure value
//  logic — no UI, no state; the guess-round screen (PR3) renders whatever
//  this emits.
//
//  ROUTE — "Where's it coming from?" / "Where's it headed?":
//    The question asks about the route endpoint FARTHER from the observer
//    (locked 2026-06-29 design). The correct airport plus 3 distractors from
//    the bundled `airports.json` (~294 curated major airports derived from
//    public-domain OurAirports data — tools/generate-airports.py). Distractor
//    quality is the plan's risk #5, so distractors are (a) from the same
//    broad region (OurAirports continent code) as the correct answer and
//    (b) plausibility-weighted: airports whose distance-from-observer is
//    close to the correct airport's are preferred, so a plane 11,000 km out
//    of SFO gets "HKG / ICN / SIN / NRT", not "HKG / OAK / LAS / SJC".
//
//  The option set contains the correct answer and 4 unique display
//  strings, shuffled with the injectable RNG (SeededRNG in tests).
//
//  `nonisolated` per repo convention: pure data/geometry logic callable from
//  any actor.
//

import Foundation

// MARK: - Airport table

/// One row of the bundled `airports.json` — a curated major airport.
nonisolated struct GuessAirport: Decodable, Equatable, Sendable {
    /// 4-letter ICAO ident ("VHHH") — the wire value the server verifies
    /// against the route resolver's endpoints.
    let icao: String
    /// 3-letter IATA code ("HKG") — what travelers read; leads the chip.
    let iata: String
    /// Traveler-recognizable city name ("Hong Kong").
    let city: String
    let lat: Double
    let lon: Double
    /// OurAirports two-letter continent code (AF AS EU NA OC SA) — the
    /// "same broad region" bucket for distractor sampling.
    let continent: String

    /// Chip text, matching the locked design's "HKG · Hong Kong" shape.
    var display: String { "\(iata) · \(city)" }
}

// MARK: - GuessOptions

nonisolated enum GuessOptions {

    /// Options per question — the correct answer + 3 distractors.
    static let optionCount = 4

    /// One tappable chip. `value` is what goes on the wire (`guess.value`):
    /// an ICAO airport ident. `display` is the chip text; option sets
    /// guarantee 4 unique displays.
    struct Option: Equatable, Sendable {
        let value: String
        let display: String
    }

    /// Which route endpoint the question asks about.
    enum RouteEndpoint: String, Equatable, Sendable {
        case origin        // "Where's it coming from?"
        case destination   // "Where's it headed?"
    }

    struct RouteQuestion: Equatable, Sendable {
        let endpoint: RouteEndpoint
        /// Exactly 4, shuffled, includes the correct answer.
        let options: [Option]
        /// The correct airport's ICAO ident (uppercased) — PR3 compares the
        /// tapped option's `value` against this for the local verdict.
        let correctValue: String
    }

    /// The curated airport pool, ICAO-sorted (the JSON is generated sorted;
    /// array order matters for seeded determinism). Missing/corrupt resource
    /// degrades to an empty pool — route questions become unavailable, never
    /// a crash (same posture as AircraftNaming.table).
    static let airports: [GuessAirport] = {
        guard let url = Bundle.main.url(forResource: "airports", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([GuessAirport].self, from: data)
        else { return [] }
        return decoded
    }()

    static let airportsByIcao: [String: GuessAirport] = {
        Dictionary(airports.map { ($0.icao, $0) }, uniquingKeysWith: { a, _ in a })
    }()

    // MARK: - Availability (the scheduler's routeAvailable input)

    /// True when a route question can actually be built: at least one
    /// endpoint resolves in the curated airport table (the correct chip
    /// needs a display name and coordinates), and the route isn't degenerate
    /// (both endpoints the same field hop). The scheduler must not fire a
    /// round the option builder can't render.
    static func routeAvailable(originIcao: String?, destIcao: String?) -> Bool {
        let origin = normalizedIdent(originIcao)
        let dest = normalizedIdent(destIcao)
        if let origin, let dest, origin == dest { return false }
        let originKnown = origin.flatMap { airportsByIcao[$0] } != nil
        let destKnown = dest.flatMap { airportsByIcao[$0] } != nil
        return originKnown || destKnown
    }

    // MARK: - Route question

    /// Build the route question for a catch's frozen route, or nil when no
    /// honest option set can be built (endpoint not in the curated pool,
    /// degenerate route, pool exhausted).
    ///
    /// The asked endpoint is the one FARTHER from the observer, among the
    /// endpoints that resolve in the curated table — if only one endpoint is
    /// known (small regional field on the other end), the question gracefully
    /// asks about the known one.
    static func routeQuestion(
        originIcao: String?,
        destIcao: String?,
        observerLat: Double,
        observerLon: Double,
        using rng: inout some RandomNumberGenerator
    ) -> RouteQuestion? {
        let originIdent = normalizedIdent(originIcao)
        let destIdent = normalizedIdent(destIcao)
        if let originIdent, let destIdent, originIdent == destIdent { return nil }

        var candidates: [(endpoint: RouteEndpoint, airport: GuessAirport)] = []
        if let a = originIdent.flatMap({ airportsByIcao[$0] }) { candidates.append((.origin, a)) }
        if let a = destIdent.flatMap({ airportsByIcao[$0] }) { candidates.append((.destination, a)) }
        guard let asked = candidates.max(by: {
            distanceMeters(from: observerLat, observerLon, to: $0.airport)
                < distanceMeters(from: observerLat, observerLon, to: $1.airport)
        }) else { return nil }

        let correct = asked.airport
        // The OTHER true endpoint must never appear as a distractor: the
        // server verifies a route guess against EITHER endpoint, so a chip
        // that's locally "wrong" but server-correct would guarantee verdict
        // drift. Excluded by ident even when it's not in the curated pool.
        let otherIdent = asked.endpoint == .origin ? destIdent : originIdent

        func pool(sameRegionOnly: Bool) -> [GuessAirport] {
            airports.filter {
                $0.icao != correct.icao
                    && $0.icao != otherIdent
                    && (!sameRegionOnly || $0.continent == correct.continent)
            }
        }
        // Same broad region as the correct answer; a thin region (shouldn't
        // happen with the curated pool — every continent has ≥16 entries)
        // widens to the whole pool rather than failing the round.
        var candidatePool = pool(sameRegionOnly: true)
        if candidatePool.count < optionCount - 1 {
            candidatePool = pool(sameRegionOnly: false)
        }
        guard candidatePool.count >= optionCount - 1 else { return nil }

        // Plausibility weights: prefer distractors whose distance from the
        // observer is close to the correct airport's, on a ~500 km softness
        // scale. An airport at the same range as the true answer is maximally
        // plausible (weight 1); one 5,000 km off is ~1/11.
        let correctDistance = distanceMeters(from: observerLat, observerLon, to: correct)
        let softnessMeters = 500_000.0
        let weights = candidatePool.map { airport in
            let delta = abs(distanceMeters(from: observerLat, observerLon, to: airport) - correctDistance)
            return 1.0 / (1.0 + delta / softnessMeters)
        }
        let distractors = weightedSample(candidatePool, weights: weights,
                                         count: optionCount - 1, using: &rng)
        guard distractors.count == optionCount - 1 else { return nil }

        let options = ([correct] + distractors)
            .map { Option(value: $0.icao, display: $0.display) }
            .shuffled(using: &rng)
        return RouteQuestion(endpoint: asked.endpoint, options: options, correctValue: correct.icao)
    }

    // MARK: - Helpers

    /// Trim + uppercase an ICAO airport ident / typecode; blank → nil.
    private static func normalizedIdent(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !t.isEmpty else { return nil }
        return t
    }

    private static func distanceMeters(
        from lat: Double, _ lon: Double, to airport: GuessAirport
    ) -> Double {
        Geo.distance(fromLat: lat, lon: lon, toLat: airport.lat, lon: airport.lon)
    }

    /// Weighted sampling WITHOUT replacement: `count` items drawn from
    /// `pool`, each draw proportional to its weight among the remaining
    /// items. O(count · n) — pools are a few hundred entries.
    static func weightedSample<T>(
        _ pool: [T],
        weights: [Double],
        count: Int,
        using rng: inout some RandomNumberGenerator
    ) -> [T] {
        precondition(pool.count == weights.count, "one weight per pool item")
        var remaining = Array(zip(pool, weights)).filter { $0.1 > 0 }
        var result: [T] = []
        while result.count < count, !remaining.isEmpty {
            let total = remaining.reduce(0) { $0 + $1.1 }
            var roll = Double.random(in: 0..<total, using: &rng)
            var pickedIndex = remaining.count - 1
            for (i, item) in remaining.enumerated() {
                roll -= item.1
                if roll < 0 { pickedIndex = i; break }
            }
            result.append(remaining.remove(at: pickedIndex).0)
        }
        return result
    }
}
