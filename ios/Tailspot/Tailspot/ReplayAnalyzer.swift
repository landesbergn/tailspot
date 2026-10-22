//
//  ReplayAnalyzer.swift
//  Tailspot
//
//  Offline-replay side of the harness. Reads a `.jsonl` produced by
//  `ReplayRecorder` and runs each tick through the same annotation /
//  visibility / membership logic the live app uses — emitting per-tick
//  diagnostics so a recorded session can be inspected and (eventually)
//  regression-tested against engine changes.
//
//  Design notes:
//  - Pure: no UI, no I/O beyond optionally reading a file. Tests
//    construct ReplayEvents in-memory and feed them straight in.
//  - Uses the same `ObservedAircraft.annotate` and `chooseCatchMembers`
//    helpers as ContentView/ADSBManager — when those change, the
//    analyzer automatically picks up the change. That's the point.
//  - Pin events survive the frame-is-the-catch redesign as ASSERTIONS:
//    a `tapPin` in a recording has always meant "the observer saw this
//    plane here", which is exactly the assertion the live tap makes
//    now. The analyzer's membership simulation treats the pinned plane
//    as asserted until an `unpin` (old recordings) — the live 15 s
//    off-frame grace is not simulated.
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
    /// The simulated press membership at this tick — what the capture
    /// button would catch (frame-is-the-catch: bright on-frame planes +
    /// the pinned/asserted plane, size-ranked, capped at
    /// `maxCatchTargets`). Empty = button disabled.
    let chosenIcaos: [String]
    /// The membership WITHOUT the user's assertion — what the app would
    /// have chosen on its own. The failure-mode bench compares this
    /// against the pin (ground truth): a full-tier on-frame plane the
    /// user saw that ambient membership excludes is the crowded-out /
    /// wrong-plane class (mode 5).
    let ambientChosenIcaos: [String]

    struct AircraftReport: Equatable, Sendable {
        let icao24: String
        let callsign: String?
        let bearingDeg: Double
        let elevationDeg: Double
        let slantDistanceMeters: Double
        let isVisible: Bool
        /// `.full` visibility tier — the bright band press membership
        /// draws from (faint planes need an assertion).
        let isFullTier: Bool
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
            out.append(describeAircraft(ar, chosenIcaos: tick.chosenIcaos))
        }

        // Press membership.
        out.append("  chosen: \(tick.chosenIcaos.isEmpty ? "—" : tick.chosenIcaos.joined(separator: ", "))")
        return out
    }

    private static func describeAircraft(_ ar: ReplayTickReport.AircraftReport, chosenIcaos: [String]) -> String {
        let marker = chosenIcaos.contains(ar.icao24) ? "·" : " "
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

    private static func formatHeaderDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

// MARK: - Analyzer

/// Configuration for one analysis run. Defaults match an iPhone 16 in
/// portrait orientation; override for other hardware.
@MainActor
struct ReplayAnalyzer {
    var screenSize: CGSize = CGSize(width: 393, height: 852)
    var hfovDeg: Double = 56
    var vfovDeg: Double = 72

    /// Analyze a sequence of events. `session-start` events update the
    /// report header; `tick` events become one TickReport each;
    /// `tapPin` / `unpin` events update the running assertion state the
    /// membership simulation consumes — matching what ContentView's
    /// tap-assert path does live.
    ///
    /// Events are processed in **timestamp order**, not array order.
    /// Files written by `ReplayRecorder` happen to be sorted (writes
    /// are sequential on a monotonic clock), but a `.tapPin` fired
    /// from a tap gesture and a `.tick` fired from a 1 Hz timer can
    /// race on the JSONL line ordering at the millisecond level. The
    /// explicit sort below makes the analysis stable regardless of
    /// any future input source — concatenated files, merged streams,
    /// or anything else.
    func analyze(_ events: [ReplayEvent]) -> ReplayReport {
        let ordered = events.sorted { $0.timestamp < $1.timestamp }

        var sessionStart: ReplayEvent.SessionStart?
        var pinnedIcao: String?
        var tickReports: [ReplayTickReport] = []
        // Visibility-hysteresis state, carried across ticks so a plane at
        // the distance cap stays shown rather than flickering (mirrors the
        // live `ADSBManager.shownIcaos`).
        var shownIcaos: Set<String> = []

        for event in ordered {
            switch event {
            case .sessionStart(let s):
                sessionStart = s
            case .tapPin(let p):
                pinnedIcao = p.icao24
            case .emptyTap:
                // Diagnostic ground truth only — no membership effect.
                break
            case .unpin:
                pinnedIcao = nil
            case .tick(let t):
                tickReports.append(report(for: t, pinnedIcao: pinnedIcao, shownIcaos: &shownIcaos))
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

    private func report(for tick: ReplayEvent.Tick, pinnedIcao: String? = nil, shownIcaos: inout Set<String>) -> ReplayTickReport {
        let observer = reconstructObserver(from: tick)

        // Camera zoom changes the effective FOV: at 2× the same screen
        // shows half the world horizontally. Divide the configured FOV
        // by the tick's zoom (default 1.0 for back-compat with files
        // recorded before the zoom field shipped).
        let zoom = tick.sensor.zoomFactor ?? 1.0
        let effectiveHfov = hfovDeg / zoom
        let effectiveVfov = vfovDeg / zoom

        // Camera roll for the pinhole projection. Prefer the gravity vector
        // (exact, robust at the portrait hold); recordings made before the
        // 3D-pinhole work have no gravity, so fall back to roll = 0 rather
        // than the unreliable Euler `rollRad`.
        let rollDeg: Double = {
            if let gx = tick.sensor.gravityX,
               let gy = tick.sensor.gravityY,
               let gz = tick.sensor.gravityZ {
                return Geo.rollDeg(gravityX: gx, gravityY: gy, gravityZ: gz)
            }
            return 0
        }()

        // Compute per-aircraft annotation. Ticks without a GPS fix
        // skip annotation entirely — we can't compute bearings without
        // an observer.
        var summaries: [ReplayTickReport.AircraftReport] = []
        var visibleObs: [ObservedAircraft] = []
        var memberCandidates: [MembershipCandidate] = []

        if let observer {
            // Match ADSBManager's sort: nearest-first. Build a parallel
            // (snapshot, observed) list so summaries carry the same
            // ordering.
            let rawPairs: [(ReplayEvent.AircraftSnapshot, ObservedAircraft)] = tick.aircraft.compactMap { snap in
                guard let obs = ObservedAircraft.annotate(
                    Aircraft(snap), observer: observer, now: tick.timestamp
                ) else { return nil }
                return (snap, obs)
            }.sorted { $0.1.slantDistanceMeters < $1.1.slantDistanceMeters }

            // Apply visibility hysteresis (same helper as the live path) so a
            // plane hovering at the distance cap doesn't flicker across ticks.
            var obsList = rawPairs.map { $0.1 }
            shownIcaos = applyVisibilityHysteresis(&obsList, previouslyShown: shownIcaos)
            let pairs = Array(zip(rawPairs.map { $0.0 }, obsList))

            for (snap, obs) in pairs {
                let isVisible = obs.isLikelyVisibleToObserver
                if isVisible { visibleObs.append(obs) }
                let screenPos = obs.screenPosition(
                    phoneHeadingDeg: tick.sensor.headingDeg ?? 0,
                    cameraElevationDeg: tick.sensor.cameraElevationDeg,
                    rollDeg: rollDeg,
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
                    isFullTier: obs.visibilityTier == .full,
                    screenPosition: screenPos
                ))
                // Membership simulation input — mirrors ContentView's
                // candidate build: on-frame planes only; the pinned plane
                // counts as asserted (hidden tier included — that is what
                // a tap-rescue assertion does live); no camera in a
                // replay, so the occlusion demote never fires.
                let isAsserted = snap.icao24 == pinnedIcao && !obs.grounded
                if screenPos != nil, isVisible || isAsserted {
                    memberCandidates.append(MembershipCandidate(
                        icao24: snap.icao24,
                        arcmin: obs.apparentSizeArcminutes,
                        isFullTier: obs.visibilityTier == .full,
                        isAsserted: isAsserted,
                        isOccluded: false
                    ))
                }
            }
        }

        let membership = chooseCatchMembers(memberCandidates)
        // The counterfactual the bench scores against: membership with the
        // user's assertion stripped — what the app would choose unaided.
        let ambient = chooseCatchMembers(memberCandidates.compactMap { c in
            guard c.isAsserted else { return c }
            guard c.isFullTier else { return nil }  // faint/hidden only entered via the assertion
            return MembershipCandidate(
                icao24: c.icao24, arcmin: c.arcmin, isFullTier: c.isFullTier,
                isAsserted: false, isOccluded: c.isOccluded
            )
        })

        return ReplayTickReport(
            timestamp: tick.timestamp,
            observerLatitude: tick.sensor.latitude,
            observerLongitude: tick.sensor.longitude,
            headingDeg: tick.sensor.headingDeg,
            cameraElevationDeg: tick.sensor.cameraElevationDeg,
            aircraft: summaries,
            visibleCount: visibleObs.count,
            chosenIcaos: membership.chosen,
            ambientChosenIcaos: ambient.chosen
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
