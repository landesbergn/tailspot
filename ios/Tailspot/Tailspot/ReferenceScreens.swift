//
//  ReferenceScreens.swift
//  Tailspot
//
//  Static "Pokédex reference" for the 5 rarity tiers — in-app docs for
//  the game system. (A companion Types reference existed until
//  2026-07-08; cut as not useful — the Hangar's Sets segment already
//  teaches the type buckets in context.)
//

import SwiftUI

// MARK: - Rarity

struct RarityReferenceScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(Rarity.allCases, id: \.self) { r in
                    rarityCard(r)
                }
                Text("Points come from rarity, plus a one-time bonus the first time you catch a new type. Multi-catch combos stack on top. Planes we can't identify default to Common.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Rarity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIVE TIERS")
                .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.cyan)
            Text("Every plane has a tier.")
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Tiers track how much of a type is actually in the sky — plus a scarcity layer for military, vintage, and vanishing airliners.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
        }
    }

    private func rarityCard(_ r: Rarity) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.row).fill(r.tint.opacity(0.18))
                // Fixed size: a numeral inside the fixed 64 pt tile; the
                // combined label below speaks the points.
                Text("\(r.basePoints)")
                    .font(Brand.Font.mono(size: 18, weight: .heavy))
                    .foregroundStyle(r.tint)
            }
            .frame(width: 64, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.Radius.row).strokeBorder(r.tint, lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RarityBadge(rarity: r, size: .md)
                }
                // Docs screen — let examples wrap at large text sizes
                // rather than truncate.
                Text(examples(for: r))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Text("Base \(r.basePoints) pt")
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .tracking(0.6)
            }
            Spacer()
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(r.label) tier, base \(r.basePoints) points. Examples: \(examples(for: r))")
    }

    // Examples must track the live tier table (AircraftTypes.json —
    // re-tiered by the 2026-07-01 collection economy). Spot-check a
    // typecode's `rarity` there before editing these strings.
    private func examples(for r: Rarity) -> String {
        switch r {
        case .common:    return "737 · A320 · E175 · 787 · Cessna 172"
        case .uncommon:  return "Phenom 300 · King Air · PC-12 · Challenger"
        case .rare:      return "747 · A380 · A340 · G650 · P-51"
        case .epic:      return "747-8 · C-17 · C-130 · C-5 · DC-10"
        case .legendary: return "Air Force One · B-2 · F-16 · SR-71"
        }
    }
}

#Preview("Rarity") {
    NavigationStack { RarityReferenceScreen() }
}

