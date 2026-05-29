//
//  SetsScreen.swift
//  Tailspot
//
//  Browser of all PokeSets with per-set progress, plus a detail
//  drill-down for an individual set showing every slot — caught
//  ones full-color, uncaught ones as rarity-tinted silhouettes.
//

import SwiftUI
import SwiftData

struct SetsScreen: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    var body: some View {
        List {
            Section {
                summaryHero
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            Section("Sets") {
                ForEach(PokeSets.all) { set in
                    NavigationLink(value: set) {
                        setRow(set)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sets")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PokeSet.self) { set in
            SetDetailScreen(set: set)
        }
    }

    private var summaryHero: some View {
        let totals = PokeSets.all.map { PokeSets.progress(of: $0, against: catches) }
        let caught = totals.reduce(0) { $0 + $1.caught }
        let total = totals.reduce(0) { $0 + $1.total }
        return VStack(alignment: .leading, spacing: 6) {
            Text("POKÉDEX-STYLE")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.cyan)
            Text("Sets by type")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
            HStack(spacing: 12) {
                Text("\(caught)")
                    .font(Brand.Font.mono(size: 32, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 0) {
                    Text("of \(total) slots")
                        .font(Brand.Font.cardSubtitle)
                        .foregroundStyle(Brand.Color.textSecondary)
                    Text("ACROSS \(PokeSets.all.count) SETS")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated)
    }

    private func setRow(_ set: PokeSet) -> some View {
        let progress = PokeSets.progress(of: set, against: catches)
        let fill = progress.total == 0 ? 0 : Double(progress.caught) / Double(progress.total)
        let complete = progress.caught == progress.total
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(set.type.tint.opacity(0.20))
                Text(set.type.glyph)
                    .font(Brand.Font.mono(size: 16, weight: .bold))
                    .foregroundStyle(set.type.tint)
            }
            .frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(set.title)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(Brand.Color.textPrimary)
                    if complete {
                        Text("COMPLETE")
                            .font(Brand.Font.mono(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Brand.Color.alertNormal, in: .capsule)
                    }
                }
                HStack(spacing: 8) {
                    Text("\(progress.caught) / \(progress.total)")
                        .font(Brand.Font.mono(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.Color.textSecondary)
                        .monospacedDigit()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.Color.bgElevated)
                            Capsule().fill(set.type.tint).frame(width: geo.size.width * CGFloat(fill))
                        }
                    }
                    .frame(height: 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail

struct SetDetailScreen: View {
    let set: PokeSet
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]

    private var slotStatus: [(PokeSetEntry, PokeSets.SlotStatus)] {
        PokeSets.status(of: set, against: catches)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroHeader
                pokedexLabel
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12),
                ], spacing: 12) {
                    ForEach(Array(slotStatus.enumerated()), id: \.element.0.id) { idx, pair in
                        slotTile(index: idx + 1, entry: pair.0, status: pair.1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle(set.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var pokedexLabel: some View {
        HStack {
            Text("POKÉDEX · \(set.entries.count) ENTRIES")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var heroHeader: some View {
        let progress = PokeSets.progress(of: set, against: catches)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TypeBadge(type: set.type, size: .lg)
                Spacer()
                Text("\(progress.caught) / \(progress.total)")
                    .font(Brand.Font.mono(size: 18, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
            }
            Text(set.title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Brand.Color.textPrimary)
            Text("Catch every airframe to complete this set.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    @ViewBuilder
    private func slotTile(index: Int, entry: PokeSetEntry, status: PokeSets.SlotStatus) -> some View {
        let isCaught: Bool = {
            if case .caught = status { return true }
            return false
        }()
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isCaught
                          ? entry.rarity.tint.opacity(0.14)
                          : Brand.Color.bgElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isCaught ? entry.rarity.tint : Brand.Color.textTertiary.opacity(0.25),
                                style: .init(lineWidth: 1, dash: isCaught ? [] : [3, 3])
                            )
                    )
                // The silhouette / glyph treatment.
                Image(systemName: "airplane")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(isCaught
                                     ? entry.rarity.tint
                                     : Brand.Color.textTertiary.opacity(0.45))
                // Top-leading: entry number; top-trailing: caught
                // checkmark (only when caught).
                VStack {
                    HStack {
                        Text(String(format: "#%02d", index))
                            .font(Brand.Font.mono(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Brand.Color.textTertiary)
                            .padding(8)
                        Spacer()
                        if isCaught {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Brand.Color.alertNormal)
                                .padding(8)
                        }
                    }
                    Spacer()
                }
            }
            .aspectRatio(1.2, contentMode: .fit)
            VStack(spacing: 2) {
                Text(isCaught ? entry.canonicalName : "Not yet caught")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCaught
                                     ? Brand.Color.textPrimary
                                     : Brand.Color.textTertiary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                RarityBadge(rarity: entry.rarity, size: .sm)
                    .opacity(isCaught ? 1 : 0.55)
            }
        }
    }
}

#Preview {
    NavigationStack { SetsScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
