//
//  MiniCardView.swift
//  Tailspot
//
//  Compact 2-col grid card used in the Hangar's "card grid" mode
//  (HangarB on the design canvas). Visual port of
//  `design/screens/detail-hangar-profile.jsx::MiniCard`:
//
//    rounded 12pt card
//    vertical bg-elevated → bg-surface gradient fill
//    1pt solid rarity border
//    2pt rarity-tinted top rail
//    header: cyan callsign + small RarityBadge
//    photo slot (user catch photo if present, else striped placeholder)
//    model title + operator caption
//    footer: small TypeBadge + ×N count pill (when n > 1)
//
//  Sized to whatever width the parent LazyVGrid hands it; height is
//  content-driven so all cards in a row line up.
//

import SwiftUI

struct MiniCardView: View {
    let row: HangarRow

    private var c: Catch { row.mostRecent }
    private var rarity: Rarity { row.rarity }
    private var type: AircraftType { row.aircraftType }
    private var callsign: String {
        c.callsign?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? c.icao24.uppercased()
    }
    private var modelText: String {
        let key = HangarGrouping.key(for: c, mode: .aircraftType)
        return key == HangarGrouping.unknownTitle ? "Unknown aircraft" : key
    }
    private var operatorText: String {
        c.operatorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — callsign + small rarity badge.
            HStack(alignment: .center) {
                Text(callsign)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Brand.Color.cyan)
                    .tracking(0.3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                RarityBadge(rarity: rarity, size: .sm)
            }
            .padding(.top, 2) // gap below the top rail

            // Photo slot — user's catch photo if present, otherwise
            // a striped placeholder in the rarity tint.
            photoSlot
                .frame(height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            // Title + operator.
            VStack(alignment: .leading, spacing: 2) {
                Text(modelText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(operatorText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .lineLimit(1)
            }

            // Footer — type badge + count pill.
            HStack(alignment: .center) {
                TypeBadge(type: type, size: .sm)
                Spacer(minLength: 4)
                if row.count > 1 {
                    Text("×\(row.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.5), in: .capsule)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // Vertical gradient bg-elevated → bg-surface.
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            // 2pt rarity-tinted top rail.
            Rectangle()
                .fill(rarity.tint)
                .frame(height: 2)
        }
        .overlay(
            // 1pt solid rarity border around the whole card.
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(rarity.tint, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Photo slot. Loads the local catch JPEG if `photoFilename`
    /// exists; otherwise renders a 45° striped placeholder in the
    /// rarity tint (same treatment as the PokeCard placeholder).
    @ViewBuilder
    private var photoSlot: some View {
        if let filename = c.photoFilename,
           let url = CatchPhotoStore.url(forFilename: filename) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .empty, .failure:
                    placeholderStripes
                @unknown default:
                    placeholderStripes
                }
            }
            .frame(maxWidth: .infinity)
            .background(Brand.Color.bgSurface)
        } else {
            placeholderStripes
        }
    }

    /// Striped placeholder — diagonal lines in the rarity tint over
    /// the surface background. Matches the canvas PhotoPlaceholder.
    private var placeholderStripes: some View {
        ZStack {
            Brand.Color.bgSurface
            StripesShape()
                .stroke(rarity.tint.opacity(0.20), lineWidth: 6)
            Text(modelText.split(separator: " ").first.map(String.init)?.uppercased() ?? "")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Diagonal stripe pattern for the photo placeholder. Lines run at
/// ~45° spaced 12pt apart — visually identical to the canvas's
/// `repeating-linear-gradient(135deg, ...)`.
private struct StripesShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let step: CGFloat = 12
        // Start at -height so the diagonal lines cover the full rect
        // at any aspect ratio.
        var x = -rect.height
        while x < rect.width + rect.height {
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
            x += step
        }
        return p
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
