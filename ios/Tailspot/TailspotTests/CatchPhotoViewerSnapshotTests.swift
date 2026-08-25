//
//  CatchPhotoViewerSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the full-res pinch-zoom catch-photo viewer
//  (ProfileSettingsSnapshotTests pattern). NOT an assertion test: writes
//  PNGs to /private/tmp/tailspot_snaps and passes — review the images.
//
//  The viewer's zoom host is a UIScrollView (UIViewRepresentable), which
//  ImageRenderer can't draw, so this hosts the screen in a real UIWindow
//  and snapshots via drawHierarchy; the zoomed state is exercised by
//  driving the scroll view's zoomScale directly.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Catch photo viewer snapshots (visual pass)", .serialized)
struct CatchPhotoViewerSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)
    private static let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)

    /// A synthetic "catch photo" with fine detail (registration text, panel
    /// lines) so the 1x vs 3x snapshots visibly differ — sized like a real
    /// 12 MP portrait capture.
    private func fixturePhotoURL() throws -> URL {
        let size = CGSize(width: 3024, height: 4032)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            // Sky gradient.
            let colors = [UIColor(red: 0.25, green: 0.45, blue: 0.75, alpha: 1).cgColor,
                          UIColor(red: 0.75, green: 0.85, blue: 0.95, alpha: 1).cgColor]
            let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(grad, start: .zero,
                                             end: CGPoint(x: 0, y: size.height), options: [])
            // Plane silhouette (fuselage + wings), off-center like a real catch.
            UIColor(white: 0.15, alpha: 1).setFill()
            let cx = size.width * 0.62, cy = size.height * 0.34
            ctx.cgContext.fillEllipse(in: CGRect(x: cx - 420, y: cy - 60, width: 840, height: 120))
            ctx.cgContext.fill(CGRect(x: cx - 60, y: cy - 380, width: 90, height: 760))
            // Fine detail only legible zoomed: a registration on the fuselage.
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 44, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            ("N747TS" as NSString).draw(at: CGPoint(x: cx + 90, y: cy - 24), withAttributes: attrs)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer_fixture_catch.jpg")
        try img.jpegData(compressionQuality: 0.8)!.write(to: url)
        return url
    }

    private func snapshotWindow(_ host: UIHostingController<some View>, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(bounds: Self.bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: Self.bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    @Test func renderViewerFitAndZoomed() throws {
        let url = try fixturePhotoURL()
        let host = UIHostingController(rootView: CatchPhotoViewer(url: url))
        let window = UIWindow(frame: Self.bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // The viewer decodes the JPEG in a detached task — pump the run loop
        // until the scroll view (image branch) appears, up to ~3 s.
        var scroll: UIScrollView? = nil
        for _ in 0..<30 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            if let s = firstScrollView(in: host.view) { scroll = s; break }
        }
        snapshotWindow(host, as: "photo_viewer_1x_fit")

        // Drive the zoom the pinch would: 3x, then pan-ish via zoom rect.
        if let scroll {
            scroll.setZoomScale(3, animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            snapshotWindow(host, as: "photo_viewer_3x_zoomed")
        }
        window.isHidden = true
    }

    /// The entry point: the settled card whose hero is now tappable — pure
    /// SwiftUI, but rendered through the same window harness for parity.
    @Test func renderDetailCardEntryPoint() throws {
        let url = try fixturePhotoURL()
        let plane = CardPlane(
            callsign: "TS747", model: "Boeing 747-400", carrier: "Tailspot Test",
            rarity: .rare, type: .wide,
            altText: "34,000 FT", speedText: "480 KT", distText: "12.4 KM",
            photoURL: url, photoFocus: CGPoint(x: 0.62, y: 0.34),
            originIcao: "SFO", destIcao: "HND",
            originName: "San Francisco", destName: "Tokyo",
            isFirstOfType: false
        )
        let card = SettledCatchCard(plane: plane, isFirstOfType: false, width: 340,
                                    onPhotoTap: {},
                                    photoTapAccessibilityLabel: "View photo full screen")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.Color.bgPrimary)
        let host = UIHostingController(rootView: card)
        let window = UIWindow(frame: Self.bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        snapshotWindow(host, as: "photo_viewer_entry_card")
        window.isHidden = true
    }
}
#endif
