//
//  OffscreenIndicator.swift
//  Tailspot
//
//  Edge-of-frame "finder scope" indicators. The field failure that motivated
//  this (2026-06-12): zoomed to 5× (≈11° FOV), Noah pointed within 12–17° of
//  an Atlas 747 (GTI9648) that was in-data, fresh, and visibility-passing —
//  but its label projected just off-screen, so the sky looked empty and taps
//  found nothing. Compass error that session (±11°) can EXCEED the zoomed
//  half-FOV, so at high zoom the user can't reliably aim by eye. The fix is a
//  finder-scope affordance: for any plane that passes the visibility gate but
//  doesn't land on-screen, pin a chevron to the screen edge pointing the way
//  to pan, with the callsign on it.
//
//  WHY ANGULAR-SPACE MATH, NOT SCREEN-SPACE CLAMPING.
//  The naive approach — project to screen coords, then clamp the off-screen
//  point back onto the edge rectangle — breaks for planes BEHIND the user.
//  The pinhole perspective divide (x/z, y/z) is only valid in front of the
//  camera (z > 0); behind it (z < 0) the divide flips sign and explodes, so a
//  clamped screen point can point the WRONG way. Instead we work in the
//  camera's own frame: take the un-clamped (x, y, z) direction the projection
//  itself produces (`Geo.cameraFrameVector`), and reason about the direction
//  from screen center using the in-screen-plane components (x = right,
//  y = up). For an in-front plane that direction matches the projected point;
//  for a behind-you plane (z ≤ 0) the same (x, y) still tells us which side it
//  is on, and we clamp the chevron to that side edge so it always points the
//  SHORTER way around. One projection basis feeds both the on-screen label
//  test and this off-screen test, so the boundary between them is gap-free by
//  construction (see `OffscreenIndicator.indicator`).
//

import Foundation
import CoreGraphics

/// A single edge chevron: where to draw it, which way it points, and what to
/// label it. Pure data — the SwiftUI layer turns this into a glyph + chip.
nonisolated struct OffscreenIndicator: Equatable, Sendable {
    /// icao24 of the aircraft this points at. Used as the stable identity for
    /// the SwiftUI `ForEach` so chevrons don't tear down/rebuild frame to
    /// frame (which would kill the slide animation as a plane pans in).
    let icao24: String
    /// Callsign (or fallback) shown in the chip.
    let label: String
    /// Anchor point on the screen edge, in the same top-left-origin pixel
    /// space as `screenPosition`.
    let point: CGPoint
    /// Chevron rotation in DEGREES, clockwise, where 0° points to the right
    /// (+x). A right-edge plane → 0°, top-edge → −90° (up), left → 180°,
    /// bottom → 90° (down). Matches SwiftUI's `.rotationEffect` convention
    /// for a glyph whose natural orientation points right (e.g.
    /// `chevron.right`).
    let angleDeg: Double
    /// Angular distance from the view axis, in degrees (0 = dead center,
    /// 180 = directly behind). Smaller = closer to coming on-screen. Used to
    /// rank + cap; surfaced so callers can dim by how far off-axis a plane is.
    let axisAngleDeg: Double
}

nonisolated enum OffscreenIndicators {

    /// Default inset of the chevron anchor from the literal screen edge, in
    /// points. Keeps the glyph + chip fully on-screen rather than half-clipped.
    static let defaultEdgeInset: CGFloat = 24

    /// Max chevrons to show at once. More than this turns the frame into a
    /// picket fence; the three closest-to-axis are the ones the user is most
    /// likely about to pan onto.
    static let maxIndicators = 3

    /// Build the edge indicator for ONE aircraft, given its already-projected
    /// camera-frame direction and the usable rect.
    ///
    /// Returns nil when the aircraft is ON-SCREEN — and this nil MUST coincide
    /// exactly with `Geo.screenPosition` returning a point, so there's no dead
    /// zone (neither a label nor a chevron) and no double-render (both at
    /// once). We guarantee that by deriving the on-screen test from the SAME
    /// `(x, y, z)` and FOV the projection uses:
    ///
    ///   on-screen ⇔ z > 0 ∧ |x/z| ≤ tan(hfov/2) ∧ |y/z| ≤ tan(vfov/2)
    ///
    /// which is algebraically identical to `screenPosition`'s
    /// `z > 0 ∧ |xRel| ≤ 1 ∧ |yRel| ≤ 1`.
    ///
    /// - Parameters:
    ///   - frame: the un-clamped camera-frame direction (`Geo.cameraFrameVector`).
    ///   - usableRect: the rectangle (in screen pixels) the chevron anchor is
    ///     clamped into — already shrunk for the top sensor panel and bottom
    ///     capture bar. Inset further by `edgeInset` for the glyph footprint.
    ///   - screenSize: full screen size; the view axis maps to its center.
    static func indicator(
        icao24: String,
        label: String,
        frame: Geo.CameraFrameVector,
        screenSize: CGSize,
        usableRect: CGRect,
        hfovDeg: Double,
        vfovDeg: Double,
        edgeInset: CGFloat = defaultEdgeInset
    ) -> OffscreenIndicator? {
        let halfHTan = tan((hfovDeg / 2) * .pi / 180)
        let halfVTan = tan((vfovDeg / 2) * .pi / 180)

        // On-screen test — must mirror Geo.screenPosition exactly.
        if frame.z > 0 {
            let xRel = (frame.x / frame.z) / halfHTan
            let yRel = (frame.y / frame.z) / halfVTan
            if abs(xRel) <= 1 && abs(yRel) <= 1 {
                return nil   // on-screen: the PlaneLabel renders, no chevron.
            }
        }

        // Off-screen. Find the screen-plane direction from center toward the
        // plane. (x = right, y = up). Normalize against the half-FOV tangents
        // so a plane one full frame off in azimuth weighs the same as one full
        // frame off in elevation — direction is measured in "frames from
        // center", which is what the user reads on the panel.
        //
        // For a behind-you plane (z ≤ 0) the perspective divide is invalid, so
        // we use the raw (x, y) direction directly; its sign still encodes
        // which side the plane is on, which is all the chevron needs.
        let dirX: Double
        let dirY: Double
        if frame.z > 0 {
            dirX = (frame.x / frame.z) / halfHTan
            dirY = (frame.y / frame.z) / halfVTan
        } else {
            // Behind the camera. Point toward the side the plane sits on. If
            // it's directly behind with no lateral component, default to the
            // nearer horizontal edge by the sign of x (0 → right) so the
            // chevron never collapses to an undefined direction.
            dirX = frame.x != 0 ? frame.x / halfHTan : 1
            dirY = frame.y / halfVTan
        }

        // angleDeg: screen-plane direction, screen coords (y points DOWN), so
        // negate dirY (which is up-positive). 0° = right, −90° = up.
        let angleRad = atan2(-dirY, dirX)
        let angleDeg = angleRad * 180 / .pi

        // Cast a ray from the usable-rect center along (dirX, −dirY) and find
        // where it exits the rect; that exit point (inset by edgeInset) is the
        // chevron anchor. Ray–rectangle intersection: scale to the nearer of
        // the vertical/horizontal walls.
        let inset = usableRect.insetBy(dx: edgeInset, dy: edgeInset)
        // Guard a degenerate usableRect (inset larger than the rect): fall
        // back to the un-inset rect center so we never produce NaN.
        let rect = (inset.width > 0 && inset.height > 0) ? inset : usableRect
        let cx = rect.midX
        let cy = rect.midY
        let halfW = rect.width / 2
        let halfH = rect.height / 2

        // Screen-space ray direction (y down).
        let rx = dirX
        let ry = -dirY
        // Distance to vertical wall vs horizontal wall; smaller wins (first
        // exit). Treat a near-zero component as never hitting that wall.
        let tX = abs(rx) > 1e-9 ? halfW / abs(rx) : .greatestFiniteMagnitude
        let tY = abs(ry) > 1e-9 ? halfH / abs(ry) : .greatestFiniteMagnitude
        let t = min(tX, tY)

        let point = CGPoint(
            x: (cx + rx * t).clamped(to: rect.minX...rect.maxX),
            y: (cy + ry * t).clamped(to: rect.minY...rect.maxY)
        )

        // Axis angle: full 3D angle between the bore-sight (forward, +z) and
        // the target direction. acos(z / |v|). 0 = dead ahead, 180 = behind.
        let mag = (frame.x * frame.x + frame.y * frame.y + frame.z * frame.z).squareRoot()
        let axisAngleDeg = mag > 0
            ? acos((frame.z / mag).clamped(to: -1...1)) * 180 / .pi
            : 0

        return OffscreenIndicator(
            icao24: icao24,
            label: label,
            point: point,
            angleDeg: angleDeg,
            axisAngleDeg: axisAngleDeg
        )
    }

    /// Build the capped, stably-ordered set of off-screen indicators for a
    /// frame.
    ///
    /// - `candidates` are (icao24, callsign, camera-frame vector) for every
    ///   plane that passed the visibility gate. On-screen planes are dropped
    ///   (their `indicator` returns nil).
    /// - Keeps the `maxIndicators` closest-to-axis (smallest `axisAngleDeg`):
    ///   the planes the user is most likely about to pan onto.
    /// - Output ORDER is by icao24, not by axis angle — a stable key so the
    ///   SwiftUI `ForEach` identity doesn't reshuffle (and the chevrons don't
    ///   swap-flicker) when two planes trade ranks frame to frame. The CAP is
    ///   still applied on the axis-angle ranking; only the render order is by
    ///   id. Ties in axis angle break by icao24 so the selected SET is
    ///   deterministic too.
    static func indicators(
        candidates: [(icao24: String, label: String, frame: Geo.CameraFrameVector)],
        screenSize: CGSize,
        usableRect: CGRect,
        hfovDeg: Double,
        vfovDeg: Double,
        edgeInset: CGFloat = defaultEdgeInset,
        maxCount: Int = maxIndicators
    ) -> [OffscreenIndicator] {
        let all = candidates.compactMap { c in
            indicator(
                icao24: c.icao24,
                label: c.label,
                frame: c.frame,
                screenSize: screenSize,
                usableRect: usableRect,
                hfovDeg: hfovDeg,
                vfovDeg: vfovDeg,
                edgeInset: edgeInset
            )
        }
        // Rank closest-to-axis; deterministic tie-break by icao24.
        let ranked = all.sorted { a, b in
            if a.axisAngleDeg != b.axisAngleDeg { return a.axisAngleDeg < b.axisAngleDeg }
            return a.icao24 < b.icao24
        }
        let kept = Array(ranked.prefix(max(0, maxCount)))
        // Render order: stable by id so identity doesn't churn frame to frame.
        return kept.sorted { $0.icao24 < $1.icao24 }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
