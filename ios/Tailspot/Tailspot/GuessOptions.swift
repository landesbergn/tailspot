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
//    The question prefers the MAJOR (recognizable) endpoint, and among ties
//    the one FARTHER from the observer (locked 2026-06-29 design). The correct
//    airport plus 3 distractors from the bundled `airports.json`
//    (tools/generate-airports.py, public-domain OurAirports data). That table
//    plays two roles split by the `major` flag: EVERY row — including
//    comprehensive US regional coverage — resolves a route endpoint so a round
//    can fire, but only `major` rows (curated worldwide hubs + US large
//    airports) are sampled as distractors. Distractor quality is the plan's
//    risk #5, so distractors are (a) major, (b) from the same broad region
//    (OurAirports continent code) as the correct answer, and (c)
//    plausibility-weighted: airports whose distance-from-observer is close to
//    the correct airport's are preferred, so a plane 11,000 km out of SFO gets
//    "HKG / ICN / SIN / NRT", not "HKG / OAK / LAS / SJC".
//
//  The option set contains the correct answer and 4 unique display
//  strings, shuffled with the injectable RNG (SeededRNG in tests).
//
//  `nonisolated` per repo convention: pure data/geometry logic callable from
//  any actor.
//

import Foundation

// MARK: - Airport table

/// One row of the bundled `airports.json` (tools/generate-airports.py).
///
/// The table plays two roles and `major` splits them: EVERY row resolves a
/// route endpoint (so a round can fire and the correct chip renders), but
/// only `major` rows are sampled as distractors — see `major`.
nonisolated struct GuessAirport: Equatable, Sendable {
    /// 4-letter ICAO ident ("VHHH") — the wire value the server verifies
    /// against the route resolver's endpoints. (US idents like "KMRY" come
    /// from the OurAirports `ident` column.)
    let icao: String
    /// 3-letter IATA code ("HKG") — what travelers read; leads the chip.
    /// EMPTY for many small US resolution-only fields (see `display`).
    let iata: String
    /// Traveler-recognizable city name ("Hong Kong").
    let city: String
    let lat: Double
    let lon: Double
    /// OurAirports two-letter continent code (AF AS EU NA OC SA) — the
    /// "same broad region" bucket for distractor sampling.
    let continent: String
    /// `true` for recognizable airports (curated worldwide hubs + US large
    /// airports) — the ONLY rows sampled as wrong-answer distractors. `false`
    /// for US medium/small resolution-only fields: they resolve routes and
    /// render the correct chip, but must never surface as an obscure wrong
    /// answer. Decodes as `true` when absent (an old-shape row stays a valid
    /// distractor rather than silently vanishing from the pool).
    let major: Bool

    /// Chip text, matching the locked design's "HKG · Hong Kong" shape. Small
    /// resolution-only fields often have no IATA — lead with the ICAO ident
    /// then ("KMRY · Monterey"), never a bare "· City".
    var display: String { iata.isEmpty ? "\(icao) · \(city)" : "\(iata) · \(city)" }
}

nonisolated extension GuessAirport: Decodable {
    private enum CodingKeys: String, CodingKey {
        case icao, iata, city, lat, lon, continent, major
    }

    /// Hand-rolled so `major` is decode-optional (defaults `true`): the
    /// airports.json shape gained `major` in the comprehensive-US-coverage
    /// pass, and a row without it must still load as a usable distractor.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icao = try c.decode(String.self, forKey: .icao)
        iata = try c.decode(String.self, forKey: .iata)
        city = try c.decode(String.self, forKey: .city)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        continent = try c.decode(String.self, forKey: .continent)
        major = try c.decodeIfPresent(Bool.self, forKey: .major) ?? true
    }
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

    /// The full airport table, ICAO-sorted (the JSON is generated sorted;
    /// array order matters for seeded determinism). Both resolution rows and
    /// distractor-eligible (`major`) rows live here — filter on `major` when
    /// sampling distractors. Missing/corrupt resource degrades to an empty
    /// pool — route questions become unavailable, never a crash (same posture
    /// as AircraftNaming.table).
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
    /// The asked endpoint is chosen among the endpoints that resolve in the
    /// table: prefer a MAJOR (recognizable) one, then, among ties, the one
    /// FARTHER from the observer. If only one endpoint resolves (small regional
    /// field on the other end) the question gracefully asks about it; a
    /// resolution-only field is asked about only when it's the sole resolver.
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
        // Prefer asking about a MAJOR (recognizable) endpoint — a KSFO→small-
        // field route asks about SFO, not the small field. Fall back to a
        // non-major endpoint only when it's the only one that resolves. Among
        // the preferred set, ask the one FARTHER from the observer (locked
        // 2026-06-29 design).
        let preferred = candidates.contains { $0.airport.major }
            ? candidates.filter { $0.airport.major }
            : candidates
        guard let asked = preferred.max(by: {
            distanceMeters(from: observerLat, observerLon, to: $0.airport)
                < distanceMeters(from: observerLat, observerLon, to: $1.airport)
        }) else { return nil }

        let correct = asked.airport
        // The OTHER true endpoint must never appear as a distractor: the
        // server verifies a route guess against EITHER endpoint, so a chip
        // that's locally "wrong" but server-correct would guarantee verdict
        // drift. Excluded by ident even when it's not in the curated pool.
        let otherIdent = asked.endpoint == .origin ? destIdent : originIdent

        // Distractors are sampled ONLY from `major` airports: the recognizable
        // hubs. The comprehensive US resolution-only fields (major == false)
        // resolve routes but must never surface as an obscure wrong answer —
        // "plausibly wrong" beats "obscurely wrong".
        func pool(sameRegionOnly: Bool) -> [GuessAirport] {
            airports.filter {
                $0.major
                    && $0.icao != correct.icao
                    && $0.icao != otherIdent
                    && (!sameRegionOnly || $0.continent == correct.continent)
            }
        }
        // Same broad region as the correct answer; a thin MAJOR region
        // (shouldn't happen — every continent has ≥16 major entries) widens to
        // major-anywhere rather than failing the round. A non-major airport is
        // never sampled as a distractor at either width.
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
