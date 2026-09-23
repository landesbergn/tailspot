//
//  ADSBSource.swift
//  Tailspot
//
//  A protocol — Swift's term for "interface" — that says: anyone who
//  conforms to ADSBSource must provide a way to fetch aircraft inside
//  a lat/lon bounding box. Once we have this, ADSBManager can call
//  `aircraftInBbox` without caring whether the data is coming from the
//  live Tailspot backend or a test fixture. (OpenSky-direct and the mock
//  source were removed in the 2026-06-21 cutover; the seam remains so
//  tests can inject fixtures and a future source can drop in.)
//
//  The protocol is `Sendable` so the conformer can be safely held by
//  the @MainActor ADSBManager and called across an `await`.
//

import Foundation

// Marked `nonisolated` so conformers (and their methods) are usable
// from any actor — without this, the project's MainActor default
// isolation would force conformers to MainActor too, defeating the
// whole point of having an injectable source.
nonisolated protocol ADSBSource: Sendable {
    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft]

    /// Fetch per-aircraft metadata (manufacturer / model / registration /
    /// operator) for a single icao24. Returns nil if the source has no
    /// record. Throws on transport/auth errors.
    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata?
}

/// Transport errors an `ADSBSource` can throw. Source-neutral — the live
/// source (`TailspotBackendClient`) throws these and `ADSBManager` surfaces
/// them via `lastError`. (Formerly `OpenSkyClient.ClientError`; promoted to
/// a shared type when the OpenSky source was removed and the backend became
/// the only ADS-B source.)
///
/// `rateLimited` is a 429, split out of `http(status:)` because one caller
/// must treat it differently: `GET /v1/metadata/:icao24` is limited to
/// 300/min/IP by the backend's API hardening (2026-09-06), and being told to
/// slow down is not a failure worth putting a red pill in front of the user.
/// `ADSBManager.metadata(for:)` swallows it (logs, doesn't cache, retries on
/// the next lookup); everything else still surfaces normally.
nonisolated enum ADSBSourceError: Error, LocalizedError {
    case badURL
    case http(status: Int)
    case rateLimited
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:              return "Bad URL"
        case .http(let s):         return "HTTP \(s)"
        case .rateLimited:         return "Rate limited (HTTP 429)"
        case .decoding(let inner): return "Decoding: \(inner.localizedDescription)"
        }
    }
}
