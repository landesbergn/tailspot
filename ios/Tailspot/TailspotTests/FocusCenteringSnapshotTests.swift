//
//  FocusCenteringSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the photo-centering + flight-number work:
//  renders SettledCatchCard for REAL catch photos placed at
//  /private/tmp/tailspot_focus_review, BEFORE (nil focus → center-crop, the
//  old behavior) vs AFTER (focus recovered from the baked bracket by
//  CatchPhotoFocusRecovery → the plane centered, with zoom for edge planes).
//  Writes PNGs to /private/tmp/tailspot_snaps; skips silently if no review
//  photos are staged. NOT an assertion test.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
import os
@testable import Tailspot

@MainActor
@Suite("Focus centering snapshots (visual pass)")
struct FocusCenteringSnapshotTests {

    // (file, callsign, carrier, model) for the staged review photos.
    private let cases: [(String, String, String, String)] = [
        ("a4c592.jpg", "JBU1770", "JetBlue Airways", "Airbus A321neo"),
        ("c010cb.jpg", "ACA708", "Air Canada", "Airbus A320"),
        ("a1863b.jpg", "DAL405", "Delta Air Lines", "Airbus A321neo"),
        ("a198ed.jpg", "JBU1770", "JetBlue Airways", "Airbus A320"),
    ]

    @Test func renderCenteringBeforeAfter() {
        let reviewDir = URL(fileURLWithPath: "/private/tmp/tailspot_focus_review", isDirectory: true)
        let outDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for (file, callsign, carrier, model) in cases {
            let url = reviewDir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let recovered = CatchPhotoFocusRecovery.recoverFocus(fromJPEG: data)
            Log.ui.notice("focus review \(file, privacy: .public): recovered=\(String(describing: recovered), privacy: .public)")

            func plane(_ focus: CGPoint?) -> CardPlane {
                CardPlane(
                    callsign: callsign, model: model, carrier: carrier,
                    rarity: .common, type: .narrow,
                    altText: "4,100 ft", speedText: "273 kt", distText: "2.6 km",
                    photoURL: url, photoFocus: focus,
                    originIcao: "YYZ", destIcao: "LGA",
                    originName: "Toronto", destName: "New York")
            }

            for (suffix, focus) in [("before", CGPoint?.none), ("after", recovered)] {
                let view = VStack {
                    SettledCatchCard(plane: plane(focus), isFirstOfType: false, width: 357)
                }
                .padding(12)
                .background(Brand.Color.bgPrimary)
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                guard let png = renderer.uiImage?.pngData() else { continue }
                let stem = file.replacingOccurrences(of: ".jpg", with: "")
                try? png.write(to: outDir.appendingPathComponent("focus_\(stem)_\(suffix).png"))
            }
        }
        #expect(true)
    }
}
#endif
