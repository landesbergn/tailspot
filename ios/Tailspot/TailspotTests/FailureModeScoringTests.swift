//
//  FailureModeScoringTests.swift
//  TailspotTests
//
//  Drives ReplayAnalyzer.scoreFailureModes over synthetic recordings with
//  known ground truth (the tap-pin) and verifies each geometric failure
//  mode is scored — or, where a mode can't manifest from the replay tick
//  stream (phantom), that it does NOT false-fire.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Failure-mode scoring")
@MainActor
struct FailureModeScoringTests {

    // MARK: - Fixtures (mirror ReplayAnalyzerTests' synthetic setup)

    private let t0 = Date(timeIntervalSince1970: 1_715_000_000)

    private func sessionStart() -> ReplayEvent.SessionStart {
        .init(timestamp: t0, appVersion: "0.1.0", deviceModel: "iPhone17,3", schemaVersion: 1)
    }

    private func berkeleySensor(headingDeg: Double = 270, cameraEl: Double = 0) -> ReplayEvent.SensorSnapshot {
        .init(latitude: 37.87, longitude: -122.27, altitudeMeters: 40, horizontalAccuracyMeters: 5,
              headingDeg: headingDeg, headingAccuracyDeg: 3, pitchRad: .pi / 2, rollRad: 0, yawRad: 0,
              cameraElevationDeg: cameraEl, zoomFactor: nil)
    }

    /// Due west of Berkeley. Altitude sets elevation; lonOffset sets range.
    private func westAircraft(icao: String = "abc123", altMeters: Double = 300, lonOffset: Double = -0.034) -> ReplayEvent.AircraftSnapshot {
        .init(icao24: icao, callsign: "FLY\(icao.suffix(3).uppercased())", originCountry: "United States",
              latitude: 37.87, longitude: -122.27 + lonOffset, altitudeMeters: altMeters,
              velocityMps: 0, trackDeg: 270, onGround: false, positionTimestamp: nil)
    }

    private func tick(at off: TimeInterval, sensor: ReplayEvent.SensorSnapshot, aircraft: [ReplayEvent.AircraftSnapshot]) -> ReplayEvent.Tick {
        .init(timestamp: t0.addingTimeInterval(off), sensor: sensor, aircraft: aircraft)
    }

    /// Where a plane actually projects on screen, learned by running the
    /// analyzer once — so adversarial pins are built against real geometry.
    private func screenPos(_ icao: String, _ aircraft: [ReplayEvent.AircraftSnapshot]) -> CGPoint {
        let r = ReplayAnalyzer().analyze([.tick(tick(at: 0, sensor: berkeleySensor(), aircraft: aircraft))])
        return r.ticks[0].aircraft.first { $0.icao24 == icao }!.screenPosition!
    }

    // MARK: - Happy path

    @Test func cleanSessionHasNoFindings() {
        let report = ReplayAnalyzer().scoreFailureModes([
            .sessionStart(sessionStart()),
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [westAircraft()])),
        ])
        #expect(report.isClean)
    }

    // MARK: - Missed (mode 1)

    @Test func pinnedButFilteredPlaneScoresMissed() {
        // ~80 km west, above horizon but past the visibility cap → filtered.
        let far = westAircraft(icao: "far001", altMeters: 1000, lonOffset: -0.9)
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [far])),
        ])
        #expect(report.modesFired == [.missedPlane])
        #expect(report.findings(for: .missedPlane).first?.icao24 == "far001")
    }

    @Test func emptyTapOnFilteredPlaneScoresMissed() {
        // The FDX1268 class: a plane in-data but past the visibility cap, so
        // the user can't pin it — the tap records an `empty-tap` whose own
        // reason is "filtered". No tap-pin exists, so only the empty-tap pass
        // can catch it.
        let far = westAircraft(icao: "far001", altMeters: 1000, lonOffset: -0.9)
        let report = ReplayAnalyzer().scoreFailureModes([
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [far])),
            .emptyTap(.init(timestamp: t0.addingTimeInterval(0.6), x: 195, y: 472,
                            nearestIcao24: "far001", nearestCallsign: "FDX1268",
                            nearestSlantMeters: 80_000, nearestElevationDeg: 0.5,
                            nearestAngularOffsetDeg: 5, reason: "filtered")),
        ])
        #expect(report.modesFired == [.missedPlane])
        #expect(report.findings(for: .missedPlane).first?.icao24 == "far001")
    }

    @Test func emptyTapNonFilteredReasonsDoNotScoreMissed() {
        // off-frame / on-screen / nothing-nearby are not filter misses — only
        // "filtered" means the visibility tier hid an in-data plane.
        let visiblePlane = westAircraft(icao: "vis001")  // ~3 km, in-view
        let base: [ReplayEvent] = [.tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [visiblePlane]))]
        for reason in ["off-frame", "on-screen", "nothing-nearby"] {
            let report = ReplayAnalyzer().scoreFailureModes(base + [
                .emptyTap(.init(timestamp: t0.addingTimeInterval(0.6), x: 0, y: 0,
                                nearestIcao24: "vis001", nearestCallsign: nil,
                                nearestSlantMeters: 3000, nearestElevationDeg: 5,
                                nearestAngularOffsetDeg: 5, reason: reason)),
            ])
            #expect(!report.modesFired.contains(.missedPlane), "reason=\(reason) is not a filter miss")
        }
    }

    @Test func emptyTapMissedDoesNotDoubleCountWithPin() {
        // A filtered plane that is ALSO (somehow) pinned must yield exactly one
        // missed finding for that tick+icao, not two.
        let far = westAircraft(icao: "far001", altMeters: 1000, lonOffset: -0.9)
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [far])),
            .emptyTap(.init(timestamp: t0.addingTimeInterval(0.6), x: 195, y: 472,
                            nearestIcao24: "far001", nearestCallsign: "FDX1268",
                            nearestSlantMeters: 80_000, nearestElevationDeg: 0.5,
                            nearestAngularOffsetDeg: 5, reason: "filtered")),
        ])
        #expect(report.findings(for: .missedPlane).count == 1)
    }

    // MARK: - Spatial offset (mode 3)

    @Test func pinFarFromProjectedLabelScoresOffset() {
        let planes = [westAircraft(icao: "abc123")]
        let pos = screenPos("abc123", planes)
        // Pin 120 px right of where the label projects → clearly off-plane.
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: "abc123", x: Double(pos.x) + 120, y: Double(pos.y))),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: planes)),
        ])
        #expect(report.modesFired.contains(.spatialOffset))
        #expect(report.findings(for: .spatialOffset).first?.icao24 == "abc123")
    }

    // MARK: - Mis-association (mode 5)

    @Test func pinOnPlaneAppWouldNotCenterScoresMisAssociation() {
        // Two visible planes; learn which the center logic picks, pin the
        // other — the app's auto-pick then diverges from ground truth.
        let a = westAircraft(icao: "aaa111", altMeters: 300)              // higher → farther from center
        let b = westAircraft(icao: "bbb222", altMeters: 220)             // lower → nearer center
        let planes = [a, b]
        let r0 = ReplayAnalyzer().analyze([.tick(tick(at: 0, sensor: berkeleySensor(), aircraft: planes))])
        let closest = try! #require(r0.ticks[0].closestToCenterIcao24)
        let pinTarget = closest == "aaa111" ? "bbb222" : "aaa111"
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: pinTarget)),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: planes)),
        ])
        #expect(report.modesFired.contains(.misAssociation))
        #expect(report.findings(for: .misAssociation).first?.icao24 == closest)
    }

    // MARK: - Phantom (mode 8) — no false positive

    @Test func vanishedPinnedPlaneDoesNotFalselyScorePhantom() {
        // Pin A, then a tick where A is gone and nothing is visible: the
        // engine holds sticky(A) as intended grace — not a phantom, and not
        // a missed (A isn't in the data to compare against).
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, sensor: berkeleySensor(), aircraft: [])),
        ])
        #expect(!report.modesFired.contains(.phantomCapture))
        #expect(report.isClean)
    }

    // MARK: - Edges

    @Test func sessionWithoutPinMakesNoGeometricClaims() {
        let report = ReplayAnalyzer().scoreFailureModes([
            .sessionStart(sessionStart()),
            .tick(tick(at: 0, sensor: berkeleySensor(), aircraft: [westAircraft()])),
        ])
        #expect(report.isClean)
    }

    @Test func tickBeforeGpsFixIsNotScoredMissed() {
        let noFix = ReplayEvent.SensorSnapshot(
            latitude: nil, longitude: nil, altitudeMeters: nil, horizontalAccuracyMeters: nil,
            headingDeg: nil, headingAccuracyDeg: nil, pitchRad: 0, rollRad: 0, yawRad: 0,
            cameraElevationDeg: 0, zoomFactor: nil)
        let report = ReplayAnalyzer().scoreFailureModes([
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, sensor: noFix, aircraft: [westAircraft()])),
        ])
        #expect(!report.modesFired.contains(.missedPlane))
        #expect(report.isClean)
    }
}
