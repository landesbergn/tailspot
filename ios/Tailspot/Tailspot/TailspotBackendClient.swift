//
//  TailspotBackendClient.swift
//  Tailspot
//
//  ADSBSource implementation backed by our own api.tailspot.app proxy
//  (WP 1.6 of the Track 1 plan). The backend polls adsb.lol server-side
//  (MLAT included — GA and helicopters appear), caches per region tile,
//  and serves a NAMED-KEY JSON shape in SI units — so unlike the OpenSky
//  positional-array decode in Aircraft.swift, this file decodes ordinary
//  keyed Codable structs and maps them onto the existing `Aircraft` value.
//
//  Deliberate seams:
//  - `baseURL` is injectable (tests, local dev server, future hostname move).
//  - Errors are thrown as `ADSBSourceError` (a source-neutral enum) so
//    ADSBManager's 429-backoff (`catch ADSBSourceError.rateLimited`) works.
//  - The wire DTOs (`BackendAircraftResponse` etc.) are separate from
//    `Aircraft`, mirroring how `AircraftSnapshot` stays separate in the
//    replay format: backend wire changes must not ripple into core types.
//
//  This is the ONLY ADS-B source. OpenSky (device-direct) and the mock
//  source were removed in the 2026-06-21 cutover: the backend is field-proven,
//  and the silent backend→OpenSky failover hid backend problems mid-session
//  while dragging along an OAuth-secret apparatus that had leaked twice. If
//  api.tailspot.app is unreachable now, the app surfaces the error rather than
//  degrading to a sparser source.
//

import Foundation

// MARK: - Wire DTOs (named-key JSON, SI units; contract frozen in WP 1.2/1.4)

/// One aircraft as served by `GET /v1/aircraft`. All units SI: meters,
/// m/s, degrees true, unix seconds.
nonisolated struct BackendAircraft: Decodable {
    let icao24: String
    let callsign: String?
    let originCountry: String?
    let longitude: Double
    let latitude: Double
    let altitudeMeters: Double
    let velocityMps: Double?
    let trackDeg: Double?
    let onGround: Bool
    let positionTimestamp: Double?
    /// ICAO type designator from adsb.lol's `t` field (e.g. "A359"); nil when
    /// the feed didn't carry one. Optional in the wire shape — an old backend
    /// build that omits the key decodes as nil. This is what lets a catch
    /// resolve make/model for a foreign airframe the FAA-only metadata endpoint
    /// can't see.
    let typecode: String?
    /// Registration / tail (e.g. "9V-SMH") from adsb.lol's `r` field; nil if none.
    let registration: String?
    /// ADS-B emitter category (e.g. "A5" heavy, "A7" rotorcraft), uppercased by
    /// the backend; nil when the feed didn't carry one. Same optional/back-compat
    /// semantics as `typecode`. Drives authoritative rotorcraft tagging.
    let category: String?
    /// The flight's route (origin → destination airports) when the backend can
    /// resolve it. ADDITIVE + optional: the whole `route` key is omitted for most
    /// GA/military/routeless flights, and both sub-fields are independently
    /// optional — so an older backend that never sends it (or a routeless flight)
    /// decodes as nil with no error. Both codes are 4-letter ICAO airport idents.
    let route: Route?

    /// Nested `route` object on `GET /v1/aircraft` (U6 backend addition):
    /// `{ "originIcao": "KSFO", "destIcao": "EGLL" }`. Both sub-fields optional.
    nonisolated struct Route: Decodable {
        let originIcao: String?
        let destIcao: String?
        /// Human-readable origin/destination airport/city ("San Francisco"),
        /// when the backend's routeset enrichment carried it. Optional — an
        /// older backend or code-only route decodes these as nil.
        let originName: String?
        let destName: String?
    }

    /// Map onto the app's core `Aircraft` value. `originCountry` is
    /// non-optional there (OpenSky always sent it); the backend derives it
    /// from the icao24 allocation block and may return null for unallocated
    /// addresses — fall back to a display dash rather than dropping the row.
    func asAircraft() -> Aircraft {
        Aircraft(
            icao24: icao24,
            callsign: callsign,
            originCountry: originCountry ?? "—",
            longitude: longitude,
            latitude: latitude,
            altitudeMeters: altitudeMeters,
            velocityMps: velocityMps,
            trackDeg: trackDeg,
            onGround: onGround,
            positionTimestamp: positionTimestamp.map { Date(timeIntervalSince1970: $0) },
            typecode: typecode,
            registration: registration,
            category: category,
            originIcao: route?.originIcao,
            destIcao: route?.destIcao,
            originName: route?.originName,
            destName: route?.destName
        )
    }
}

/// Envelope of `GET /v1/aircraft`. `fetchedAt` is when the BACKEND fetched
/// from upstream (not when it answered us) — useful later for staleness UI;
/// unused by ADSBManager today.
nonisolated struct BackendAircraftResponse: Decodable {
    let fetchedAt: Double
    let aircraft: [BackendAircraft]
}

/// `GET /v1/metadata/{icao24}` body (200 case).
nonisolated struct BackendMetadata: Decodable {
    let icao24: String
    let registration: String?
    let manufacturer: String?
    let model: String?
    let typecode: String?
    let operatorName: String?
    let source: String

    /// Map onto the existing `AircraftMetadata` shape consumed by the
    /// metadata cache + detail views. The backend has no separate ICAO
    /// manufacturer string, so `manufacturerIcao` is nil.
    func asAircraftMetadata() -> AircraftMetadata {
        AircraftMetadata(
            icao24: icao24,
            registration: registration,
            manufacturerName: manufacturer,
            manufacturerIcao: nil,
            model: model,
            typecode: typecode,
            operatorName: operatorName
        )
    }
}

// MARK: - Client

nonisolated struct TailspotBackendClient: ADSBSource {
    /// Production API host. Override in init for tests / local dev.
    static let defaultBaseURL = URL(string: "https://api.tailspot.app")!

    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TailspotBackendClient.defaultBaseURL,
         session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft] {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("v1/aircraft"),
            resolvingAgainstBaseURL: false
        )
        comps?.queryItems = [
            URLQueryItem(name: "lamin", value: String(lamin)),
            URLQueryItem(name: "lomin", value: String(lomin)),
            URLQueryItem(name: "lamax", value: String(lamax)),
            URLQueryItem(name: "lomax", value: String(lomax)),
        ]
        guard let url = comps?.url else { throw ADSBSourceError.badURL }

        let data = try await get(url)
        do {
            let decoded = try JSONDecoder().decode(BackendAircraftResponse.self, from: data)
            return decoded.aircraft.map { $0.asAircraft() }
        } catch {
            throw ADSBSourceError.decoding(error)
        }
    }

    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
        let url = baseURL.appendingPathComponent("v1/metadata/\(icao24)")
        let data: Data
        do {
            data = try await get(url)
        } catch ADSBSourceError.http(let status) where status == 404 {
            // Unknown airframe is a real answer, not an error — the metadata
            // cache stores nil as a known-miss so we don't re-fetch.
            return nil
        }
        do {
            return try JSONDecoder().decode(BackendMetadata.self, from: data)
                .asAircraftMetadata()
        } catch {
            throw ADSBSourceError.decoding(error)
        }
    }

    /// Shared GET with the status-code mapping ADSBManager expects.
    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ADSBSourceError.http(status: -1)
        }
        switch http.statusCode {
        case 200: return data
        case 429: throw ADSBSourceError.rateLimited
        default: throw ADSBSourceError.http(status: http.statusCode)
        }
    }
}
