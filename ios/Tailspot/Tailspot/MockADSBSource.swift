//
//  MockADSBSource.swift
//  Tailspot
//
//  Hand-picked synthetic aircraft for couch-testing. Each entry is
//  defined by (bearing-from-observer, ground-distance, altitude); we
//  project that into a lat/lon at fetch time so the planes always
//  appear at the same angular positions relative to wherever you
//  actually are.
//
//  Stable across launches — no randomness — so you can verify your
//  mental model: "the UAL248 mock is always at bearing 045° elevation
//  ~23° from me, no matter where me is."
//
//  Use the tap-to-toggle on the ADSB status row in ContentView to
//  switch between this and OpenSkyClient at runtime.
//

import Foundation

nonisolated final class MockADSBSource: ADSBSource, Sendable {

    /// One mock aircraft, expressed as its angular relationship to the
    /// observer rather than absolute lat/lon. Resolves to a real
    /// Aircraft each fetch using Geo.project.
    private struct Template {
        let icao24: String
        let callsign: String
        let originCountry: String
        let bearingDeg: Double          // from observer
        let groundDistanceKm: Double    // from observer
        let altitudeMeters: Double      // MSL
        let trackDeg: Double            // direction of travel
        let velocityMps: Double
    }

    /// Five aircraft spread around the user, with a variety of bearings,
    /// distances, and altitudes — chosen so all have positive elevation
    /// (visible above horizon) and span a reasonable range of "feels
    /// like a small plane on approach" → "feels like a 747 at cruise".
    private let templates: [Template] = [
        // NE, mid-distance, cruise altitude — this is your "test target".
        // Should land near bearing 045°, elevation ~23°.
        Template(icao24: "a3b15e", callsign: "UAL248",  originCountry: "United States",
                 bearingDeg:  45, groundDistanceKm: 25, altitudeMeters: 10_500,
                 trackDeg: 270, velocityMps: 240),

        // SE, close, lower altitude — feels like approach traffic.
        Template(icao24: "a52f30", callsign: "SWA1841", originCountry: "United States",
                 bearingDeg: 135, groundDistanceKm:  8, altitudeMeters:  1_800,
                 trackDeg: 220, velocityMps: 180),

        // West, far, high cruise — feels like overhead traffic.
        Template(icao24: "a91234", callsign: "ASA12",   originCountry: "United States",
                 bearingDeg: 270, groundDistanceKm: 40, altitudeMeters: 11_500,
                 trackDeg:  90, velocityMps: 260),

        // North, mid-distance, mid-altitude — small jet.
        Template(icao24: "a4abcd", callsign: "DAL567",  originCountry: "United States",
                 bearingDeg:   0, groundDistanceKm: 15, altitudeMeters:  4_500,
                 trackDeg: 180, velocityMps: 200),

        // SSW, close, high — should produce a steep elevation (~37°).
        Template(icao24: "abc789", callsign: "JBU412",  originCountry: "United States",
                 bearingDeg: 200, groundDistanceKm: 12, altitudeMeters:  9_000,
                 trackDeg:  30, velocityMps: 230),
    ]

    func aircraftInBbox(
        lamin: Double, lomin: Double, lamax: Double, lomax: Double
    ) async throws -> [Aircraft] {
        // Treat the bbox center as the observer's position. Good enough
        // for a mock — the manager builds bboxes around the user's GPS,
        // so center ≈ user.
        let centerLat = (lamin + lamax) / 2
        let centerLon = (lomin + lomax) / 2

        // Add a tiny artificial latency so the loading indicator behaves
        // realistically and the toggle isn't suspiciously instantaneous.
        try? await Task.sleep(for: .milliseconds(150))

        return templates.map { t in
            let (lat, lon) = Geo.project(
                fromLat: centerLat, lon: centerLon,
                bearingDeg: t.bearingDeg,
                distanceMeters: t.groundDistanceKm * 1_000
            )
            return Aircraft(
                icao24: t.icao24,
                callsign: t.callsign,
                originCountry: t.originCountry,
                longitude: lon,
                latitude: lat,
                altitudeMeters: t.altitudeMeters,
                velocityMps: t.velocityMps,
                trackDeg: t.trackDeg,
                onGround: false,
                // Fresh-now timestamp so the manager's extrapolation is
                // a no-op for mock data — keeps the mocks anchored at the
                // bearings/distances declared in the templates.
                positionTimestamp: Date()
            )
        }
    }
}
