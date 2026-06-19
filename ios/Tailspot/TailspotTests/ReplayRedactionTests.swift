//
//  ReplayRedactionTests.swift
//  TailspotTests
//
//  Characterizes ReplayRedaction: the geometry the analyzer reads must be
//  IDENTICAL pre/post redaction (the safety property — redaction only
//  promotes a fixture if it doesn't change what the engine sees), while
//  location, identity, and time are broken so the scene can't be re-located
//  via public flight data. Reads a real committed fixture as INPUT only; it
//  is never modified (existing FieldReplays/ fixtures stay as-is per the
//  redact-only-new-promotions decision).
//

import Testing
import Foundation
@testable import Tailspot

private final class RedactionToken {}

@MainActor
@Suite("Replay redaction")
struct ReplayRedactionTests {

    private let t0 = Date(timeIntervalSince1970: 1_715_000_000)

    /// The ANA179 fixture (real icao24 86d5d8) — used as redaction input.
    private let fixtureName = "replay-2026-06-11T161754Z"

    private func loadFixture(_ name: String) throws -> [ReplayEvent] {
        let bundle = Bundle(for: RedactionToken.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "jsonl"),
                               "fixture \(name).jsonl missing from test bundle")
        return try ReplayJSONL.decode(Data(contentsOf: url))
    }

    private func timestamps(_ events: [ReplayEvent]) -> [Date] {
        events.map { e in
            switch e {
            case .sessionStart(let s): return s.timestamp
            case .tick(let t):         return t.timestamp
            case .tapPin(let p):       return p.timestamp
            case .unpin(let u):        return u.timestamp
            case .emptyTap(let t):     return t.timestamp
            }
        }
    }

    // MARK: - Safety property: geometry is invariant

    @Test func redactionPreservesVisibilityAndProjectionExactly() throws {
        let events = try loadFixture(fixtureName)
        let analyzer = ReplayAnalyzer()
        let base = analyzer.analyze(events)
        let red = analyzer.analyze(ReplayRedaction.redact(events))

        #expect(base.ticks.count == red.ticks.count)
        for (b, r) in zip(base.ticks, red.ticks) {
            #expect(b.visibleCount == r.visibleCount)
            #expect(b.aircraft.count == r.aircraft.count)
            // Redaction preserves event + aircraft ordering, so compare by
            // index (the icao24 itself is synthetic).
            for (ba, ra) in zip(b.aircraft, r.aircraft) {
                #expect(ba.isVisible == ra.isVisible)
                switch (ba.screenPosition, ra.screenPosition) {
                case let (p?, q?):
                    #expect(abs(p.x - q.x) < 0.01)
                    #expect(abs(p.y - q.y) < 0.01)
                case (nil, nil):
                    break
                default:
                    Issue.record("screenPosition presence diverged at an aircraft")
                }
            }
        }
    }

    // MARK: - Identity + time broken

    @Test func redactionStripsRealIdentityAndTime() throws {
        let events = try loadFixture(fixtureName)
        let red = ReplayRedaction.redact(events)

        for case .tick(let t) in red {
            for a in t.aircraft {
                #expect(a.icao24 != "86d5d8")          // real ANA179 hardware id gone
                #expect(a.icao24.hasPrefix("RDCT"))    // synthetic
            }
        }
        // Every timestamp rebased onto the 2020 anchor (session is minutes),
        // so nothing reveals the real 2026 capture time.
        let ts = timestamps(red)
        let dayAfterAnchor = ReplayRedaction.timeAnchor.addingTimeInterval(86_400)
        #expect(ts.allSatisfy { $0 >= ReplayRedaction.timeAnchor && $0 < dayAfterAnchor })
    }

    @Test func redactionZeroesAbsoluteLongitude() throws {
        let events = try loadFixture(fixtureName)
        let red = ReplayRedaction.redact(events)
        let firstObsLon = red.lazy.compactMap { e -> Double? in
            if case .tick(let t) = e { return t.sensor.longitude }
            return nil
        }.first
        let lon = try #require(firstObsLon)
        #expect(abs(lon) < 0.5)   // first observer fix shifted to ~0
    }

    // MARK: - Callsign shape preserved

    @Test func redactionPreservesCallsignShape() {
        let ga = ReplayEvent.AircraftSnapshot(
            icao24: "aaa111", callsign: "N12345", originCountry: "United States",
            latitude: 37.87, longitude: -122.27, altitudeMeters: 300,
            velocityMps: 50, trackDeg: 270, onGround: false, positionTimestamp: nil)
        let airliner = ReplayEvent.AircraftSnapshot(
            icao24: "bbb222", callsign: "UAL123", originCountry: "United States",
            latitude: 37.87, longitude: -122.30, altitudeMeters: 3000,
            velocityMps: 200, trackDeg: 90, onGround: false, positionTimestamp: nil)
        let sensor = ReplayEvent.SensorSnapshot(
            latitude: 37.87, longitude: -122.27, altitudeMeters: 40,
            horizontalAccuracyMeters: 5, headingDeg: 270, headingAccuracyDeg: 3,
            pitchRad: .pi / 2, rollRad: 0, yawRad: 0, cameraElevationDeg: 0, zoomFactor: nil)
        let tick = ReplayEvent.Tick(timestamp: t0, sensor: sensor, aircraft: [ga, airliner])

        let red = ReplayRedaction.redact([.tick(tick)])
        guard case .tick(let rt) = red.first else {
            Issue.record("expected a redacted tick"); return
        }
        let rGA = rt.aircraft[0], rAir = rt.aircraft[1]
        // N-number stays a small airframe (half-cap still fires); airline stays not.
        #expect(Aircraft(rGA).isLikelySmallAirframe)
        #expect(!Aircraft(rAir).isLikelySmallAirframe)
        // Real tails are gone.
        #expect(rGA.callsign != "N12345")
        #expect(rAir.callsign != "UAL123")
    }

    // MARK: - Determinism

    @Test func redactionIsDeterministic() throws {
        let events = try loadFixture(fixtureName)
        #expect(ReplayRedaction.redact(events) == ReplayRedaction.redact(events))
    }
}
