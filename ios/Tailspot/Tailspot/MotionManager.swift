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
import CoreMotion

final class MotionManager: ObservableObject {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "MotionQueue"
        q.qualityOfService = .userInitiated
        return q
    }()

    // All angles in radians; convert to degrees in the view.
    @Published var pitch: Double = 0   // tilt forward / back
    @Published var roll: Double = 0    // tilt left / right
    @Published var yaw: Double = 0     // rotation around vertical

    func start() {
        guard manager.isDeviceMotionAvailable else {
            print("Device motion not available on this device")
            return
        }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0  // 30 Hz is plenty for UI

        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: queue) { [weak self] motion, error in
            guard let self, let motion else { return }
            // CMMotionManager fires on our background queue; @Published mutations
            // must hop back to main for SwiftUI to consume them safely.
            DispatchQueue.main.async {
                self.pitch = motion.attitude.pitch
                self.roll = motion.attitude.roll
                self.yaw = motion.attitude.yaw
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
