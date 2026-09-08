//
//  RevealDeviceMatrixRenderTests.swift
//  TailspotTests
//
//  Visual-pass harness (NOT an assertion test): renders the LIVE catch reveal
//  in a hosted UIWindow across a matrix of device safe-area sizes × card
//  configurations, so a layout change can be eyeballed everywhere it matters
//  — the SE tester's three-line card, the tall phones, the bonus round.
//  Writes PNGs to /private/tmp/tailspot_matrix/<tag>/. OPT-IN — 20 hosted
//  renders take ~100 s, too slow for the routine suite — enable it with the
//  tag as the value, run it against the old and the new code, and diff:
//
//      TEST_RUNNER_TAILSPOT_MATRIX=before xcodebuild test … \
//        -only-testing:TailspotTests/RevealDeviceMatrixRenderTests
//
//  (`TEST_RUNNER_` is stripped by xcodebuild when it forwards the variable to
//  the test host.) Compose the folders into sheets with a PIL/ImageMagick
//  script; the 2026-09-06 sweep lives in docs/ui-sweeps/2026-09-06/.
//
//  Hosted live (not ImageRenderer) because the reveal's card region is a
//  ScrollView, which ImageRenderer draws blank — see RevealShortScreenTests
//  for the harness notes (async sleeps, ignoresSafeArea root).
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

/// The output folder name — "before" for the baseline run, "after" for the
/// fix. nil (unset) disables the suite. File-scope because a `@Suite` trait
/// cannot reference the suite's own statics (circular macro reference).
private let matrixTag: String? = ProcessInfo.processInfo.environment["TAILSPOT_MATRIX"]

@MainActor
@Suite("Reveal device matrix renders (visual pass)", .serialized,
       .enabled(if: matrixTag != nil, "opt-in: set TEST_RUNNER_TAILSPOT_MATRIX=<tag>"))
struct RevealDeviceMatrixRenderTests {

    static let outDir = URL(fileURLWithPath: "/private/tmp/tailspot_matrix/\(matrixTag ?? "unset")", isDirectory: true)

    struct Device { let name: String; let size: CGSize }
    /// Safe-area sizes (points), portrait: screen minus status bar / island
    /// and home indicator. iPad-in-iPhone-compatibility mode equals the SE.
    static let devices: [Device] = [
        Device(name: "se",       size: CGSize(width: 375, height: 647)),   // 667 − 20
        Device(name: "mini",     size: CGSize(width: 375, height: 728)),   // 812 − 50 − 34
        Device(name: "16",       size: CGSize(width: 393, height: 759)),   // 852 − 59 − 34
        Device(name: "16pro",    size: CGSize(width: 402, height: 778)),   // 874 − 62 − 34
        Device(name: "16promax", size: CGSize(width: 440, height: 860)),   // 956 − 62 − 34
    ]

    struct Config { let name: String; let plane: CardPlane; let guess: GuessRoundQuestion?; let wait: Double }

    static func configs() -> [Config] {
        var rng = SystemRandomNumberGenerator()
        let route = GuessOptions.routeQuestion(
            originIcao: "KSFO", destIcao: "VHHH",
            observerLat: 37.8, observerLon: -122.27, using: &rng)
        return [
            Config(name: "1line_route", plane: CardPlane(
                callsign: "JBU613", model: "Airbus A220-300", carrier: "JetBlue",
                rarity: .uncommon, type: .narrow,
                altText: "35,433 ft", speedText: "451 kt", distText: "14.5 km",
                originIcao: "KBOS", destIcao: "KSFO",
                originName: "Boston Logan", destName: "San Francisco"), guess: nil, wait: 4.0),
            Config(name: "2line_fot_route", plane: CardPlane(
                callsign: "RCH872", model: "Boeing C-17 Globemaster III", carrier: "U.S. Air Force",
                rarity: .epic, type: .mil,
                altText: "27,887 ft", speedText: "418 kt", distText: "9.2 km",
                originIcao: "KSUU", destIcao: "PHIK",
                originName: "Travis AFB", destName: "Honolulu",
                isFirstOfType: true), guess: nil, wait: 4.5),
            Config(name: "3line_bell206", plane: CardPlane(
                callsign: "N217MH", model: "Bell 206 JetRanger / LongRanger", carrier: "Private",
                rarity: .uncommon, type: .ga,
                altText: "1,975 ft", speedText: "65 kt", distText: "0.6 km"), guess: nil, wait: 4.0),
            Config(name: "bonus_round", plane: CardPlane(
                callsign: "UAL248", model: "Boeing 787-9", carrier: "United Airlines",
                rarity: .rare, type: .wide,
                altText: "37,004 ft", speedText: "478 kt", distText: "12.0 km",
                originIcao: "SFO", destIcao: "VHHH",
                originName: "San Francisco", destName: "Hong Kong",
                isFirstOfType: true), guess: route.map { GuessRoundQuestion(route: $0) }, wait: 5.0),
        ]
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let s = view as? UIScrollView { return s }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    private func snapshot(_ view: UIView, bounds: CGRect, as name: String) {
        let png = UIGraphicsImageRenderer(bounds: bounds).pngData { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.outDir.appendingPathComponent("\(name).png"))
    }

    @Test func renderMatrix() async throws {
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        for device in Self.devices {
            for config in Self.configs() {
                var reveal = CatchRevealView(plane: config.plane, entryNumber: 4,
                                             onDismiss: {}, onViewInHangar: {},
                                             guess: config.guess)
                reveal.streakDays = 1
                reveal._reduceMotionOverride = true
                let host = UIHostingController(rootView: reveal.ignoresSafeArea())
                let window = UIWindow(frame: CGRect(origin: .zero, size: device.size))
                window.rootViewController = host
                window.overrideUserInterfaceStyle = .dark
                window.makeKeyAndVisible()
                host.view.layoutIfNeeded()
                try? await Task.sleep(for: .seconds(config.wait))
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try? await Task.sleep(for: .seconds(0.3))

                let bounds = CGRect(origin: .zero, size: device.size)
                let name = "\(config.name)__\(device.name)"
                snapshot(host.view, bounds: bounds, as: name)

                // Where the (new) layout scrolls, also capture the bottom.
                if let scroll = firstScrollView(in: host.view),
                   scroll.contentSize.height > scroll.bounds.height + 1 {
                    scroll.setContentOffset(
                        CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
                    try? await Task.sleep(for: .seconds(0.3))
                    snapshot(host.view, bounds: bounds, as: "\(name)__scrolled")
                }
                window.isHidden = true
            }
        }
        #expect(true)
    }
}
#endif
