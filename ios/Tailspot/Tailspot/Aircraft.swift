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

    var id: String { icao24 }

    /// Memberwise init with `typecode`/`registration` defaulted to nil so the
    /// many existing construction sites — the OpenSky positional decoder, the
    /// replay-snapshot `init(_:)`, and tests — compile unchanged; only the
    /// backend feed path (`BackendAircraft.asAircraft`) supplies the new fields.
    /// (An explicit init here suppresses the synthesized memberwise init, so
    /// there's no ambiguity between the two.)
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
        registration: String? = nil
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

        // OpenSky's positional state vector carries no type/registration — the
        // backend feed (BackendAircraft) is the only source that supplies them.
        self.typecode = nil
        self.registration = nil

        // 14 squawk, 15 spi, 16 position_source, 17 category — all skipped
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
