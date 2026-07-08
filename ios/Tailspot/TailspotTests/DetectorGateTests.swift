//
//  DetectorGateTests.swift
//  TailspotTests
//
//  L4 detector soft-gate (anti-cheat PR3): the pure verdict over synthetic
//  envelope signals, the expected-footprint math, and the telemetry
//  property builders. Mirrors the LocalSkyGateTests / CatchSizeFloorTests
//  pattern — no camera, no CoreML, just the rules.
//

import Testing
@testable import Tailspot

@Suite("DetectorGate")
struct DetectorGateTests {

    let gate = DetectorGate()

    // Comfortably in-envelope reference signals: a big close plane in
    // daylight (a 34 m narrowbody at 2 km ≈ 121 px on a 4032 px still).
    let daylight = 0.5
    let bigFootprint = 121.0

    // MARK: - Verdict

    @Test func corroborationAlwaysWins() {
        // A real detection outranks envelope reasoning — even signals that
        // say "we shouldn't have seen it" (night, speck) don't demote a hit.
        #expect(gate.verdict(sawPlane: true, expectedFootprintPx: bigFootprint,
                             meanLuminance: daylight) == .corroborated)
        #expect(gate.verdict(sawPlane: true, expectedFootprintPx: 3,
                             meanLuminance: 0.01) == .corroborated)
        #expect(gate.verdict(sawPlane: true, expectedFootprintPx: nil,
                             meanLuminance: nil) == .corroborated)
    }

    @Test func inEnvelopeMissIsSuspicious() {
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: bigFootprint,
                             meanLuminance: daylight) == .noDetection)
        // Exactly at both floors still counts as in-envelope.
        #expect(gate.verdict(
            sawPlane: false,
            expectedFootprintPx: DetectorGate.Thresholds.default.minFootprintPx,
            meanLuminance: DetectorGate.Thresholds.default.minLuminance
        ) == .noDetection)
    }

    @Test func nightIsNeverJudged() {
        // The detector was never validated in the dark; a night catch is
        // legitimate and undetectable — the hard case the doctrine protects.
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: bigFootprint,
                             meanLuminance: 0.05) == .outOfEnvelope)
    }

    @Test func specksAreNeverJudged() {
        // Below the model's resolution floor a miss is expected, not
        // suspicious — that regime belongs to L3.
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: 12,
                             meanLuminance: daylight) == .outOfEnvelope)
    }

    @Test func missingSignalsFailOpen() {
        // No observation / no photo / camera not warmed up → never doubt.
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: nil,
                             meanLuminance: daylight) == .outOfEnvelope)
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: bigFootprint,
                             meanLuminance: nil) == .outOfEnvelope)
    }

    // MARK: - Expected footprint

    @Test func footprintMatchesSmallAngleMath() throws {
        // Narrowbody (34 m) at 2 km through a 56° FOV on a 4032 px still:
        // 0.017 rad / 0.977 rad × 4032 ≈ 70 px per radian-fraction → ~70.1.
        let px = try #require(DetectorGate.expectedFootprintPx(
            wingspanMeters: 34, slantMeters: 2000,
            effectiveHfovDeg: 56, photoWidthPx: 4032
        ))
        #expect(abs(px - (34.0 / 2000.0) / (56.0 * .pi / 180) * 4032) < 0.001)
        #expect(px > 70 && px < 71)
    }

    @Test func zoomNarrowsFovAndGrowsTheFootprint() throws {
        // 2× zoom halves the effective FOV → the same plane covers twice
        // the pixels. The envelope widens exactly when the user helps.
        let at1x = try #require(DetectorGate.expectedFootprintPx(
            wingspanMeters: 34, slantMeters: 8000,
            effectiveHfovDeg: 56, photoWidthPx: 4032
        ))
        let at2x = try #require(DetectorGate.expectedFootprintPx(
            wingspanMeters: 34, slantMeters: 8000,
            effectiveHfovDeg: 28, photoWidthPx: 4032
        ))
        #expect(abs(at2x - at1x * 2) < 0.001)
    }

    @Test func degenerateFootprintInputsYieldNil() {
        // Zero/negative inputs (no observation, degenerate photo) must
        // produce nil — which the verdict treats as out-of-envelope.
        #expect(DetectorGate.expectedFootprintPx(
            wingspanMeters: 0, slantMeters: 2000,
            effectiveHfovDeg: 56, photoWidthPx: 4032) == nil)
        #expect(DetectorGate.expectedFootprintPx(
            wingspanMeters: 34, slantMeters: 0,
            effectiveHfovDeg: 56, photoWidthPx: 4032) == nil)
        #expect(DetectorGate.expectedFootprintPx(
            wingspanMeters: 34, slantMeters: 2000,
            effectiveHfovDeg: 56, photoWidthPx: 0) == nil)
    }

    @Test func johnsCitationIsOutOfEnvelope() throws {
        // The 28.7 km Citation (16 m bizjet) from the NYC session: ~2.3 px
        // at 1× — far below the floor, so L4 correctly leaves it to L3
        // rather than doubting a miss the model could never have hit.
        let px = try #require(DetectorGate.expectedFootprintPx(
            wingspanMeters: 16, slantMeters: 28_700,
            effectiveHfovDeg: 56, photoWidthPx: 4032
        ))
        #expect(px < DetectorGate.Thresholds.default.minFootprintPx)
        #expect(gate.verdict(sawPlane: false, expectedFootprintPx: px,
                             meanLuminance: daylight) == .outOfEnvelope)
    }

    // MARK: - Telemetry builders

    @Test func detectorGatePropertiesCarryTheCalibrationSignals() {
        let p = CatchTelemetry.detectorGateProperties(
            verdict: .noDetection, snapHit: false, liveFix: false,
            expectedFootprintPx: 42.5, meanLuminance: 0.4, enforcing: false
        )
        #expect(p["verdict"]?.jsonValue as? String == "no_detection")
        #expect(p["snap_hit"]?.jsonValue as? Bool == false)
        #expect(p["live_fix"]?.jsonValue as? Bool == false)
        #expect(p["would_flag"]?.jsonValue as? Bool == true)
        #expect(p["enforcing"]?.jsonValue as? Bool == false)
        #expect(p["expected_footprint_px"]?.jsonValue as? Double == 42.5)
        #expect(p["mean_luminance"]?.jsonValue as? Double == 0.4)
    }

    @Test func detectorGatePropertiesOmitAbsentSignals() {
        let p = CatchTelemetry.detectorGateProperties(
            verdict: .outOfEnvelope, snapHit: false, liveFix: true,
            expectedFootprintPx: nil, meanLuminance: nil, enforcing: true
        )
        #expect(p["expected_footprint_px"] == nil)
        #expect(p["mean_luminance"] == nil)
        #expect(p["would_flag"]?.jsonValue as? Bool == false)
    }

    @Test func performedPropertiesCarryTheVerdictOnlyWhenJudged() {
        let judged = CatchTelemetry.performedProperties(
            icao24: "a1b2c3", rarity: "common", aircraftType: "narrow",
            slantKm: 4.2, visualConfirmEnabled: true, visualFixConfidence: nil,
            detectorVerdict: .corroborated
        )
        #expect(judged["detector_verdict"]?.jsonValue as? String == "corroborated")

        // Multi-catch / no-photo rows must read "not judged", not a value.
        let unjudged = CatchTelemetry.performedProperties(
            icao24: "a1b2c3", rarity: "common", aircraftType: "narrow",
            slantKm: 4.2, visualConfirmEnabled: true, visualFixConfidence: nil
        )
        #expect(unjudged["detector_verdict"] == nil)
    }
}
