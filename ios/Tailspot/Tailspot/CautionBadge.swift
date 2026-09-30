//
//  CautionBadge.swift
//  Tailspot
//
//  The LOUD compass-caution banner, as its own view so the width test can
//  measure the shipping thing. It used to live inline in
//  `ContentView.cautionBadge`, with a hand-copied duplicate in
//  `CompassWarningSnapshotTests` — which meant the test that asserts the
//  badge fits beside the account button was measuring a copy that could
//  (and would) drift from the real one.
//
//  The button behaviour stays in ContentView: this is the label only, so it
//  renders identically in the app and in a test harness.
//

import SwiftUI

struct CautionBadge: View {
    /// Pre-formatted heading accuracy, e.g. "±40°".
    let accuracyText: String
    /// The repeating pulse is the live affordance; snapshots turn it off so
    /// a render is deterministic.
    var animated: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .symbolEffect(.pulse, options: .repeating, isActive: animated)
            VStack(alignment: .leading, spacing: 1) {
                Text("COMPASS OFF \(accuracyText)")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .tracking(1.0)
                Text("Labels may be wrong — tap to calibrate")
                    .font(Brand.Font.mono(size: 10, weight: .regular))
                    .opacity(0.85)
            }
        }
        // Dark text/glyph on amber — the classic caution read, and the only
        // high-contrast pairing (amber-on-dark is reserved for the quieter
        // data HUD).
        .foregroundStyle(Brand.Color.bgSurface)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.Color.alertCaution,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.Color.bgSurface.opacity(0.15), lineWidth: 1)
        )
        // Amber glow so it lifts off the live camera behind it.
        .shadow(color: Brand.Color.alertCaution.opacity(0.5), radius: 12, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.row))
    }
}
