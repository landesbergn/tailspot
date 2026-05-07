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

extension ObservedAircraft {
    /// Project this aircraft into screen coordinates given the phone's
    /// current pose and the camera's FOV. Returns nil if off-screen.
    /// Default FOV values are estimates for the iPhone main wide camera
    /// in portrait orientation; refine when we query AVCaptureDevice for
    /// the real values.
    ///
    /// `cameraElevationDeg` is the angle above the horizon the camera
    /// is pointing (use MotionManager.cameraElevationDeg, NOT raw pitch).
    func screenPosition(
        phoneHeadingDeg: Double,
        cameraElevationDeg: Double,
        in screenSize: CGSize,
        hfovDeg: Double = 56,
        vfovDeg: Double = 72
    ) -> CGPoint? {
        Geo.screenPosition(
            targetBearingDeg: bearingDeg,
            targetElevationDeg: elevationDeg,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        )
    }
}

@MainActor
final class ADSBManager: ObservableObject {

    @Published var observed: [ObservedAircraft] = []
    @Published var lastError: String?
    @Published var lastFetched: Date?

    /// Toggle between the live OpenSky source and a synthetic mock for
    /// couch-testing. Flipping it triggers an immediate refresh.
    @Published var useMock: Bool = false {
        didSet { Task { await refreshNow() } }
    }

    /// Search radius around the user, in km. OpenSky's anonymous tier
    /// caps bbox area; 50 km here is conservatively inside that limit
    /// at any latitude we care about.
    var radiusKm: Double = 50

    /// Base polling interval. OpenSky anonymous minimum is 10s, daily
    /// quota is 400 credits (~400 queries) — at 12s polling we burn
    /// through that in 1.3 hr. 20s is more sustainable for casual
    /// testing on the anonymous tier; registered users (with credentials
    /// in env) get 10× the daily budget and could go faster if needed.
    var pollInterval: TimeInterval = 20

    /// When the last fetch returned HTTP 429, we exponentially back off
    /// up to this cap before trying again. Resets to `pollInterval` on
    /// the next successful fetch.
    private let maxBackoffInterval: TimeInterval = 120
    private var currentInterval: TimeInterval = 20

    private let liveSource: ADSBSource
    private let mockSource: ADSBSource
    private var source: ADSBSource { useMock ? mockSource : liveSource }

    private var pollTask: Task<Void, Never>?
    private var locationProvider: (@MainActor () -> CLLocation?)?

    /// Default init keeps the production behavior unchanged. The
    /// parameters exist so tests can inject a fixture source — without
    /// them, every method on this class would have to be tested against
    /// the real OpenSky network, which is slow and flaky.
    init(
        liveSource: ADSBSource = OpenSkyClient(),
        mockSource: ADSBSource = MockADSBSource()
    ) {
        self.liveSource = liveSource
        self.mockSource = mockSource
    }

    /// Start polling. The provider closure is called on each tick to
    /// fetch the latest user location — passing it as a closure (rather
    /// than holding a strong reference to LocationManager) keeps the two
    /// classes loosely coupled.
    func start(locationProvider: @escaping @MainActor () -> CLLocation?) {
        guard pollTask == nil else { return }
        self.locationProvider = locationProvider
        self.currentInterval = pollInterval

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let loc = self?.locationProvider?() {
                    await self?.refresh(around: loc)
                    let waitSeconds = self?.currentInterval ?? 20
                    try? await Task.sleep(for: .seconds(waitSeconds))
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

    /// Force an immediate fetch using the current location, if any.
    /// Used by the useMock toggle so flipping modes is instantaneous
    /// rather than waiting for the next poll tick.
    func refreshNow() async {
        guard let loc = locationProvider?() else { return }
        await refresh(around: loc)
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
            let raw = try await source.aircraftInBbox(
                lamin: observerLat - dLat,
                lomin: observerLon - dLon,
                lamax: observerLat + dLat,
                lomax: observerLon + dLon
            )

            let now = Date()
            let annotated = raw
                .filter { !$0.onGround }
                .map { aircraft -> ObservedAircraft in
                    // Extrapolate the aircraft's position forward to
                    // "now" along its track — ADS-B reports can be
                    // 5–15 s old, and that staleness shows up as labels
                    // lagging behind real planes on screen.
                    let pos = aircraft.extrapolatedPosition(at: now)
                    let ground = Geo.distance(
                        fromLat: observerLat, lon: observerLon,
                        toLat: pos.lat, lon: pos.lon
                    )
                    let bearing = Geo.bearing(
                        fromLat: observerLat, lon: observerLon,
                        toLat: pos.lat, lon: pos.lon
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
            // Successful fetch — snap polling back to the base interval.
            self.currentInterval = pollInterval
        } catch OpenSkyClient.ClientError.rateLimited {
            // 429: over the daily quota or per-IP limit. Back off
            // exponentially so we stop hammering OpenSky.
            self.lastError = "Rate limit hit — backing off (next try in \(Int(min(currentInterval * 2, maxBackoffInterval)))s)"
            self.currentInterval = min(currentInterval * 2, maxBackoffInterval)
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
