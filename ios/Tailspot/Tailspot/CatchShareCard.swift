//
//  CatchShareCard.swift
//  Tailspot
//
//  The share artboard — rendered to an Image via ImageRenderer and handed
//  to ShareLink, so a friend receives a clean card instead of a manual
//  screenshot. Surfaced from CatchDetailView (the share pill) and the
//  post-catch reveal.
//
//  Since Direction B (2026-07-05) the artboard IS the settled reveal card
//  — `SettledCatchCard`, the same view the Hangar detail frames — wrapped
//  in minimal brand chrome (wordmark above, "CAUGHT ON TAILSPOT" below).
//  One card design across catch, Hangar, and share.
//
//  ImageRenderer is synchronous and can't wait on AsyncImage, so only the
//  LOCAL capture photo renders into a share (RevealPhoto loads file URLs
//  synchronously); remote Planespotters heroes fall back to the card's sky
//  placeholder — same behavior as the pre-B share card.
//

import SwiftUI

struct CatchShareCard: View {
    let plane: CardPlane

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .foregroundStyle(Brand.Color.cyan)
                    .font(.system(size: 15, weight: .semibold))
                Text("TAILSPOT")
                    .font(Brand.Font.mono(size: 14, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Circle().fill(plane.rarity.tint).frame(width: 6, height: 6)
                Text(plane.rarity.label.uppercased())
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(plane.rarity.tint)
            }
            .padding(.horizontal, 4)

            SettledCatchCard(
                plane: plane,
                isFirstOfType: plane.isFirstOfType,
                width: 320
            )

            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Brand.Color.cyan)
                Text("CAUGHT ON TAILSPOT")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Brand.Color.bgPrimary)
    }
}

// MARK: - Render helper

enum CatchShare {
    /// Stamp the share card into an Image for ShareLink. MainActor because
    /// ImageRenderer renders a live SwiftUI view. Height follows the card's
    /// natural size (the split-flap name can wrap to a second line).
    @MainActor
    static func image(for plane: CardPlane) -> Image {
        let renderer = ImageRenderer(content: CatchShareCard(plane: plane))
        renderer.scale = 3
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        return Image(systemName: "airplane")
    }
}
