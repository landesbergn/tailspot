//
//  Aircraft.swift
//  Tailspot
//
//  The core in-flight-aircraft value type. Not itself a wire format:
//  the backend feed arrives as keyed DTOs (`BackendAircraft` in
//  TailspotBackendClient.swift) and the replay format as
//  `AircraftSnapshot` (ReplayRecorder.swift); both map onto this
//  struct. (The OpenSky positional-array Decodable that used to live
//  here was removed with the rest of the OpenSky path — the backend
//  is the only source.)
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
    /// Best available altitude above MSL, meters. GEOMETRIC (GPS) altitude
    /// preferred, barometric only as fallback — the preference is applied in
    /// the backend's feed normalizer (`alt_geom ?? alt_baro`), so what
    /// arrives here is already the right one. Baro can sit hundreds of feet
    /// off true altitude with local pressure; at close range that error is
    /// degrees of elevation angle, exactly where the visibility curve is
    /// tightest.
    let altitudeMeters: Double
    let velocityMps: Double?    // ground speed, m/s
    let trackDeg: Double?       // direction of travel, degrees true
    let onGround: Bool
    /// When the network last received a position update for this aircraft.
    /// Used by `extrapolatedPosition(at:)` to project the position forward
    /// to "now" along the reported track. Nil if the feed didn't report it.
    let positionTimestamp: Date?
    /// ICAO type designator from the live position feed (e.g. "A359"), or nil
    /// when the source didn't carry one. `TailspotBackendClient` populates this
    /// from adsb.lol's `t` field; the replay-snapshot path leaves it nil. Lets
    /// a catch resolve make/model/type at catch time without the per-hex
    /// metadata endpoint (which is FAA-only).
    let typecode: String?
    /// Registration / tail number from the live feed (e.g. "9V-SMH"), or nil.
    let registration: String?
    /// ADS-B emitter category broadcast by the airframe (DO-260B), e.g. "A5"
    /// (heavy) or "A7" (rotorcraft) — uppercased by the backend. Nil when the
    /// source didn't carry one. `TailspotBackendClient` populates this from
    /// adsb.lol's `category`; the replay path leaves it nil. Unlike the
    /// manufacturer string, this is an authoritative rotorcraft signal — see
    /// `emitterCategory` / `isRotorcraft`.
    let category: String?
    /// ICAO airport code (4-letter, e.g. "KSFO") of the flight's ORIGIN, or nil
    /// when the feed didn't carry a route. `TailspotBackendClient` populates this
    /// from the backend's additive `route.originIcao`; the replay path leaves it
    /// nil. Frozen onto a `Catch` at catch time like the other airframe facts —
    /// most GA/military/routeless flights have no route, which is normal.
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
    /// nil so the many existing construction sites — the replay-snapshot
    /// `init(_:)` and tests — compile unchanged; only the backend feed path
    /// (`BackendAircraft.asAircraft`) supplies the new fields. (An explicit
    /// init here suppresses the synthesized memberwise init, so there's no
    /// ambiguity between the two.)
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
        // feed position should never be more than a couple of minutes old.
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
