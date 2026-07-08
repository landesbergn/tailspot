//
//  ReferenceScreens.swift
//  Tailspot
//
//  Two static "Pokédex reference" screens: one for the 5 rarity tiers,
//  one for the 7 aircraft types. Both serve as in-app docs explaining
//  the game system the player is interacting with.
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
                Text("Points come from rarity, plus a one-time bonus the first time you catch a new type. Multi-catch combos stack on top.")
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
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.cyan)
            Text("Every plane has a tier.")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Ranked by how much each type actually flies — how likely you are to see one overhead.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
        }
    }

    private func rarityCard(_ r: Rarity) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(r.tint.opacity(0.18))
                Text("\(r.basePoints)")
                    .font(Brand.Font.mono(size: 18, weight: .heavy))
                    .foregroundStyle(r.tint)
            }
            .frame(width: 64, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(r.tint, lineWidth: 1)
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    RarityBadge(rarity: r, size: .md)
                }
                Text(examples(for: r))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(2)
                Text("Base \(r.basePoints) pt")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .tracking(0.6)
            }
            Spacer()
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
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

// MARK: - Types

struct TypesReferenceScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(AircraftType.allCases, id: \.self) { t in
                        typeCard(t)
                    }
                }
                Text("Sets are organized by type. Catch one of every plane in a set to complete it.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.top, 8)
            }
            .padding(20)
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Types")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SEVEN TYPES")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.cyan)
            Text("How we bucket the sky.")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
        }
    }

    private func typeCard(_ t: AircraftType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(t.tint.opacity(0.18))
                Text(t.glyph)
                    .font(Brand.Font.mono(size: 30, weight: .bold))
                    .foregroundStyle(t.tint)
            }
            .frame(height: 76)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.label)
                    .font(Brand.Font.mono(size: 12, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(t.tint)
                Text(t.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
    }
}

#Preview("Rarity") {
    NavigationStack { RarityReferenceScreen() }
}

#Preview("Types") {
    NavigationStack { TypesReferenceScreen() }
}
