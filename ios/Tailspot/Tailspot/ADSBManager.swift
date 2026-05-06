//
//  ADSBManager.swift
//  Tailspot
//
//  Owns the ADS-B polling loop. Asks the OpenSkyClient for nearby
//  aircraft on a timer, annotates each with its bearing/elevation/
//  distance from the user's current position, and exposes the
//  resulting list to SwiftUI via @Published.
//
//  Marked @MainActor so all @Published mutations are main-thread by
//  construction — no manual DispatchQueue.main.async hops needed.
//  When we `await client.aircraftInBbox(...)`, the actor suspends and
//  the network call runs on URLSession's pool; on resume we're back on
//  main and can assign `self.observed = …` directly.
//

import Foundation
import Combine
import CoreLocation

/// An Aircraft annotated with its angular position and distance relative
/// to a specific observer location. The geometry is computed once per
/// fetch — not in the view body — so SwiftUI re-renders are cheap.
struct ObservedAircraft: Identifiable, Sendable {
    let aircraft: Aircraft
    let bearingDeg: Double          // 0..360 from true north
    let elevationDeg: Double        // above horizon, can be negative
    let groundDistanceMeters: Double
    let slantDistanceMeters: Double // line-of-sight (3D) distance

    var id: String { aircraft.icao24 }
}

@MainActor
final class ADSBManager: ObservableObject {

    @Published var observed: [ObservedAircraft] = []
    @Published var lastError: String?
    @Published var lastFetched: Date?

    /// Search radius around the user, in km. OpenSky's anonymous tier
    /// caps bbox area; 50 km here is conservatively inside that limit
    /// at any latitude we care about.
    var radiusKm: Double = 50

    /// Polling interval. OpenSky anonymous minimum is 10s; we leave a
    /// little headroom.
    var pollInterval: TimeInterval = 12

    private let client = OpenSkyClient()
    private var pollTask: Task<Void, Never>?

    /// Start polling. The provider closure is called on each tick to
    /// fetch the latest user location — passing it as a closure (rather
    /// than holding a strong reference to LocationManager) keeps the two
    /// classes loosely coupled.
    func start(locationProvider: @escaping @MainActor () -> CLLocation?) {
        guard pollTask == nil else { return }

        let interval = pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let loc = locationProvider() {
                    await self?.refresh(around: loc)
                    try? await Task.sleep(for: .seconds(interval))
                } else {
                    // Location not yet available — short retry so we
                    // fetch as soon as the first GPS fix arrives.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Single fetch + annotate cycle. Errors are surfaced via lastError;
    /// they never throw out of this method, so the polling loop survives
    /// a network blip.
    func refresh(around location: CLLocation) async {
        let observerLat = location.coordinate.latitude
        let observerLon = location.coordinate.longitude
        let observerAlt = location.altitude

        // Convert km radius → degrees of latitude/longitude.
        // 1° latitude is ~111 km everywhere.
        // 1° longitude shrinks with latitude: 111 km × cos(lat).
        let dLat = radiusKm / 111.0
        let dLon = radiusKm / (111.0 * cos(observerLat * .pi / 180))

        do {
            let raw = try await client.aircraftInBbox(
                lamin: observerLat - dLat,
                lomin: observerLon - dLon,
                lamax: observerLat + dLat,
                lomax: observerLon + dLon
            )

            let annotated = raw
                .filter { !$0.onGround }
                .map { aircraft -> ObservedAircraft in
                    let ground = Geo.distance(
                        fromLat: observerLat, lon: observerLon,
                        toLat: aircraft.latitude, lon: aircraft.longitude
                    )
                    let bearing = Geo.bearing(
                        fromLat: observerLat, lon: observerLon,
                        toLat: aircraft.latitude, lon: aircraft.longitude
                    )
                    let elev = Geo.elevation(
                        observerAltMeters: observerAlt,
                        targetAltMeters: aircraft.altitudeMeters,
                        groundDistanceMeters: ground
                    )
                    let dh = aircraft.altitudeMeters - observerAlt
                    let slant = (ground * ground + dh * dh).squareRoot()

                    return ObservedAircraft(
                        aircraft: aircraft,
                        bearingDeg: bearing,
                        elevationDeg: elev,
                        groundDistanceMeters: ground,
                        slantDistanceMeters: slant
                    )
                }
                .sorted { $0.slantDistanceMeters < $1.slantDistanceMeters }

            self.observed = annotated
            self.lastError = nil
            self.lastFetched = Date()
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
