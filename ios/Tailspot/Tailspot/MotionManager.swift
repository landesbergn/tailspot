//
//  MotionManager.swift
//  Tailspot
//
//  Wraps CMMotionManager and exposes device attitude (pitch / roll / yaw).
//  Not published: ContentView's 30 Hz TimelineView samples it (see `sample`).
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

/// One CoreMotion sample's worth of attitude + gravity, stored as a SINGLE
/// value so readers always see one coherent sample. Angles in radians.
///
/// History: this once backed six separate `@Published` properties (~180
/// body invalidations/sec), then one published struct (30/sec); since the
/// 2026-10 perf audit it isn't published at all — see `MotionManager.sample`.
/// Anything that must refresh live from motion has to sit inside a
/// TimelineView (as the AR overlay and the debug Cam-el readout do).
///
/// `nonisolated` + `Sendable` so it can be built on the CoreMotion
/// background queue and handed across to the main-thread store hop.
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

    /// The latest coalesced sample (see `MotionSample`). `private(set)` so
    /// only the CoreMotion callback writes it.
    ///
    /// Deliberately NOT `@Published` (2026-10 perf audit). Every reader is
    /// either inside ContentView's 30 Hz `TimelineView` — which re-samples
    /// this on its own schedule — or a one-shot read (the shutter-press
    /// snapshot, the 1 Hz steering/telemetry ticks, replay ticks). Publishing
    /// it fired `objectWillChange` 30×/s, which re-evaluated ContentView's
    /// ENTIRE body on top of the TimelineView's own ticks, roughly doubling
    /// the AR render work for no visible gain. The class stays an
    /// `ObservableObject` only so it can keep living in a `@StateObject`.
    private(set) var sample = MotionSample()

    // Forwarding accessors so every existing call site (`motion.pitch`,
    // `motion.gravityX`, …) keeps compiling unchanged — they now read the
    // one coalesced sample.
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
            // Sendable sample here, then store it in a SINGLE assignment on
            // main, where every reader lives (MainActor-isolated class).
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
