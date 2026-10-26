//
//  CatchModeTests.swift
//  TailspotTests
//
//  The catch-rule feature flag (2026-10-25): the PostHog flag picks the
//  mode, the shipped rule is the default, and the Debug wrench override
//  wins only on DEBUG builds. `resolve(…, honorOverride:)` is the pure
//  rule, so the Release half (override ignored) is testable here even
//  though the test target itself builds DEBUG.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch rule flag")
struct CatchModeTests {

    @Test func flagOffOrUnknownRunsTheShippedRule() {
        #expect(CatchMode.default == .legacy)
        #expect(CatchMode.fromRemote(enabled: false) == .legacy)
        #expect(CatchMode.resolve(override: nil, remoteEnabled: false, honorOverride: true) == .legacy)
    }

    @Test func flagOnRunsTheFrameRule() {
        #expect(CatchMode.fromRemote(enabled: true) == .frame)
        #expect(CatchMode.resolve(override: nil, remoteEnabled: true, honorOverride: false) == .frame)
    }

    @Test func debugOverrideBeatsTheFlag() {
        #expect(CatchMode.resolve(override: "legacy", remoteEnabled: true, honorOverride: true) == .legacy)
        #expect(CatchMode.resolve(override: "frame", remoteEnabled: false, honorOverride: true) == .frame)
    }

    @Test func releaseIgnoresTheOverride() {
        // A flipped Debug phone must not leak into a TestFlight / App Store
        // install that shares the defaults container.
        #expect(CatchMode.resolve(override: "frame", remoteEnabled: false, honorOverride: false) == .legacy)
        #expect(CatchMode.resolve(override: "legacy", remoteEnabled: true, honorOverride: false) == .frame)
    }

    @Test func unknownOverrideFollowsTheFlag() {
        #expect(CatchMode.override(stored: "zones-and-pins") == nil)
        #expect(CatchMode.override(stored: "") == nil)
        #expect(CatchMode.resolve(override: "zones-and-pins", remoteEnabled: true, honorOverride: true) == .frame)
    }

    @Test func debugBuildsHonorTheOverride() {
        // The test target is a DEBUG build.
        #expect(CatchMode.effective(override: "legacy", remoteEnabled: true) == .legacy)
        #expect(CatchMode.effective(override: nil, remoteEnabled: true) == .frame)
        #expect(CatchMode.effective(override: nil, remoteEnabled: false) == .legacy)
    }

    @Test func labelsAreDistinct() {
        #expect(Set(CatchMode.allCases.map(\.label)).count == CatchMode.allCases.count)
    }

    @Test func keysAreStable() {
        // The PostHog flag key is configured server-side; renaming it here
        // silently turns the new rule off for everyone.
        #expect(CatchMode.remoteFlagKey == "frame-is-the-catch")
        #expect(CatchMode.storageKey.hasPrefix("tailspot.debug."))
    }
}

@MainActor
@Suite("Catch rule flag holder")
struct CatchModeFlagTests {

    /// Fake PostHog: a settable flag value plus captured reload callbacks.
    final class FakeRemote {
        var value = false
        var pendingReloads: [() -> Void] = []
    }

    private func makeFlag(_ remote: FakeRemote) -> CatchModeFlag {
        CatchModeFlag(
            read: { remote.value },
            reload: { remote.pendingReloads.append($0) }
        )
    }

    @Test func readsTheCachedValueAtLaunch() {
        let remote = FakeRemote()
        remote.value = true
        #expect(makeFlag(remote).remoteEnabled == true)
    }

    @Test func coldLaunchAlsoFetchesFresh() async {
        let remote = FakeRemote()
        let flag = makeFlag(remote)
        #expect(remote.pendingReloads.count == 1)
        remote.value = true
        remote.pendingReloads.removeFirst()()
        // The callback hops to the main actor; let it run.
        await Task.yield()
        await Task.yield()
        #expect(flag.remoteEnabled == true)
    }

    @Test func aFlipBetweenRefreshesIsNotAppliedUntilTheNextSession() {
        let remote = FakeRemote()
        let flag = makeFlag(remote)
        remote.value = true
        // No refresh yet: mid-session the rule holds still.
        #expect(flag.remoteEnabled == false)
        flag.refreshForNewSession()
        #expect(flag.remoteEnabled == true)
    }
}
