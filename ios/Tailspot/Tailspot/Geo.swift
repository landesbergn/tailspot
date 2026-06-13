//
//  Geo.swift
//  Tailspot
//
//  Pure-function geometry helpers for converting between (lat, lon, altitude)
//  positions and the angular quantities we care about: bearing (compass
//  direction from observer to target) and elevation (angle above the
//  observer's horizon).
//
//  These are all great-circle / spherical-Earth approximations. Good to
//  ~0.1% over the kinds of distances we deal with (≤ 200 km).
//

import Foundation
import CoreGraphics
import simd

// All Geo helpers are pure functions on numbers — explicitly nonisolated
// so they can be called from any actor context (MainActor views, the
// background URLSession callback, tests in nonisolated contexts).
nonisolated enum Geo {
    /// Mean Earth radius in meters.
    static let earthRadiusMeters: Double = 6_371_000

    /// Great-circle distance over the ground between two lat/lon points,
    /// in meters. Uses the haversine formula.
    static func distance(
        fromLat lat1: Double, lon lon1: Double,
        toLat lat2: Double, lon lon2: Double
    ) -> Double {
        let φ1 = lat1.radians
        let φ2 = lat2.radians
        let Δφ = (lat2 - lat1).radians
        let Δλ = (lon2 - lon1).radians
        let a = sin(Δφ / 2) * sin(Δφ / 2)
              + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusMeters * c
    }

    /// Initial bearing from point 1 to point 2, in degrees from true north
    /// (0..360, clockwise — same convention as a magnetic compass).
    static func bearing(
        fromLat lat1: Double, lon lon1: Double,
        toLat lat2: Double, lon lon2: Double
    ) -> Double {
        let φ1 = lat1.radians
        let φ2 = lat2.radians
        let Δλ = (lon2 - lon1).radians
        let y = sin(Δλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(Δλ)
        let θ = atan2(y, x).degrees
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Elevation angle from observer to target, in degrees above the
    /// observer's horizon. Positive = up, negative = below horizon.
    /// Flat-Earth approximation; ignores Earth curvature, which costs
    /// ~0.1° over typical aircraft viewing distances.
    static func elevation(
        observerAltMeters: Double,
        targetAltMeters: Double,
        groundDistanceMeters: Double
    ) -> Double {
        guard groundDistanceMeters > 0 else { return 0 }
        let dh = targetAltMeters - observerAltMeters
        return atan2(dh, groundDistanceMeters).degrees
    }

    /// Project an angular world-space target (bearing/elevation) into
    /// 2D screen coordinates given the phone's current pose and the
    /// camera's FOV. Returns nil if the target is outside the camera's
    /// view frustum.
    ///
    /// `cameraElevationDeg` is the angle the camera is pointing above
    /// the horizon — NOT raw CMAttitude.pitch (those differ by 90°
    /// when the phone is held in portrait; see MotionManager.cameraElevationDeg).
    /// `rollDeg` is rotation about the camera bore-sight (0 = upright);
    /// see `Geo.rollDeg(gravityX:gravityY:gravityZ:)`.
    ///
    /// Convenience wrapper: builds a `CameraBasis` from the scalar pose and
    /// delegates to the pinhole `screenPosition(...basis...)`. This is a
    /// proper 3D pinhole projection — it couples azimuth and elevation
    /// (the separable tan model dropped that coupling, misplacing labels
    /// off-axis and at high camera elevation) and honors roll. Accurate for
    /// FOV < ~90°, which matches every iPhone main wide camera. The only
    /// residual limitation is near elevation = ±90° (gimbal at the zenith),
    /// where "up on screen" is ambiguous and the basis falls back to a
    /// stable horizontal — rarely hit while spotting.
    static func screenPosition(
        targetBearingDeg: Double,
        targetElevationDeg: Double,
        phoneHeadingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double = 0,
        screenSize: CGSize,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> CGPoint? {
        let basis = cameraBasis(
            headingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg
        )
        return screenPosition(
            targetBearingDeg: targetBearingDeg,
            targetElevationDeg: targetElevationDeg,
            basis: basis,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg
        )
    }

    // MARK: - Pinhole projection (3D)
    //
    // The separable `screenPosition` above treats screen-x and screen-y as
    // independent functions of bearing-delta and elevation-delta. A real
    // camera is a pinhole and couples them; the error grows off-axis and
    // with camera elevation. These types/functions model the camera as a
    // proper 3D pinhole: build the camera's orthonormal basis in a local
    // ENU frame (East/North/Up), project each target's unit vector through
    // it, perspective-divide. See
    // docs/superpowers/specs/2026-06-08-3d-pinhole-projection-design.md.

    /// The camera's orientation as three world-space (ENU) unit vectors.
    /// Precompute once per frame and reuse across every aircraft — the
    /// per-target projection is then three dot products and a divide.
    nonisolated struct CameraBasis: Equatable, Sendable {
        /// Camera bore-sight (direction of view) in ENU.
        let forward: SIMD3<Double>
        /// Screen-right axis in ENU.
        let right: SIMD3<Double>
        /// Screen-up axis in ENU.
        let up: SIMD3<Double>
    }

    /// Build the camera basis from scalar pose: azimuth from `headingDeg`,
    /// pitch from `cameraElevationDeg` (the gravity-derived value, NOT Euler
    /// pitch), and `rollDeg` rotation about the bore-sight.
    static func cameraBasis(
        headingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double = 0
    ) -> CameraBasis {
        let h = headingDeg.radians
        let e = cameraElevationDeg.radians
        let phi = rollDeg.radians

        // Bore-sight: azimuth from heading, pitch from camera elevation.
        // Same form as a target direction — this makes the pinhole model a
        // strict generalization of the old (heading, elevation) convention.
        let forward = SIMD3<Double>(cos(e) * sin(h), cos(e) * cos(h), sin(e))

        // Screen-up at zero roll = world-up projected perpendicular to the
        // bore-sight, normalized.
        let worldUp = SIMD3<Double>(0, 0, 1)
        var u0 = worldUp - simd_dot(worldUp, forward) * forward
        let u0len = simd_length(u0)
        if u0len > 1e-9 {
            u0 /= u0len
        } else {
            // Gimbal: bore-sight ≈ straight up/down, so "up on screen" is
            // ambiguous. Fall back to a horizontal vector so the basis stays
            // orthonormal (prevents NaN). Spotting rarely hits exactly ±90°.
            u0 = SIMD3<Double>(-sin(h), -cos(h), 0)
        }
        let r0 = simd_cross(forward, u0)   // level-north ⇒ East

        // Roll rotates the (right, up) pair about the bore-sight.
        let right = cos(phi) * r0 + sin(phi) * u0
        let up = -sin(phi) * r0 + cos(phi) * u0
        return CameraBasis(forward: forward, right: right, up: up)
    }

    /// Build the camera basis directly from the device gravity vector +
    /// heading. Derives camera elevation and roll from gravity (robust at
    /// the portrait hold where Euler roll is unreliable) and delegates to
    /// the scalar builder.
    static func cameraBasis(
        gravityX: Double, gravityY: Double, gravityZ: Double,
        headingDeg: Double
    ) -> CameraBasis {
        // Camera elevation from gravity. Mirrors
        // MotionManager.cameraElevationDeg; kept inline so Geo stays
        // dependency-free pure geometry (no CoreMotion import).
        let mag = (gravityX * gravityX + gravityY * gravityY + gravityZ * gravityZ).squareRoot()
        let camEl: Double = mag > 0 ? asin(max(-1, min(1, gravityZ / mag))).degrees : 0
        let roll = rollDeg(gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ)
        return cameraBasis(headingDeg: headingDeg, cameraElevationDeg: camEl, rollDeg: roll)
    }

    /// Device roll (rotation about the camera bore-sight) in degrees,
    /// derived from the gravity vector. 0 = upright portrait (gravity toward
    /// the device bottom, −y). Positive = right edge dipped down. Uses only
    /// the in-screen-plane gravity direction, so it is well-defined wherever
    /// the bore-sight isn't exactly vertical.
    static func rollDeg(gravityX: Double, gravityY: Double, gravityZ: Double) -> Double {
        atan2(gravityX, -gravityY).degrees
    }

    /// A target's direction expressed in the camera's own frame: the three
    /// dot products of the target unit vector against the basis axes, before
    /// any perspective divide or FOV clamp. `z > 0` ⇒ in front of the camera;
    /// `x` is screen-rightward, `y` is screen-upward (both in world units).
    ///
    /// Shared by `screenPosition` (which divides + clamps) and the
    /// off-screen-indicator edge math (which needs the un-clamped direction,
    /// including the behind-camera case where `z <= 0`). Keeping one
    /// projection of (bearing, elevation) → camera frame guarantees the
    /// on-screen label test and the off-screen chevron test can never drift.
    nonisolated struct CameraFrameVector: Equatable, Sendable {
        let x: Double   // screen-right component
        let y: Double   // screen-up component
        let z: Double   // forward (bore-sight) component; > 0 ⇒ in front
    }

    /// Project an angular target (bearing/elevation) into the camera frame.
    /// No clamp, no divide — see `CameraFrameVector`.
    static func cameraFrameVector(
        targetBearingDeg: Double,
        targetElevationDeg: Double,
        basis: CameraBasis
    ) -> CameraFrameVector {
        let b = targetBearingDeg.radians
        let e = targetElevationDeg.radians
        let t = SIMD3<Double>(cos(e) * sin(b), cos(e) * cos(b), sin(e))
        return CameraFrameVector(
            x: simd_dot(t, basis.right),
            y: simd_dot(t, basis.up),
            z: simd_dot(t, basis.forward)
        )
    }

    /// Pinhole-project an angular target (bearing/elevation) through a
    /// precomputed camera basis. Returns nil if the target is behind the
    /// camera or outside the view frustum.
    static func screenPosition(
        targetBearingDeg: Double,
        targetElevationDeg: Double,
        basis: CameraBasis,
        screenSize: CGSize,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> CGPoint? {
        let v = cameraFrameVector(
            targetBearingDeg: targetBearingDeg,
            targetElevationDeg: targetElevationDeg,
            basis: basis
        )
        guard v.z > 0 else { return nil }   // target behind the camera

        // Perspective divide, then normalize against the half-FOV tangents.
        let xRel = (v.x / v.z) / tan((hfovDeg / 2).radians)
        let yRel = (v.y / v.z) / tan((vfovDeg / 2).radians)
        guard abs(xRel) <= 1, abs(yRel) <= 1 else { return nil }

        return CGPoint(
            x: screenSize.width  / 2 + xRel * screenSize.width  / 2,
            y: screenSize.height / 2 - yRel * screenSize.height / 2  // Y flipped (origin top-left)
        )
    }

    /// Inverse of `bearing`/`distance`: given a starting point, an
    /// initial true-north bearing, and a ground distance, return the
    /// destination point. Used by the mock ADS-B source to place fake
    /// aircraft at known angular positions relative to the observer.
    static func project(
        fromLat lat: Double, lon: Double,
        bearingDeg: Double,
        distanceMeters: Double
    ) -> (lat: Double, lon: Double) {
        let δ = distanceMeters / earthRadiusMeters
        let θ = bearingDeg.radians
        let φ1 = lat.radians
        let λ1 = lon.radians

        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(
            sin(θ) * sin(δ) * cos(φ1),
            cos(δ) - sin(φ1) * sin(φ2)
        )
        return (φ2.degrees, λ2.degrees)
    }
}

// MARK: - Convenience

nonisolated private extension Double {
    /// Degrees → radians.
    var radians: Double { self * .pi / 180 }
    /// Radians → degrees.
    var degrees: Double { self * 180 / .pi }
}
