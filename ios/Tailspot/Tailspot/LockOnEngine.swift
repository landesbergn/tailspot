//
//  LockOnEngine.swift
//  Tailspot
//
//  State machine for the AR pin interaction. Per the Task 4 redesign,
//  labels for visible planes are now ambient — every visible plane
//  carries its own per-plane label, rendered by the AR overlay
//  independently of this engine. The "lock" concept only applies to
//  an explicit pin: the user taps a plane (or empty sky) to drive
//  state through here. There is no auto-acquire: `update()` never
//  drives idle → locked on its own.
//
//  The engine is intentionally a pure state machine — it doesn't know
//  about SwiftUI or screen geometry. ContentView calls forceLock() on
//  tap, unpin() on tap-empty, and update() each frame with whichever
//  visible plane is closest to the pinned target so the engine can
//  detect the pinned plane leaving the lock zone.
//
//  State transitions (target = the closest icao24, or nil):
//
//    idle           target=*     → idle                 (no auto-acquire)
//    forceLock(X)                → locked(X)            (any state)
//    locked(X)      target=X     → locked(X)
//    locked(X)      target=Y|nil → sticky(X)            (pin lost)
//    sticky(X)      target=X     → locked(X)            (recovered)
//    sticky(X) & age <  stickyDur target≠X → sticky(X)
//    sticky(X) & age >= stickyDur target≠X → idle
//    unpin()                     → idle                 (any state)
//
//  Sticky hold gives the user time to read the label after panning
//  off (compass jitter alone can move the projected position out of
//  the lock zone for a moment).
//

import Foundation
import CoreGraphics
import Combine

@MainActor
final class LockOnEngine: ObservableObject {

    enum State: Equatable {
        case idle
        case locked(targetIcao24: String, lockedAt: Date)
        case sticky(targetIcao24: String, lostAt: Date)

        /// The icao24 of whichever aircraft is currently locked / held.
        /// Nil only when idle.
        var targetIcao24: String? {
            switch self {
            case .idle: return nil
            case .locked(let t, _), .sticky(let t, _): return t
            }
        }

        /// True when actively presenting a lock or holding sticky. Used
        /// by the multi-catch UI to suppress the capture frame while a
        /// pinned-plane flow is in progress so the two don't visually
        /// compete.
        var isLockedOrSticky: Bool {
            switch self {
            case .locked, .sticky: return true
            case .idle: return false
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// How long a lock holds after the closest-target signal drops.
    /// Lets the user read the label even if compass jitter moves the
    /// projected position out of the lock zone briefly.
    var stickyHoldDuration: TimeInterval = 2.0

    /// Drive the state machine one tick forward. Call from the view
    /// at 30+ Hz with the icao24 of whichever visible aircraft is
    /// closest to the pinned target (or nil if none). `now` is
    /// injected for tests.
    ///
    /// This does NOT auto-acquire from idle. `forceLock()` is the only
    /// entry into `.locked`.
    func update(closestTargetIcao24: String?, now: Date = Date()) {
        switch state {
        case .idle:
            // No auto-acquire — the engine only enters locked via
            // forceLock(). update() doesn't drive idle → locked anymore.
            break

        case .locked(let oldIcao, _):
            guard let icao = closestTargetIcao24 else {
                state = .sticky(targetIcao24: oldIcao, lostAt: now)
                return
            }
            if icao != oldIcao {
                // The currently-locked plane is no longer the closest —
                // hold sticky on the old one. The user can tap to re-pin
                // if they want a different target.
                state = .sticky(targetIcao24: oldIcao, lostAt: now)
            }

        case .sticky(let oldIcao, let lostAt):
            if let icao = closestTargetIcao24, icao == oldIcao {
                state = .locked(targetIcao24: icao, lockedAt: now)
            } else if now.timeIntervalSince(lostAt) >= stickyHoldDuration {
                state = .idle
            }
        }
    }

    /// Jump straight to `locked(target)`. Used by tap-to-pin: when the
    /// user explicitly points at a plane, this is the only path into
    /// `.locked`. update() can still walk the state forward from here
    /// on the next tick (e.g., target leaves → sticky).
    func forceLock(targetIcao24: String, now: Date = Date()) {
        state = .locked(targetIcao24: targetIcao24, lockedAt: now)
    }

    /// Clear any active lock/sticky and return to idle. Used by
    /// ContentView when the user taps empty sky while a pin is in
    /// effect.
    func unpin() {
        state = .idle
    }
}

// MARK: - Lock-zone helper

/// Returns the icao24 of the visible aircraft whose projected screen
/// position is closest to a reference point — by default the screen
/// center — provided it falls within `lockZoneRadius` of that point.
/// Nil otherwise.
///
/// Used in two modes by ContentView:
///   - center-driven (default): `at` is nil; the lock follows whatever
///     plane the user is aiming at.
///   - tap-driven: `at` is the tap location; the lock pins to whatever
///     plane the user explicitly pointed at.
///
/// `hfovDeg` / `vfovDeg` should reflect the camera's *effective* FOV —
/// i.e., base FOV / current zoom factor — so the projection math
/// matches what's on screen. `lockZoneRadius` stays in pixels (it's
/// a UI affordance, not an angular tolerance): at high zoom the same
/// 80 px covers a tighter angular wedge, which is exactly right for
/// disambiguating planes that have spread apart on screen.
///
/// Pure function; sits next to the engine because they're co-used.
/// Doesn't know about SwiftUI — takes the inputs the engine needs
/// to call its update().
@MainActor
func closestTargetIcao24(
    in observed: [ObservedAircraft],
    at point: CGPoint? = nil,
    phoneHeadingDeg: Double,
    cameraElevationDeg: Double,
    rollDeg: Double = 0,
    screenSize: CGSize,
    hfovDeg: Double = 56,
    vfovDeg: Double = 72,
    lockZoneRadius: CGFloat = 80
) -> String? {
    let anchor = point ?? CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    // Build the camera basis once and reuse — keeps lock-zone geometry
    // identical to the label projection (same pose, same basis).
    let basis = Geo.cameraBasis(
        headingDeg: phoneHeadingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
    )

    var bestIcao: String? = nil
    var bestDist: CGFloat = .infinity

    for obs in observed where obs.isLikelyVisibleToObserver {
        guard let pos = obs.screenPosition(
            basis: basis,
            in: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        ) else { continue }

        let dx = pos.x - anchor.x
        let dy = pos.y - anchor.y
        let dist = (dx*dx + dy*dy).squareRoot()
        if dist <= lockZoneRadius && dist < bestDist {
            bestDist = dist
            bestIcao = obs.aircraft.icao24
        }
    }

    return bestIcao
}

/// Returns icao24s sorted by distance-to-anchor (ascending) for every
/// visible aircraft whose screen projection lands inside a circular
/// `zoneRadius` around `point` (defaulting to screen center).
///
/// Companion to `closestTargetIcao24` — same geometry, different
/// fan-out. Used by the multi-catch mechanic to find every plane
/// inside a wider "capture frame" centered on the viewfinder.
/// `zoneRadius` is in pixels, not angular degrees, so it scales
/// the same way as `lockZoneRadius` (a UI affordance, not a
/// tolerance).
@MainActor
func icaosInZone(
    in observed: [ObservedAircraft],
    at point: CGPoint? = nil,
    phoneHeadingDeg: Double,
    cameraElevationDeg: Double,
    rollDeg: Double = 0,
    screenSize: CGSize,
    hfovDeg: Double = 56,
    vfovDeg: Double = 72,
    zoneRadius: CGFloat = 180
) -> [String] {
    let anchor = point ?? CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    let basis = Geo.cameraBasis(
        headingDeg: phoneHeadingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
    )

    var hits: [(String, CGFloat)] = []
    for obs in observed where obs.isLikelyVisibleToObserver {
        guard let pos = obs.screenPosition(
            basis: basis,
            in: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        ) else { continue }

        let dx = pos.x - anchor.x
        let dy = pos.y - anchor.y
        let dist = (dx*dx + dy*dy).squareRoot()
        if dist <= zoneRadius {
            hits.append((obs.aircraft.icao24, dist))
        }
    }
    return hits.sorted { $0.1 < $1.1 }.map(\.0)
}
