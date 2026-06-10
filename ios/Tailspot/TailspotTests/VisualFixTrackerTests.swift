//
//  VisualFixTrackerTests.swift
//  TailspotTests
//
//  The association rules from tools/visual-confirmation/SWIFT-DESIGN.md:
//  gate, confidence ranking, first-acquisition snap, EMA convergence,
//  miss budget, expiry, and state retention.
//

import CoreGraphics
import Foundation
import Testing
@testable import Tailspot

@Suite("VisualFixTracker")
struct VisualFixTrackerTests {

    private func det(x: CGFloat, y: CGFloat, conf: Float) -> Detection {
        // 40×40 box centered on (x, y).
        .init(rect: CGRect(x: x - 20, y: y - 20, width: 40, height: 40), confidence: conf)
    }

    private let predicted = CGPoint(x: 200, y: 300)

    @Test func firstAcquisitionSnapsToDetectionImmediately() {
        var tracker = VisualFixTracker(gateRadius: 150)
        let fix = tracker.ingest(
            icao24: "abc123",
            detections: [det(x: 260, y: 280, conf: 0.9)],
            predicted: predicted
        )
        // No ease-in from zero: the very first fix sits ON the detection.
        #expect(fix?.screenPoint == CGPoint(x: 260, y: 280))
        #expect(fix?.confidence == 0.9)
    }

    @Test func detectionOutsideGateIsRejected() {
        var tracker = VisualFixTracker(gateRadius: 50)
        let fix = tracker.ingest(
            icao24: "abc123",
            detections: [det(x: 400, y: 300, conf: 0.95)], // 200 pt away
            predicted: predicted
        )
        #expect(fix == nil)
        #expect(!tracker.hasFix(for: "abc123"))
    }

    @Test func highestConfidenceWinsOverNearest() {
        var tracker = VisualFixTracker(gateRadius: 150)
        let fix = tracker.ingest(
            icao24: "abc123",
            detections: [
                det(x: 210, y: 300, conf: 0.40), // nearest
                det(x: 300, y: 320, conf: 0.90), // strongest
            ],
            predicted: predicted
        )
        #expect(fix?.screenPoint == CGPoint(x: 300, y: 320))
    }

    @Test func emaSmoothsSubsequentSamples() {
        var tracker = VisualFixTracker(gateRadius: 150)
        // Acquire at offset (+60, 0)…
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        // …then a jittery sample at offset (+80, 0). EMA(0.4): 60 + 0.4·20 = 68.
        let fix = tracker.ingest(
            icao24: "abc123",
            detections: [det(x: 280, y: 300, conf: 0.9)],
            predicted: predicted
        )
        #expect(fix != nil)
        if let p = fix?.screenPoint {
            #expect(abs(p.x - 268) < 0.001)
            #expect(p.y == 300)
        }
    }

    @Test func offsetTracksAMovingPrediction() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        // Plane + prediction both moved 100 pt right; offset stays +60.
        let moved = CGPoint(x: 300, y: 300)
        let fix = tracker.fix(for: "abc123", predicted: moved)
        #expect(fix?.screenPoint == CGPoint(x: 360, y: 300))
    }

    @Test func missesInsideBudgetKeepServingLastGoodOffset() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        var fix: VisualFix?
        for _ in 1...7 { // maxMisses is 8 — stay inside the budget
            fix = tracker.ingest(icao24: "abc123", detections: [], predicted: predicted)
        }
        #expect(fix?.screenPoint == CGPoint(x: 260, y: 300))
        #expect(tracker.hasFix(for: "abc123"))
    }

    @Test func fixExpiresAfterMaxConsecutiveMisses() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        var fix: VisualFix?
        for _ in 1...8 {
            fix = tracker.ingest(icao24: "abc123", detections: [], predicted: predicted)
        }
        #expect(fix == nil)
        #expect(!tracker.hasFix(for: "abc123"))
    }

    @Test func aHitResetsTheMissCounter() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        for _ in 1...7 {
            tracker.ingest(icao24: "abc123", detections: [], predicted: predicted)
        }
        tracker.ingest(icao24: "abc123", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        for _ in 1...7 { // 7 more misses — budget was reset by the hit
            tracker.ingest(icao24: "abc123", detections: [], predicted: predicted)
        }
        #expect(tracker.hasFix(for: "abc123"))
    }

    @Test func missesNeverCreateAFixFromNothing() {
        var tracker = VisualFixTracker(gateRadius: 150)
        let fix = tracker.ingest(icao24: "abc123", detections: [], predicted: predicted)
        #expect(fix == nil)
    }

    @Test func retainDropsUntrackedAircraft() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "aaa111", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        tracker.ingest(icao24: "bbb222", detections: [det(x: 180, y: 290, conf: 0.8)], predicted: predicted)
        tracker.retain(only: ["bbb222"])
        #expect(!tracker.hasFix(for: "aaa111"))
        #expect(tracker.hasFix(for: "bbb222"))
    }

    @Test func independentAircraftKeepIndependentOffsets() {
        var tracker = VisualFixTracker(gateRadius: 150)
        tracker.ingest(icao24: "aaa111", detections: [det(x: 260, y: 300, conf: 0.9)], predicted: predicted)
        tracker.ingest(icao24: "bbb222", detections: [det(x: 150, y: 250, conf: 0.8)], predicted: predicted)
        #expect(tracker.fix(for: "aaa111", predicted: predicted)?.screenPoint == CGPoint(x: 260, y: 300))
        #expect(tracker.fix(for: "bbb222", predicted: predicted)?.screenPoint == CGPoint(x: 150, y: 250))
    }
}
