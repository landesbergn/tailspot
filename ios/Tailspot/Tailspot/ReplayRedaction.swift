//
//  ReplayRedaction.swift
//  Tailspot
//
//  Promotes a local full-fidelity recording into a CI-safe fixture: the
//  geometry the analyzer reads is preserved EXACTLY, but the real location,
//  identities, and times are gone. Pure + deterministic (plan KTD4, U6).
//
//  Safety property (the load-bearing invariant, characterized in tests):
//  every `isVisible` / `screenPosition` the analyzer computes is identical
//  pre- and post-redaction, so a redacted fixture asserts the same engine
//  behavior as the original.
//
//  Preserved (so geometry is invariant):
//  - Latitude is left EXACT. The local east-west distance scale is
//    cos(latitude); changing latitude would re-scale the scene and could
//    flip a borderline visibility result. Retained latitude alone is a
//    global circle — not locating once identity and time are broken.
//  - All relative timing (intervals between ticks and to positionTimestamp),
//    so extrapolation and event ordering are unchanged.
//  - Callsign SHAPE: an N-number stays `N`+digit, so the small-GA
//    visibility half-cap (`Aircraft.isLikelySmallAirframe`) still fires.
//
//  Broken (so a longitude offset can't be reversed via public flight data):
//  - Longitude: shifted so the first observer fix sits at lon 0.
//  - icao24: stable synthetic ids.
//  - callsign: synthetic value (shape kept, real tail gone).
//  - timestamps: rebased onto a fixed anchor, intervals preserved.
//

import Foundation

nonisolated enum ReplayRedaction {

    /// A fixed, plausible-but-fake session anchor (2020-01-01 UTC). Real
    /// session times are rebased onto it; every interval is preserved.
    static let timeAnchor = Date(timeIntervalSince1970: 1_577_836_800)

    /// Redact a recording into a CI-safe form. See the type comment for the
    /// preserved/broken contract.
    static func redact(_ events: [ReplayEvent]) -> [ReplayEvent] {
        let lonShift = -(firstObserverLongitude(events) ?? 0)
        let firstTime = events.map(\.timestamp).min() ?? timeAnchor
        let icaoIndex = icaoIndexMap(events)
        return events.map { event($0, lonShift: lonShift, firstTime: firstTime, icaoIndex: icaoIndex) }
    }

    /// Synthetic callsign that preserves the small-airframe shape the
    /// visibility heuristic reads: an `N`+digit registration stays `N`+digit;
    /// anything else becomes a clearly-non-`N` synthetic. nil/empty passes
    /// through (no shape to preserve).
    static func syntheticCallsign(_ original: String?, index: Int) -> String? {
        guard let original, !original.isEmpty else { return original }
        let isNNumber = original.first == "N"
            && (original.dropFirst().first.map(\.isNumber) ?? false)
        return isNNumber ? "N" + String(format: "%05d", index)
                         : "SYN" + String(format: "%03d", index)
    }

    // MARK: - Internals

    private static func event(_ e: ReplayEvent, lonShift: Double, firstTime: Date, icaoIndex: [String: Int]) -> ReplayEvent {
        func shiftTime(_ d: Date) -> Date { timeAnchor.addingTimeInterval(d.timeIntervalSince(firstTime)) }
        func synIcao(_ icao: String) -> String { "RDCT" + String(format: "%03d", icaoIndex[icao] ?? 0) }

        switch e {
        case .sessionStart(let s):
            return .sessionStart(.init(
                timestamp: shiftTime(s.timestamp),
                appVersion: s.appVersion,
                deviceModel: s.deviceModel,
                schemaVersion: s.schemaVersion))

        case .tick(let tick):
            let s = tick.sensor
            let redSensor = ReplayEvent.SensorSnapshot(
                latitude: s.latitude,                          // exact — preserves cos(lat)
                longitude: s.longitude.map { $0 + lonShift },
                altitudeMeters: s.altitudeMeters,
                horizontalAccuracyMeters: s.horizontalAccuracyMeters,
                headingDeg: s.headingDeg, headingAccuracyDeg: s.headingAccuracyDeg,
                pitchRad: s.pitchRad, rollRad: s.rollRad, yawRad: s.yawRad,
                cameraElevationDeg: s.cameraElevationDeg, zoomFactor: s.zoomFactor,
                gravityX: s.gravityX, gravityY: s.gravityY, gravityZ: s.gravityZ)
            let redAircraft = tick.aircraft.map { a -> ReplayEvent.AircraftSnapshot in
                let idx = icaoIndex[a.icao24] ?? 0
                return ReplayEvent.AircraftSnapshot(
                    icao24: synIcao(a.icao24),
                    callsign: syntheticCallsign(a.callsign, index: idx),
                    originCountry: a.originCountry,
                    latitude: a.latitude,                      // exact
                    longitude: a.longitude + lonShift,
                    altitudeMeters: a.altitudeMeters,
                    velocityMps: a.velocityMps,
                    trackDeg: a.trackDeg,
                    onGround: a.onGround,
                    positionTimestamp: a.positionTimestamp.map(shiftTime))
            }
            return .tick(.init(timestamp: shiftTime(tick.timestamp), sensor: redSensor, aircraft: redAircraft))

        case .tapPin(let p):
            return .tapPin(.init(timestamp: shiftTime(p.timestamp), icao24: synIcao(p.icao24), x: p.x, y: p.y))

        case .emptyTap(let t):
            let idx = t.nearestIcao24.flatMap { icaoIndex[$0] } ?? 0
            return .emptyTap(.init(
                timestamp: shiftTime(t.timestamp), x: t.x, y: t.y,
                nearestIcao24: t.nearestIcao24.map(synIcao),
                nearestCallsign: syntheticCallsign(t.nearestCallsign, index: idx),
                nearestSlantMeters: t.nearestSlantMeters,
                nearestElevationDeg: t.nearestElevationDeg,
                nearestAngularOffsetDeg: t.nearestAngularOffsetDeg,
                reason: t.reason))

        case .unpin(let u):
            return .unpin(.init(timestamp: shiftTime(u.timestamp)))
        }
    }

    private static func firstObserverLongitude(_ events: [ReplayEvent]) -> Double? {
        for case .tick(let t) in events {
            if let lon = t.sensor.longitude { return lon }
        }
        return nil
    }

    private static func icaoIndexMap(_ events: [ReplayEvent]) -> [String: Int] {
        var icaos = Set<String>()
        for e in events {
            switch e {
            case .tick(let t):    t.aircraft.forEach { icaos.insert($0.icao24) }
            case .tapPin(let p):  icaos.insert(p.icao24)
            case .emptyTap(let t): if let n = t.nearestIcao24 { icaos.insert(n) }
            default: break
            }
        }
        var map: [String: Int] = [:]
        for (i, icao) in icaos.sorted().enumerated() { map[icao] = i }
        return map
    }

}
