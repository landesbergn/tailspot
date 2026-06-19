//
//  ReplayDiagnosisTests.swift
//  TailspotTests
//
//  Verifies FailureModeReport.diagnose() — the Claude-readable summary —
//  localizes failures (mode, tick, icao, delta) and stays deterministic.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Replay diagnosis")
@MainActor
struct ReplayDiagnosisTests {

    private let t0 = Date(timeIntervalSince1970: 1_715_000_000)

    @Test func cleanReportSaysNoFailures() {
        let report = FailureModeReport(findings: [])
        #expect(report.diagnose() == "No failure modes scored.")
    }

    @Test func diagnosisNamesEveryModeWithLocatingDetail() {
        let report = FailureModeReport(findings: [
            .init(mode: .spatialOffset, tickIndex: 5, timestamp: t0,
                  icao24: "abc123", detail: "120 px off pin"),
            .init(mode: .misAssociation, tickIndex: 5, timestamp: t0,
                  icao24: "bbb222", detail: "center-pick bbb222, expected aaa111"),
        ])
        let s = report.diagnose()
        // Both modes named.
        #expect(s.contains("spatialOffset"))
        #expect(s.contains("misAssociation"))
        // The locating detail for each: tick index, plane, delta.
        #expect(s.contains("t#5"))
        #expect(s.contains("abc123"))
        #expect(s.contains("120 px off pin"))
        #expect(s.contains("bbb222"))
        #expect(s.contains("expected aaa111"))
    }

    @Test func diagnosisIsDeterministic() {
        let report = FailureModeReport(findings: [
            .init(mode: .missedPlane, tickIndex: 2, timestamp: t0, icao24: "x1", detail: "not visible"),
            .init(mode: .spatialOffset, tickIndex: 3, timestamp: t0, icao24: "x1", detail: "90 px off pin"),
        ])
        #expect(report.diagnose() == report.diagnose())
    }

    @Test func nilIcaoRendersDash() {
        let report = FailureModeReport(findings: [
            .init(mode: .phantomCapture, tickIndex: 1, timestamp: t0, icao24: nil, detail: "no plane"),
        ])
        #expect(report.diagnose().contains("t#1  —  no plane"))
    }
}
