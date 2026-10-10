//
//  EmptySkyTapReplayHarness.swift
//  TailspotTests
//
//  Rebuilds the empty-sky-tap candidate set for one RECORDED tap, mirroring
//  `recordEmptySkyTapDiagnosis` exactly: annotate the aligned tick's raw
//  aircraft with the tick's observer pose, compute each plane's angular
//  offset from the tapped direction under the tick's heading / elevation /
//  zoom, and snapshot tier + reveal facts. Shared by the replay-driven
//  regressions (FarToastRegressionTests, FieldReplayRegressionTests) so a
//  field recording can be pushed through the live tap pipeline offline.
//

import CoreGraphics
import CoreLocation
import Foundation
import Testing

@testable import Tailspot

/// iPhone 16 portrait defaults, matching `ReplayAnalyzer`'s.
let replayHarnessScreenSize = CGSize(width: 393, height: 852)
let replayHarnessBaseHfovDeg = 56.0
let replayHarnessBaseVfovDeg = 72.0

@MainActor
func emptySkyTapCandidates(
    tap: ReplayEvent.EmptyTap, tick: ReplayEvent.Tick,
    screenSize: CGSize = replayHarnessScreenSize,
    baseHfovDeg: Double = replayHarnessBaseHfovDeg,
    baseVfovDeg: Double = replayHarnessBaseVfovDeg
) throws -> (candidates: [EmptySkyTapCandidate], observed: [ObservedAircraft]) {
    let s = tick.sensor
    let lat = try #require(s.latitude)
    let lon = try #require(s.longitude)
    let heading = try #require(s.headingDeg)
    let observer = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
        altitude: s.altitudeMeters ?? 0,
        horizontalAccuracy: s.horizontalAccuracyMeters ?? 10,
        verticalAccuracy: 10,
        timestamp: tick.timestamp
    )
    let observed = tick.aircraft.compactMap {
        ObservedAircraft.annotate(Aircraft($0), observer: observer, now: tick.timestamp)
    }
    let zoom = s.zoomFactor ?? 1.0
    let hfovDeg = baseHfovDeg / zoom
    let vfovDeg = baseVfovDeg / zoom
    // Gravity-derived roll, matching ReplayAnalyzer (Euler rollRad is
    // unreliable at the portrait hold).
    let rollDeg: Double
    if let gx = s.gravityX, let gy = s.gravityY, let gz = s.gravityZ {
        rollDeg = Geo.rollDeg(gravityX: gx, gravityY: gy, gravityZ: gz)
    } else {
        rollDeg = 0
    }
    let basis = Geo.cameraBasis(
        headingDeg: heading,
        cameraElevationDeg: s.cameraElevationDeg,
        rollDeg: rollDeg
    )
    let tapAzDeg = (Double(tap.x) / Double(screenSize.width) - 0.5) * hfovDeg
    let tapElDeg = (0.5 - Double(tap.y) / Double(screenSize.height)) * vfovDeg

    var out: [EmptySkyTapCandidate] = []
    for (i, obs) in observed.enumerated() {
        let v = Geo.cameraFrameVector(
            targetBearingDeg: obs.bearingDeg,
            targetElevationDeg: obs.elevationDeg,
            basis: basis
        )
        let azDeg = atan2(v.x, max(v.z, 1e-6)) * 180 / .pi
        let elDeg = atan2(v.y, max(v.z, 1e-6)) * 180 / .pi
        let off = v.z <= 0
            ? 180.0
            : ((azDeg - tapAzDeg) * (azDeg - tapAzDeg)
                + (elDeg - tapElDeg) * (elDeg - tapElDeg)).squareRoot()
        out.append(EmptySkyTapCandidate(
            index: i,
            offsetDeg: off,
            onScreen: obs.screenPosition(
                basis: basis, in: screenSize,
                hfovDeg: hfovDeg, vfovDeg: vfovDeg
            ) != nil,
            grounded: obs.grounded,
            slantMeters: obs.slantDistanceMeters,
            tier: obs.visibilityTier,
            plausiblyRevealable: obs.isPlausiblyRevealable,
            aboveHorizon: obs.elevationDeg > 0
        ))
    }
    return (out, observed)
}
