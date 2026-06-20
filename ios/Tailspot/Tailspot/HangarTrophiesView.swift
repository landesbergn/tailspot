//
//  HangarTrophiesView.swift
//  Tailspot
//
//  Trophies-view body for the Hangar sheet. Achievements are BINARY —
//  earned or not, one flat pool (no medals/badges split, no metal tiers,
//  no header). Redesigned 2026-06-20 (Noah) after the leveled-metal model
//  conflated with the aircraft rarity/type pills:
//
//    • Earned achievements lead, in a distinct CYAN hex (the brand accent,
//      deliberately NOT the gold that read as "legendary" rarity).
//    • Visible-locked achievements show their real name + a quiet "62 / 100"
//      toward the single goal — it's still binary, just "how close".
//    • SECRET achievements are absent from the list entirely until earned,
//      then they appear (with a moment from TrophyUnlockView).
//
//  Layout matches the Sets/Recent feeds: a ScrollView + LazyVStack of
//  rounded cards. TrophyView caches each hex (drawingGroup) so paging stays
//  smooth.
//

import SwiftUI
import SwiftData

/// Which achievements the Trophies tab shows, and in what order. Pure so the
/// "secret stays hidden until earned" + "earned first" rules are unit-testable
/// without SwiftUI.
nonisolated enum TrophyBoard {
    static func visible(
        roster: [Achievement] = Trophies.roster,
        inputs: TrophyProgressInputs
    ) -> [Achievement] {
        // Secret achievements are hidden until earned; everything else always
        // shows. `filter` preserves roster order, so partitioning earned-first
        // keeps a stable order within each group.
        let shown = roster.filter { !$0.secret || $0.isEarned(inputs: inputs) }
        let earned = shown.filter { $0.isEarned(inputs: inputs) }
        let locked = shown.filter { !$0.isEarned(inputs: inputs) }
        return earned + locked
    }
}

struct HangarTrophiesView: View {
    @Query private var catches: [Catch]

    /// The single accent for an earned achievement hex — cyan-family metal,
    /// chosen to sit apart from the rarity/type palettes (grey/green/cyan/
    /// purple/gold pills) by shape + a consistent cool tone, not gold.
    private let earnedTier: TrophyTier = .platinum

    var body: some View {
        let inputs = Trophies.inputs(from: catches)
        let items = TrophyBoard.visible(inputs: inputs)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { card($0, inputs: inputs) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Brand.Color.bgPrimary)
    }

    @ViewBuilder
    private func card(_ ach: Achievement, inputs: TrophyProgressInputs) -> some View {
        let earned = ach.isEarned(inputs: inputs)
        let progress = ach.currentProgress(inputs: inputs)
        HStack(alignment: .center, spacing: 14) {
            TrophyView(tier: earnedTier, iconName: ach.iconName, size: 52, locked: !earned)
            VStack(alignment: .leading, spacing: 5) {
                Text(ach.title)
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(earned ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                Text(ach.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
                footer(ach: ach, earned: earned, progress: progress)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            earned ? Brand.Color.bgElevated : Brand.Color.bgElevated.opacity(0.5),
            in: .rect(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Brand.Color.textPrimary.opacity(earned ? 0.06 : 0.04), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ach.title), \(earned ? "earned" : "locked"). \(ach.summary)")
    }

    @ViewBuilder
    private func footer(ach: Achievement, earned: Bool, progress: Int) -> some View {
        if earned {
            Label("EARNED", systemImage: "checkmark.seal.fill")
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Brand.Color.cyan)
                .padding(.top, 1)
        } else if ach.threshold > 1 {
            // Binary, but show how close you are to the single goal.
            let frac = Double(min(progress, ach.threshold)) / Double(ach.threshold)
            HStack(spacing: 6) {
                Text("\(min(progress, ach.threshold)) / \(ach.threshold)")
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 6)
                ProgressBar(fill: frac, tint: Brand.Color.cyan)
                    .frame(width: 76, height: 4)
            }
            .padding(.top, 1)
        } else {
            Label("LOCKED", systemImage: "lock.fill")
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.top, 1)
        }
    }
}

// MARK: - Progress bar

private struct ProgressBar: View {
    let fill: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.Color.bgSurface)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fill))))
            }
        }
    }
}

#Preview {
    NavigationStack {
        HangarTrophiesView()
    }
    .modelContainer(for: Catch.self, inMemory: true)
}
