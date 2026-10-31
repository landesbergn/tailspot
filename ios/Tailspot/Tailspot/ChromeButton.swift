//
//  ChromeButton.swift
//  Tailspot
//
//  The one way out of a custom-chrome screen (back-controls pass,
//  2026-10-30; design/back-controls-audit.html). A tester holding the phone
//  up with both hands couldn't see the old exits: a 30 pt grey X on the
//  Hangar, 36 pt discs on the detail screens, a bare cyan chevron on Sets.
//  Now every custom exit is this control, and the rule is:
//
//    - `.close` (X, top RIGHT) puts a screen away — back to the camera.
//    - `.back` (chevron, top LEFT) goes back one level inside a stack.
//
//  Screens with a system navigation bar use the native iOS 26 close button
//  (`Button(role: .close)` in the toolbar) instead.
//
//  It's a plain SwiftUI `Button` in the system's Liquid Glass button style
//  (`.buttonStyle(.glass)` + a circle border shape), so it looks and presses
//  like the toolbar's own glass buttons. The circle is 44 pt DRAWN, not
//  just tapped: Apple's minimum hit target is also the minimum visible size
//  here, because the tester's problem was seeing the button, not hitting
//  it. The glyph grows with Dynamic Type (`@ScaledMetric`) up to a cap.
//

import SwiftUI

/// Size constants shared by every top-row chrome button (the exits and the
/// detail screen's trash + share), so a row of chrome reads as one set.
enum ChromeMetrics {
    static let disc: CGFloat = 44
    static let glyph: CGFloat = 18
    static let glyphMax: CGFloat = 24
    /// Padding `.buttonStyle(.glass)` adds on each side of its label. The
    /// label is sized `disc - 2 × glassInset` so the finished button is the
    /// disc; framing the label at the full disc drew it at 58 pt and crowded
    /// the catch card (Noah's device pass, 2026-10-30).
    /// `buttonIsLaidOutAtTheDiscSize` measures the real layout.
    static let glassInset: CGFloat = 7
}

struct ChromeButton: View {
    enum Kind {
        case close, back

        var systemName: String { self == .close ? "xmark" : "chevron.left" }
        var defaultLabel: String { self == .close ? "Close" : "Back" }
    }

    private let systemName: String
    private let tint: Color
    private let role: ButtonRole?
    private let accessibilityLabel: String
    private let action: () -> Void

    /// Body-relative so the glyph tracks the user's text size setting.
    @ScaledMetric(relativeTo: .body) private var glyph = ChromeMetrics.glyph

    /// An exit: X (close) or chevron (back). VoiceOver label defaults to
    /// "Close" / "Back".
    init(_ kind: Kind, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.systemName = kind.systemName
        self.tint = Brand.Color.textPrimary
        self.role = kind == .close ? .close : nil
        self.accessibilityLabel = accessibilityLabel ?? kind.defaultLabel
        self.action = action
    }

    /// Any other top-row action in the same look (the detail screen's
    /// trash and share).
    init(systemName: String, tint: Color = Brand.Color.textPrimary,
         accessibilityLabel: String, action: @escaping () -> Void) {
        self.systemName = systemName
        self.tint = tint
        self.role = nil
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: systemName)
                .font(.system(size: min(glyph, ChromeMetrics.glyphMax), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: ChromeMetrics.disc - 2 * ChromeMetrics.glassInset,
                       height: ChromeMetrics.disc - 2 * ChromeMetrics.glassInset)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
    }
}
