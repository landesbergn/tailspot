//
//  CatchPhotoViewerSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for the full-res pinch-zoom catch-photo viewer
//  (ProfileSettingsSnapshotTests pattern): writes PNGs to
//  /private/tmp/tailspot_snaps for review. The render tests always pass;
//  `openViewerCloseButtonClearsStatusBar` is a REAL regression assertion.
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
    /// Regression (tester report 2026-11-04): on the post-catch reveal — a
    /// full-screen cover — the open viewer's X sat under the status bar
    /// (dead to taps) because the overlay hosted it inside its
    /// `.ignoresSafeArea()` morph layer. The X must clear the top inset.
    @Test func openViewerCloseButtonClearsStatusBar() async throws {
        let url = try fixturePhotoURL()
        _ = RevealPhoto.cachedDecode(url: url)
        let model = HeroZoomModel()
        let host = UIHostingController(rootView: ZStack {
            Color.black.ignoresSafeArea()
            HeroZoomOverlay(model: model)
        })
        let topInset: CGFloat = 59   // Dynamic Island status bar height
        host.additionalSafeAreaInsets = UIEdgeInsets(top: topInset, left: 0, bottom: 34, right: 0)
        let window = UIWindow(frame: Self.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        model.openByTap(url: url, focus: nil)
        // The open morph settles in ~340 ms, then the viewer swaps in —
        // poll, since a loaded MainActor (full parallel suite) runs late.
        for _ in 0..<50 where model.phase != .open {
            try? await Task.sleep(for: .seconds(0.1))
        }
        try #require(model.phase == .open)
        // The hosted test window exposes no accessibility tree, so probe
        // pixels: the X's white glyph is the only bright thing in its
        // column above the photo (the 3:4 fixture fits from y≈164).
        // Polled: a loaded MainActor can lay the viewer out late.
        func probe() throws -> Int? {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let shot = UIGraphicsImageRenderer(bounds: Self.bounds, format: fmt).image { _ in
                host.view.drawHierarchy(in: Self.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
            try? shot.pngData()?.write(to: Self.snapDir.appendingPathComponent("photo_viewer_open_inset.png"))
            let cg = try #require(shot.cgImage)
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try #require(CGContext(
                data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let glyphX = Int(Self.bounds.width - 16 - 22)   // trailing pad + half the disc
            for y in 0..<150 {
                for x in (glyphX - 8)...(glyphX + 8) {
                    let o = (y * w + x) * 4
                    if px[o] > 200, px[o + 1] > 200, px[o + 2] > 200 { return y }
                }
            }
            return nil
        }
        var topGlyphY: Int? = nil
        for _ in 0..<30 {
            host.view.layoutIfNeeded()
            topGlyphY = try probe()
            if topGlyphY != nil { break }
            try? await Task.sleep(for: .seconds(0.1))
        }
        let y = try #require(topGlyphY, "no X glyph found above the photo")
        #expect(CGFloat(y) >= topInset, "Close X glyph starts at y=\(y), under the status bar")
        window.isHidden = true
    }
    /// Mirrors the reveal's real presentation: a `.fullScreenCover` with a
    /// clear presentation background, the overlay last in a GeometryReader
    /// ZStack (CatchRevealView.body).
    private struct CoverHarness: View {
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

    @Test func coverPresentedViewerCloseButtonClearsStatusBar() async throws {
        let url = try fixturePhotoURL()
        _ = RevealPhoto.cachedDecode(url: url)
        let model = HeroZoomModel()
        let host = UIHostingController(rootView: CoverHarness(model: model))
        let window = UIWindow(frame: Self.bounds)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try? await Task.sleep(for: .seconds(1.0))   // cover presents
        model.openByTap(url: url, focus: nil)
        for _ in 0..<50 where model.phase != .open {
            try? await Task.sleep(for: .seconds(0.1))
        }
        try #require(model.phase == .open)
        #expect(host.presentedViewController != nil, "cover never presented")
        let topInset = host.presentedViewController?.view.safeAreaInsets.top ?? 0
        var topGlyphY: Int? = nil
        for _ in 0..<30 {
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let shot = UIGraphicsImageRenderer(bounds: Self.bounds, format: fmt).image { _ in
                (host.presentedViewController?.view ?? window).drawHierarchy(in: Self.bounds, afterScreenUpdates: true)
            }
            try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
            try? shot.pngData()?.write(to: Self.snapDir.appendingPathComponent("photo_viewer_cover.png"))
            let cg = try #require(shot.cgImage)
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = try #require(CGContext(
                data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            let glyphX = Int(Self.bounds.width - 16 - 22)
            outer: for y in 0..<150 {
                for x in (glyphX - 8)...(glyphX + 8) {
                    let o = (y * w + x) * 4
                    if px[o] > 200, px[o + 1] > 200, px[o + 2] > 200 { topGlyphY = y; break outer }
                }
            }
            if topGlyphY != nil { break }
            try? await Task.sleep(for: .seconds(0.1))
        }
        let y = try #require(topGlyphY, "no X glyph found above the photo")
        #expect(topInset > 0, "test window has no safe area: \(topInset)")
        #expect(CGFloat(y) >= topInset, "Close X glyph at y=\(y), window inset \(topInset)")
        window.isHidden = true
    }
}
#endif
