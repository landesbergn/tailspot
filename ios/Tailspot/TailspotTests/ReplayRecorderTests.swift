//
//  ReplayRecorderTests.swift
//  TailspotTests
//
//  Round-trip tests for the replay format and recorder lifecycle.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Replay format")
struct ReplayJSONLTests {

    private func sampleTick(offset seconds: TimeInterval = 0) -> ReplayEvent.Tick {
        ReplayEvent.Tick(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000 + seconds),
            sensor: .init(
                latitude: 37.87,
                longitude: -122.27,
                altitudeMeters: 40,
                horizontalAccuracyMeters: 5,
                headingDeg: 270,
                headingAccuracyDeg: 3,
                pitchRad: 1.1,
                rollRad: 0.1,
                yawRad: 0.05,
                cameraElevationDeg: 27,
                zoomFactor: nil
            ),
            aircraft: [
                .init(
                    icao24: "a3b15e",
                    callsign: "UAL248",
                    originCountry: "United States",
                    latitude: 37.81,
                    longitude: -122.30,
                    altitudeMeters: 9144,
                    velocityMps: 230,
                    trackDeg: 270.5,
                    onGround: false,
                    positionTimestamp: Date(timeIntervalSince1970: 1_714_999_995)
                )
            ]
        )
    }

    private func sampleSessionStart() -> ReplayEvent.SessionStart {
        .init(
            timestamp: Date(timeIntervalSince1970: 1_715_000_000),
            appVersion: "0.1.0",
            deviceModel: "iPhone17,3",
            schemaVersion: 1
        )
    }

    @Test func encodesEachEventAsOneLine() throws {
        let line = try ReplayJSONL.line(for: .tick(sampleTick()))
        let newlines = line.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        #expect(newlines == 1)
        #expect(line.last == 0x0A)
    }

    @Test func roundTripsSessionStartAndTicks() throws {
        let events: [ReplayEvent] = [
            .sessionStart(sampleSessionStart()),
            .tick(sampleTick(offset: 1)),
            .tick(sampleTick(offset: 2)),
        ]
        var concatenated = Data()
        for e in events {
            concatenated.append(try ReplayJSONL.line(for: e))
        }
        let decoded = try ReplayJSONL.decode(concatenated)
        #expect(decoded == events)
    }

    @Test func roundTripsTapPinAndUnpin() throws {
        let events: [ReplayEvent] = [
            .tapPin(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_010), icao24: "abc")),
            .unpin(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_011))),
        ]
        var data = Data()
        for e in events { data.append(try ReplayJSONL.line(for: e)) }
        let decoded = try ReplayJSONL.decode(data)
        #expect(decoded == events)
    }

    @Test func roundTripsGravityAndTapLocation() throws {
        let sensor = ReplayEvent.SensorSnapshot(
            latitude: 37.87, longitude: -122.27, altitudeMeters: 40,
            horizontalAccuracyMeters: 5, headingDeg: 270, headingAccuracyDeg: 3,
            pitchRad: 1.1, rollRad: 0.1, yawRad: 0.05, cameraElevationDeg: 27,
            zoomFactor: 2.0,
            gravityX: 0.12, gravityY: -0.93, gravityZ: 0.34
        )
        let events: [ReplayEvent] = [
            .tick(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_000),
                        sensor: sensor, aircraft: [])),
            .tapPin(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_005),
                          icao24: "abc", x: 123.5, y: 456.25)),
        ]
        var data = Data()
        for e in events { data.append(try ReplayJSONL.line(for: e)) }
        let decoded = try ReplayJSONL.decode(data)

        #expect(decoded == events)   // Equatable round-trip incl. new fields
        guard case .tick(let t) = decoded[0] else { Issue.record("expected tick"); return }
        #expect(t.sensor.gravityX == 0.12)
        #expect(t.sensor.gravityY == -0.93)
        #expect(t.sensor.gravityZ == 0.34)
        guard case .tapPin(let p) = decoded[1] else { Issue.record("expected tapPin"); return }
        #expect(p.x == 123.5)
        #expect(p.y == 456.25)
    }

    @Test func legacyRecordsWithoutGravityOrTapLocationDecodeToNil() throws {
        // The synthesized Codable omits nil optionals on encode, so a record
        // built without gravity / tap location is byte-identical to a file
        // recorded before those fields shipped. Decoding must yield nil
        // (not a failure) — the back-compat contract.
        let sensor = ReplayEvent.SensorSnapshot(
            latitude: 37.87, longitude: -122.27, altitudeMeters: 40,
            horizontalAccuracyMeters: 5, headingDeg: 270, headingAccuracyDeg: 3,
            pitchRad: 1.1, rollRad: 0.1, yawRad: 0.05, cameraElevationDeg: 27,
            zoomFactor: nil
        )
        let events: [ReplayEvent] = [
            .tick(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_000),
                        sensor: sensor, aircraft: [])),
            .tapPin(.init(timestamp: Date(timeIntervalSince1970: 1_715_000_005), icao24: "abc")),
        ]
        var data = Data()
        for e in events { data.append(try ReplayJSONL.line(for: e)) }
        let decoded = try ReplayJSONL.decode(data)

        guard case .tick(let t) = decoded[0] else { Issue.record("expected tick"); return }
        #expect(t.sensor.gravityX == nil)
        #expect(t.sensor.gravityY == nil)
        #expect(t.sensor.gravityZ == nil)
        #expect(t.sensor.cameraElevationDeg == 27)   // the rest still decodes
        guard case .tapPin(let p) = decoded[1] else { Issue.record("expected tapPin"); return }
        #expect(p.x == nil)
        #expect(p.y == nil)
    }

    @Test func dropsTrailingPartialLine() throws {
        // Simulate a crash mid-write: the last line has no trailing
        // newline. Decode should silently drop it and return only the
        // complete events, so the rest of a recorded session stays
        // replayable.
        let good = try ReplayJSONL.line(for: .tick(sampleTick()))
        var data = Data()
        data.append(good)
        data.append(good)
        data.append(Data("{\"type\":\"tick\"".utf8))  // partial; no newline
        let decoded = try ReplayJSONL.decode(data)
        #expect(decoded.count == 2)
    }

    @Test func dropsBlankTrailingNewlines() throws {
        let good = try ReplayJSONL.line(for: .tick(sampleTick()))
        var data = Data()
        data.append(good)
        data.append(0x0A) // extra blank line
        data.append(0x0A)
        let decoded = try ReplayJSONL.decode(data)
        #expect(decoded.count == 1)
    }
}

@Suite("ReplayRecorder")
@MainActor
struct ReplayRecorderTests {

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("replay-test-\(UUID().uuidString).jsonl")
    }

    private func sampleTick() -> ReplayEvent.Tick {
        ReplayEvent.Tick(
            timestamp: Date(),
            sensor: .init(
                latitude: 0, longitude: 0, altitudeMeters: nil,
                horizontalAccuracyMeters: nil, headingDeg: nil,
                headingAccuracyDeg: nil, pitchRad: 0, rollRad: 0,
                yawRad: 0, cameraElevationDeg: 0,
                zoomFactor: nil
            ),
            aircraft: []
        )
    }

    @Test func startWritesSessionStart() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url, appVersion: "1.2.3", deviceModel: "iPhone17,3",
                        now: Date(timeIntervalSince1970: 1_715_000_000))
        r.stop()

        let data = try Data(contentsOf: url)
        let events = try ReplayJSONL.decode(data)
        #expect(events.count == 1)
        if case let .sessionStart(s) = events[0] {
            #expect(s.appVersion == "1.2.3")
            #expect(s.deviceModel == "iPhone17,3")
            #expect(s.schemaVersion == ReplayRecorder.schemaVersion)
        } else {
            Issue.record("First event was not sessionStart")
        }
    }

    @Test func recordTickAppendsAndBumpsCount() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url)
        r.recordTick(sampleTick())
        r.recordTick(sampleTick())
        #expect(r.eventCount == 3) // session-start + 2 ticks
        r.stop()

        let events = try ReplayJSONL.decode(Data(contentsOf: url))
        #expect(events.count == 3)
        if case .sessionStart = events[0] {} else { Issue.record("expected sessionStart first") }
        if case .tick = events[1] {} else { Issue.record("expected tick second") }
        if case .tick = events[2] {} else { Issue.record("expected tick third") }
    }

    @Test func recordTickWhenNotRecordingIsANoop() throws {
        // Callers should be able to fire from a Timer without
        // checking isRecording — guarded inside.
        let r = ReplayRecorder()
        r.recordTick(sampleTick())  // must not crash
        #expect(r.eventCount == 0)
        #expect(r.isRecording == false)
    }

    @Test func recordTapPinAndUnpinAppendLines() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url)
        r.recordTapPin(icao24: "abc", at: Date(timeIntervalSince1970: 1_715_000_010))
        r.recordUnpin(at: Date(timeIntervalSince1970: 1_715_000_011))
        #expect(r.eventCount == 3) // session-start + tapPin + unpin
        r.stop()

        let events = try ReplayJSONL.decode(Data(contentsOf: url))
        #expect(events.count == 3)
        if case .tapPin(let p) = events[1] {
            #expect(p.icao24 == "abc")
        } else { Issue.record("Expected tapPin second; got \(events[1])") }
        if case .unpin = events[2] {} else { Issue.record("Expected unpin third") }
    }

    @Test func recordTapPinWritesTapLocation() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url)
        r.recordTapPin(icao24: "abc",
                       at: Date(timeIntervalSince1970: 1_715_000_010),
                       tapPoint: CGPoint(x: 42, y: 99))
        r.stop()

        let events = try ReplayJSONL.decode(Data(contentsOf: url))
        guard case .tapPin(let p) = events[1] else { Issue.record("expected tapPin second"); return }
        #expect(p.icao24 == "abc")
        #expect(p.x == 42)
        #expect(p.y == 99)
    }

    @Test func recordTapPinWhenNotRecordingIsANoop() {
        let r = ReplayRecorder()
        r.recordTapPin(icao24: "abc")
        r.recordUnpin()
        #expect(r.eventCount == 0)
        #expect(r.isRecording == false)
    }

    @Test func startTwiceThrows() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url)
        #expect(throws: ReplayRecorder.RecorderError.alreadyRecording) {
            _ = try r.start(at: url)
        }
        r.stop()
    }

    @Test func stopClearsStateAndIsIdempotent() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let r = ReplayRecorder()
        _ = try r.start(at: url)
        r.stop()
        #expect(r.isRecording == false)
        r.stop() // idempotent; must not crash
        #expect(r.isRecording == false)
    }

    @Test func aircraftSnapshotConvertsFromAircraft() {
        let a = Aircraft(
            icao24: "a3b15e", callsign: "UAL248",
            originCountry: "United States",
            longitude: -122.30, latitude: 37.81,
            altitudeMeters: 9144,
            velocityMps: 230, trackDeg: 270.5,
            onGround: false,
            positionTimestamp: Date(timeIntervalSince1970: 1_714_999_995)
        )
        let snap = ReplayEvent.AircraftSnapshot(a)
        #expect(snap.icao24 == "a3b15e")
        #expect(snap.callsign == "UAL248")
        #expect(snap.latitude == 37.81)
        #expect(snap.longitude == -122.30)
        #expect(snap.velocityMps == 230)
        #expect(snap.trackDeg == 270.5)
        #expect(snap.onGround == false)
        #expect(snap.positionTimestamp == Date(timeIntervalSince1970: 1_714_999_995))
    }
}
