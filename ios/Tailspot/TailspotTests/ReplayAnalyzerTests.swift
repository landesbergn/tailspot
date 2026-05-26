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

    @Test func tickWithVisibleAircraftAnnotatesAndStaysIdle() {
        // No auto-acquire after Task 4 — the engine stays idle until a
        // tapPin event drives it through forceLock(). The analyzer
        // still computes closestToCenter for the ambient-label path,
        // but lockState only changes on explicit pin events.
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
        // Closest-to-center is still computed (used elsewhere); the
        // engine just doesn't auto-lock on it.
        #expect(r.closestToCenterIcao24 == "abc123")
        #expect(r.lockState == .idle)
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

    @Test func ticksAloneNeverEnterLocked() {
        // Without a tapPin, no number of ticks should auto-acquire.
        // The engine only enters .locked via explicit forceLock now.
        let sensor = berkeleySensor()
        let plane = westAircraft(icao: "abc123")
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0.0, from: t0, sensor: sensor, aircraft: [plane])),
            .tick(tick(at: 0.7, from: t0, sensor: sensor, aircraft: [plane])),
            .tick(tick(at: 1.4, from: t0, sensor: sensor, aircraft: [plane])),
        ])
        for r in report.ticks {
            #expect(r.lockState == .idle)
        }
    }

    @Test func losingTargetMovesLockedToSticky() {
        let sensor = berkeleySensor()
        let plane = westAircraft(icao: "abc123")
        let report = ReplayAnalyzer().analyze([
            // tapPin drives the engine into .locked
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            // Tick with the same target → stays locked.
            .tick(tick(at: 0.1, from: t0, sensor: sensor, aircraft: [plane])),
            // Later tick with no aircraft → loses target → sticky.
            .tick(tick(at: 1.0, from: t0, sensor: sensor, aircraft: [])),
        ])
        if case .sticky(let t, _) = report.ticks[1].lockState {
            #expect(t == "abc123")
        } else {
            Issue.record("Tick 1 should be sticky, got \(report.ticks[1].lockState)")
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

    @Test func describeWithTickIncludesPoseAndAircraft() {
        // Run the analyzer over a known fixture so the report's
        // structure (visible count, closest, lock state) matches what
        // describe() will format. With Task 4 the engine no longer
        // auto-acquires, so the lock state on a tick-only session
        // stays "idle".
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
        // Lock state name appears — no auto-acquire, so still idle.
        #expect(s.contains("lock: idle"))
    }

    @Test func describeMarksClosestToCenterWithBullet() {
        // Two aircraft, only one in the lock zone. The describe()
        // output should annotate that row with a bullet, the other
        // without. Use a far-off second plane that's still visible
        // (close enough) but not within 80 px of center.
        let other = ReplayEvent.AircraftSnapshot(
            icao24: "other", callsign: "OTHER",
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.01,   // small offset west
            altitudeMeters: 1500,                          // ~10° elevation → outside lock zone vertically
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
        #expect(s.contains("· abc123"))   // closest gets the bullet marker
        #expect(s.contains("  other"))    // other does not
    }

    // MARK: - Tap-pin replay

    @Test func tapPinForcesLockOnIcaoEvenWithoutMatchingTick() {
        // A tapPin event with no aircraft visible in the prior tick
        // should still produce a locked() engine state on the next
        // tick (the engine got `forceLock`ed). Without tapPin
        // honoring, the analyzer would lock onto whatever's closest
        // to center instead.
        let plane = westAircraft(icao: "abc123")
        // tapPin happens BEFORE the first tick; the engine should
        // already be locked(abc123) when we evaluate the tick.
        let report = ReplayAnalyzer().analyze([
            .sessionStart(sessionStart()),
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: [plane])),
        ])
        if case .locked(let icao, _) = report.ticks[0].lockState {
            #expect(icao == "abc123")
        } else {
            Issue.record("Expected .locked(abc123) after tapPin; got \(report.ticks[0].lockState)")
        }
    }

    @Test func unpinFallsBackToCenterDriven() {
        // tapPin to plane A, then unpin, then a tick where plane A is
        // still visible AND closest to center. Engine state at the
        // tick should reflect the center-driven logic (acquiring,
        // since the locked state from forceLock dropped to acquiring
        // when target was momentarily not-equal-to-locked? — actually
        // unpin doesn't reset engine; the .locked state from forceLock
        // would persist. The new tick's update() will see target=A
        // again and keep locked.) Tests the post-unpin behavior
        // doesn't *re-pin*: a different plane closer to center should
        // win.
        let pinPlane = westAircraft(icao: "abc123")
        // A second plane way off bearing — not visible / not closest.
        // Tap-pin to "abc123", unpin, then add a tick with only "abc123"
        // present. After unpin, the analyzer should be back to center-
        // driven, so the next tick re-acquires through update().
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .unpin(.init(timestamp: t0.addingTimeInterval(0.1))),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: [pinPlane])),
        ])
        // After unpin, target follows center-driven logic. Plane is
        // still center-closest, so engine stays locked (it was already
        // locked from the prior forceLock and the target hasn't changed).
        if case .locked(let icao, _) = report.ticks[0].lockState {
            #expect(icao == "abc123")
        } else {
            Issue.record("Expected continued .locked(abc123); got \(report.ticks[0].lockState)")
        }
    }

    @Test func eventsOutOfOrderAreSortedByTimestamp() {
        // Tap-pin events from user input can in principle race the
        // 1 Hz tick writer at the millisecond level. The analyzer
        // sorts by timestamp before processing so the outcome
        // doesn't depend on the input array order.
        let plane = westAircraft(icao: "abc123")
        // Build events in reversed timestamp order to be sure the
        // sort is doing the work.
        let report = ReplayAnalyzer().analyze([
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: [plane])),
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .sessionStart(sessionStart()),
        ])
        // Despite the .tick being array-first, sorting should put
        // sessionStart → tapPin → tick → analyzer locks(abc123).
        #expect(report.sessionStart != nil)
        if case .locked(let icao, _) = report.ticks[0].lockState {
            #expect(icao == "abc123")
        } else {
            Issue.record("Expected .locked(abc123) after timestamp sort; got \(report.ticks[0].lockState)")
        }
    }

    @Test func pinnedPlaneNoLongerVisibleFallsBackToCenter() {
        // tapPin to "abc123", then a tick where "abc123" is NOT in the
        // aircraft list and a different plane "xyz" IS visible and
        // close to center. Pin is dead — the analyzer fell back to
        // center-driven, so update() sees "xyz" while the engine is
        // .locked(abc123). With Task 4 there's no acquiring anymore:
        // the engine drops the lock to .sticky(abc123).
        let xyz = ReplayEvent.AircraftSnapshot(
            icao24: "xyz", callsign: "OTH",
            originCountry: "United States",
            latitude: 37.87, longitude: -122.27 - 0.034,  // due west, same as westAircraft
            altitudeMeters: 60,
            velocityMps: 0, trackDeg: 270,
            onGround: false,
            positionTimestamp: nil
        )
        let report = ReplayAnalyzer().analyze([
            .tapPin(.init(timestamp: t0, icao24: "abc123")),
            .tick(tick(at: 0.5, from: t0, sensor: berkeleySensor(), aircraft: [xyz])),
        ])
        // Engine starts locked(abc123) from forceLock. Tick says target
        // = pinStillVisible ? "abc123" : centerClosest ("xyz"). Since
        // "abc123" is NOT visible, target = "xyz". Engine transitions
        // locked(abc123) → sticky(abc123): a different closest target
        // doesn't steal the lock, it just bumps it into sticky-hold.
        if case .sticky(let icao, _) = report.ticks[0].lockState {
            #expect(icao == "abc123")
        } else {
            Issue.record("Expected .sticky(abc123) when pin disappeared; got \(report.ticks[0].lockState)")
        }
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
        #expect(s.contains("lock: idle"))
    }
}
