//
//  HangarTrophiesView.swift
//  Tailspot
//
//  Trophies-view body for the Hangar sheet. Awards come in two clearly
//  separated kinds (Spec § 7, clarified 2026-06-16):
//
//    • MEDALS  — leveled awards. Climb bronze → silver → gold → platinum
//                by catching more (Catcher, Night Owl, …). The metal
//                coloring IS the meaning: it's your current tier, and a
//                progress bar shows the climb to the next one.
//    • BADGES  — one-of-one feats. A single milestone you either have or
//                you don't (First Rare, Legendary, Quintet, …). No tiers,
//                no progress bar — just earned or locked. The absence of a
//                bar is the signal that it isn't leveled.
//
//  Layout matches the Sets and Recent feeds: a ScrollView + LazyVStack of
//  rounded cards (NOT a List), so only on-screen badges render and the
//  spacing is consistent. TrophyView caches each hex as a Metal texture
//  (drawingGroup, no blur shadow) so scrolling/segment-paging stays smooth.
//

import SwiftUI
import SwiftData

struct HangarTrophiesView: View {
    @Query private var catches: [Catch]

    var body: some View {
        // Compute the aggregate ONCE and split the roster by kind.
        let inputs = Trophies.inputs(from: catches)
        let medals = Trophies.roster.filter(\.isLeveled).sorted {
            let ca = medalCompletion($0, inputs: inputs), cb = medalCompletion($1, inputs: inputs)
            return ca != cb ? ca > cb : $0.title < $1.title
        }
        let badges = Trophies.roster.filter(\.isOneShot).sorted {
            let ea = !$0.isLocked(inputs: inputs), eb = !$1.isLocked(inputs: inputs)
            return ea != eb ? ea : $0.title < $1.title
        }
        let medalsStarted = medals.filter { !$0.isLocked(inputs: inputs) }.count
        let badgesEarned = badges.filter { !$0.isLocked(inputs: inputs) }.count

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                headerCard(medalsStarted: medalsStarted, medalTotal: medals.count,
                           badgesEarned: badgesEarned, badgeTotal: badges.count)
                    .padding(.bottom, 2)

                sectionHeader("MEDALS", subtitle: "Tiered — level up bronze → platinum",
                              earned: medalsStarted, total: medals.count)
                ForEach(medals) { medalCard($0, inputs: inputs) }

                sectionHeader("BADGES", subtitle: "One-time feats — earned or not",
                              earned: badgesEarned, total: badges.count)
                ForEach(badges) { badgeCard($0, inputs: inputs) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Brand.Color.bgPrimary)
    }

    /// Overall completion of a leveled medal (progress toward its top tier),
    /// used only for sort order so the closest-to-maxed medals bubble up.
    private func medalCompletion(_ ach: Achievement, inputs: TrophyProgressInputs) -> Double {
        guard let maxAt = ach.tiers.last?.at, maxAt > 0 else { return 0 }
        return min(1, Double(ach.currentProgress(inputs: inputs)) / Double(maxAt))
    }

    // MARK: - Header

    private func headerCard(medalsStarted: Int, medalTotal: Int, badgesEarned: Int, badgeTotal: Int) -> some View {
        HStack(spacing: 0) {
            statTile(value: medalsStarted, total: medalTotal, label: "MEDALS")
            Rectangle()
                .fill(Brand.Color.textPrimary.opacity(0.08))
                .frame(width: 1, height: 44)
            statTile(value: badgesEarned, total: badgeTotal, label: "BADGES")
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }

    private func statTile(value: Int, total: Int, label: String) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(value)")
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("/ \(total)")
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
            }
            Text(label)
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, subtitle: String, earned: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Brand.Font.mono(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textSecondary)
                Text("\(earned) / \(total)")
                    .font(Brand.Font.mono(size: 10, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary.opacity(0.7))
                    .monospacedDigit()
            }
            Text(subtitle)
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.leading, 4)
        .padding(.top, 10)
    }

    // MARK: - Medal card (leveled)

    private func medalCard(_ ach: Achievement, inputs: TrophyProgressInputs) -> some View {
        let current = ach.currentTier(inputs: inputs)
        let next = ach.nextTier(inputs: inputs)
        let progress = ach.currentProgress(inputs: inputs)
        return HStack(alignment: .center, spacing: 14) {
            TrophyView(tier: current ?? .bronze, iconName: ach.iconName, size: 52, locked: current == nil)
            VStack(alignment: .leading, spacing: 5) {
                Text(ach.title)
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(ach.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
                medalFooter(ach: ach, current: current, next: next, progress: progress)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }

    /// Tier label + "progress / next" + a bar filling the CURRENT tier
    /// segment; or "GOLD · MAX" once the top tier is reached.
    @ViewBuilder
    private func medalFooter(ach: Achievement, current: TrophyTier?, next: AchievementTier?, progress: Int) -> some View {
        if let next {
            let prevAt = ach.tiers.last { progress >= $0.at }?.at ?? 0
            let span = max(1, next.at - prevAt)
            let fill = max(0, min(1, Double(progress - prevAt) / Double(span)))
            HStack(spacing: 6) {
                Text(current?.label ?? "LOCKED")
                    .font(Brand.Font.mono(size: 9, weight: .bold))
                    .foregroundStyle(current.map { Color(hex: $0.outerHex) } ?? Brand.Color.textTertiary)
                    .tracking(0.8)
                Text("\(progress) / \(next.at)")
                    .font(Brand.Font.mono(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 6)
                ProgressBar(fill: fill, tint: Color(hex: next.tier.outerHex))
                    .frame(width: 76, height: 4)
            }
            .padding(.top, 1)
        } else if let current {
            Text("\(current.label) · MAX")
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .foregroundStyle(Color(hex: current.outerHex))
                .tracking(0.8)
                .padding(.top, 1)
        }
    }

    // MARK: - Badge card (one of one)

    private func badgeCard(_ ach: Achievement, inputs: TrophyProgressInputs) -> some View {
        let earned = !ach.isLocked(inputs: inputs)
        let tier = ach.tiers.first?.tier ?? .gold
        let tint = Color(hex: tier.outerHex)
        return HStack(alignment: .center, spacing: 14) {
            TrophyView(tier: tier, iconName: ach.iconName, size: 52, locked: !earned)
            VStack(alignment: .leading, spacing: 5) {
                Text(ach.title)
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(earned ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                Text(ach.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
                if earned {
                    Label("EARNED", systemImage: "checkmark.seal.fill")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(tint)
                        .padding(.top, 1)
                } else {
                    Label("LOCKED", systemImage: "lock.fill")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (earned ? Brand.Color.bgElevated : Brand.Color.bgElevated.opacity(0.5)),
            in: .rect(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Brand.Color.textPrimary.opacity(earned ? 0.06 : 0.04), lineWidth: 1)
        )
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
                    .frame(width: geo.size.width * CGFloat(fill))
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
