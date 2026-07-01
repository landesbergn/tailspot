//
//  Aircraft.swift
//  Tailspot
//
//  The Aircraft struct + its custom Decodable for the OpenSky API.
//
//  OpenSky's `/api/states/all` returns each aircraft as a *positional*
//  JSON array — values keyed by index, not by name — like:
//
//    ["a3b15e", "AAL123  ", "United States", 1715000000, 1715000000,
//     -122.27, 37.87, 9144.0, false, 230.0, 270.5, ...]
//
//  We decode by pulling values off an unkeyed container in order.
//
//  The `FailableDecodable` wrapper lets us decode an array of aircraft
//  *lossily*: any entry that fails to decode (e.g. a radar contact with
//  no lat/lon) becomes nil instead of throwing and killing the whole
//  batch. We compactMap the nils away after.
//

import Foundation

// Xcode 26 sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` for new app
// projects, which makes every type implicitly MainActor. Aircraft is a
// pure value type that needs to flow across actor boundaries (decoded
// off the network thread, displayed from a view on main, etc.) — mark
// it `nonisolated` so its `Decodable` conformance and stored properties
// are usable from anywhere.
nonisolated struct Aircraft: Identifiable, Equatable, Sendable {
    let icao24: String          // 24-bit ICAO transponder address (lowercase hex)
    let callsign: String?       // trimmed flight callsign, may be nil
    let originCountry: String   // country of registration
    let longitude: Double
    let latitude: Double
    let altitudeMeters: Double  // best available altitude above MSL
    let velocityMps: Double?    // ground speed, m/s
    let trackDeg: Double?       // direction of travel, degrees true
    let onGround: Bool
    /// When the network last received a position update for this aircraft.
    /// Used by `extrapolatedPosition(at:)` to project the position forward
    /// to "now" along the reported track. Nil if OpenSky didn't report it.
    let positionTimestamp: Date?
    /// ICAO type designator from the live position feed (e.g. "A359"), or nil
    /// when the source didn't carry one. `TailspotBackendClient` populates this
    /// from adsb.lol's `t` field; the legacy OpenSky positional decoder and the
    /// replay-snapshot path leave it nil. Lets a catch resolve make/model/type
    /// at catch time without the per-hex metadata endpoint (which is FAA-only).
    let typecode: String?
    /// Registration / tail number from the live feed (e.g. "9V-SMH"), or nil.
    let registration: String?
    /// ADS-B emitter category broadcast by the airframe (DO-260B), e.g. "A5"
    /// (heavy) or "A7" (rotorcraft) — uppercased by the backend. Nil when the
    /// source didn't carry one. `TailspotBackendClient` populates this from
    /// adsb.lol's `category`; the legacy OpenSky positional decoder and the
    /// replay path leave it nil. Unlike the manufacturer string, this is an
    /// authoritative rotorcraft signal — see `emitterCategory` / `isRotorcraft`.
    let category: String?
    /// ICAO airport code (4-letter, e.g. "KSFO") of the flight's ORIGIN, or nil
    /// when the feed didn't carry a route. `TailspotBackendClient` populates this
    /// from the backend's additive `route.originIcao`; the legacy OpenSky
    /// positional decoder and the replay path leave it nil. Frozen onto a `Catch`
    /// at catch time like the other airframe facts — most GA/military/routeless
    /// flights have no route, which is normal.
    let originIcao: String?
    /// ICAO airport code (4-letter, e.g. "EGLL") of the flight's DESTINATION, or
    /// nil. Same source/semantics as `originIcao`.
    let destIcao: String?
    /// Human-readable origin airport/city ("San Francisco"), when the backend's
    /// routeset enrichment carried it. Same source/lifecycle as `originIcao`.
    let originName: String?
    /// Human-readable destination airport/city ("London"). Same as `originName`.
    let destName: String?

    var id: String { icao24 }

    /// The decoded ADS-B emitter category, or nil if the feed carried none or
    /// the code is unrecognized. Interpret via this rather than comparing the
    /// raw string at call sites.
    var emitterCategory: EmitterCategory? { EmitterCategory(rawValue: category) }

    /// True when the airframe *broadcasts itself* as a rotorcraft (emitter
    /// category A7). Authoritative — independent of any manufacturer/model
    /// string match. Nil/unknown category → false.
    var isRotorcraft: Bool { emitterCategory == .rotorcraft }

    /// Memberwise init with `typecode`/`registration`/`category` defaulted to
    /// nil so the many existing construction sites — the OpenSky positional
    /// decoder, the replay-snapshot `init(_:)`, and tests — compile unchanged;
    /// only the backend feed path (`BackendAircraft.asAircraft`) supplies the
    /// new fields. (An explicit init here suppresses the synthesized memberwise
    /// init, so there's no ambiguity between the two.)
    init(
        icao24: String,
        callsign: String?,
        originCountry: String,
        longitude: Double,
        latitude: Double,
        altitudeMeters: Double,
        velocityMps: Double?,
        trackDeg: Double?,
        onGround: Bool,
        positionTimestamp: Date?,
        typecode: String? = nil,
        registration: String? = nil,
        category: String? = nil,
        originIcao: String? = nil,
        destIcao: String? = nil,
        originName: String? = nil,
        destName: String? = nil
    ) {
        self.icao24 = icao24
        self.callsign = callsign
        self.originCountry = originCountry
        self.longitude = longitude
        self.latitude = latitude
        self.altitudeMeters = altitudeMeters
        self.velocityMps = velocityMps
        self.trackDeg = trackDeg
        self.onGround = onGround
        self.positionTimestamp = positionTimestamp
        self.typecode = typecode
        self.registration = registration
        self.category = category
        self.originIcao = originIcao
        self.destIcao = destIcao
        self.originName = originName
        self.destName = destName
    }

    /// Heuristic: is this a small (GA-sized) airframe? US general-aviation
    /// aircraft fly under their registration as the callsign — `N` followed
    /// by a digit (N3001B, N21866) — while airline/cargo/charter traffic
    /// uses ICAO three-letter prefixes (UAL, DAL, FDX, SKW…). Used by the
    /// visibility filter to halve the distance cap for airframes with a
    /// fraction of an airliner's visual size. Imperfect (a bizjet can file
    /// under its N-number) but field-accurate so far: every confirmed-ghost
    /// N-number, zero confirmed-visible ones.
    var isLikelySmallAirframe: Bool {
        guard let cs = callsign, cs.count >= 2 else { return false }
        return cs.first == "N" && cs[cs.index(after: cs.startIndex)].isNumber
    }

    /// Rough wingspan (meters) inferred from the ADS-B emitter category,
    /// falling back to the GA registration heuristic, then a neutral
    /// medium-large default. Used ONLY by the catch-time angular-size floor
    /// (`ObservedAircraft.apparentSizeArcminutes` → `clearsCatchSizeFloor`)
    /// to reject targets too small-and-distant to resolve by eye — never by
    /// the label/visibility path. Deliberately conservative: when the class
    /// is unknown we assume a LARGE airframe so the floor fails OPEN (it must
    /// never block a catch we can't confidently size). Class numbers are
    /// representative spans, not exact per-type values.
    var estimatedWingspanMeters: Double {
        switch emitterCategory {
        case .heavy:            return 60   // widebody (777 / A350)
        case .highVortexLarge:  return 38   // B757-class
        case .large:            return 34   // narrowbody (737 / A320)
        case .small:            return 16   // regional jet / bizjet / turboprop
        case .light:            return 11   // GA single / light twin
        case .highPerformance:  return 13   // fast bizjet / military
        case .rotorcraft:       return 14   // main-rotor diameter
        case .glider:           return 15
        case .uav:              return 5
        case .noInfo, .lighterThanAir, .other, .none:
            // No authoritative size. Use the GA callsign heuristic, else
            // assume a medium-large airframe so the floor fails open.
            return isLikelySmallAirframe ? 12 : 40
        }
    }
}

extension Aircraft {
    /// Project this aircraft's position forward to `now` using its reported
    /// velocity and track. Returns the raw lat/lon if any required field is
    /// missing, or if the extrapolation age is implausible.
    ///
    /// Why this exists: ADS-B positions can be 5–15 s old, and a typical
    /// jet at 250 m/s drifts ~1.3 km per 10 s of staleness. At a 30 km
    /// viewing distance that's several degrees of bearing error — visible
    /// as labels lagging the actual plane on screen.
    func extrapolatedPosition(at now: Date) -> (lat: Double, lon: Double) {
        guard
            let t = positionTimestamp,
            let v = velocityMps, v > 0,
            let track = trackDeg
        else {
            return (latitude, longitude)
        }
        let age = now.timeIntervalSince(t)
        // Sanity-cap to avoid extrapolating from corrupt data; a "fresh"
        // OpenSky response should never be more than a couple of minutes old.
        guard age > 0, age < 120 else {
            return (latitude, longitude)
        }
        return Geo.project(
            fromLat: latitude, lon: longitude,
            bearingDeg: track,
            distanceMeters: v * age
        )
    }
}

// `nonisolated` applies to the whole extension — without it, the
// project's MainActor default isolation makes the Decodable conformance
// MainActor-isolated, which breaks tests that decode in nonisolated
// context. The init's `nonisolated` alone isn't enough; the *conformance*
// itself has to be nonisolated.
nonisolated extension Aircraft: Decodable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()

        // 0  icao24
        self.icao24 = try c.decode(String.self)

        // 1  callsign (often padded with trailing whitespace)
        let rawCallsign = try c.decodeIfPresent(String.self)
        self.callsign = rawCallsign?
            .trimmingCharacters(in: .whitespaces)
            .nilIfEmpty

        // 2  origin_country
        self.originCountry = try c.decode(String.self)

        // 3  time_position (Int?, Unix seconds when network last received
        //    a position update for this aircraft). Used for forward
        //    extrapolation in ObservedAircraft annotation.
        let timePosition = try c.decodeIfPresent(Int.self)
        self.positionTimestamp = timePosition.map {
            Date(timeIntervalSince1970: TimeInterval($0))
        }

        // 4  last_contact (Int)          — we don't use it
        _ = try c.decode(Int.self)

        // 5  longitude (Double?)
        // 6  latitude (Double?)
        guard
            let lon = try c.decodeIfPresent(Double.self),
            let lat = try c.decodeIfPresent(Double.self)
        else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Aircraft is missing lat/lon (radar contact?)"
            )
        }
        self.longitude = lon
        self.latitude = lat

        // 7  baro_altitude (Double?, meters)
        let baro = try c.decodeIfPresent(Double.self)

        // 8  on_ground
        self.onGround = try c.decode(Bool.self)

        // 9  velocity (m/s)
        self.velocityMps = try c.decodeIfPresent(Double.self)

        // 10 true_track (deg)
        self.trackDeg = try c.decodeIfPresent(Double.self)

        // 11 vertical_rate                — skipped
        _ = try c.decodeIfPresent(Double.self)

        // 12 sensors (array)              — skipped
        _ = try? c.decodeIfPresent([Int].self)

        // 13 geo_altitude (Double?, meters) — preferred over baro
        let geo = try c.decodeIfPresent(Double.self)

        self.altitudeMeters = geo ?? baro ?? 0

        // OpenSky's positional state vector carries no type/registration/category/
        // route in the slots we read — the backend feed (BackendAircraft) is the
        // only source that supplies them.
        self.typecode = nil
        self.registration = nil
        self.category = nil
        self.originIcao = nil
        self.destIcao = nil
        self.originName = nil
        self.destName = nil

        // 14 squawk, 15 spi, 16 position_source, 17 category — all skipped
    }
}

// MARK: - Emitter category

/// ADS-B emitter category (DO-260B). The airframe broadcasts one of these
/// alongside its position; readsb/adsb.lol surfaces it as a two-char code
/// ("A0"…"A7", "B0"…"B7", "C0"…"C7") and the backend uppercases it before it
/// reaches us. Only the cases we actually reason about are spelled out — every
/// other valid-but-uninteresting code collapses to `.other`; a nil/empty string
/// yields `nil` via the failable init so call sites can `if let` cleanly.
///
/// The motivating use is `rotorcraft` (A7): the one *authoritative* "this is a
/// helicopter" signal, independent of any manufacturer/model string match. The
/// remaining cases are decoded now so future size/kind features (heavy, glider,
/// UAV…) can read them without re-plumbing the wire.
nonisolated enum EmitterCategory: Equatable, Sendable {
    case noInfo           // A0 / B0 / C0 — emitter present but no category set
    case light            // A1  (< 15 500 lb)
    case small            // A2  (15 500–75 000 lb)
    case large            // A3  (75 000–300 000 lb)
    case highVortexLarge  // A4  (e.g. B757)
    case heavy            // A5  (> 300 000 lb)
    case highPerformance  // A6  (> 5 g, > 400 kt)
    case rotorcraft       // A7  — helicopters
    case glider           // B1  glider / sailplane
    case lighterThanAir   // B2
    case uav              // B6  unmanned
    case other            // any other defined-but-uninteresting code

    /// Parse a feed category code (e.g. "A7"). Case-insensitive and
    /// whitespace-tolerant; returns nil for nil/empty input.
    init?(rawValue: String?) {
        guard
            let raw = rawValue?.trimmingCharacters(in: .whitespaces).uppercased(),
            !raw.isEmpty
        else { return nil }
        switch raw {
        case "A0", "B0", "C0": self = .noInfo
        case "A1": self = .light
        case "A2": self = .small
        case "A3": self = .large
        case "A4": self = .highVortexLarge
        case "A5": self = .heavy
        case "A6": self = .highPerformance
        case "A7": self = .rotorcraft
        case "B1": self = .glider
        case "B2": self = .lighterThanAir
        case "B6": self = .uav
        default: self = .other
        }
    }
}

/// Wraps a Decodable so per-element errors don't kill the whole batch.
/// JSONDecoder will assign `value = nil` for any element whose inner
/// init(from:) throws.
nonisolated struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        self.value = try? T(from: decoder)
    }
}

// MARK: - Convenience

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
