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

// MARK: - Human-readable formatter

nonisolated extension ReplayReport {
    /// Multi-line String summary suitable for `Text(...).monospaced()`
    /// in a debug viewer, or for piping into a terminal. Keeps the
    /// structure flat (no nested indents past two levels) so it stays
    /// readable on a phone screen.
    ///
    /// Fixed-width columns are used inside each per-aircraft row so
    /// values line up visually — important for spotting outliers
    /// quickly across many ticks.
    func describe() -> String {
        var lines: [String] = []

        // Header
        if let s = sessionStart {
            lines.append("Tailspot replay  ·  \(Self.formatHeaderDate(s.timestamp))")
            lines.append("\(s.deviceModel)  app \(s.appVersion)  schema \(s.schemaVersion)")
        } else {
            lines.append("Tailspot replay  ·  (no session-start header)")
        }

        let count = ticks.count
        if count == 0 {
            lines.append("0 ticks")
            return lines.joined(separator: "\n")
        }

        if let first = ticks.first, let last = ticks.last {
            let dur = last.timestamp.timeIntervalSince(first.timestamp)
            lines.append("\(count) tick\(count == 1 ? "" : "s") (~\(String(format: "%.1f", dur)) s)")
        }

        // Per-tick blocks. Tick t=0 is the first tick's timestamp;
        // subsequent ticks are offsets in seconds.
        let base = ticks.first?.timestamp ?? Date()
        for (i, tick) in ticks.enumerated() {
            lines.append("")  // blank separator
            lines.append(contentsOf: Self.describeTick(tick, index: i, base: base))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers (file-private would be nicer but extension doesn't allow it)

    private static func describeTick(_ tick: ReplayTickReport, index: Int, base: Date) -> [String] {
        var out: [String] = []
        let offset = tick.timestamp.timeIntervalSince(base)
        let obsStr: String
        if let lat = tick.observerLatitude, let lon = tick.observerLongitude {
            obsStr = String(format: "obs=(%.4f°, %.4f°)", lat, lon)
        } else {
            obsStr = "obs=(no fix)"
        }
        let hdgStr: String
        if let h = tick.headingDeg {
            hdgStr = String(format: "hdg=%5.1f°", h)
        } else {
            hdgStr = "hdg=  —"
        }
        // Zoom isn't in the report struct directly; ReplayTickReport
        // doesn't carry it. (The analyzer already used it to compute
        // FOV; surfacing here would require threading it through —
        // skip for v0 to keep the formatter pure.)
        out.append(String(format: "t=%+.1fs  \(obsStr)  \(hdgStr)  camEl=%+5.1f°",
                          offset, tick.cameraElevationDeg))

        // Aircraft summary: count + visible-count, then one row each.
        let total = tick.aircraft.count
        let vis = tick.visibleCount
        out.append("  \(total) aircraft, \(vis) visible")

        for ar in tick.aircraft {
            out.append(describeAircraft(ar, closestIcao: tick.closestToCenterIcao24))
        }

        // Lock state.
        out.append("  closest-to-center: \(tick.closestToCenterIcao24 ?? "—")")
        out.append("  lock: \(describeLock(tick.lockState))")
        return out
    }

    private static func describeAircraft(_ ar: ReplayTickReport.AircraftReport, closestIcao: String?) -> String {
        let marker = (ar.icao24 == closestIcao) ? "·" : " "
        let cs = (ar.callsign ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)
        let bearing = String(format: "brg=%5.1f°", ar.bearingDeg)
        let elev = String(format: "el=%+5.1f°", ar.elevationDeg)
        let slant = String(format: "slant=%5.1f km", ar.slantDistanceMeters / 1000)
        let status: String
        if !ar.isVisible {
            status = "(out of range)"
        } else if ar.screenPosition == nil {
            status = "(off-screen)"
        } else {
            status = ""
        }
        return "   \(marker) \(ar.icao24)  \(cs)  \(bearing)  \(elev)  \(slant)  \(status)"
    }

    private static func describeLock(_ state: LockOnEngine.State) -> String {
        switch state {
        case .idle:                                 return "idle"
        case .acquiring(let icao, _):               return "acquiring(\(icao))"
        case .locked(let icao, _):                  return "locked(\(icao))"
        case .sticky(let icao, _):                  return "sticky(\(icao))"
        }
    }

    private static func formatHeaderDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
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
