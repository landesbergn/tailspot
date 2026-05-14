//
//  LockOnEngine.swift
//  Tailspot
//
//  State machine for the AR lock-on interaction. The AR view defaults
//  to a clean sky with a tiny center crosshair — labels don't appear
//  automatically. The user aims at a plane; after a brief acquisition
//  window the engine "locks on" and the view renders identifying info
//  for that one plane. Inspired by HUD lock-on affordances in
//  fighter-jet sims (think Top Gun).
//
//  The engine is intentionally a pure state machine — it doesn't know
//  about SwiftUI or screen geometry. The view computes "what's the
//  closest visible plane to screen center" each frame and feeds it in
//  via update(closestTargetIcao24:now:). The state transitions are
//  testable without any UI scaffolding.
//
//  State transitions (target = the closest icao24, or nil):
//
//    idle           target=nil   → idle
//    idle           target=X     → acquiring(X)
//    acquiring(X)   target=X & age >= acqDur  → locked(X)
//    acquiring(X)   target=X & age <  acqDur  → acquiring(X)
//    acquiring(X)   target=Y     → acquiring(Y)        (restart)
//    acquiring(X)   target=nil   → idle                (acq cancelled)
//    locked(X)      target=X     → locked(X)
//    locked(X)      target=Y     → acquiring(Y)        (new target)
//    locked(X)      target=nil   → sticky(X)           (grace period)
//    sticky(X)      target=X     → locked(X)           (recovered)
//    sticky(X)      target=Y     → acquiring(Y)
//    sticky(X) & age <  stickyDur target=nil → sticky(X)
//    sticky(X) & age >= stickyDur target=nil → idle
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
        case acquiring(targetIcao24: String, startedAt: Date)
        case locked(targetIcao24: String, lockedAt: Date)
        case sticky(targetIcao24: String, lostAt: Date)

        /// The icao24 of whichever aircraft the engine is currently
        /// thinking about. Nil only when idle.
        var targetIcao24: String? {
            switch self {
            case .idle: return nil
            case .acquiring(let t, _), .locked(let t, _), .sticky(let t, _): return t
            }
        }
    }

    @Published private(set) var state: State = .idle

    /// How long acquisition runs before the lock snaps to `locked`.
    var acquisitionDuration: TimeInterval = 0.6
    /// How long a lock holds after the closest-target signal drops.
    /// Lets the user read the label even if compass jitter moves the
    /// projected position out of the lock zone briefly.
    var stickyHoldDuration: TimeInterval = 2.0

    /// Drive the state machine one tick forward. Call from the view
    /// at 30+ Hz with the icao24 of whichever visible aircraft is
    /// closest to screen center (within the lock-zone radius), or
    /// nil if no plane is in the zone. `now` is injected for tests.
    func update(closestTargetIcao24: String?, now: Date = Date()) {
        switch state {
        case .idle:
            if let icao = closestTargetIcao24 {
                state = .acquiring(targetIcao24: icao, startedAt: now)
            }

        case .acquiring(let oldIcao, let startedAt):
            guard let icao = closestTargetIcao24 else {
                state = .idle
                return
            }
            if icao == oldIcao {
                if now.timeIntervalSince(startedAt) >= acquisitionDuration {
                    state = .locked(targetIcao24: icao, lockedAt: now)
                }
                // else: keep acquiring
            } else {
                state = .acquiring(targetIcao24: icao, startedAt: now)
            }

        case .locked(let oldIcao, _):
            guard let icao = closestTargetIcao24 else {
                state = .sticky(targetIcao24: oldIcao, lostAt: now)
                return
            }
            if icao != oldIcao {
                state = .acquiring(targetIcao24: icao, startedAt: now)
            }
            // else: stay locked

        case .sticky(let oldIcao, let lostAt):
            guard let icao = closestTargetIcao24 else {
                if now.timeIntervalSince(lostAt) >= stickyHoldDuration {
                    state = .idle
                }
                return
            }
            if icao == oldIcao {
                state = .locked(targetIcao24: icao, lockedAt: now)
            } else {
                state = .acquiring(targetIcao24: icao, startedAt: now)
            }
        }
    }

    /// Progress through acquisition, 0..1. Useful for animation —
    /// the corner brackets ease from 0 (large/faint) to 1 (small/solid)
    /// over `acquisitionDuration`. Returns 0 unless in `.acquiring`.
    func acquisitionProgress(now: Date = Date()) -> Double {
        if case .acquiring(_, let startedAt) = state {
            let elapsed = now.timeIntervalSince(startedAt)
            return min(1, max(0, elapsed / acquisitionDuration))
        }
        return 0
    }
}

// MARK: - Lock-zone helper

/// Returns the icao24 of the visible aircraft whose projected screen
/// position is closest to screen center, provided it falls within
/// `lockZoneRadius` of center. Nil otherwise.
///
/// Pure function; sits next to the engine because they're co-used.
/// Doesn't know about SwiftUI — takes the inputs the engine needs
/// to call its update().
@MainActor
func closestTargetIcao24(
    in observed: [ObservedAircraft],
    phoneHeadingDeg: Double,
    cameraElevationDeg: Double,
    screenSize: CGSize,
    lockZoneRadius: CGFloat = 80
) -> String? {
    let centerX = screenSize.width / 2
    let centerY = screenSize.height / 2

    var bestIcao: String? = nil
    var bestDist: CGFloat = .infinity

    for obs in observed where obs.isLikelyVisibleToObserver {
        guard let pos = obs.screenPosition(
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            in: screenSize
        ) else { continue }

        let dx = pos.x - centerX
        let dy = pos.y - centerY
        let dist = (dx*dx + dy*dy).squareRoot()
        if dist <= lockZoneRadius && dist < bestDist {
            bestDist = dist
            bestIcao = obs.aircraft.icao24
        }
    }

    return bestIcao
}
