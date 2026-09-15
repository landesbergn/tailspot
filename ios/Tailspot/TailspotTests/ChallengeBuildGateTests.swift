//
//  ChallengeBuildGateTests.swift
//  TailspotTests
//
//  All four ChallengeBuildGate.Verdict cases (spec section 11.2's table:
//  available, disabled by the kill switch, update-required below
//  minBuild, and unknown before the config has been fetched).
//

import Testing
@testable import Tailspot

@Suite("Challenge build gate")
struct ChallengeBuildGateTests {

    private func config(enabled: Bool, minBuild: Int) -> ChallengesConfig {
        ChallengesConfig(enabled: enabled, availability: "public", minBuild: minBuild, appStoreURL: nil)
    }

    @Test func noConfigIsUnknown() {
        #expect(ChallengeBuildGate.verdict(config: nil, currentBuild: 100) == .unknown)
    }

    @Test func disabledFlagBeatsEverythingElse() {
        let c = config(enabled: false, minBuild: 1)
        #expect(ChallengeBuildGate.verdict(config: c, currentBuild: 999) == .disabled)
    }

    @Test func belowMinBuildIsUpdateRequired() {
        let c = config(enabled: true, minBuild: 95)
        #expect(ChallengeBuildGate.verdict(config: c, currentBuild: 90) == .updateRequired(minBuild: 95))
    }

    @Test func atOrAboveMinBuildIsAvailable() {
        let c = config(enabled: true, minBuild: 95)
        #expect(ChallengeBuildGate.verdict(config: c, currentBuild: 95) == .available)
        #expect(ChallengeBuildGate.verdict(config: c, currentBuild: 200) == .available)
    }
}
