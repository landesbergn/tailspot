//
//  ReplayAnalyzerTests.swift
//  TailspotTests
//
//  Drives the analyzer over synthetic recordings (no real device
//  capture required) and verifies the per-tick reports.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Replay analyzer")
@MainActor
struct ReplayAnalyzerTests {

    // MARK: - Fixtures

    /// A sensor snapshot positioned in Berkeley, looking due west,
    /// camera horizontal. Easy to reason about projection from this
    /// pose (a target directly west should sit at horizontal center).
    private func berkeleySensor(headingDeg: Double = 270, cameraEl: Double = 0, zoom: Double? = nil) -> ReplayEvent.SensorSnapshot {
        .init(
            latitude: 37.87, longitude: -122.27,
            altitudeMeters: 40, horizontalAccuracyMeters: 5,
            headingDeg: headingDeg, headingAccuracyDeg: 3,
            pitchRad: .pi / 2, rollRad: 0, yawRad: 0,
            cameraElevationDeg: cameraEl,
            zoomFactor: zoom
        )
    }

    /// An aircraft directly west of the observer at ~3 km horizontal.
    /// Altitude 60 m (vs observer's 40 m) puts elevation at ~0.4° —
    /// above horizon (so it passes the visibility filter) but small
    /// enough that with a horizontal camera the projection lands well
    /// within the 80 px lock zone around screen center. Bumping the
    /// altitude into 500 m territory pushes it out of the lock zone
    /// (~8.7° → ~103 px above center on a 393×852 portrait screen).
    private func westAircraft(icao: String = "abc123", altMeters: Double = 60) -> ReplayEvent.AircraftSnapshot {
        // 0.034° lon at lat 37.87 is roughly 3 km west.
        .init(
            icao24: icao, callsign: "FLY\(icao.suffix(3).uppercased())",
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.034,
            altitudeMeters: altMeters,
            velocityMps: 0, trackDeg: 270,
            onGround: false,
            positionTimestamp: nil  // disables extrapolation; position stays put
        )
    }

    private func tick(at offsetSeconds: TimeInterval,
                      from base: Date,
                      sensor: ReplayEvent.SensorSnapshot,
                      aircraft: [ReplayEvent.AircraftSnapshot]) -> ReplayEvent.Tick {
        .init(
            timestamp: base.addingTimeInterval(offsetSeconds),
            sensor: sensor,
            aircraft: aircraft
        )
    }

    private let t0 = Date(timeIntervalSince1970: 1_715_000_000)

    private func sessionStart() -> ReplayEvent.SessionStart {
        .init(timestamp: t0, appVersion: "0.1.0", deviceModel: "iPhone17,3", schemaVersion: 1)
    }

    // MARK: - Basics

    @Test func emptyEventsProducesEmptyReport() {
        let report = ReplayAnalyzer().analyze([])
        #expect(report.sessionStart == nil)
        #expect(report.ticks.isEmpty)
    }

    @Test func sessionStartPopulatesHeader() {
        let report = ReplayAnalyzer().analyze([.sessionStart(sessionStart())])
        #expect(report.sessionStart?.appVersion == "0.1.0")
        #expect(report.sessionStart?.deviceModel == "iPhone17,3")
        #expect(report.ticks.isEmpty)
    }

    @Test func tickWithoutGpsFixSkipsAnnotation() {
        let sensorNoFix = ReplayEvent.SensorSnapshot(
            latitude: nil, longitude: nil, altitudeMeters: nil,
            horizontalAccuracyMeters: nil, headingDeg: nil,
            headingAccuracyDeg: nil, pitchRad: 0, rollRad: 0,
            yawRad: 0, cameraElevationDeg: 0,
            zoomFactor: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: sensorNoFix, aircraft: [westAircraft()]))
        ])
        #expect(report.ticks.count == 1)
        let r = report.ticks[0]
        #expect(r.observerLatitude == nil)
        #expect(r.aircraft.isEmpty)        // can't annotate without observer
        #expect(r.visibleCount == 0)
        #expect(r.closestToCenterIcao24 == nil)
        #expect(r.lockState == .idle)
    }

    // MARK: - Annotation

    @Test func tickWithVisibleAircraftAnnotatesAndAcquires() {
        let report = ReplayAnalyzer().analyze([
            .sessionStart(sessionStart()),
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(),
                       aircraft: [westAircraft(icao: "abc123")]))
        ])
        let r = report.ticks[0]
        #expect(r.aircraft.count == 1)
        let ar = r.aircraft[0]
        #expect(ar.icao24 == "abc123")
        // Due west should give a bearing near 270°.
        #expect(abs(ar.bearingDeg - 270) < 2)
        // Aircraft 20 m above observer at 3 km range → small but
        // positive elevation. Visibility filter requires >0.
        #expect(ar.elevationDeg > 0)
        #expect(ar.isVisible)
        #expect(ar.screenPosition != nil)
        // First tick with a target in the lock zone → acquiring.
        #expect(r.closestToCenterIcao24 == "abc123")
        if case .acquiring(let t, _) = r.lockState {
            #expect(t == "abc123")
        } else {
            Issue.record("Expected .acquiring after first tick, got \(r.lockState)")
        }
    }

    @Test func belowHorizonOrFarAircraftIsNotVisible() {
        // Same plane, but very high altitude wrap-around: place far
        // away (~80 km) so the slant distance exceeds the 30 km cap.
        let farAircraft = ReplayEvent.AircraftSnapshot(
            icao24: "far001", callsign: nil,
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.9,  // ~80 km west
            altitudeMeters: 1000,
            velocityMps: 0, trackDeg: 270,
            onGround: false,
            positionTimestamp: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(),
                       aircraft: [farAircraft]))
        ])
        let r = report.ticks[0]
        #expect(r.aircraft.count == 1)
        #expect(r.aircraft[0].isVisible == false)
        #expect(r.visibleCount == 0)
        #expect(r.closestToCenterIcao24 == nil)
        #expect(r.lockState == .idle)
    }

    @Test func onGroundAircraftIsDroppedEntirely() {
        let grounded = ReplayEvent.AircraftSnapshot(
            icao24: "taxi01", callsign: nil,
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.034,
            altitudeMeters: 5, velocityMps: 0, trackDeg: nil,
            onGround: true,
            positionTimestamp: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(),
                       aircraft: [grounded]))
        ])
        // annotate() returns nil for on-ground; the analyzer never
        // sees an ObservedAircraft, so its summary row is also dropped.
        #expect(report.ticks[0].aircraft.isEmpty)
        #expect(report.ticks[0].visibleCount == 0)
    }

    // MARK: - Lock-on progression

    @Test func lockGraduatesFromAcquiringToLockedAfterAcquisitionDuration() {
        // Drive the engine with the same target across enough ticks
        // to exceed acquisitionDuration (default 0.6 s). 1 Hz ticks
        // at +0, +0.7 s do it.
        let sensor = berkeleySensor()
        let plane = westAircraft(icao: "abc123")
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0.0, from: t0, sensor: sensor, aircraft: [plane])),
            .tick(tick(at: 0.7, from: t0, sensor: sensor, aircraft: [plane])),
        ])
        // Tick 0: acquiring; Tick 1: locked (>= 0.6 s elapsed).
        if case .acquiring = report.ticks[0].lockState {} else {
            Issue.record("Tick 0 should be acquiring, got \(report.ticks[0].lockState)")
        }
        if case .locked(let t, _) = report.ticks[1].lockState {
            #expect(t == "abc123")
        } else {
            Issue.record("Tick 1 should be locked, got \(report.ticks[1].lockState)")
        }
    }

    @Test func losingTargetMovesLockedToSticky() {
        let sensor = berkeleySensor()
        let plane = westAircraft(icao: "abc123")
        let report = ReplayAnalyzer().analyze([
            // 0.0s + 0.7s with target: ends up locked
            .tick(tick(at: 0.0, from: t0, sensor: sensor, aircraft: [plane])),
            .tick(tick(at: 0.7, from: t0, sensor: sensor, aircraft: [plane])),
            // 1.5s with no aircraft → loses the target → sticky
            .tick(tick(at: 1.5, from: t0, sensor: sensor, aircraft: [])),
        ])
        if case .sticky(let t, _) = report.ticks[2].lockState {
            #expect(t == "abc123")
        } else {
            Issue.record("Tick 2 should be sticky, got \(report.ticks[2].lockState)")
        }
    }

    // MARK: - File-based analyze

    @Test func analyzesFromJSONLFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("analyzer-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let recorder = ReplayRecorder()
        _ = try recorder.start(at: url, appVersion: "1.2.3", deviceModel: "iPhoneSim,1", now: t0)
        recorder.recordTick(tick(at: 0, from: t0, sensor: berkeleySensor(), aircraft: [westAircraft()]))
        recorder.stop()

        let report = try ReplayAnalyzer().analyze(fileURL: url)
        #expect(report.sessionStart?.appVersion == "1.2.3")
        #expect(report.ticks.count == 1)
        #expect(report.ticks[0].aircraft.count == 1)
    }
}
