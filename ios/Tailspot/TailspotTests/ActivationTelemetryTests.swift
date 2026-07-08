//
//  ActivationTelemetryTests.swift
//  TailspotTests
//
//  Activation-funnel telemetry (PLAN §9 #3): the pure builders and the
//  once-per-install latch semantics. Same pattern as CatchTelemetryTests —
//  pin the event vocabulary so a rename can't silently break the PostHog
//  funnel.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("ActivationTelemetry")
struct ActivationTelemetryTests {

    // MARK: - Step naming

    @Test func stepNamesMatchTheShippedFlow() {
        // These strings are the PostHog funnel vocabulary — the dashboard
        // breaks if they drift from the OnboardingFlow step indexes.
        #expect(ActivationTelemetry.stepName(0) == "welcome")
        #expect(ActivationTelemetry.stepName(1) == "permissions")
        #expect(ActivationTelemetry.stepName(2) == "handle")
    }

    @Test func unknownStepsStillReportRatherThanVanish() {
        // A future 4th step (e.g. compass calibration) must show up in the
        // funnel even before anyone names it here.
        #expect(ActivationTelemetry.stepName(3) == "step_3")
    }

    // MARK: - Builders

    @Test func stepViewedCarriesIndexAndName() {
        let p = ActivationTelemetry.stepViewedProperties(step: 1)
        #expect(p["step"]?.jsonValue as? Int == 1)
        #expect(p["step_name"]?.jsonValue as? String == "permissions")
    }

    @Test func permissionOutcomeCarriesPermissionAndGrant() {
        let p = ActivationTelemetry.permissionProperties(permission: "camera", granted: false)
        #expect(p["permission"]?.jsonValue as? String == "camera")
        #expect(p["granted"]?.jsonValue as? Bool == false)
    }

    @Test func completedCarriesClaimResult() {
        let p = ActivationTelemetry.completedProperties(claimResult: "offline_fallback")
        #expect(p["handle_claim"]?.jsonValue as? String == "offline_fallback")
    }

    // MARK: - Once-per-install latches

    private func freshDefaults() throws -> UserDefaults {
        let suite = "activation-telemetry-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func arFirstFrameLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        #expect(!defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
        ActivationTelemetry.fireARFirstFrameOnce(defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
        // Second call must be a no-op (the latch survives) — this runs on
        // the camera frame path, so idempotence is the load-bearing part.
        ActivationTelemetry.fireARFirstFrameOnce(defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.arFirstFrameFiredKey))
    }

    @Test func firstPlaneSeenLatchesAfterOneFire() throws {
        let defaults = try freshDefaults()
        ActivationTelemetry.fireFirstPlaneSeenOnce(visibleCount: 3, defaults: defaults)
        #expect(defaults.bool(forKey: ActivationTelemetry.firstPlaneSeenFiredKey))
    }

    @Test func latchKeysAreDistinctFromEachOtherAndFirstCatch() {
        // Three independent milestones — a shared key would collapse the
        // funnel into one event.
        let keys = [
            ActivationTelemetry.arFirstFrameFiredKey,
            ActivationTelemetry.firstPlaneSeenFiredKey,
            CatchTelemetry.firstCatchFiredKey,
        ]
        #expect(Set(keys).count == keys.count)
    }
}
