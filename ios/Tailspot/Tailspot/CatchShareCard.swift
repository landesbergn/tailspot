//
//  CatchShareCard.swift
//  Tailspot
//
//  A polished, brand-styled artboard for SHARING a catch — rendered to an
//  Image via ImageRenderer and handed to ShareLink, so a friend receives a
//  clean card instead of a manual screenshot. Surfaced from CatchDetailView
//  (the share pill) and the post-catch CardReveal.
//
//  ImageRenderer is synchronous and can't wait on AsyncImage, so the catch
//  photo is passed in as an already-loaded UIImage (loaded from the local
//  capture file via `loadLocalPhoto`); remote Planespotters URLs are skipped
//  for the share render and we fall back to a clean branded placeholder.
//

import SwiftUI

struct CatchShareCard: View {
    let plane: CardPlane
    let photo: UIImage?

    private var callsign: String {
        plane.callsign?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? "TAILSPOT"
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                gradient: Gradient(colors: [plane.rarity.tint.opacity(0.22), .clear]),
                center: UnitPoint(x: 0.5, y: 0.28),
                startRadius: 0, endRadius: 300
            )
            .blendMode(.screen)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "airplane")
                        .foregroundStyle(Brand.Color.cyan)
                        .font(.system(size: 17))
                    Text("TAILSPOT")
                        .font(Brand.Font.mono(size: 15, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    RarityBadge(rarity: plane.rarity, size: .md)
                }

                photoBlock
                    .frame(height: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(plane.rarity.tint.opacity(0.6), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(callsign)
                        .font(Brand.Font.mono(size: 26, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let model = plane.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                        Text(model)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .lineLimit(1)
                    }
                    if let carrier = plane.carrier?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                        Text(carrier)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Brand.Color.textSecondary)
                            .lineLimit(1)
                    }
                }

                HStack {
                    TypeBadge(type: plane.type, size: .md)
                    Spacer()
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Brand.Color.cyan)
                    Text("Caught on Tailspot")
                        .font(Brand.Font.mono(size: 11, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            .padding(22)
        }
        .frame(width: 360, height: 540)
        .overlay(alignment: .top) {
            Rectangle().fill(plane.rarity.tint).frame(height: 3)
        }
    }

    @ViewBuilder
    private var photoBlock: some View {
        if let photo {
            Image(uiImage: photo)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
        } else {
            ZStack {
                Brand.Color.bgSurface
                Image(systemName: "airplane")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(plane.rarity.tint.opacity(0.45))
                    .rotationEffect(.degrees(-45))
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Render + photo helpers

enum CatchShare {
    /// Synchronously load the local capture JPEG for a share render.
    /// Returns nil for remote (Planespotters) URLs or a missing file —
    /// the card then renders its branded placeholder.
    static func loadLocalPhoto(_ url: URL?) -> UIImage? {
        guard let url, url.isFileURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Stamp the share card into an Image for ShareLink. MainActor because
    /// ImageRenderer renders a live SwiftUI view.
    @MainActor
    static func image(for plane: CardPlane, photo: UIImage?) -> Image {
        let renderer = ImageRenderer(content: CatchShareCard(plane: plane, photo: photo))
        renderer.scale = 3
        if let ui = renderer.uiImage {
            return Image(uiImage: ui)
        }
        return Image(systemName: "airplane")
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
