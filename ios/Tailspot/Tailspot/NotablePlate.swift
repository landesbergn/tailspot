//
//  NotablePlate.swift
//  Tailspot
//
//  The gold "notable plate" shown on a caught notable plane (the reveal,
//  the settled card, the share cards): a star, "NOTABLE · <CATEGORY>" in
//  ledger gold, and the name beneath in normal ink when the server knows
//  it. Built in the reveal's vocabulary (RP palette, the ALT/SPD label
//  voice) so it sits on those cards like one of their own parts.
//
//  Post-catch only. The live AR label shows just a star (PlaneLabel).
//

import SwiftUI

struct NotablePlate: View {
    let notable: NotablePlane
    /// The host card's scale (card width / 300), like every reveal atom.
    let scale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
            Image(systemName: "star.fill")
                .font(.system(size: 9.5 * scale, weight: .bold))
                .foregroundStyle(RP.gold)
            VStack(alignment: .leading, spacing: 3 * scale) {
                // Category: the card's label voice, in gold. A long one
                // ("Head of state and government") wraps to a second line
                // rather than shrinking out of reach.
                Text(notable.plateTitle)
                    .font(.system(size: 9.5 * scale, weight: .semibold, design: .monospaced))
                    .tracking(1.5)
                    .foregroundColor(RP.gold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                if let name = notable.name {
                    // The name talks to the user, so system type (the
                    // design rule: mono is for instruments and data).
                    Text(name)
                        .font(.system(size: 14 * scale, weight: .semibold))
                        .foregroundColor(RP.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RP.gold.opacity(0.07), in: .rect(cornerRadius: Brand.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.chip)
                .strokeBorder(RP.gold.opacity(0.75), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notable.accessibilityText)
    }
}
