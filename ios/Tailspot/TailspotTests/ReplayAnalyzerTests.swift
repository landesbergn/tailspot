//
//  ReplayAnalyzerTests.swift
//  TailspotTests
//
//  Drives the analyzer over synthetic recordings (no real device
//  capture required) and verifies the per-tick reports — including the
//  frame-is-the-catch membership simulation (chosenIcaos).
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
    /// Default altitude 300 m: at 3 km horizontal that's ~4.95° elevation
    /// (clears the 3° visibility buffer added 2026-05-26) and projects
    /// ~59 px above screen center on a 393×852 portrait screen — well
    /// inside the frame, so it's a press-membership candidate.
    private func westAircraft(icao: String = "abc123", altMeters: Double = 300,
                              lonOffset: Double = 0.034) -> ReplayEvent.AircraftSnapshot {
        // 0.034° lon at lat 37.87 is roughly 3 km west.
        .init(
            icao24: icao, callsign: "FLY\(icao.suffix(3).uppercased())",
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - lonOffset,
            altitudeMeters: altMeters,
            velocityMps: 0, trackDeg: 270,
            onGround: false,
            positionTimestamp: nil  // disables extrapolation; position stays put
        )
    }

    /// A plane far beyond the visibility band (~80 km west) but still
    /// projecting near screen center at the westward pose — the
    /// tap-rescue (assertion) class: in the data, hidden tier, on frame.
    private func hiddenFarAircraft(icao: String = "far001") -> ReplayEvent.AircraftSnapshot {
        .init(
            icao24: icao, callsign: nil,
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.9,  // ~80 km west
            altitudeMeters: 1000,
            velocityMps: 0, trackDeg: 270,
            onGround: false,
            positionTimestamp: nil
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
        #expect(r.chosenIcaos.isEmpty)
    }

    // MARK: - Annotation

    @Test func visibleOnFramePlaneIsChosen() {
        // Frame is the catch: a bright-tier plane projecting onto the
        // frame is press membership all by itself — no pin, no zone.
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
        #expect(ar.elevationDeg > 0)
        #expect(ar.isVisible)
        #expect(ar.screenPosition != nil)
        #expect(r.chosenIcaos == ["abc123"])
    }

    @Test func belowHorizonOrFarAircraftIsNotVisibleAndNotChosen() {
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(),
                       aircraft: [hiddenFarAircraft()]))
        ])
        let r = report.ticks[0]
        #expect(r.aircraft.count == 1)
        #expect(r.aircraft[0].isVisible == false)
        #expect(r.visibleCount == 0)
        // Hidden tier without an assertion never enters membership.
        #expect(r.chosenIcaos.isEmpty)
    }

    @Test func onGroundAircraftIsAnnotatedButNeverVisibleOrChosen() {
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
        // Grounded easter egg (2026-07-09): annotate() no longer drops
        // on-ground aircraft — they carry `grounded = true` and pin to the
        // hidden tier, so the summary row exists but is never visible.
        #expect(report.ticks[0].aircraft.count == 1)
        #expect(report.ticks[0].aircraft[0].isVisible == false)
        #expect(report.ticks[0].visibleCount == 0)
        #expect(report.ticks[0].chosenIcaos.isEmpty)
    }

    // MARK: - Membership simulation

    @Test func membershipCapsAtMaxTargetsRankedBySize() {
        // Four comparable planes due west at increasing distance. Apparent
        // size falls with slant, so the three NEAREST are chosen (larger
        // first) and the farthest overflows the `maxCatchTargets` cap.
        let planes = [
            westAircraft(icao: "aaa111", altMeters: 220, lonOffset: 0.024),  // ~2.1 km
            westAircraft(icao: "bbb222", altMeters: 300, lonOffset: 0.034),  // ~3.0 km
            westAircraft(icao: "ccc333", altMeters: 400, lonOffset: 0.046),  // ~4.0 km
            westAircraft(icao: "ddd444", altMeters: 500, lonOffset: 0.058),  // ~5.1 km
        ]
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(), aircraft: planes))
        ])
        let r = report.ticks[0]
        #expect(r.visibleCount == 4)
        #expect(r.chosenIcaos == ["aaa111", "bbb222", "ccc333"])
    }

    @Test func assertedHiddenPlaneJoinsMembership() {
        // A tapPin (assertion) on a hidden-tier plane that projects onto
        // the frame makes it catchable — the tap-rescue path, exactly as
        // the live app treats an asserted plane.
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(),
                       aircraft: [hiddenFarAircraft()]))
        ])
        let r = report.ticks[0]
        #expect(r.aircraft[0].isVisible == false)
        #expect(r.chosenIcaos == ["far001"])
    }

    @Test func unpinDropsTheAssertion() {
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .unpin(.init(timestamp: t0.addingTimeInterval(0.1))),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(),
                       aircraft: [hiddenFarAircraft()]))
        ])
        #expect(report.ticks[0].chosenIcaos.isEmpty)
    }

    @Test func assertedPlaneOutranksLargerVisiblePlanes() {
        // An assertion is guaranteed a slot ahead of the size ranking.
        let planes = [
            westAircraft(icao: "aaa111", altMeters: 220, lonOffset: 0.024),
            westAircraft(icao: "bbb222", altMeters: 300, lonOffset: 0.034),
            westAircraft(icao: "ccc333", altMeters: 400, lonOffset: 0.046),
            hiddenFarAircraft(icao: "far001"),
        ]
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: planes))
        ])
        let chosen = report.ticks[0].chosenIcaos
        #expect(chosen.count == 3)
        #expect(chosen.first == "far001")
        #expect(chosen.contains("aaa111"))
        #expect(chosen.contains("bbb222"))
    }

    @Test func pinnedPlaneAbsentFromDataIsNotChosen() {
        // Assertion on a plane that then leaves the feed: membership can
        // only choose planes that exist in the tick.
        let xyz = westAircraft(icao: "xyz999")
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: [xyz])),
        ])
        #expect(report.ticks[0].chosenIcaos == ["xyz999"])
    }

    @Test func eventsOutOfOrderAreSortedByTimestamp() {
        // Tap-pin events from user input can in principle race the
        // 1 Hz tick writer at the millisecond level. The analyzer
        // sorts by timestamp before processing so the outcome
        // doesn't depend on the input array order.
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(),
                       aircraft: [hiddenFarAircraft()])),
            .tapPin(.init(timestamp: t0, icao24: "far001")),
            .sessionStart(sessionStart()),
        ])
        // Despite the .tick being array-first, sorting puts the tapPin
        // before it, so the assertion applies at the tick.
        #expect(report.sessionStart != nil)
        #expect(report.ticks[0].chosenIcaos == ["far001"])
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

    // MARK: - describe() formatter

    @Test func describeEmptyReport() {
        let report = ReplayReport(sessionStart: nil, ticks: [])
        let s = report.describe()
        #expect(s.contains("no session-start header"))
        #expect(s.contains("0 ticks"))
    }

    @Test func describeSessionOnlyShowsHeader() {
        let report = ReplayReport(sessionStart: sessionStart(), ticks: [])
        let s = report.describe()
        // Header fields all appear in their canonical form.
        #expect(s.contains("Tailspot replay"))
        #expect(s.contains("iPhone17,3"))
        #expect(s.contains("app 0.1.0"))
        #expect(s.contains("schema 1"))
    }

    @Test func describeWithTickIncludesPoseAircraftAndChosen() {
        let report = ReplayAnalyzer().analyze([
            .sessionStart(sessionStart()),
            .tick(tick(at: 0, from: t0, sensor: berkeleySensor(), aircraft: [westAircraft()]))
        ])
        let s = report.describe()
        // One tick → ~0.0s offset line.
        #expect(s.contains("t=+0.0s"))
        // Observer pose is printed.
        #expect(s.contains("37.8700"))
        #expect(s.contains("-122.2700"))
        // Aircraft icao + callsign appear.
        #expect(s.contains("abc123"))
        // Membership line names the chosen plane.
        #expect(s.contains("chosen: abc123"))
    }

    @Test func describeMarksChosenWithBullet() {
        // Two aircraft, one in membership. The describe() output should
        // annotate the chosen row with a bullet, the other without. The
        // second plane is visible but projects OUTSIDE the vertical FOV
        // (~59° elevation), so it never becomes a membership candidate.
        let other = ReplayEvent.AircraftSnapshot(
            icao24: "other", callsign: "OTHER",
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.01,   // small offset west
            altitudeMeters: 1500,                          // ~59° elevation → off frame
            velocityMps: 0, trackDeg: nil,
            onGround: false,
            positionTimestamp: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0,
                       sensor: berkeleySensor(),
                       aircraft: [westAircraft(icao: "abc123"), other]))
        ])
        let s = report.describe()
        #expect(s.contains("· abc123"))   // chosen gets the bullet marker
        #expect(s.contains("  other"))    // off-frame plane does not
    }

    // MARK: - 3D pinhole: gravity-derived roll plumbing

    /// End-to-end plumbing check (spec §6.3): the sensor row → basis-builder
    /// selection → projection path inside the analyzer. A plane due west and
    /// slightly above the horizon projects straight above screen center with
    /// no roll; feeding a gravity vector that encodes a 45° roll must rotate
    /// it sideways. Also exercises the gravity-absent fallback (roll = 0).
    @Test func gravityRollRotatesProjectionAndAbsentGravityIsZeroRoll() {
        var analyzer = ReplayAnalyzer()
        analyzer.screenSize = CGSize(width: 400, height: 800)   // center = (200, 400)
        let plane = westAircraft(icao: "abc123", altMeters: 300) // ~5° above, due west

        // No gravity fields → analyzer uses roll = 0. Plane sits horizontally
        // centered, above center.
        let noGravity = analyzer.analyze([
            .tick(tick(at: 0, from: t0,
                       sensor: berkeleySensor(headingDeg: 270, cameraEl: 0),
                       aircraft: [plane]))
        ])
        let pNoRoll = try! #require(noGravity.ticks[0].aircraft[0].screenPosition)
        #expect(abs(pNoRoll.x - 200) < 1)   // horizontally centered
        #expect(pNoRoll.y < 400)            // above center

        // Gravity encoding a 45° roll (gz = 0 → camEl stays 0; in-plane
        // gravity tilted 45°). Same geometry must now shift off-center
        // horizontally.
        let rolledSensor = ReplayEvent.SensorSnapshot(
            latitude: 37.87, longitude: -122.27, altitudeMeters: 40,
            horizontalAccuracyMeters: 5, headingDeg: 270, headingAccuracyDeg: 3,
            pitchRad: .pi / 2, rollRad: 0, yawRad: 0, cameraElevationDeg: 0,
            zoomFactor: nil,
            gravityX: sin(.pi / 4), gravityY: -cos(.pi / 4), gravityZ: 0
        )
        let withRoll = analyzer.analyze([
            .tick(tick(at: 0, from: t0, sensor: rolledSensor, aircraft: [plane]))
        ])
        let pRoll = try! #require(withRoll.ticks[0].aircraft[0].screenPosition)
        #expect(pRoll.x > 210)              // rotated off-center by the roll
    }

    @Test func describeNoGpsTickShowsObsNoFix() {
        let sensorNoFix = ReplayEvent.SensorSnapshot(
            latitude: nil, longitude: nil, altitudeMeters: nil,
            horizontalAccuracyMeters: nil, headingDeg: nil,
            headingAccuracyDeg: nil, pitchRad: 0, rollRad: 0,
            yawRad: 0, cameraElevationDeg: 0,
            zoomFactor: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0, from: t0, sensor: sensorNoFix, aircraft: []))
        ])
        let s = report.describe()
        #expect(s.contains("obs=(no fix)"))
        #expect(s.contains("hdg=  —"))
        #expect(s.contains("chosen: —"))
    }
}
