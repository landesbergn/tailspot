//
//  CompassCalibrationSheetSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the compass calibration sheet. Hosts the
//  real sheet view in a window, at
//  SE / iPhone 16 / Pro Max sizes, for the three accuracy states a user
//  can open it in. NOT an assertion test: writes PNGs to
//  /private/tmp/tailspot_snaps/compass-sheet and passes. Review the images
//  after running.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Compass calibration sheet snapshots (visual pass)", .serialized)
struct CompassCalibrationSheetSnapshotTests {

    private static let snapDir = URL(
        fileURLWithPath: "/private/tmp/tailspot_snaps/compass-sheet", isDirectory: true)

    private static let devices: [(String, CGSize)] = [
        ("se", CGSize(width: 375, height: 667)),
        ("16", CGSize(width: 393, height: 852)),
        ("promax", CGSize(width: 440, height: 956)),
    ]

    /// (name, headingAccuracy). -1 is CoreLocation's "invalid" value, which
    /// a badly uncalibrated compass reports.
    private static let states: [(String, Double?)] = [
        ("off", 40),
        ("noreading", -1),
        ("fixed", 8),
    ]

    private func snapshot(accuracy: Double?, size: CGSize, as name: String) async {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let location = LocationManager()
        location.heading = accuracy == -1 ? nil : 212
        location.headingAccuracy = accuracy
        // The sheet's content hosted as the root: a real `.sheet`
        // presentation draws blank offscreen. Height is the device's.
        let root = CompassCalibrationSheet(location: location)
            .preferredColorScheme(.dark)
        let bounds = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: root)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        // Let layout and the first location reads settle.
        try? await Task.sleep(for: .seconds(1.2))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    @Test func renderSheetStates() async {
        for (device, size) in Self.devices {
            for (state, accuracy) in Self.states {
                await snapshot(accuracy: accuracy, size: size, as: "\(state)_\(device)")
            }
        }
        #expect(true)
    }
}
#endif
