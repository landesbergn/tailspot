//
//  LockOnEngineTests.swift
//  TailspotTests
//
//  State-transition tests for the lock-on machine. All dates are
//  injected so the tests are deterministic — no real timers.
//
//  The engine is now a 3-state machine (idle / locked / sticky) with
//  no auto-acquire — `forceLock` is the only way to enter `.locked`.
//  Labels for visible planes are rendered ambiently per-plane by the
//  AR overlay (see Task 5), not driven off engine state.
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
        e.stickyHoldDuration = 2.0
        return e
    }

    @Test func idleStaysIdleWithoutTarget() {
        let e = engine()
        e.update(closestTargetIcao24: nil, now: t0)
        #expect(e.state == .idle)
    }

    @Test func idleStaysIdleEvenWithVisibleTarget() {
        // No auto-acquire: update() does not drive idle → locked.
        // The user must tap to pin (which calls forceLock).
        let e = engine()
        e.update(closestTargetIcao24: "abc", now: t0)
        #expect(e.state == .idle)
    }

    @Test func forceLockMovesIdleToLocked() {
        let e = engine()
        #expect(e.state == .idle)
        e.forceLock(targetIcao24: "abc", now: t0)
        if case .locked(let t, let lockedAt) = e.state {
            #expect(t == "abc")
            #expect(lockedAt == t0)
        } else {
            Issue.record("Expected .locked after forceLock, got \(e.state)")
        }
    }

    @Test func forceLockReplacesPriorLock() {
        // Tap-pinning a different plane mid-flight should hop instantly.
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.forceLock(targetIcao24: "xyz", now: t0.addingTimeInterval(2))
        if case .locked(let icao, _) = e.state {
            #expect(icao == "xyz")
        } else {
            Issue.record("Expected .locked(xyz) after forceLock, got \(e.state)")
        }
    }

    @Test func updateWithNilFromLockedMovesToSticky() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: nil, now: t0)
        if case .sticky(let t, _) = e.state {
            #expect(t == "abc")
        } else {
            Issue.record("Expected .sticky after losing target, got \(e.state)")
        }
    }

    @Test func lockedHoldsWithSameTarget() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: "abc", now: t0.addingTimeInterval(0.1))
        if case .locked(let t, let lockedAt) = e.state {
            #expect(t == "abc")
            // lockedAt is preserved (no re-lock).
            #expect(lockedAt == t0)
        } else {
            Issue.record("Expected .locked(abc) to hold, got \(e.state)")
        }
    }

    @Test func lockedWithDifferentClosestTargetGoesSticky() {
        // The locked plane is no longer the closest — hold sticky on
        // the original pin. The user can tap to re-pin if they want
        // a different target.
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        let lostTime = t0.addingTimeInterval(0.5)
        e.update(closestTargetIcao24: "xyz", now: lostTime)
        if case .sticky(let t, let lostAt) = e.state {
            #expect(t == "abc")
            #expect(lostAt == lostTime)
        } else {
            Issue.record("Expected .sticky(abc) when a different plane is closest, got \(e.state)")
        }
    }

    @Test func stickyExpiresToIdleAfterDuration() {
        let e = engine()
        e.stickyHoldDuration = 0.1
        e.forceLock(targetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: nil, now: t0)
        e.update(closestTargetIcao24: nil, now: t0.addingTimeInterval(0.2))
        #expect(e.state == .idle)
    }

    @Test func stickyHoldsBeforeDurationElapses() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        let lostTime = t0.addingTimeInterval(0.1)
        e.update(closestTargetIcao24: nil, now: lostTime)
        // Before hold expires: still sticky.
        e.update(closestTargetIcao24: nil, now: lostTime.addingTimeInterval(1.0))
        if case .sticky(let t, _) = e.state {
            #expect(t == "abc")
        } else {
            Issue.record("Expected .sticky to hold before duration, got \(e.state)")
        }
    }

    @Test func stickyRecoversToLockedOnSameTarget() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: nil, now: t0)
        let recoverTime = t0.addingTimeInterval(0.5)
        e.update(closestTargetIcao24: "abc", now: recoverTime)
        if case .locked(let t, let lockedAt) = e.state {
            #expect(t == "abc")
            #expect(lockedAt == recoverTime)
        } else {
            Issue.record("Expected .locked after sticky recovery, got \(e.state)")
        }
    }

    @Test func stickyIgnoresDifferentTargets() {
        // While sticky-holding "abc", a different closest plane should
        // not steal the lock — only the original target can recover it,
        // or the hold expires to idle. (User can tap-pin if they want
        // a new target.)
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        let lostTime = t0.addingTimeInterval(0.1)
        e.update(closestTargetIcao24: nil, now: lostTime)
        e.update(closestTargetIcao24: "xyz", now: lostTime.addingTimeInterval(0.5))
        // Still sticky on abc.
        if case .sticky(let t, _) = e.state {
            #expect(t == "abc")
        } else {
            Issue.record("Expected .sticky(abc) to stay when a different plane appears, got \(e.state)")
        }
    }

    @Test func unpinClearsActiveLock() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.unpin()
        #expect(e.state == .idle)
    }

    @Test func unpinClearsSticky() {
        let e = engine()
        e.forceLock(targetIcao24: "abc", now: t0)
        e.update(closestTargetIcao24: nil, now: t0)
        e.unpin()
        #expect(e.state == .idle)
    }

    @Test func isLockedOrStickyReflectsState() {
        let e = engine()
        #expect(e.state.isLockedOrSticky == false)
        e.forceLock(targetIcao24: "abc", now: t0)
        #expect(e.state.isLockedOrSticky == true)
        e.update(closestTargetIcao24: nil, now: t0)
        #expect(e.state.isLockedOrSticky == true) // sticky
        e.unpin()
        #expect(e.state.isLockedOrSticky == false)
    }

    @Test func targetIcao24ReflectsState() {
        let e = engine()
        #expect(e.state.targetIcao24 == nil)
        e.forceLock(targetIcao24: "abc", now: t0)
        #expect(e.state.targetIcao24 == "abc")
        e.update(closestTargetIcao24: nil, now: t0)
        #expect(e.state.targetIcao24 == "abc") // sticky still carries it
    }
}
