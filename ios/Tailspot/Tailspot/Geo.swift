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

enum Geo {
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

private extension Double {
    /// Degrees → radians.
    var radians: Double { self * .pi / 180 }
    /// Radians → degrees.
    var degrees: Double { self * 180 / .pi }
}
