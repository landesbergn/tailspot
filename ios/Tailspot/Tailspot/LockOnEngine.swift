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

// MARK: - Plausibility-weighted catch target (2026-07-13)
//
// The catch bug behind this: target selection ranked candidates by SCREEN
// distance to the crosshair alone, with zero preference for the closer / lower
// / larger plane. In dense airspace under a poor compass that bagged a 12.9 km
// cruise A319 (nearly overhead) instead of the closer, lower plane the user was
// aiming at (NYC field mis-catch, 2026-07-13). These pure helpers add two
// things, both validated by an offline spike over the replay corpus:
//   1. dominantAimTarget — when one in-zone plane is far more visually
//      prominent than the rest, catch just it (single) instead of multi-bagging
//      the cluster. Reduces to the old behavior in sparse sky (~1% of ticks
//      changed in the corpus, always toward the closer/bigger plane).
//   2. aimConfidence — a post-catch (never blocking) flag for a center catch
//      that is off-crosshair AND small AND made under a poor compass: the
//      hallmark of "wrong plane," surfaced as a Keep/Discard question.

/// One in-zone catch candidate with the geometry the plausibility layer needs
/// — a superset of `icaosInZone` membership carrying the fields selection and
/// the aim-confidence flag consume.
nonisolated struct CatchCandidate: Equatable, Sendable {
    let icao24: String
    let offsetDeg: Double        // angular separation from the crosshair (bore-sight)
    let offsetPx: CGFloat        // screen-pixel separation (what zone membership uses)
    let arcmin: Double           // apparent angular size
    let slantMeters: Double
}

/// In-zone visible planes with full geometry, sorted by pixel offset — the
/// same membership as `icaosInZone`, carrying the angular offset + apparent
/// size the plausibility selection and the aim-confidence flag need.
@MainActor
func catchCandidates(
    in observed: [ObservedAircraft],
    at point: CGPoint? = nil,
    phoneHeadingDeg: Double,
    cameraElevationDeg: Double,
    rollDeg: Double = 0,
    screenSize: CGSize,
    hfovDeg: Double = 56,
    vfovDeg: Double = 72,
    zoneRadius: CGFloat = 100
) -> [CatchCandidate] {
    let anchor = point ?? CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    let basis = Geo.cameraBasis(
        headingDeg: phoneHeadingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
    )
    var out: [CatchCandidate] = []
    for obs in observed where obs.isLikelyVisibleToObserver {
        guard let pos = obs.screenPosition(
            basis: basis, in: screenSize, hfovDeg: hfovDeg, vfovDeg: vfovDeg
        ) else { continue }
        let dx = pos.x - anchor.x, dy = pos.y - anchor.y
        let px = (dx*dx + dy*dy).squareRoot()
        guard px <= zoneRadius else { continue }
        let v = Geo.cameraFrameVector(
            targetBearingDeg: obs.bearingDeg, targetElevationDeg: obs.elevationDeg, basis: basis
        )
        let offDeg = v.z <= 0 ? 180.0 : atan2((v.x*v.x + v.y*v.y).squareRoot(), v.z) * 180 / .pi
        out.append(CatchCandidate(
            icao24: obs.aircraft.icao24, offsetDeg: offDeg, offsetPx: px,
            arcmin: obs.apparentSizeArcminutes, slantMeters: obs.slantDistanceMeters
        ))
    }
    return out.sorted { $0.offsetPx < $1.offsetPx }
}

/// σ (degrees) for the crosshair proximity term, clamped from the logged
/// compass accuracy. A trusted compass (small σ) makes centrality decisive
/// (≈ nearest-crosshair); a poor one widens tolerance so prominence can break
/// the tie — which is exactly when nearest-crosshair picks the wrong plane.
nonisolated func aimSigmaDeg(_ headingAccuracyDeg: Double?) -> Double {
    let acc = headingAccuracyDeg ?? 8
    return min(max(acc < 0 ? 8 : acc, 4), 25)
}

/// Prominence score for choosing the single dominant target: crosshair
/// proximity (compass-scaled) × apparent size. Size enters multiplicatively so
/// a big close plane can outrank a smaller one slightly nearer the crosshair
/// when the compass is unreliable.
nonisolated func aimProminence(offsetDeg: Double, arcmin: Double, headingAccuracyDeg: Double?) -> Double {
    let sigma = aimSigmaDeg(headingAccuracyDeg)
    return exp(-(offsetDeg*offsetDeg) / (2*sigma*sigma)) * max(arcmin, 0)
}

/// The single in-zone plane whose aim-prominence dominates the runner-up by at
/// least `dominanceRatio`, else nil — nil means "no clear winner," so the
/// caller keeps the existing single/multi logic (a genuine formation/approach
/// pair of comparable planes still multi-catches). Empty or one-element inputs
/// return nil too (the one-candidate case is already `.single`).
nonisolated func dominantAimTarget(
    _ candidates: [CatchCandidate],
    headingAccuracyDeg: Double?,
    dominanceRatio: Double = 2.5
) -> String? {
    guard candidates.count >= 2 else { return nil }
    let scored = candidates
        .map { ($0.icao24, aimProminence(offsetDeg: $0.offsetDeg, arcmin: $0.arcmin, headingAccuracyDeg: headingAccuracyDeg)) }
        .sorted { $0.1 > $1.1 }
    let (topIcao, top) = scored[0]
    let runnerUp = scored[1].1
    guard top > 0, runnerUp <= 0 || top / runnerUp >= dominanceRatio else { return nil }
    return topIcao
}

/// Confidence (0…1) that a center (non-tapped) catch is the plane the user
/// meant — LOW when the compass is untrusted, the target sits off the
/// crosshair, or it's too small to resolve. Unlike `aimProminence`, the
/// crosshair tolerance here is FIXED (`reticleToleranceDeg`) and a poor compass
/// lowers confidence outright (`compassTrust`), because for the flag an
/// unreliable reticle makes *any* center catch less certain. Drives the
/// post-catch `uncertainAim` question; an explicit tap is exempt.
nonisolated func aimConfidence(
    offsetDeg: Double,
    arcmin: Double,
    headingAccuracyDeg: Double?,
    goodAccuracyDeg: Double = 15,
    reticleToleranceDeg: Double = 7
) -> Double {
    let acc = headingAccuracyDeg ?? goodAccuracyDeg
    let compassTrust = acc < 0 ? 0.5 : min(1.0, goodAccuracyDeg / max(acc, 1))
    let centrality = exp(-(offsetDeg*offsetDeg) / (2*reticleToleranceDeg*reticleToleranceDeg))
    let resolv = min(1.0, max(arcmin, 0) / 10.0)   // saturate at ~10′ (clearly resolved)
    return compassTrust * centrality * (0.4 + 0.6 * resolv)
}
