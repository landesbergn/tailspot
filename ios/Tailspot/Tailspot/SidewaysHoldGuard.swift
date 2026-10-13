//
//  SidewaysHoldGuard.swift
//  Tailspot
//
//  Blocks spotting when the UI is laid out sideways.
//
//  Why: the identify math assumes an upright portrait hold. Heading is
//  pinned to `.portrait` (LocationManager) and camera roll comes from the
//  chassis gravity vector (Geo.rollDeg), both measured against the
//  device's long axis. The Portrait-only Info.plist pin used to guarantee
//  the UI agreed with that axis. iPhone Duo breaks the guarantee: Apple's
//  guidance is that the INNER display does not honor supported interface
//  orientations, so if someone turns the unfolded phone sideways the UI
//  can rotate while the sensors don't, and every AR label would land 90°
//  off — a confident wrong ID, the worst outcome for catch-confirmation.
//
//  Rather than build landscape support (ios/CLAUDE.md: don't add landscape
//  UI), detect the sideways layout from the screen's own shape and cover
//  the AR view with a "hold it upright" card until the UI is portrait
//  again. On every slab iPhone this never fires (the pin holds), so it's
//  inert outside iPhone Duo.
//
//  SwiftUI pattern: a GeometryReader reports the size it was offered, so
//  the guard reads the full-screen size directly — no scene/orientation
//  API, and it can't disagree with what's actually on screen.
//

import SwiftUI

nonisolated enum SpottingLayout {
    /// True when the full-screen layout is wider than it is tall — the UI
    /// is sideways relative to the portrait axis the sensors assume.
    /// Both iPhone Duo displays are taller than wide in portrait (inner
    /// ≈ 0.70, outer ≈ 0.69 width/height), so a portrait layout never
    /// trips this; only a genuinely rotated one does.
    static func isSideways(_ size: CGSize) -> Bool {
        size.width > 0 && size.height > 0 && size.width > size.height
    }
}

struct SidewaysHoldGuard: View {
    @State private var isSideways = false

    var body: some View {
        // `onGeometryChange` reports the full-screen size without wrapping
        // content in a GeometryReader. `allowsHitTesting(isSideways)` makes
        // pass-through explicit: in the normal portrait case this view can
        // never intercept a tap meant for the AR view or the bottom bar.
        Color.clear
            .onGeometryChange(for: Bool.self) { proxy in
                SpottingLayout.isSideways(proxy.size)
            } action: { sideways in
                isSideways = sideways
            }
            .overlay {
                if isSideways { SidewaysHoldCard() }
            }
            .allowsHitTesting(isSideways)
            .ignoresSafeArea()
    }
}

private struct SidewaysHoldCard: View {
    var body: some View {
        ZStack {
            // Near-opaque wash: the labels underneath are wrong in this
            // pose, so don't let them show through as if they were real.
            Brand.Color.bgPrimary.opacity(0.94)
            VStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Brand.Color.alertCaution)
                    .accessibilityHidden(true)
                Text("Hold your phone upright")
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tailspot matches planes using your phone's tall edge as \u{201C}up.\u{201D} Turn it back to portrait to keep spotting.")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: 420)
        }
        // Swallow taps so nothing underneath (tap-to-ID, the shutter) can
        // act on a sideways pose.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .combine)
        .onAppear { Analytics.capture("sideways_hold_guard_shown") }
    }
}
