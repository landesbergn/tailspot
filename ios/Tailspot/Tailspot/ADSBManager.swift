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
    /// Returns nil if:
    ///   - The aircraft is reported on the ground (taxiing → no label).
    ///   - The last position update is older than `maxPositionAge` —
    ///     stale rows are usually planes that just landed, lost ADS-B
    ///     coverage, or otherwise dropped off radar. They show up as
    ///     "ghost labels" hovering where the plane used to be.
    ///
    /// Centralized here so the replay analyzer can reuse the exact
    /// same geometry the live path uses.
    static func annotate(
        _ aircraft: Aircraft,
        observer: CLLocation,
        now: Date,
        maxPositionAge: TimeInterval = ObservedAircraft.maxPositionAge
    ) -> ObservedAircraft? {
        guard !aircraft.onGround else { return nil }
        if let ts = aircraft.positionTimestamp,
           now.timeIntervalSince(ts) > maxPositionAge {
            return nil
        }
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

    /// Drop aircraft whose last ADS-B position update is older than
    /// this (seconds). OpenSky position timestamps update every few
    /// seconds for in-flight aircraft; a stale row usually means the
    /// plane landed, lost coverage, or dropped off radar — a "ghost".
    ///
    /// Raised 60 → 150 on 2026-06-01. The old 60 s floor deleted labels
    /// for genuinely-visible planes whose free-tier OpenSky position was
    /// merely slow to refresh — and, worse, during 429 backoff (poll gap
    /// up to 120 s) it aged out EVERY plane at once, reading in the field
    /// as "no planes at all" until an app restart forced a fresh poll.
    /// `reAnnotate` additionally grows this allowance by however overdue
    /// polling is (see its `effectiveMaxAge`), so a backoff gap can't
    /// blank the whole sky.
    static let maxPositionAge: TimeInterval = 150

    /// Whether this aircraft is plausibly visible to the naked eye
    /// right now. Two filters:
    ///
    ///   1. `elevationDeg > minVisibleElevationDeg` — the plane is
    ///      above the user's visual horizon, with a small buffer for
    ///      terrestrial obstructions (hills, buildings, trees).
    ///   2. `slantDistanceMeters < maxVisibleDistance(forElevationDeg:)`
    ///      — an elevation-DEPENDENT cap: ~12 km near the horizon
    ///      (haze + clutter band) opening to 35 km by 10° (clean-sky
    ///      band). See `maxVisibleDistance` for the field data behind
    ///      the curve.
    ///
    /// Explicitly does NOT account for weather (clouds, haze vary by
    /// day) or atmospheric scattering. The curve encodes a typical Bay
    /// Area day; per-condition adjustment is out of scope for v0.
    var isLikelyVisibleToObserver: Bool {
        elevationDeg > Self.minVisibleElevationDeg
            && slantDistanceMeters < Self.maxVisibleDistance(forElevationDeg: elevationDeg)
    }

    /// Elevation-dependent distance cap. A flat cap can't separate real
    /// sightings from ghosts: near the horizon (1-4°) you look through
    /// maximum atmosphere, haze, and terrain/building clutter, so only
    /// close planes actually read to the eye; higher up the background
    /// clears and the allowance grows. Linear ramp from
    /// `nearVisibleDistanceMeters` at the elevation floor up to
    /// `maxVisibleDistanceMeters` at `fullVisibilityElevationDeg`.
    ///
    /// Fitted to tap-pin ground truth from three field sessions
    /// (2026-06-04 night, 2026-06-06 day): every confirmed-visible plane
    /// was < 10 km (4.7 km @ 36°, 5.8 km @ 16°); all eleven confirmed
    /// ghosts were ≥ 20 km — including high-elevation ones (33 km @ 10.8°
    /// in daylight, 20 km @ 11° at night). The current constants separate
    /// that data 13/13. If a contrail-heavy day ever shows real planes
    /// being pruned, raise the plateau — but distant-airframe visibility
    /// has so far been intuition, not observation.
    static func maxVisibleDistance(forElevationDeg elevationDeg: Double) -> Double {
        if elevationDeg >= fullVisibilityElevationDeg { return maxVisibleDistanceMeters }
        let f = (elevationDeg - minVisibleElevationDeg)
            / (fullVisibilityElevationDeg - minVisibleElevationDeg)
        return nearVisibleDistanceMeters
            + max(0, f) * (maxVisibleDistanceMeters - nearVisibleDistanceMeters)
    }

    /// Distance allowed right at the elevation floor (1°). Low-and-far is
    /// the classic ghost signature; low-and-near (approach traffic over
    /// the bay) is real. Tunable.
    static let nearVisibleDistanceMeters: Double = 12_000

    /// Elevation at which the full `maxVisibleDistanceMeters` applies —
    /// high enough that the plane sits against open sky. Raised 10 → 20
    /// on 2026-06-06: a daytime ghost at 33 km / 10.8° slipped exactly
    /// over the 10° plateau edge. Tunable.
    static let fullVisibilityElevationDeg: Double = 20

    /// Minimum elevation a plane must clear before we surface it in
    /// the AR overlay. A small buffer trims the literal horizon-edge
    /// ghosts (planes hidden behind hills / skyline / trees).
    ///
    /// Lowered 3 → 1 on 2026-06-01: replaying a real Berkeley session
    /// showed 3° was deleting visible approach/departure traffic at
    /// 1-3° elevation (low over the bay is still in plain sight). 1°
    /// keeps sub-horizon ghosts out without pruning visible low traffic.
    static let minVisibleElevationDeg: Double = 1

    /// The FAR end of the distance cap — applies at and above
    /// `fullVisibilityElevationDeg`, where the plane sits against open
    /// sky.
    ///
    /// History: 30 km originally; tightened to a flat 20 km on 2026-05-26;
    /// raised to a flat 35 km on 2026-06-01 (over-admitted ghosts);
    /// elevation-dependent curve since 2026-06-04; plateau lowered
    /// 35 → 25 km on 2026-06-06 after tap-pin ground truth showed zero
    /// confirmed sightings beyond 20 km in either day or night sessions.
    /// This constant is the curve's upper plateau — see
    /// `maxVisibleDistance(forElevationDeg:)`.
    static let maxVisibleDistanceMeters: Double = 25_000

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

/// Per-cycle counts of where aircraft drop out of the AR overlay:
/// `fetched → onGround → stale → belowElevation → tooFar → shown`.
/// Diagnostic instrumentation added 2026-06-01 to localize which filter
/// clause is pruning genuinely-visible traffic. Surfaced on-screen and via
/// os_log so a single field session pinpoints the culprit.
///
/// `belowElevation` and `tooFar` are counted independently — a plane
/// failing both is tallied in each, so the columns localize blame, they
/// don't partition. `shown` is the authoritative "what the user sees".
struct VisibilityDiagnostic: Equatable, Sendable {
    var fetched = 0
    var onGround = 0
    var stale = 0
    var belowElevation = 0
    var tooFar = 0
    var shown = 0
}

@MainActor
final class ADSBManager: ObservableObject {

    @Published var observed: [ObservedAircraft] = []
    /// Latest visibility-funnel counts (see `VisibilityDiagnostic`). Updated
    /// every `reAnnotate` tick; drives the temporary on-screen tracked/shown
    /// readout while we validate the 2026-06-01 visibility re-tune.
    @Published var diagnostic = VisibilityDiagnostic()
    /// Last funnel we emitted to os_log — so the 1 Hz reAnnotate loop only
    /// logs when the counts actually change, not 60× a minute.
    private var lastLoggedDiagnostic: VisibilityDiagnostic?
    @Published var lastError: String?
    /// True when the last error is auto-recovering (e.g. HTTP 429
    /// backoff) and doesn't require user action. UI surfaces use
    /// this to render the message in a softer, non-alarming style.
    @Published var lastErrorIsTransient: Bool = false
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

    /// Whether the live source has OAuth credentials. Surfaced for
    /// the debug overlay so we can see at a glance whether the app
    /// is using the registered tier (4000/day) or running anonymous
    /// (400/day — exhausts in ~1.3h at the default poll rate).
    var liveSourceIsAuthed: Bool {
        (liveSource as? OpenSkyClient)?.hasCredentials ?? false
    }

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
            // verbose: log per-plane drop reasons once per network poll
            // (not on the 1 Hz smoothness tick) so the field log isn't spammed.
            self.reAnnotate(observer: location, now: Date(), verbose: true)

            self.lastError = nil
            self.lastErrorIsTransient = false
            self.lastFetched = Date()
            // Successful fetch — snap polling back to the base interval.
            self.currentInterval = pollInterval
        } catch OpenSkyClient.ClientError.rateLimited {
            // 429: over the daily quota or per-IP limit. Back off
            // exponentially so we stop hammering OpenSky. The error
            // is auto-recovering — UI marks it transient so the
            // empty-sky pill doesn't render it as a screaming alert.
            let nextSecs = Int(min(currentInterval * 2, maxBackoffInterval))
            self.lastError = "API limit · retry in \(nextSecs)s"
            self.lastErrorIsTransient = true
            self.currentInterval = min(currentInterval * 2, maxBackoffInterval)
        } catch {
            self.lastError = error.localizedDescription
            self.lastErrorIsTransient = false
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
    private func reAnnotate(observer: CLLocation, now: Date, verbose: Bool = false) {
        // During 429 backoff we poll slowly, so the freshest data we hold is
        // legitimately older than at the base cadence. Grow the staleness
        // allowance by however overdue polling is, so a backoff gap doesn't
        // age out every plane at once (the "no planes + restart fixes it"
        // failure). At the base 20 s cadence the extra term is 0.
        let effectiveMaxAge = ObservedAircraft.maxPositionAge
            + max(0, currentInterval - pollInterval)

        let annotated = rawAircraft
            .compactMap {
                ObservedAircraft.annotate($0, observer: observer, now: now,
                                          maxPositionAge: effectiveMaxAge)
            }
            .sorted { $0.slantDistanceMeters < $1.slantDistanceMeters }
        self.observed = annotated

        updateDiagnostic(now: now, effectiveMaxAge: effectiveMaxAge,
                         annotated: annotated, verbose: verbose)
    }

    /// Compute the visibility funnel for instrumentation. Does NOT change
    /// what `observed` holds (consumers still apply `isLikelyVisibleToObserver`
    /// themselves) — this is counts + optional per-plane logs only.
    private func updateDiagnostic(now: Date, effectiveMaxAge: TimeInterval,
                                  annotated: [ObservedAircraft], verbose: Bool) {
        var diag = VisibilityDiagnostic()
        diag.fetched = rawAircraft.count

        // onGround + stale are dropped inside annotate(); re-derive their
        // counts here from the raw set so the funnel adds up.
        for ac in rawAircraft {
            if ac.onGround { diag.onGround += 1; continue }
            if let ts = ac.positionTimestamp, now.timeIntervalSince(ts) > effectiveMaxAge {
                diag.stale += 1
                if verbose {
                    Log.adsb.info("drop STALE \(ac.callsign ?? ac.icao24, privacy: .public) age=\(Int(now.timeIntervalSince(ts)))s (limit \(Int(effectiveMaxAge))s)")
                }
            }
        }

        for obs in annotated {
            let belowElev = obs.elevationDeg <= ObservedAircraft.minVisibleElevationDeg
            let tooFar = obs.slantDistanceMeters
                >= ObservedAircraft.maxVisibleDistance(forElevationDeg: obs.elevationDeg)
            if belowElev { diag.belowElevation += 1 }
            if tooFar { diag.tooFar += 1 }
            if verbose && (belowElev || tooFar) {
                let why = [belowElev ? "low-elev" : nil, tooFar ? "too-far" : nil]
                    .compactMap { $0 }.joined(separator: "+")
                Log.adsb.info("drop \(why, privacy: .public) \(obs.aircraft.callsign ?? obs.aircraft.icao24, privacy: .public) elev=\(String(format: "%.1f", obs.elevationDeg))° dist=\(String(format: "%.1f", obs.slantDistanceMeters / 1000))km")
            }
        }

        diag.shown = annotated.filter(\.isLikelyVisibleToObserver).count
        self.diagnostic = diag

        if diag != lastLoggedDiagnostic {
            Log.adsb.info("visibility funnel: fetched=\(diag.fetched) onGround=\(diag.onGround) stale=\(diag.stale) lowElev=\(diag.belowElevation) tooFar=\(diag.tooFar) → shown=\(diag.shown)")
            lastLoggedDiagnostic = diag
        }
    }
}
