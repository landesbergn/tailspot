//
//  HangarTrophiesView.swift
//  Tailspot
//
//  Trophies-view body for the Hangar sheet. Renders the achievement
//  ladder (Earned / In progress / Locked) plus the hero tier-overview
//  card. Spec § 4.2, § 7. Used by HangarView's Trophies segment.
//
//  This view is the body of the former standalone TrophiesScreen —
//  TrophiesScreen now wraps this view so any remaining push paths
//  (e.g. settings, future deep links) still work.
//
//  Layout matches the Sets and Recent feeds: a ScrollView + LazyVStack
//  of rounded cards (NOT a List). The List was inset-grouped and
//  UICollectionView-backed, which — stacked with the other heavy
//  segment — was part of the Trophies-tab lag; the bigger cost was the
//  blur-shadowed trophy badges re-compositing every frame, fixed in
//  TrophyView (drawingGroup + no blur). LazyVStack also means only the
//  on-screen badges render at all.
//

import SwiftUI
import SwiftData

struct HangarTrophiesView: View {
    @Query private var catches: [Catch]

    var body: some View {
        // Compute the aggregate ONCE per render and derive the three
        // partitions from it — the old version recomputed `inputs` (an
        // O(catches) pass) on every access of every computed property.
        let inputs = Trophies.inputs(from: catches)
        let earned = Trophies.roster.filter { !$0.isLocked(inputs: inputs) }
        let inProgress = Trophies.roster.filter { isInProgress($0, inputs: inputs) }
        let inProgressIDs = Set(inProgress.map(\.id))
        let locked = Trophies.roster.filter { $0.isLocked(inputs: inputs) && !inProgressIDs.contains($0.id) }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                heroCard(inputs: inputs, unlocked: earned.count, inProgressCount: inProgress.count)
                    .padding(.bottom, 2)

                if !earned.isEmpty {
                    sectionHeader("EARNED", count: earned.count)
                    ForEach(earned) { achievementCard($0, inputs: inputs) }
                }
                if !inProgress.isEmpty {
                    sectionHeader("IN PROGRESS", count: inProgress.count)
                    ForEach(inProgress) { achievementCard($0, inputs: inputs) }
                }
                if !locked.isEmpty {
                    sectionHeader("LOCKED", count: locked.count)
                    ForEach(locked) { lockedCard($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Brand.Color.bgPrimary)
    }

    /// Locked, but at least 25 % of the way to its next tier — the
    /// "close to unlocking" bucket that tells the user where to push.
    private func isInProgress(_ ach: Achievement, inputs: TrophyProgressInputs) -> Bool {
        guard ach.isLocked(inputs: inputs), let next = ach.nextTier(inputs: inputs) else { return false }
        return Double(ach.currentProgress(inputs: inputs)) / Double(max(1, next.at)) >= 0.25
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            Text("\(count)")
                .font(Brand.Font.mono(size: 10, weight: .semibold))
                .foregroundStyle(Brand.Color.textTertiary.opacity(0.6))
                .monospacedDigit()
        }
        .padding(.leading, 4)
        .padding(.top, 8)
    }

    // MARK: - Hero card

    private func heroCard(inputs: TrophyProgressInputs, unlocked: Int, inProgressCount: Int) -> some View {
        let tierCounts = Dictionary(grouping: Trophies.roster.compactMap { $0.currentTier(inputs: inputs) }) { $0 }
            .mapValues(\.count)
        return VStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach(TrophyTier.allCases, id: \.self) { tier in
                    tierColumn(tier: tier, count: tierCounts[tier] ?? 0, inputs: inputs)
                        .frame(maxWidth: .infinity)
                }
            }
            Rectangle()
                .fill(Brand.Color.textPrimary.opacity(0.06))
                .frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(unlocked)")
                    .font(Brand.Font.mono(size: 30, weight: .heavy))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("of \(Trophies.roster.count) unlocked")
                    .font(Brand.Font.cardSubtitle)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if inProgressCount > 0 {
                    Text("\(inProgressCount) CLOSE")
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Brand.Color.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Brand.Color.cyan.opacity(0.16), in: .capsule)
                }
            }
        }
        .padding(16)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.06), lineWidth: 1)
        )
    }

    private func tierColumn(tier: TrophyTier, count: Int, inputs: TrophyProgressInputs) -> some View {
        VStack(spacing: 6) {
            TrophyView(tier: tier, iconName: representativeIcon(for: tier, inputs: inputs), size: 46, locked: count == 0)
                .opacity(count == 0 ? 0.45 : 1)
            Text("\(count)")
                .font(Brand.Font.mono(size: 13, weight: .bold))
                .foregroundStyle(count == 0 ? Brand.Color.textTertiary : Color(hex: tier.outerHex))
                .monospacedDigit()
        }
    }

    /// First achievement currently at `tier`, falling back to a stable
    /// per-tier default so the strip never renders blank.
    private func representativeIcon(for tier: TrophyTier, inputs: TrophyProgressInputs) -> String {
        if let found = Trophies.roster.first(where: { $0.currentTier(inputs: inputs) == tier }) {
            return found.iconName
        }
        switch tier {
        case .bronze:   return "catcher"
        case .silver:   return "diamond"
        case .gold:     return "centurion"
        case .platinum: return "crown"
        }
    }

    // MARK: - Achievement card (earned + in-progress)

    private func achievementCard(_ ach: Achievement, inputs: TrophyProgressInputs) -> some View {
        let current = ach.currentTier(inputs: inputs)
        let next = ach.nextTier(inputs: inputs)
        let progress = ach.currentProgress(inputs: inputs)
        return HStack(alignment: .center, spacing: 14) {
            TrophyView(
                tier: current ?? .bronze,
                iconName: ach.iconName,
                size: 52,
                locked: current == nil
            )
            VStack(alignment: .leading, spacing: 5) {
                Text(ach.title)
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(ach.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .lineLimit(1)
                rowFooter(ach: ach, current: current, next: next, progress: progress)
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

    /// Bottom line of the row: either "TIER · progress / next" with a
    /// progress bar, or "MAX" when every tier is already unlocked.
    @ViewBuilder
    private func rowFooter(ach: Achievement, current: TrophyTier?, next: AchievementTier?, progress: Int) -> some View {
        if let next {
            let prevAt = ach.tiers.last { progress >= $0.at }?.at ?? 0
            let span = max(1, next.at - prevAt)
            let fill = max(0, min(1, Double(progress - prevAt) / Double(span)))
            HStack(spacing: 6) {
                if let current {
                    Text(current.label)
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .foregroundStyle(Color(hex: current.outerHex))
                        .tracking(0.8)
                }
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

    // MARK: - Locked card

    /// LOCKED section card: hides the title + summary behind "???" so
    /// the user discovers them by playing.
    private func lockedCard(_ ach: Achievement) -> some View {
        HStack(alignment: .center, spacing: 14) {
            TrophyView(tier: .bronze, iconName: ach.iconName, size: 52, locked: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("???")
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textSecondary)
                Text("Hidden trophy — unlock by playing.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated.opacity(0.5), in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Brand.Color.textPrimary.opacity(0.05), lineWidth: 1)
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
