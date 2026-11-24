//
//  NotablePlate.swift
//  Tailspot
//
//  The gold "notable plate" shown on a caught notable plane (the reveal,
//  the settled card, the share cards). It is a caption on the BOTTOM EDGE
//  OF THE PHOTO: a star, the name in normal ink, and the category in
//  ledger gold. Sitting on the photo, it adds no height to the card, so a
//  notable card is exactly as tall as an ordinary one (Noah, 2026-11-22:
//  the boxed plate under the identity line made the card crowded and
//  pushed it past one screen).
//
//  Post-catch only. The live AR label shows just a star (PlaneLabel).
//

import SwiftUI

struct NotablePlate: View {
    let notable: NotablePlane
    /// The host card's scale (card width / 300), like every reveal atom.
    let scale: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            oneLine
            twoLines
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 6 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RP.bg.opacity(0.82))
        .overlay(alignment: .top) {
            Rectangle().fill(RP.gold.opacity(0.75)).frame(height: 1)
        }
        // The photo under it keeps its own tap (zoom, Planespotters link).
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notable.accessibilityText)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.system(size: 9.5 * scale, weight: .bold))
            .foregroundStyle(RP.gold)
    }

    /// Category in the card's label voice, in gold.
    private func category(_ text: String, compact: Bool = false) -> some View {
        Text(text.uppercased())
            .font(.system(size: (compact ? 8.5 : 9) * scale, weight: .semibold, design: .monospaced))
            .tracking(compact ? 0.6 : 1.2)
            .foregroundColor(RP.gold)
            .lineLimit(1)
    }

    /// The name talks to the user, so system type (the design rule: mono
    /// is for instruments and data).
    private func nameText(_ name: String, compact: Bool = false) -> some View {
        Text(name)
            .font(.system(size: (compact ? 13 : 13.5) * scale, weight: .semibold))
            .foregroundColor(RP.ink)
            .lineLimit(1)
    }

    /// Star, name, category on one line. With no name, the category alone.
    private var oneLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5 * scale) {
            star
            if let name = notable.name {
                nameText(name, compact: true)
                Spacer(minLength: 4 * scale)
                category(notable.label, compact: true)
            } else {
                category(notable.plateTitle)
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A long name: the category above, the name below, each allowed to
    /// shrink a little before it truncates.
    private var twoLines: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * scale) {
            star
            VStack(alignment: .leading, spacing: 2 * scale) {
                category(notable.name == nil ? notable.plateTitle : notable.label)
                    .minimumScaleFactor(0.75)
                if let name = notable.name {
                    nameText(name).minimumScaleFactor(0.75)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
