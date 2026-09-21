//
//  TopStripLayout.swift
//  Tailspot
//
//  The numbers that decide whether the compass caution banner and the
//  top-trailing chrome can touch each other. They live here, not inline in
//  `ContentView`, so the layout tests measure the same constants the view
//  lays out with — a test that declares its own copy of "44" and "60" goes
//  green even if the view stops using them.
//
//  These pin the CONSTANTS, not the rendered frames: nothing here knows
//  that SwiftUI honoured them. The render in
//  `TopStripLayoutSnapshotTests` is what shows the result.
//
//  `nonisolated` — pure numbers, no UI, no state.
//

import CoreGraphics

nonisolated enum TopStripLayout {
    // MARK: Banner region (the top-centre stack)

    /// Inset from the screen's leading edge.
    static let bannerLeading: CGFloat = 16
    /// Inset from the trailing edge — wide enough to clear the account
    /// button, which is the only control on the banner's row.
    static let bannerTrailing: CGFloat = 60

    /// The width the banner actually gets on a screen this wide.
    static func bannerWidth(screenWidth: CGFloat) -> CGFloat {
        screenWidth - bannerLeading - bannerTrailing
    }

    /// The x of the banner region's right edge.
    static func bannerRight(screenWidth: CGFloat) -> CGFloat {
        screenWidth - bannerTrailing
    }

    // MARK: Top-trailing controls

    /// The account button's circle, and the hit target every control in
    /// this strip meets (HIG minimum).
    static let controlDiameter: CGFloat = 44
    /// The DEBUG wrench's visible disc; its hit region is expanded to
    /// `controlDiameter` by `wrenchHitInset` on each side.
    static let wrenchDiameter: CGFloat = 32
    static var wrenchHitInset: CGFloat { (controlDiameter - wrenchDiameter) / 2 }
    /// Gap between stacked controls.
    static let controlSpacing: CGFloat = 10
    static let controlsTopPadding: CGFloat = 8
    static let controlsTrailingPadding: CGFloat = 12

    /// The x of the left edge of the top-row control (the account button).
    /// The strip is safe exactly when this is at or right of
    /// `bannerRight(screenWidth:)`.
    static func topRowControlLeft(screenWidth: CGFloat) -> CGFloat {
        screenWidth - controlsTrailingPadding - controlDiameter
    }

    /// Where a second control BESIDE the account button would start — the
    /// pre-2026-09-21 DEBUG layout, kept as a named number because it is
    /// the thing the overlap test has to keep failing.
    static func secondControlLeftIfSideBySide(screenWidth: CGFloat) -> CGFloat {
        topRowControlLeft(screenWidth: screenWidth) - controlSpacing - controlDiameter
    }
}
