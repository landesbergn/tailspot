//
//  TrophiesScreen.swift
//  Tailspot
//
//  Reads every `Catch` from SwiftData, runs the trophy classifier
//  once over them, and renders an inset-grouped list of the full
//  achievement roster. Each row carries the trophy badge, title,
//  current tier (or "LOCKED"), and progress toward the next tier.
//

import SwiftUI
import SwiftData

struct TrophiesScreen: View {
    @Query private var catches: [Catch]
    /// Computed once per `catches` change. The `body` re-evaluates
    /// on @Query updates, but this keeps the cost off the per-row
    /// path.
    private var inputs: TrophyProgressInputs {
        Trophies.inputs(from: catches)
    }

    private var unlockedCount: Int {
        Trophies.roster.filter { !$0.isLocked(inputs: inputs) }.count
    }

    // MARK: - Partition by status

    /// Trophies the user has unlocked at any tier.
    private var earnedTrophies: [Achievement] {
        Trophies.roster.filter { !$0.isLocked(inputs: inputs) }
    }

    /// Locked trophies with at least one tier whose threshold the
    /// user is at least 25 % of the way to. Surfaces "close to
    /// unlocking" candidates so the screen suggests where to push.
    private var inProgressTrophies: [Achievement] {
        Trophies.roster.filter { ach in
            guard ach.isLocked(inputs: inputs),
                  let next = ach.nextTier(inputs: inputs) else { return false }
            let p = ach.currentProgress(inputs: inputs)
            return Double(p) / Double(max(1, next.at)) >= 0.25
        }
    }

    /// Locked + not close — rendered as anonymous "???" cards so the
    /// user has a discoverable surface area to play toward.
    private var lockedTrophies: [Achievement] {
        Trophies.roster.filter { ach in
            ach.isLocked(inputs: inputs) && !inProgressTrophies.contains(ach)
        }
    }

    var body: some View {
        List {
            Section {
                heroStrip
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if !earnedTrophies.isEmpty {
                Section("Earned") {
                    ForEach(earnedTrophies) { ach in
                        achievementRow(ach)
                    }
                }
            }
            if !inProgressTrophies.isEmpty {
                Section {
                    ForEach(inProgressTrophies) { ach in
                        achievementRow(ach)
                    }
                } header: {
                    Text("In progress")
                } footer: {
                    Text("Close to unlocking — keep catching.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
            if !lockedTrophies.isEmpty {
                Section("Locked") {
                    ForEach(lockedTrophies) { ach in
                        hiddenRow(ach)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Trophies")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Cards rendered in the LOCKED section. Hides the title +
    /// summary behind "???" placeholders so the user discovers them
    /// by playing. Tappable later (defer detail-sheet to a future
    /// iteration) — for now this is a static row.
    private func hiddenRow(_ ach: Achievement) -> some View {
        HStack(alignment: .center, spacing: 14) {
            TrophyView(tier: .bronze, iconName: ach.iconName, size: 56, locked: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("???")
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Hidden trophy — unlock by playing.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Hero strip

    /// Tier overview: one of each tier the user has earned, lined up
    /// at the top so the page opens with the most visually
    /// satisfying content.
    private var heroStrip: some View {
        let tierCounts = Dictionary(grouping: Trophies.roster.compactMap { $0.currentTier(inputs: inputs) }) { $0 }
            .mapValues(\.count)
        return VStack(spacing: 14) {
            HStack(spacing: 18) {
                ForEach(TrophyTier.allCases, id: \.self) { tier in
                    tierColumn(tier: tier, count: tierCounts[tier] ?? 0)
                }
            }
            .padding(.horizontal, 24)
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(unlockedCount)")
                        .font(.system(size: 32, weight: .heavy, design: .monospaced))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .monospacedDigit()
                    Text("of \(Trophies.roster.count)")
                        .font(Brand.Font.cardSubtitle)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .monospacedDigit()
                }
                if !inProgressTrophies.isEmpty {
                    Text("\(inProgressTrophies.count) close to unlocking")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Brand.Color.cyan)
                } else {
                    Text("UNLOCKED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated)
    }

    private func tierColumn(tier: TrophyTier, count: Int) -> some View {
        VStack(spacing: 6) {
            // Show a representative trophy in this tier from the
            // roster; pick the first achievement currently at this
            // tier so the icon means something to the user.
            let rep = representativeIcon(for: tier)
            TrophyView(tier: tier, iconName: rep, size: 44, locked: count == 0)
                .opacity(count == 0 ? 0.55 : 1)
            Text("\(count)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: tier.outerHex))
                .monospacedDigit()
        }
    }

    /// First achievement currently at `tier`, falling back to a
    /// stable per-tier default so the strip never renders blank.
    private func representativeIcon(for tier: TrophyTier) -> String {
        let found = Trophies.roster.first { $0.currentTier(inputs: inputs) == tier }
        if let found { return found.iconName }
        switch tier {
        case .bronze:   return "catcher"
        case .silver:   return "diamond"
        case .gold:     return "centurion"
        case .platinum: return "crown"
        }
    }

    // MARK: - Row

    private func achievementRow(_ ach: Achievement) -> some View {
        let current = ach.currentTier(inputs: inputs)
        let next = ach.nextTier(inputs: inputs)
        let progress = ach.currentProgress(inputs: inputs)
        return HStack(alignment: .center, spacing: 14) {
            TrophyView(
                tier: current ?? .bronze,
                iconName: ach.iconName,
                size: 56,
                locked: current == nil
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(ach.title)
                    .font(Brand.Font.cardTitle)
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(ach.summary)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                rowFooter(ach: ach, current: current, next: next, progress: progress)
            }
        }
        .padding(.vertical, 4)
    }

    /// Bottom line of the row: either "TIER · progress / next" with
    /// a progress bar, or "MAX" when every tier is already unlocked.
    @ViewBuilder
    private func rowFooter(ach: Achievement, current: TrophyTier?, next: AchievementTier?, progress: Int) -> some View {
        if let next {
            let prevAt = ach.tiers.last { progress >= $0.at }?.at ?? 0
            let span = max(1, next.at - prevAt)
            let fill = max(0, min(1, Double(progress - prevAt) / Double(span)))
            HStack(spacing: 6) {
                if let current {
                    Text(current.label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(hex: current.outerHex))
                        .tracking(0.8)
                }
                Text("\(progress) / \(next.at)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
                Spacer(minLength: 6)
                ProgressBar(fill: fill, tint: Color(hex: next.tier.outerHex))
                    .frame(width: 72, height: 4)
            }
        } else if let current {
            Text("\(current.label) · MAX")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(hex: current.outerHex))
                .tracking(0.8)
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
                Capsule().fill(Brand.Color.bgElevated)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(fill))
            }
        }
    }
}

#Preview {
    NavigationStack {
        TrophiesScreen()
    }
    .modelContainer(for: Catch.self, inMemory: true)
}
