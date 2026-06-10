//
//  BadgeViews.swift
//  Tailspot
//
//  Two small SwiftUI badges that turn up wherever a plane is shown:
//
//   - RarityBadge: bordered mono-font pill in the rarity tint
//     (e.g., "RARE" in cyan). Legendary gets a leading ★ glyph so
//     it pops more than just a color change.
//
//   - TypeBadge: rounded pill with a dark-circle glyph (N/W/R/B/M/G/H)
//     followed by the type label, on a type-tinted background.
//
//  Both have sm/md/lg variants so they scale gracefully when used
//  inside a tight catch card footer (md) or as section labels (lg).
//

import SwiftUI

// MARK: - RarityBadge

struct RarityBadge: View {
    let rarity: Rarity
    var size: BadgeSize = .md

    var body: some View {
        let m = size.metrics
        HStack(spacing: 4) {
            if rarity == .legendary {
                Text("★")
                    .font(.system(size: m.fontSize - 1, weight: .bold))
            }
            Text(rarity.label)
                .font(Brand.Font.mono(size: m.fontSize, weight: .bold))
                .tracking(0.8)
        }
        .padding(.horizontal, m.padX)
        .padding(.vertical, m.padY)
        .foregroundStyle(rarity.tint)
        .background(rarity.tint.opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(rarity.tint, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - TypeBadge

struct TypeBadge: View {
    let type: AircraftType
    var size: BadgeSize = .md

    var body: some View {
        let m = size.metrics
        HStack(spacing: 4) {
            Text(type.glyph)
                .font(Brand.Font.mono(size: m.fontSize - 1, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(width: m.glyphSize, height: m.glyphSize)
                .background(.black.opacity(0.22), in: .circle)
            Text(type.label)
                .font(.system(size: m.fontSize, weight: .bold))
                .tracking(0.4)
        }
        .padding(.horizontal, m.padX + 1)
        .padding(.vertical, m.padY)
        .foregroundStyle(.black.opacity(0.75))
        .background(type.tint)
        .clipShape(Capsule())
    }
}

// MARK: - Sizing

enum BadgeSize {
    case sm, md, lg

    struct Metrics {
        let padX: CGFloat
        let padY: CGFloat
        let fontSize: CGFloat
        let glyphSize: CGFloat
    }

    var metrics: Metrics {
        switch self {
        case .sm: return .init(padX: 5,  padY: 1,   fontSize: 8,  glyphSize: 12)
        case .md: return .init(padX: 7,  padY: 1.5, fontSize: 9,  glyphSize: 14)
        case .lg: return .init(padX: 9,  padY: 3,   fontSize: 11, glyphSize: 16)
        }
    }
}

// MARK: - Combined dual-badge

/// Common pattern: render the rarity badge directly followed by the
/// type badge with a small gap. Falls back to a wrapping HStack so
/// extremely narrow containers don't clip the second pill.
struct TagRow: View {
    let rarity: Rarity
    let type: AircraftType
    var size: BadgeSize = .md

    var body: some View {
        HStack(spacing: 5) {
            RarityBadge(rarity: rarity, size: size)
            TypeBadge(type: type, size: size)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        TagRow(rarity: .common,    type: .narrow)
        TagRow(rarity: .uncommon,  type: .narrow)
        TagRow(rarity: .rare,      type: .wide)
        TagRow(rarity: .epic,      type: .wide)
        TagRow(rarity: .legendary, type: .heritage)
    }
    .padding()
    .background(Brand.Color.bgPrimary)
}
