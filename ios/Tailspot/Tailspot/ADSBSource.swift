//
//  ADSBSource.swift
//  Tailspot
//
//  A protocol — Swift's term for "interface" — that says: anyone who
//  conforms to ADSBSource must provide a way to fetch aircraft inside
//  a lat/lon bounding box. Once we have this, ADSBManager can call
//  `aircraftInBbox` without caring whether the data is coming from
//  OpenSky, a mock generator for couch-testing, or — eventually —
//  our own backend proxy.
//
//  The protocol is `Sendable` so the conformer can be safely held by
//  the @MainActor ADSBManager and called across an `await`. (Same
//  reason OpenSkyClient was made Sendable last commit.)
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
