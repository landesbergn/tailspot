//
//  ReplayAnalyzer.swift
//  Tailspot
//
//  Offline-replay side of the harness. Reads a `.jsonl` produced by
//  `ReplayRecorder` and runs each tick through the same annotation /
//  visibility / lock-on logic the live app uses — emitting per-tick
//  diagnostics so a recorded session can be inspected and (eventually)
//  regression-tested against engine changes.
//
//  Design notes:
//  - Pure: no UI, no I/O beyond optionally reading a file. Tests
//    construct ReplayEvents in-memory and feed them straight in.
//  - Uses the same `ObservedAircraft.annotate` and `closestTargetIcao24`
//    helpers as ContentView/ADSBManager — when those change, the
//    analyzer automatically picks up the change. That's the point.
//  - `LockOnEngine` is stateful, so the analyzer creates a fresh one
//    per `analyze(_:)` call. Multiple analyze calls don't share state.
//

import Foundation
import CoreGraphics
import CoreLocation

// MARK: - Report types

/// Per-tick output of an analysis run. One of these per `tick` event
/// in the source recording.
struct ReplayTickReport: Equatable, Sendable {
    let timestamp: Date
    /// Reconstructed observer pose, or nil if the tick's sensor row
    /// had no GPS fix (tick was recorded before the first fix).
    let observerLatitude: Double?
    let observerLongitude: Double?
    let headingDeg: Double?
    let cameraElevationDeg: Double
    /// One entry per aircraft snapshot in the tick. Sorted by slant
    /// distance ascending (matches what ADSBManager publishes).
    let aircraft: [AircraftReport]
    /// Count of aircraft passing the visibility predicate
    /// (above-horizon + within 30 km).
    let visibleCount: Int
    /// Icao24 of the visible aircraft whose projection is closest to
    /// screen center within the lock-zone radius, or nil.
    let closestToCenterIcao24: String?
    /// Lock-on engine state after processing this tick. Lets a caller
    /// see acquisition→locked→sticky progression across the session.
    let lockState: LockOnEngine.State

    struct AircraftReport: Equatable, Sendable {
        let icao24: String
        let callsign: String?
        let bearingDeg: Double
        let elevationDeg: Double
        let slantDistanceMeters: Double
        let isVisible: Bool
        /// Projected position on the configured screen, or nil if
        /// outside the camera FOV.
        let screenPosition: CGPoint?
    }
}

/// Whole-session output. `sessionStart` is nil for files missing the
/// header line — we don't refuse to analyze, since recordings cut
/// short before the first write can still be useful.
struct ReplayReport: Equatable, Sendable {
    let sessionStart: ReplayEvent.SessionStart?
    let ticks: [ReplayTickReport]
}

// MARK: - Analyzer

/// Configuration for one analysis run. Defaults match an iPhone 16 in
/// portrait orientation; override for other hardware. The lock-zone
/// radius mirrors ContentView's default (80 px).
@MainActor
struct ReplayAnalyzer {
    var screenSize: CGSize = CGSize(width: 393, height: 852)
    var hfovDeg: Double = 56
    var vfovDeg: Double = 72
    var lockZoneRadius: CGFloat = 80

    /// Analyze a sequence of events. `session-start` events update the
    /// report header; `tick` events become one TickReport each.
    func analyze(_ events: [ReplayEvent]) -> ReplayReport {
        var sessionStart: ReplayEvent.SessionStart?
        let engine = LockOnEngine()
        var tickReports: [ReplayTickReport] = []

        for event in events {
            switch event {
            case .sessionStart(let s):
                sessionStart = s
            case .tick(let t):
                tickReports.append(report(for: t, engine: engine))
            }
        }

        return ReplayReport(sessionStart: sessionStart, ticks: tickReports)
    }

    /// Convenience: read + decode + analyze a file in one shot.
    func analyze(fileURL: URL) throws -> ReplayReport {
        let data = try Data(contentsOf: fileURL)
        return analyze(try ReplayJSONL.decode(data))
    }

    // MARK: - Internals

    private func report(for tick: ReplayEvent.Tick, engine: LockOnEngine) -> ReplayTickReport {
        let observer = reconstructObserver(from: tick)

        // Camera zoom changes the effective FOV: at 2× the same screen
        // shows half the world horizontally. Divide the configured FOV
        // by the tick's zoom (default 1.0 for back-compat with files
        // recorded before the zoom field shipped).
        let zoom = tick.sensor.zoomFactor ?? 1.0
        let effectiveHfov = hfovDeg / zoom
        let effectiveVfov = vfovDeg / zoom

        // Compute per-aircraft annotation. Ticks without a GPS fix
        // skip annotation entirely — we can't compute bearings without
        // an observer.
        var summaries: [ReplayTickReport.AircraftReport] = []
        var visibleObs: [ObservedAircraft] = []

        if let observer {
            // Match ADSBManager's sort: nearest-first. Build a parallel
            // (snapshot, observed) list so summaries carry the same
            // ordering.
            let pairs: [(ReplayEvent.AircraftSnapshot, ObservedAircraft)] = tick.aircraft.compactMap { snap in
                guard let obs = ObservedAircraft.annotate(
                    Aircraft(snap), observer: observer, now: tick.timestamp
                ) else { return nil }
                return (snap, obs)
            }.sorted { $0.1.slantDistanceMeters < $1.1.slantDistanceMeters }

            for (snap, obs) in pairs {
                let isVisible = obs.isLikelyVisibleToObserver
                if isVisible { visibleObs.append(obs) }
                let screenPos = obs.screenPosition(
                    phoneHeadingDeg: tick.sensor.headingDeg ?? 0,
                    cameraElevationDeg: tick.sensor.cameraElevationDeg,
                    in: screenSize,
                    hfovDeg: effectiveHfov,
                    vfovDeg: effectiveVfov
                )
                summaries.append(.init(
                    icao24: snap.icao24,
                    callsign: snap.callsign,
                    bearingDeg: obs.bearingDeg,
                    elevationDeg: obs.elevationDeg,
                    slantDistanceMeters: obs.slantDistanceMeters,
                    isVisible: isVisible,
                    screenPosition: screenPos
                ))
            }
        }

        let closest = closestTargetIcao24(
            in: visibleObs,
            phoneHeadingDeg: tick.sensor.headingDeg ?? 0,
            cameraElevationDeg: tick.sensor.cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: effectiveHfov,
            vfovDeg: effectiveVfov,
            lockZoneRadius: lockZoneRadius
        )
        engine.update(closestTargetIcao24: closest, now: tick.timestamp)

        return ReplayTickReport(
            timestamp: tick.timestamp,
            observerLatitude: tick.sensor.latitude,
            observerLongitude: tick.sensor.longitude,
            headingDeg: tick.sensor.headingDeg,
            cameraElevationDeg: tick.sensor.cameraElevationDeg,
            aircraft: summaries,
            visibleCount: visibleObs.count,
            closestToCenterIcao24: closest,
            lockState: engine.state
        )
    }

    private func reconstructObserver(from tick: ReplayEvent.Tick) -> CLLocation? {
        guard let lat = tick.sensor.latitude,
              let lon = tick.sensor.longitude else { return nil }
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: tick.sensor.altitudeMeters ?? 0,
            horizontalAccuracy: tick.sensor.horizontalAccuracyMeters ?? -1,
            verticalAccuracy: -1,
            timestamp: tick.timestamp
        )
    }
}

// MARK: - Aircraft from snapshot

/// `nonisolated` so the convenience init is reachable from any actor
/// context, mirroring the rest of Aircraft's extensions (per the
/// "Extensions get their own isolation" rule in CLAUDE.md).
nonisolated extension Aircraft {
    /// Reconstruct an `Aircraft` from a recorded `AircraftSnapshot`.
    /// Used by the analyzer to feed snapshots through the same
    /// geometry helpers the live path uses.
    init(_ snapshot: ReplayEvent.AircraftSnapshot) {
        self.init(
            icao24: snapshot.icao24,
            callsign: snapshot.callsign,
            originCountry: snapshot.originCountry,
            longitude: snapshot.longitude,
            latitude: snapshot.latitude,
            altitudeMeters: snapshot.altitudeMeters,
            velocityMps: snapshot.velocityMps,
            trackDeg: snapshot.trackDeg,
            onGround: snapshot.onGround,
            positionTimestamp: snapshot.positionTimestamp
        )
    }
}
