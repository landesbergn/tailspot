//
//  BackControlsTests.swift
//  TailspotTests
//
//  Pins the back-controls pass (2026-10-30): the shared exit control's
//  glyphs and labels, and the `reveal_dismissed` event shape.
//

import Testing
import Foundation
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Back controls")
struct BackControlsTests {

    @Test func closeIsAnXAndBackIsAChevron() {
        #expect(ChromeButton.Kind.close.systemName == "xmark")
        #expect(ChromeButton.Kind.back.systemName == "chevron.left")
        #expect(ChromeButton.Kind.close.defaultLabel == "Close")
        #expect(ChromeButton.Kind.back.defaultLabel == "Back")
    }

    @Test func discIsDrawnAtTheMinimumTapSize() {
        // The tester's problem was seeing the exit, so the DRAWN disc is
        // Apple's 44 pt minimum, not just its hit area.
        #expect(ChromeMetrics.disc == 44)
        #expect(ChromeMetrics.glyph < ChromeMetrics.glyphMax)
        #expect(ChromeMetrics.glyphMax < ChromeMetrics.disc - 2 * ChromeMetrics.glassInset)
    }

    @Test func buttonIsLaidOutAtTheDiscSize() {
        // Measures the real layout, not the constant: `.buttonStyle(.glass)`
        // adds its own padding around the label, which drew the first cut
        // at ~57 pt on device and ate the gap above the catch card.
        for button in [ChromeButton(.close) {}, ChromeButton(.back) {},
                       ChromeButton(systemName: "trash", accessibilityLabel: "Delete") {}] {
            let host = UIHostingController(rootView: button)
            let size = host.sizeThatFits(in: CGSize(width: 400, height: 400))
            #expect(abs(size.width - ChromeMetrics.disc) < 0.5, "width \(size.width)")
            #expect(abs(size.height - ChromeMetrics.disc) < 0.5, "height \(size.height)")
        }
    }

    @Test func revealDismissedCarriesMethodAndDwell() {
        let props = RevealDismissAnalytics.properties(method: .continue, dwell: 3.2504)
        #expect(props["method"]?.jsonValue as? String == "continue")
        #expect(props["dwell_ms"]?.jsonValue as? Int == 3250)
        #expect(props.count == 2)
    }

    @Test func revealDismissedMethodVocabulary() {
        #expect(RevealDismissAnalytics.Method.continue.rawValue == "continue")
        #expect(RevealDismissAnalytics.Method.tapAnywhere.rawValue == "tap_anywhere")
        #expect(RevealDismissAnalytics.Method.viewInHangar.rawValue == "view_in_hangar")
    }

    @Test func negativeDwellClampsToZero() {
        let props = RevealDismissAnalytics.properties(method: .tapAnywhere, dwell: -1)
        #expect(props["dwell_ms"]?.jsonValue as? Int == 0)
    }

    // The capture path (one event, muted sends none) is asserted in
    // AnalyticsFacadeTests, the one suite allowed to swap the global sink.
}
