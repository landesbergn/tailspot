//
//  RevealShortScreenTests.swift
//  TailspotTests
//
//  Regression guard for the iPhone SE reveal (TestFlight, 2026-09-06): a
//  three-line-name card is taller than the SE's 647 pt safe area minus the
//  CTA strip, and before the fix the "tap to continue / View in Hangar" row
//  was pushed off the bottom — the tester had no way to proceed. The reveal
//  now hosts the card in a scroll view with the CTA pinned below it.
//
//  Unlike the ImageRenderer harnesses, this hosts the LIVE view in a UIWindow
//  (ImageRenderer can't draw UIScrollView-backed content), so it exercises the
//  real scroll view: on the SE-sized window the content must overflow (and
//  scroll), and on a 6.1" window the same card must NOT scroll — the tall-
//  phone reveal stays as fixed as it was. PNGs land in /private/tmp/
//  tailspot_snaps for the visual pass; the `#expect`s are the actual test.
//
//  Two harness notes worth keeping: the waits are `await Task.sleep`, not a
//  `RunLoop.run(until:)` spin — a spin blocks the main-actor job behind the
//  reveal's `.task` (the settle that shows the CTA), so the strip never
//  appeared; and the root view ignores the host's safe area, because the
//  window otherwise inherits the simulator device's insets (59 pt island on
//  an iPhone 17) and the window size stops meaning "the SE's safe area".
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Reveal on short screens (SE)")
struct RevealShortScreenTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// The tester's card: a three-line split-flap name, no route (DIST fills
    /// the slot), an uncommon tier, a one-day streak in the entry-stamp row.
    private static let bell206 = CardPlane(
        callsign: "N217MH", model: "Bell 206 JetRanger / LongRanger", carrier: "Private",
        rarity: .uncommon, type: .ga,
        altText: "1,975 ft", speedText: "65 kt", distText: "0.6 km")

    private struct Hosted {
        let host: UIViewController
        let window: UIWindow
        let scroll: UIScrollView?
    }

    /// Hosts the reveal in a window of `size` (treated as the device's
    /// safe-area size), lets the split-flap ceremony settle, and returns the
    /// host + the scroll view the card lives in.
    ///
    /// Plain reveals only. A bonus-round (chips-up) variant was tried: it
    /// passed in isolation — the chips card measures ~833 pt at 393 wide,
    /// taller than a 6.1" safe area even before the scroll view, and now
    /// scrolls with the CTA pinned — but under the parallel full suite the
    /// chips never popped in the hosted window, so it was not a stable guard.
    /// The static mirror in `GuessRoundSnapshotTests` covers that state.
    private func hostReveal(size: CGSize,
                            settledWhen: @escaping (UIScrollView) -> Bool = { _ in true }) async -> Hosted {
        var reveal = CatchRevealView(plane: Self.bell206, entryNumber: 4,
                                     onDismiss: {}, onViewInHangar: {})
        reveal.streakDays = 1
        // Reduce Motion ends on the identical settled frame and skips the
        // per-cell tumble, so the settle is quick and deterministic.
        reveal._reduceMotionOverride = true
        let host = UIHostingController(rootView: reveal.ignoresSafeArea())
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        // Poll rather than sleep a fixed span: at least 4 s (past the uncommon
        // tier's 1.9 s ceremony and the 0.3 s settle fade), then until the
        // caller's condition holds, capped at 30 s. The full suite runs test
        // clones in parallel and starves the main thread, so a flat sleep is
        // not a reliable wait. Each tick forces a layout pass so `contentSize`
        // reflects the current card, not a mid-transition frame.
        let started = Date()
        var scroll: UIScrollView?
        repeat {
            try? await Task.sleep(for: .seconds(0.25))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            scroll = firstScrollView(in: host.view)
            if Date().timeIntervalSince(started) >= 4, let scroll, settledWhen(scroll) { break }
        } while Date().timeIntervalSince(started) < 30
        return Hosted(host: host, window: window, scroll: scroll)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private func snapshot(_ view: UIView, bounds: CGRect, as name: String) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
    }

    @Test func seSizedRevealScrollsAndKeepsCTAOnScreen() async throws {
        // iPhone SE (3rd gen) safe area: 375 × (667 − 20 status bar).
        let size = CGSize(width: 375, height: 647)
        let hosted = await hostReveal(size: size) { $0.contentSize.height > $0.bounds.height + 20 }
        defer { hosted.window.isHidden = true }
        let bounds = CGRect(origin: .zero, size: size)

        let scrollView = try #require(hosted.scroll, "the reveal should host its card in a scroll view")
        // The card overflows the viewport → the scroll view has somewhere to go.
        #expect(scrollView.contentSize.height > scrollView.bounds.height + 20,
                "SE card (\(scrollView.contentSize.height) pt) should overflow the \(scrollView.bounds.height) pt viewport")
        // The scroll region stops above the CTA strip: the strip (~71 pt) is
        // pinned inside the window, not pushed below it.
        let scrollFrame = scrollView.convert(scrollView.bounds, to: hosted.window)
        #expect(scrollFrame.maxY <= size.height - 60,
                "scroll viewport should end above the CTA strip (maxY \(scrollFrame.maxY))")
        snapshot(hosted.host.view, bounds: bounds, as: "se_live_top")

        scrollView.setContentOffset(
            CGPoint(x: 0, y: scrollView.contentSize.height - scrollView.bounds.height), animated: false)
        try? await Task.sleep(for: .seconds(0.3))
        snapshot(hosted.host.view, bounds: bounds, as: "se_live_scrolled")
    }

    @Test func tallPhoneRevealDoesNotScroll() async throws {
        // iPhone 16 safe area: 393 × (852 − 59 island − 34 home indicator).
        let size = CGSize(width: 393, height: 759)
        let hosted = await hostReveal(size: size)
        defer { hosted.window.isHidden = true }

        let scrollView = try #require(hosted.scroll)
        // Same three-line card fits with the CTA below it — the content is
        // exactly the viewport (min-height), so nothing scrolls.
        #expect(scrollView.contentSize.height <= scrollView.bounds.height + 0.5,
                "6.1\" card (\(scrollView.contentSize.height) pt) should fit the \(scrollView.bounds.height) pt viewport")
        snapshot(hosted.host.view, bounds: CGRect(origin: .zero, size: size), as: "tall_live_bell206")
    }
}
#endif
