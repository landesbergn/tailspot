//
//  CatchPhotoViewerSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the full-res pinch-zoom catch-photo viewer
//  (ProfileSettingsSnapshotTests pattern): writes PNGs to
//  /private/tmp/tailspot_snaps for review. The render tests always pass;
//  `revealViewerFillsScreen` and `sheetViewerFillsScreen` are REAL
//  regression assertions.
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

    @Test func renderViewerFitAndZoomed() async throws {
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
            try? await Task.sleep(for: .seconds(0.1))
            if let s = firstScrollView(in: host.view) { scroll = s; break }
        }
        snapshotWindow(host, as: "photo_viewer_1x_fit")

        // Drive the zoom the pinch would: 3x, then pan-ish via zoom rect.
        if let scroll {
            scroll.setZoomScale(3, animated: false)
            try? await Task.sleep(for: .seconds(0.2))
            snapshotWindow(host, as: "photo_viewer_3x_zoomed")
        }
        window.isHidden = true
    }

    /// The entry point: the settled card whose hero is now tappable — pure
    /// SwiftUI, but rendered through the same window harness for parity.
    @Test func renderDetailCardEntryPoint() async throws {
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
        try? await Task.sleep(for: .seconds(0.3))
        snapshotWindow(host, as: "photo_viewer_entry_card")
        window.isHidden = true
    }
    /// Regression (tester reports 2026-11-04). The open viewer must own the
    /// WHOLE screen wherever the card lives:
    ///  - On the post-catch reveal (a clear full-screen cover) the X sat
    ///    under the status bar, dead to taps.
    ///  - On the Hangar detail (a sheet) the viewer stopped at the sheet's
    ///    rounded top, with the screen behind showing above it.
    /// Both hosts are mirrored below; each must end with the viewer in its
    /// own cover, black to the top edge, the X below the status bar.
    private struct RevealHarness: View {
        let model: HeroZoomModel
        @State private var shown = false
        var body: some View {
            Color.black.ignoresSafeArea()
                .onAppear { shown = true }
                .fullScreenCover(isPresented: $shown) {
                    GeometryReader { _ in
                        ZStack {
                            Color.gray.ignoresSafeArea()
                            HeroZoomOverlay(model: model)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .presentationBackground(.clear)
                }
        }
    }

    private struct SheetHarness: View {
        let model: HeroZoomModel
        @State private var shown = false
        var body: some View {
            Color.gray.ignoresSafeArea()
                .onAppear { shown = true }
                .sheet(isPresented: $shown) {
                    ZStack {
                        Color.gray.ignoresSafeArea()
                        HeroZoomOverlay(model: model)
                    }
                }
        }
    }

    @Test func revealViewerFillsScreen() async throws {
        let model = HeroZoomModel()
        try await assertViewerFillsScreen(
            UIHostingController(rootView: RevealHarness(model: model)), model: model,
            snapshot: "photo_viewer_from_reveal")
    }

    @Test func sheetViewerFillsScreen() async throws {
        let model = HeroZoomModel()
        try await assertViewerFillsScreen(
            UIHostingController(rootView: SheetHarness(model: model)), model: model,
            snapshot: "photo_viewer_from_sheet")
    }

    private func assertViewerFillsScreen(_ host: UIViewController, model: HeroZoomModel,
                                         snapshot: String) async throws {
        let url = try fixturePhotoURL()
        _ = RevealPhoto.cachedDecode(url: url)
        let window = UIWindow(frame: Self.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try? await Task.sleep(for: .seconds(1.0))   // host's cover/sheet presents
        let screenHost = try #require(host.presentedViewController, "host screen never presented")
        model.openByTap(url: url, focus: nil)
        // The open morph settles in ~340 ms, then the viewer's cover
        // presents. Poll: a loaded MainActor (full suite) runs late.
        for _ in 0..<50 where !(model.phase == .open && screenHost.presentedViewController != nil) {
            try? await Task.sleep(for: .seconds(0.1))
        }
        try #require(model.phase == .open)
        let viewer = try #require(screenHost.presentedViewController?.view,
                                  "viewer was not presented full screen")
        let topInset = viewer.safeAreaInsets.top
        #expect(topInset > 0, "test window has no safe area: \(topInset)")

        // The hosted window exposes no accessibility tree, so probe pixels:
        // the X's white glyph is the only bright thing in its column above
        // the photo. Polled: a loaded MainActor can lay the viewer out late.
        var glyphY: Int? = nil
        var px = [UInt8]()
        var w = 0
        for _ in 0..<30 {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let shot = UIGraphicsImageRenderer(bounds: Self.bounds, format: fmt).image { _ in
                viewer.drawHierarchy(in: Self.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
            try? shot.pngData()?.write(to: Self.snapDir.appendingPathComponent("\(snapshot).png"))
            let cg = try #require(shot.cgImage)
            w = cg.width
            let h = cg.height
            px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try #require(CGContext(
                data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let glyphX = Int(Self.bounds.width - 16 - 22)   // trailing pad + half the disc
            outer: for y in 0..<150 {
                for x in (glyphX - 8)...(glyphX + 8) {
                    let o = (y * w + x) * 4
                    if px[o] > 200, px[o + 1] > 200, px[o + 2] > 200 { glyphY = y; break outer }
                }
            }
            if glyphY != nil { break }
            try? await Task.sleep(for: .seconds(0.1))
        }
        let y = try #require(glyphY, "no X glyph found above the photo")
        #expect(CGFloat(y) >= topInset, "Close X glyph at y=\(y), status bar inset \(topInset)")
        // Black to the very top: no gray host showing above the viewer.
        for (x, y) in [(4, 4), (Int(Self.bounds.midX), 4), (4, Int(topInset) + 4)] {
            let o = (y * w + x) * 4
            #expect(px[o] < 20 && px[o + 1] < 20 && px[o + 2] < 20,
                    "ground not black at (\(x),\(y)): \(px[o]),\(px[o + 1]),\(px[o + 2])")
        }
    }
}
#endif
