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
import os

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
    /// Build an `ObservedAircraft` from a raw `Aircraft` + observer
    /// pose at `now`. Forward-extrapolates the aircraft's position
    /// to `now` using its reported track/velocity, then computes
    /// the bearing/elevation/slant from the observer.
    ///
    /// Returns nil if the aircraft is reported on the ground — we
    /// don't want labels for taxiing planes. Centralized here so the
    /// replay analyzer can reuse the exact same geometry the live
    /// path uses.
    static func annotate(_ aircraft: Aircraft, observer: CLLocation, now: Date) -> ObservedAircraft? {
        guard !aircraft.onGround else { return nil }
        let pos = aircraft.extrapolatedPosition(at: now)
        let observerLat = observer.coordinate.latitude
        let observerLon = observer.coordinate.longitude
        let observerAlt = observer.altitude
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

    /// Whether this aircraft is plausibly visible to the naked eye
    /// right now. Two filters:
    ///
    ///   1. `elevationDeg > 0` — the plane is above the user's geometric
    ///      horizon (flat-Earth, since the curvature correction is small
    ///      for the distances that pass filter #2).
    ///   2. `slantDistanceMeters < maxVisibleDistanceMeters` — the plane
    ///      is close enough to actually see. 30 km is the v1 cap,
    ///      tuned from Berkeley field testing: most commercial traffic
    ///      past 30 km is a speck against the sky and was producing
    ///      clutter that distracted from the planes actually in view.
    ///
    /// Explicitly does NOT account for obstacles (buildings, hills),
    /// weather (clouds, haze), or atmospheric scattering. Those are
    /// real but introduce too much complexity for v1 POC.
    var isLikelyVisibleToObserver: Bool {
        elevationDeg > 0 && slantDistanceMeters < Self.maxVisibleDistanceMeters
    }

    /// Tunable. 30 km is the default — adjust if field testing shows
    /// labels too aggressively pruned (commercial traffic that's
    /// visibly there but past the cap).
    static let maxVisibleDistanceMeters: Double = 30_000

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

    /// Network poll interval. OpenSky anonymous minimum is 10s, daily
    /// quota is 400 credits (~400 queries) — at 12s polling we burn
    /// through that in 1.3 hr. 20s is more sustainable for casual
    /// testing on the anonymous tier; registered users (with credentials
    /// in env) get 10× the daily budget and could go faster if needed.
    var pollInterval: TimeInterval = 20

    /// How often we re-annotate the last-fetched raw aircraft to "now"
    /// — forward-extrapolating positions and recomputing bearings from
    /// the current observer location. Decoupled from `pollInterval` so
    /// boxes glide smoothly between network fetches instead of jumping
    /// every 20s when new data arrives.
    var reAnnotationInterval: TimeInterval = 1

    /// When the last fetch returned HTTP 429, we exponentially back off
    /// up to this cap before trying again. Resets to `pollInterval` on
    /// the next successful fetch.
    private let maxBackoffInterval: TimeInterval = 120
    private var currentInterval: TimeInterval = 20

    private let liveSource: ADSBSource
    private let mockSource: ADSBSource
    private var source: ADSBSource { useMock ? mockSource : liveSource }

    /// The last-fetched aircraft list, kept raw (no annotation). The
    /// re-annotation tick reads from here, extrapolates to "now," and
    /// publishes `observed`. We never publish this directly — SwiftUI
    /// renders from `observed` which is the annotated, sorted view.
    private var rawAircraft: [Aircraft] = []

    private var pollTask: Task<Void, Never>?
    private var reAnnotationTask: Task<Void, Never>?
    private var locationProvider: (@MainActor () -> CLLocation?)?
    /// Per-icao24 metadata memoization. Lookups go through here lazily
    /// when AircraftDetailView appears for a given aircraft.
    private let metadataCache = MetadataCache()

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

        // Network poll: fetches new state from OpenSky periodically.
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

        // Smoothness loop: every reAnnotationInterval, re-extrapolate
        // the raw aircraft positions to "now" using the current
        // observer location, recompute angular positions, publish.
        // This is what makes the AR boxes glide smoothly with each
        // plane's motion instead of jumping every 20s when new ADS-B
        // data arrives.
        let tick = reAnnotationInterval
        reAnnotationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let loc = self?.locationProvider?() {
                    self?.reAnnotate(observer: loc, now: Date())
                }
                try? await Task.sleep(for: .seconds(tick))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        reAnnotationTask?.cancel()
        reAnnotationTask = nil
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
    ///
    /// On success the raw aircraft list is stashed in `rawAircraft` and
    /// also immediately re-annotated so callers (and tests) see the new
    /// data without waiting for the next smoothness tick.
    func refresh(around location: CLLocation) async {
        let observerLat = location.coordinate.latitude
        let observerLon = location.coordinate.longitude

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
            self.rawAircraft = raw
            self.reAnnotate(observer: location, now: Date())

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

    /// Resolve metadata for a single icao24, consulting the in-memory
    /// cache first and falling back to the current source on miss.
    /// A successful response (including a 404 / nil) is cached;
    /// transport errors are NOT cached, so a later tap can retry.
    func metadata(for icao24: String) async -> AircraftMetadata? {
        switch await metadataCache.get(icao24: icao24) {
        case .hit(let value):
            return value
        case .notFetched:
            do {
                let fetched = try await source.aircraftMetadata(icao24: icao24)
                await metadataCache.set(icao24: icao24, value: fetched)
                return fetched
            } catch {
                // Transport / auth / 429 — surface via lastError but
                // do NOT cache. The next tap will retry.
                Log.adsb.error("metadata lookup failed for \(icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
                self.lastError = "Metadata lookup failed: \(error.localizedDescription)"
                return nil
            }
        }
    }

    /// Build `observed` from `rawAircraft` using the given observer
    /// position and "now" timestamp. Run frequently by the smoothness
    /// loop and once per `refresh` immediately after fetch.
    ///
    /// Cheap: no I/O, only geometry. Safe to call at 1 Hz with 50+
    /// aircraft in the bbox. Annotation logic itself lives on
    /// `ObservedAircraft.annotate(_:observer:now:)` so the replay
    /// analyzer can reuse the exact same geometry.
    private func reAnnotate(observer: CLLocation, now: Date) {
        self.observed = rawAircraft
            .compactMap { ObservedAircraft.annotate($0, observer: observer, now: now) }
            .sorted { $0.slantDistanceMeters < $1.slantDistanceMeters }
    }
}
