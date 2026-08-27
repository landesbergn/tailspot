//
//  GuidedCatchTests.swift
//  TailspotTests
//
//  The guided first-catch engine (plan U1): activation seam, retirement
//  latch semantics, target hysteresis, steering math, and the step
//  guard order (Scanning > GoOutside > Calibrate > QuietSky > steps).
//

import Foundation
import Testing
@testable import Tailspot

@Suite("GuidedCatch")
struct GuidedCatchTests {

    private func candidate(
        _ icao: String,
        bearing: Double = 45,
        elevation: Double = 20,
        slant: Double = 5_000
    ) -> GuidedCandidate {
        GuidedCandidate(
            icao24: icao,
            bearingDeg: bearing,
            elevationDeg: elevation,
            slantDistanceMeters: slant,
            displayName: icao.uppercased()
        )
    }

    private func inputs(
        fetched: Bool = true,
        indoors: Bool = false,
        compassBad: Bool = false,
        candidates: [GuidedCandidate] = [],
        current: String? = nil,
        heading: Double? = 0,
        camElevation: Double = 10,
        onScreen: Set<String> = [],
        captureEnabled: Bool = false
    ) -> GuidedCatchInputs {
        GuidedCatchInputs(
            hasFirstADSBResponse: fetched,
            pointedIndoors: indoors,
            compassWarningLatched: compassBad,
            candidates: candidates,
            currentTargetIcao24: current,
            headingDeg: heading,
            cameraElevationDeg: camElevation,
            onScreenIcaos: onScreen,
            captureEnabled: captureEnabled
        )
    }

    // MARK: - Activation (AE1)

    @Test func zeroCatchesActivatesAndAnyCatchDeactivates() {
        #expect(GuidedCatch.isModeActive(catchCount: 0, retired: false))
        #expect(!GuidedCatch.isModeActive(catchCount: 1, retired: false))
        #expect(!GuidedCatch.isModeActive(catchCount: 1_000, retired: false))
    }

    @Test func forcedOverrideActivatesOnAVeteranDevice() {
        // AE1/AE8: the debug override is a synthetic zero-catch INPUT.
        #expect(GuidedCatch.isModeActive(catchCount: 1_000, retired: false, forcedZeroCatches: true))
        #expect(GuidedCatch.isModeActive(catchCount: 1_000, retired: true, forcedZeroCatches: true))
    }

    @Test func keptCatchLatchRetiresAndDiscardReArms() {
        // KTD2/A2: a kept catch sets the latch (even if rows later vanish,
        // the mode stays retired); a discarded catch never set it, so
        // count-back-to-zero re-arms.
        #expect(!GuidedCatch.isModeActive(catchCount: 0, retired: true))
        #expect(GuidedCatch.isModeActive(catchCount: 0, retired: false))
    }

    @Test func debugForcedFlagRoundTrips() throws {
        // AE8 plumbing: the wrench toggle reads back what it wrote, and a
        // fresh defaults domain starts un-forced.
        let suite = "guided-debug-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        #expect(!GuidedCatchDebug.isForced(defaults: defaults))
        GuidedCatchDebug.setForced(true, defaults: defaults)
        #expect(GuidedCatchDebug.isForced(defaults: defaults))
        GuidedCatchDebug.setForced(false, defaults: defaults)
        #expect(!GuidedCatchDebug.isForced(defaults: defaults))
    }

    @Test func retirementLatchPersistsViaDefaults() throws {
        let suite = "guided-catch-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        #expect(!GuidedCatch.isRetired(defaults: defaults))
        GuidedCatch.markRetired(defaults: defaults)
        #expect(GuidedCatch.isRetired(defaults: defaults))
    }

    // MARK: - Guard order

    @Test func scanningBeatsEverythingBeforeFirstResponse() {
        // Never claim a quiet sky before data loads — even indoors with a
        // bad compass, the first response gate wins.
        let d = GuidedCatch.deriveStep(inputs(fetched: false, indoors: true, compassBad: true))
        #expect(d.step == .scanning)
    }

    @Test func goOutsideBeatsCalibrateAndCandidates() {
        let d = GuidedCatch.deriveStep(inputs(
            indoors: true, compassBad: true, candidates: [candidate("abc123")]
        ))
        #expect(d.step == .goOutside)
    }

    @Test func calibrateBeatsCandidatesWhenCompassIsBad() {
        // AE4: no directional steering on a heading the app can't trust.
        let d = GuidedCatch.deriveStep(inputs(compassBad: true, candidates: [candidate("abc123")]))
        #expect(d.step == .calibrate)
    }

    @Test func quietSkyRequiresDataAndNoCandidates() {
        // AE5.
        let d = GuidedCatch.deriveStep(inputs(candidates: []))
        #expect(d.step == .quietSky)
        #expect(d.targetIcao24 == nil)
    }

    // MARK: - Find / Center / Capture (AE2, AE9)

    @Test func offFrameCandidateYieldsFindWithSteering() {
        // AE2: plane behind the user — turn direction, no on-screen label.
        let d = GuidedCatch.deriveStep(inputs(
            candidates: [candidate("abc123", bearing: 180)],
            heading: 0
        ))
        guard case .find(let steer?) = d.step else {
            Issue.record("expected .find with steering, got \(d.step)")
            return
        }
        #expect(steer.isBehind)
        #expect(steer.distanceMeters == 5_000)
        #expect(d.targetIcao24 == "abc123")
    }

    @Test func nilHeadingYieldsFindWithoutSteering() {
        let d = GuidedCatch.deriveStep(inputs(
            candidates: [candidate("abc123")],
            heading: nil
        ))
        guard case .find(let steer) = d.step else {
            Issue.record("expected .find, got \(d.step)")
            return
        }
        #expect(steer == nil)
    }

    @Test func onScreenTargetAdvancesToCenterThenCapture() {
        // AE9: advancement follows projection and enablement, not time.
        let center = GuidedCatch.deriveStep(inputs(
            candidates: [candidate("abc123")],
            onScreen: ["abc123"],
            captureEnabled: false
        ))
        #expect(center.step == .center)

        let capture = GuidedCatch.deriveStep(inputs(
            candidates: [candidate("abc123")],
            onScreen: ["abc123"],
            captureEnabled: true
        ))
        #expect(capture.step == .capture)
    }

    // MARK: - Hysteresis

    @Test func fivePercentCloserChallengerDoesNotStealTheTarget() {
        let held = candidate("held01", slant: 10_000)
        let close = candidate("close1", slant: 9_500)
        let picked = GuidedCatch.pickTarget(current: "held01", candidates: [held, close])
        #expect(picked?.icao24 == "held01")
    }

    @Test func twentyFivePercentCloserChallengerStealsTheTarget() {
        let held = candidate("held01", slant: 10_000)
        let close = candidate("close1", slant: 7_500)
        let picked = GuidedCatch.pickTarget(current: "held01", candidates: [held, close])
        #expect(picked?.icao24 == "close1")
    }

    @Test func departedTargetRepicksNearest() {
        let a = candidate("aaa111", slant: 8_000)
        let b = candidate("bbb222", slant: 6_000)
        let picked = GuidedCatch.pickTarget(current: "gone99", candidates: [a, b])
        #expect(picked?.icao24 == "bbb222")
    }

    // MARK: - Steering math

    @Test func signedDeltaTakesTheShortWayAround() {
        #expect(GuidedCatch.signedDelta(fromDeg: 350, toDeg: 10) == 20)
        #expect(GuidedCatch.signedDelta(fromDeg: 10, toDeg: 350) == -20)
        #expect(GuidedCatch.signedDelta(fromDeg: 0, toDeg: 180) == 180)
    }

    @Test func steeringCarriesElevationDelta() {
        let s = GuidedCatch.steering(
            to: candidate("abc123", bearing: 90, elevation: 35),
            headingDeg: 60,
            cameraElevationDeg: 10
        )
        #expect(s.turnDeg == 30)
        #expect(s.elevationDeltaDeg == 25)
        #expect(!s.isBehind)
    }
}
