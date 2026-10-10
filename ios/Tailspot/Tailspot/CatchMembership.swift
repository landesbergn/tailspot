//
//  CatchMembership.swift
//  Tailspot
//
//  The frame-is-the-catch selection rules (2026-08-28 redesign; decision
//  record in docs/plans/2026-08-28-frame-is-the-catch.md). Pointing the
//  camera IS the aim: there is no catch zone, no lock zone, and no pin —
//  a press catches the planes the user can plausibly see on frame,
//  capped at `maxCatchTargets`.
//
//  Membership ranking (D3·2, all inputs computed per frame by the view):
//    1. bright tier only — a plane must be `.full` visibility tier (the
//       "you can likely see this" band) OR user-asserted (tap-rescue /
//       faint-tier promotion: an explicit "there's a plane here").
//    2. confidently-occluded demotes — a non-asserted plane whose bracket
//       patch reads `.notSky` (building / tree under it) is out. A user
//       assertion beats the grid: the camera can misread, the user can't
//       be argued with about what they see.
//    3. asserted planes are guaranteed a slot, before any size ranking.
//    4. larger apparent size (arcminutes — angular, so zoom never
//       reorders the ranking) wins the remaining slots.
//    5. take `maxCatchTargets`.
//
//  The chosen set is FROZEN at the shutter press: catch-time vision
//  (the per-target photo snap) moves brackets and feeds the gates, but
//  never edits membership — the shown planes are the caught planes.
//

import Foundation
import CoreGraphics

/// Max planes one press can catch (D3·2, Noah 2026-08-28). Also the cap
/// the multi reveal fans, so the two can't disagree.
nonisolated let maxCatchTargets = 3

/// One on-frame plane considered for press membership — the minimal
/// facts `chooseCatchMembers` needs, extracted so the rule is
/// unit-testable without building full observations (the
/// `classifyEmptySkyTapNearest` precedent).
nonisolated struct MembershipCandidate: Equatable, Sendable {
    let icao24: String
    /// Apparent angular size — the size-ranking key.
    let arcmin: Double
    /// `.full` visibility tier (bright label). Faint-tier planes are in
    /// the data but NOT in the press unless asserted.
    let isFullTier: Bool
    /// User-asserted (tap-rescue or faint-tier promotion): guaranteed a
    /// slot, and exempt from the occlusion demote.
    let isAsserted: Bool
    /// The local sky gate read a confident `.notSky` under this plane's
    /// bracket (building/tree). Demotes non-asserted planes out of
    /// membership; never flips the press off for planes in open sky.
    let isOccluded: Bool
}

/// The press membership for one frame: the ranked chosen set (≤
/// `maxCatchTargets`) and the eligible-but-unchosen overflow (only ever
/// non-empty when more than `maxCatchTargets` bright planes share the
/// frame — the label layer steps overflow planes down so the ×N badge
/// always equals the full-bright count).
nonisolated struct CatchMembership: Equatable, Sendable {
    let chosen: [String]
    let overflow: [String]

    static let empty = CatchMembership(chosen: [], overflow: [])
}

/// Rank the frame's candidates into the press membership. Pure;
/// deterministic for equal inputs (ties break by icao24 so a frame of
/// identical specks can't flicker its chosen set between frames).
nonisolated func chooseCatchMembers(
    _ candidates: [MembershipCandidate],
    maxCount: Int = maxCatchTargets
) -> CatchMembership {
    guard maxCount > 0 else { return .empty }
    let eligible = candidates.filter {
        $0.isAsserted || ($0.isFullTier && !$0.isOccluded)
    }
    let ranked = eligible.sorted { a, b in
        if a.isAsserted != b.isAsserted { return a.isAsserted }
        if a.arcmin != b.arcmin { return a.arcmin > b.arcmin }
        return a.icao24 < b.icao24
    }
    let chosen = ranked.prefix(maxCount).map(\.icao24)
    let overflow = ranked.dropFirst(maxCount).map(\.icao24)
    return CatchMembership(chosen: chosen, overflow: overflow)
}

// MARK: - Catch-time bracket assignment (D4·2)

/// One per-target snap attempt at catch time: the press-pose predicted
/// screen point the ring search was anchored on, and the detector's
/// snapped point (nil = no detection / search couldn't run).
nonisolated struct TargetSnap: Equatable, Sendable {
    let icao24: String
    let predicted: CGPoint
    let snapped: CGPoint?
}

/// Two accepted snap points closer than this (screen points) are treated
/// as the same physical detection — a ring search anchored on plane A
/// can lock onto nearby plane B's pixels when the compass has drifted.
/// ~60 pt is well inside one bracket box (96–140 pt), so genuinely
/// separate planes never collide.
nonisolated let snapConflictSeparation: CGFloat = 60

/// Enforce unique assignment across per-target snaps (D4·2): no
/// detection may serve two brackets. Snaps are accepted best-correction-
/// first (smallest predicted→snapped distance = the most trustworthy
/// lock); a later snap landing within `minSeparation` of an accepted
/// point loses its detection and falls back to geometry (snapped → nil).
/// Returns the resolved snaps in the input's order.
nonisolated func resolveSnapConflicts(
    _ snaps: [TargetSnap],
    minSeparation: CGFloat = snapConflictSeparation
) -> [TargetSnap] {
    var accepted: [(icao24: String, point: CGPoint)] = []
    // Best correction first; ties break by icao24 for determinism.
    let order = snaps
        .compactMap { snap -> (TargetSnap, CGFloat)? in
            guard let s = snap.snapped else { return nil }
            return (snap, hypot(s.x - snap.predicted.x, s.y - snap.predicted.y))
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.icao24 < b.0.icao24
        }
    var demoted: Set<String> = []
    for (snap, _) in order {
        guard let point = snap.snapped else { continue }
        let collides = accepted.contains {
            hypot($0.point.x - point.x, $0.point.y - point.y) < minSeparation
        }
        if collides {
            demoted.insert(snap.icao24)
        } else {
            accepted.append((snap.icao24, point))
        }
    }
    return snaps.map { snap in
        demoted.contains(snap.icao24)
            ? TargetSnap(icao24: snap.icao24, predicted: snap.predicted, snapped: nil)
            : snap
    }
}

// MARK: - Capture diagnostics candidates

/// One on-frame plane with the geometry the capture diagnostics record —
/// kept from the pre-redesign selection layer purely as a diagnostics
/// data carrier (`CatchCaptureDiagnostics.Alternative` is built from it).
nonisolated struct CatchCandidate: Equatable, Sendable {
    let icao24: String
    let offsetDeg: Double        // angular separation from the view axis
    let offsetPx: CGFloat        // screen-pixel separation from screen center
    let arcmin: Double           // apparent angular size
    let slantMeters: Double
}

/// Every visible plane that projects onto the frame, with the geometry
/// the capture diagnostics need, sorted by pixel offset from screen
/// center. The frame is the zone (no radius cap) — membership itself is
/// `chooseCatchMembers`; this exists only so a mis-catch row records
/// what else was on frame at the press.
@MainActor
func frameDiagCandidates(
    in observed: [ObservedAircraft],
    phoneHeadingDeg: Double,
    cameraElevationDeg: Double,
    rollDeg: Double = 0,
    screenSize: CGSize,
    hfovDeg: Double = 56,
    vfovDeg: Double = 72
) -> [CatchCandidate] {
    let center = CGPoint(x: screenSize.width / 2, y: screenSize.height / 2)
    let basis = Geo.cameraBasis(
        headingDeg: phoneHeadingDeg, cameraElevationDeg: cameraElevationDeg, rollDeg: rollDeg
    )
    var out: [CatchCandidate] = []
    for obs in observed where obs.isLikelyVisibleToObserver {
        guard let pos = obs.screenPosition(
            basis: basis, in: screenSize, hfovDeg: hfovDeg, vfovDeg: vfovDeg
        ) else { continue }
        let dx = pos.x - center.x, dy = pos.y - center.y
        let v = Geo.cameraFrameVector(
            targetBearingDeg: obs.bearingDeg, targetElevationDeg: obs.elevationDeg, basis: basis
        )
        let offDeg = v.z <= 0 ? 180.0 : atan2((v.x*v.x + v.y*v.y).squareRoot(), v.z) * 180 / .pi
        out.append(CatchCandidate(
            icao24: obs.aircraft.icao24, offsetDeg: offDeg,
            offsetPx: (dx*dx + dy*dy).squareRoot(),
            arcmin: obs.apparentSizeArcminutes, slantMeters: obs.slantDistanceMeters
        ))
    }
    return out.sorted { $0.offsetPx < $1.offsetPx }
}

// MARK: - Tap hit-testing

/// Returns the icao24 of the visible aircraft whose projected screen
/// position is closest to a reference point — by default the screen
/// center — provided it falls within `lockZoneRadius` of that point.
/// Nil otherwise.
///
/// Survives the frame-is-the-catch redesign as the TAP hit-test (which
/// labeled plane is under the finger) and the replay analyzer's
/// projection helper; it no longer participates in catch targeting.
///
/// `hfovDeg` / `vfovDeg` should reflect the camera's *effective* FOV —
/// i.e., base FOV / current zoom factor — so the projection math
/// matches what's on screen. `lockZoneRadius` stays in pixels (it's
/// a UI affordance, not an angular tolerance).
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
    // Build the camera basis once and reuse — keeps hit-test geometry
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
