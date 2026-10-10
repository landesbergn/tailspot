//
//  CatchShareSheetSnapshotTests.swift
//  TailspotTests
//
//  Visual pass for the share sheet (2026-10-07: swipeable shape preview,
//  story backgrounds, six destinations). The sheet is a NavigationStack +
//  paged TabView, which ImageRenderer draws blank, so each page is hosted
//  in a real UIWindow and captured with drawHierarchy. Writes PNGs to
//  /private/tmp/tailspot_snaps; NOT an assertion test beyond "it rendered".
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Share sheet snapshots (visual pass)", .serialized)
struct CatchShareSheetSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    private let plane = CardPlane(
        callsign: "SWA3170", model: "Boeing 737-700", carrier: "Southwest Airlines",
        rarity: .common, type: .wide,
        altText: "5,250 ft", speedText: "305 mph", distText: "1.4 mi")

    @Test(arguments: SharePage.allCases)
    func sheetPage(_ page: SharePage) async throws {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView:
            CatchShareSheet(plane: plane, shareText: "Caught SWA3170",
                            shareMessage: "Caught on Tailspot", hasCatchPhoto: false,
                            startPage: page)
                .environment(\.replayMaskingDisabled, true))
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        // The sheet renders its images in .task; give them time to land.
        try await Task.sleep(for: .seconds(3))
        host.view.layoutIfNeeded()
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try png.write(to: Self.snapDir.appendingPathComponent("share_sheet_\(page.rawValue).png"))
        window.isHidden = true
        #expect(!png.isEmpty)
    }
}
#endif
