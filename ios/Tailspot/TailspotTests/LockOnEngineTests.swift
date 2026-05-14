//
//  LockOnEngineTests.swift
//  TailspotTests
//
//  State-transition tests for the lock-on machine. All dates are
//  injected so the tests are deterministic — no real timers.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("LockOnEngine state machine")
@MainActor
struct LockOnEngineTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func engine() -> LockOnEngine {
        let e = LockOnEngine()
        e.acquisitionDuration = 0.6
        e.stickyHoldDuration = 2.0
        return e
    }

    @Test func idleStaysIdleWithoutTarget() {
        let e = engine()
        e.update(closestTargetIcao24: nil, now: t0)
        #expect(e.state == .idle)
    }

    @Test func idleEntersAcquiringWhenTargetAppears() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        #expect(e.state == .acquiring(targetIcao24: "abc", startedAt: t0))
    }

    @Test func acquiringSameTargetBeforeDurationStaysAcquiring() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: "abc", now: t0.addingTimeInterval(0.3))
        // startedAt is preserved
        #expect(e.state == .acquiring(targetIcao24: "abc", startedAt: t0))
    }

    @Test func acquiringSameTargetAfterDurationSnapsToLocked() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        #expect(e.state == .locked(targetIcao24: "abc", lockedAt: lockTime))
    }

    @Test func acquiringDifferentTargetRestartsAcquisition() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let switchTime = t0.addingTimeInterval(0.4)
        e.update(closestTargetIcao24: "xyz", now: switchTime)
        #expect(e.state == .acquiring(targetIcao24: "xyz", startedAt: switchTime))
    }

    @Test func acquiringLostTargetReturnsToIdle() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: nil, now: t0.addingTimeInterval(0.2))
        #expect(e.state == .idle)
    }

    @Test func lockedStaysLockedWithSameTarget() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        // Now locked. Another update with same target should stay.
        e.update(closestTargetIcao24: "abc", now: lockTime.addingTimeInterval(0.1))
        #expect(e.state == .locked(targetIcao24: "abc", lockedAt: lockTime))
    }

    @Test func lockedDifferentTargetRestartsAcquisition() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        let switchTime = lockTime.addingTimeInterval(0.5)
        e.update(closestTargetIcao24: "xyz", now: switchTime)
        #expect(e.state == .acquiring(targetIcao24: "xyz", startedAt: switchTime))
    }

    @Test func lockedLostTargetGoesSticky() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        let lostTime = lockTime.addingTimeInterval(0.5)
        e.update(closestTargetIcao24: nil, now: lostTime)
        #expect(e.state == .sticky(targetIcao24: "abc", lostAt: lostTime))
    }

    @Test func stickyRecoveredTargetReturnsToLocked() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        e.update(closestTargetIcao24: nil, now: lockTime.addingTimeInterval(0.5))
        // Recover
        let recoverTime = lockTime.addingTimeInterval(1.0)
        e.update(closestTargetIcao24: "abc", now: recoverTime)
        #expect(e.state == .locked(targetIcao24: "abc", lockedAt: recoverTime))
    }

    @Test func stickyDifferentTargetRestartsAcquisition() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        e.update(closestTargetIcao24: nil, now: lockTime.addingTimeInterval(0.5))
        let switchTime = lockTime.addingTimeInterval(1.0)
        e.update(closestTargetIcao24: "xyz", now: switchTime)
        #expect(e.state == .acquiring(targetIcao24: "xyz", startedAt: switchTime))
    }

    @Test func stickyDecaysToIdleAfterHoldDuration() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        let lockTime = t0.addingTimeInterval(0.7)
        e.update(closestTargetIcao24: "abc", now: lockTime)
        let lostTime = lockTime.addingTimeInterval(0.5)
        e.update(closestTargetIcao24: nil, now: lostTime)
        // Before hold: still sticky
        e.update(closestTargetIcao24: nil, now: lostTime.addingTimeInterval(1.5))
        #expect(e.state == .sticky(targetIcao24: "abc", lostAt: lostTime))
        // After hold: idle
        e.update(closestTargetIcao24: nil, now: lostTime.addingTimeInterval(2.5))
        #expect(e.state == .idle)
    }

    @Test func acquisitionProgressIsZeroOutsideAcquiring() {
        let e = engine()
        #expect(e.acquisitionProgress() == 0)
        e.update(closestTargetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: "abc", now: t0.addingTimeInterval(0.7))
        // Now locked
        #expect(e.acquisitionProgress(now: t0.addingTimeInterval(1.0)) == 0)
    }

    @Test func acquisitionProgressRampsZeroToOne() {
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        #expect(e.acquisitionProgress(now: t0) == 0)
        // Midway. abs() guard around float jitter from 0.3 / 0.6.
        let mid = e.acquisitionProgress(now: t0.addingTimeInterval(0.3))
        #expect(abs(mid - 0.5) < 0.001)
        // Caps at 1
        #expect(e.acquisitionProgress(now: t0.addingTimeInterval(10)) == 1)
    }
}
