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
    // Distances retuned 2026-06-06 for the ground-truth visibility curve
    // (~4.5 km near the horizon → 13 km plateau above 30°): four templates
    // sit INSIDE the curve so mock mode shows labels on the couch, and one
    // (ASA12) sits far outside it to exercise the filter — it appears in
    // the debug list but never in AR.
    private let templates: [Template] = [
        // NE, near-overhead cruise — the contrail case the 13 km plateau
        // exists for. Elevation ~74°, slant ~10.9 km.
        Template(icao24: "a3b15e", callsign: "UAL248",  originCountry: "United States",
                 bearingDeg:  45, groundDistanceKm: 3, altitudeMeters: 10_500,
                 trackDeg: 270, velocityMps: 240),

        // SE, close, lower altitude — approach traffic. ~24°, ~4.4 km.
        Template(icao24: "a52f30", callsign: "SWA1841", originCountry: "United States",
                 bearingDeg: 135, groundDistanceKm:  4, altitudeMeters:  1_800,
                 trackDeg: 220, velocityMps: 180),

        // West, far, high cruise — deliberately OUTSIDE the visibility
        // curve (~16°, 41 km): exercises the filter in mock mode.
        Template(icao24: "a91234", callsign: "ASA12",   originCountry: "United States",
                 bearingDeg: 270, groundDistanceKm: 40, altitudeMeters: 11_500,
                 trackDeg:  90, velocityMps: 260),

        // North, mid-distance, mid-altitude — small jet. ~37°, ~7.5 km.
        Template(icao24: "a4abcd", callsign: "DAL567",  originCountry: "United States",
                 bearingDeg:   0, groundDistanceKm: 6, altitudeMeters:  4_500,
                 trackDeg: 180, velocityMps: 200),

        // SSW, close, high — steep elevation (~61°), slant ~10.3 km.
        Template(icao24: "abc789", callsign: "JBU412",  originCountry: "United States",
                 bearingDeg: 200, groundDistanceKm: 5, altitudeMeters:  9_000,
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

    // MARK: - Metadata fixtures

    /// Hand-rolled metadata for each of the five mock planes — good
    /// enough to exercise the detail-view path end-to-end in MOCK mode.
    private let metadataByIcao24: [String: AircraftMetadata] = [
        "a3b15e": AircraftMetadata(
            icao24: "a3b15e",
            registration: "N12345",
            manufacturerName: "BOEING",
            manufacturerIcao: "BOEING",
            model: "737-800",
            typecode: "B738",
            operatorName: "United Airlines"
        ),
        "a52f30": AircraftMetadata(
            icao24: "a52f30",
            registration: "N87654",
            manufacturerName: "AIRBUS",
            manufacturerIcao: "AIRBUS",
            model: "A320-200",
            typecode: "A320",
            operatorName: "Southwest Airlines"
        ),
        "a91234": AircraftMetadata(
            icao24: "a91234",
            registration: "N201AS",
            manufacturerName: "BOMBARDIER",
            manufacturerIcao: "BOMBARDIER",
            model: "CRJ-700",
            typecode: "CRJ7",
            operatorName: "Alaska Airlines"
        ),
        "a4abcd": AircraftMetadata(
            icao24: "a4abcd",
            registration: "N98765",
            manufacturerName: "ATR",
            manufacturerIcao: "ATR",
            model: "ATR 72-600",
            typecode: "AT76",
            operatorName: "Delta Connection"
        ),
        // abc789 deliberately has NO metadata — exercises the 404/cache-miss
        // path on tap.
    ]

    func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
        // Match the small artificial latency from aircraftInBbox so the
        // loading UI in AircraftDetailView behaves like the live source.
        try? await Task.sleep(for: .milliseconds(100))
        return metadataByIcao24[icao24.lowercased()]
    }
}
