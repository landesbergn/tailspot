//
//  MotionManager.swift
//  Tailspot
//
//  Wraps CMMotionManager and exposes device attitude (pitch / roll / yaw)
//  as @Published properties so SwiftUI views auto-refresh.
//
//  Reference frame: .xArbitraryZVertical — gravity-aligned vertical axis,
//  arbitrary horizontal axis. We don't need true-north alignment from this
//  manager; we get heading from CLLocationManager. We use this purely for
//  pitch (how far up the user is tilting the phone).
//

import Foundation
import Combine
import CoreMotion
import os

/// One CoreMotion sample's worth of attitude + gravity, bundled so the
/// whole sample publishes as a SINGLE value. Angles in radians.
///
/// Coalescing rationale: the old shape wrote six separate `@Published`
/// properties per 30 Hz sample, so each sample fired `objectWillChange`
/// six times (~180/sec), and every one invalidated ContentView's entire
/// body. Bundling them into one struct assigned once per sample drops
/// that to a single invalidation signal per sample.
///
/// `nonisolated` + `Sendable` so it can be built on the CoreMotion
/// background queue and handed across to the main-thread publish hop.
nonisolated struct MotionSample: Sendable {
    var pitch: Double = 0      // tilt forward / back
    var roll: Double = 0       // tilt left / right
    var yaw: Double = 0        // rotation around vertical
    var gravityX: Double = 0
    var gravityY: Double = 0
    var gravityZ: Double = 0
}

final class MotionManager: ObservableObject {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MotionQueue"
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The latest coalesced sample — the ONE `@Published` this manager now
    /// mutates per CoreMotion tick (see `MotionSample`). `private(set)` so
    /// only the CoreMotion callback writes it.
    @Published private(set) var sample = MotionSample()

    // Forwarding accessors so every existing call site (`motion.pitch`,
    // `motion.gravityX`, …) keeps compiling unchanged — they now read the
    // one coalesced sample instead of six separate stored @Published vars.
    var pitch: Double { sample.pitch }   // tilt forward / back
    var roll: Double { sample.roll }     // tilt left / right
    var yaw: Double { sample.yaw }       // rotation around vertical

    // Gravity vector in the device reference frame (CMDeviceMotion.gravity),
    // ~1 g in magnitude. Camera elevation is derived from this rather than
    // from `pitch`, because gravity has no gimbal-lock singularity at the
    // portrait hold (see `cameraElevationDeg`).
    var gravityX: Double { sample.gravityX }
    var gravityY: Double { sample.gravityY }
    var gravityZ: Double { sample.gravityZ }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            Log.motion.notice("Device motion not available on this device")
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0  // 30 Hz is plenty for UI

        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            guard let self, let motion else { return }
            // CMMotionManager fires on our background queue. Build the
            // Sendable sample here, then publish it in a SINGLE assignment on
            // main — one `objectWillChange` per sample instead of six (see
            // `MotionSample`). @Published mutations must hop back to main for
            // SwiftUI to consume them safely.
            let next = MotionSample(
                pitch: motion.attitude.pitch,
                roll: motion.attitude.roll,
                yaw: motion.attitude.yaw,
                gravityX: motion.gravity.x,
                gravityY: motion.gravity.y,
                gravityZ: motion.gravity.z
            )
            DispatchQueue.main.async {
                self.sample = next
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Camera (rear-facing) bore-sight elevation above the horizon, in
    /// degrees. Positive = pointing up, negative = pointing down.
    ///
    /// Derived from the GRAVITY vector, NOT from `CMAttitude.pitch`. The
    /// old `90 − pitch` formula was correct in the upper hemisphere but
    /// broke below the horizon: `pitch` is an Euler angle bounded to ±90°
    /// with a gimbal-lock singularity exactly at the upright-portrait /
    /// horizon-pointing pose (pitch ≈ +90°). Tilting the camera *below*
    /// the horizon makes pitch reflect back down (and roll flip ±180°)
    /// instead of passing 90°, so `90 − pitch` returned a POSITIVE value
    /// when it should be negative — inverting the AR label's vertical
    /// tracking (label slid down as you tilted down). Confirmed in a
    /// 2026-06-02 field replay: pitch peaked at ~89° and reflected while
    /// roll swung ±150°, and the derived elevation never went negative.
    ///
    /// `asin(gravity.z)` is the camera axis's true angle above the
    /// horizontal plane — continuous through the horizon, singularity-free
    /// at the portrait hold, and invariant to roll. Apple's convention
    /// puts gravity at (0,0,−1) when the screen faces up (rear camera then
    /// points straight down → −90°), so the elevation is exactly
    /// `asin(gravity.z / |gravity|)`.
    var cameraElevationDeg: Double {
        Self.cameraElevationDeg(gravityX: gravityX, gravityY: gravityY, gravityZ: gravityZ)
    }

    /// Pure, testable derivation of rear-camera elevation from a gravity
    /// vector in the device frame. Normalizes magnitude and clamps so a
    /// transient non-unit gravity can't push `asin` out of domain.
    nonisolated static func cameraElevationDeg(
        gravityX: Double, gravityY: Double, gravityZ: Double
    ) -> Double {
        let mag = (gravityX * gravityX + gravityY * gravityY + gravityZ * gravityZ).squareRoot()
        guard mag > 0 else { return 0 }
        let s = max(-1.0, min(1.0, gravityZ / mag))
        return asin(s) * 180 / .pi
    }
}
