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

struct Aircraft: Identifiable, Equatable, Sendable {
    let icao24: String          // 24-bit ICAO transponder address (lowercase hex)
    let callsign: String?       // trimmed flight callsign, may be nil
    let originCountry: String   // country of registration
    let longitude: Double
    let latitude: Double
    let altitudeMeters: Double  // best available altitude above MSL
    let velocityMps: Double?    // ground speed, m/s
    let trackDeg: Double?       // direction of travel, degrees true
    let onGround: Bool

    var id: String { icao24 }
}

extension Aircraft: Decodable {
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

        // 3  time_position (Int?)        — we don't use it
        _ = try c.decodeIfPresent(Int.self)

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

        // 14 squawk, 15 spi, 16 position_source, 17 category — all skipped
    }
}

/// Wraps a Decodable so per-element errors don't kill the whole batch.
/// JSONDecoder will assign `value = nil` for any element whose inner
/// init(from:) throws.
struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        self.value = try? T(from: decoder)
    }
}

// MARK: - Convenience

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
