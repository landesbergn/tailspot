//
//  TrophyDetailSheet.swift
//  Tailspot
//
//  The detail for one trophy, presented as a sheet from the Trophies tab.
//  Big badge, display title ("Heavies II"), unit-aware summary, the earned
//  date from the achievement-date ledger, and — for a track — the level
//  ladder with a check + date per earned level and the progress to the
//  next. A masked secret shows only "???" / "Hidden feat". Share appears
//  only once the trophy is earned. No catch photo: the trophy is the
//  subject.
//

import os
import SwiftUI

/// One share-sheet presentation: the rendered card.
private struct TrophySharePayload: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct TrophyDetailSheet: View {
    let achievement: Achievement
    let inputs: TrophyProgressInputs
    let dates: [String: Date]
    var roster: [Achievement] = Trophies.roster
    var units: DisplayUnits = UnitPreferences.shared.units
    /// Handle shown on the share card; nil resolves the stored one.
    var handleOverride: String? = nil
    let onClose: () -> Void

    @AppStorage(SpotterHandle.storageKey) private var storedHandle: String = SpotterHandle.defaultPlaceholder
    @State private var share: TrophySharePayload?

    private var earned: Bool { achievement.isEarned(inputs: inputs) }
    private var masked: Bool { achievement.secret && !earned }
    private var track: TrophyTrack? { TrophyTracks.track(forAchievementID: achievement.id) }
    private var state: TrophyTrackState? {
        track.flatMap { TrophyTrackState.make(track: $0, inputs: inputs, roster: roster) }
    }
    private var badge: TrophyBadgeSpec {
        TrophyBadgeSpec(achievement: achievement, inputs: inputs, roster: roster)
    }
    private var title: String { masked ? "???" : TrophyTracks.displayTitle(for: achievement) }
    private var summary: String {
        masked ? "Hidden feat" : TrophyTracks.displaySummary(for: achievement, units: units)
    }
    private var earnedDate: Date? { dates[achievement.id] }

    private var handle: String? {
        let h = handleOverride ?? storedHandle
        return AnalyticsIdentity.isClaimedHandle(h, placeholder: SpotterHandle.defaultPlaceholder)
            ? h.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 16) {
                    TrophyBadge(badge, size: 120)
                    VStack(spacing: 8) {
                        Text(title)
                            .brandDisplayFont()
                            .foregroundStyle(Brand.Color.textPrimary)
                            .multilineTextAlignment(.center)
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(Brand.Color.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    if !masked {
                        earnedLine
                        if let state {
                            ladder(state)
                        } else if !earned, achievement.threshold > 1 {
                            featProgress
                        }
                        if earned { shareButton }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 56)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            ChromeButton(.close, action: onClose)
                .padding(.top, 8)
                .padding(.trailing, 16)
        }
        .background(Brand.Color.bgPrimary)
        .sheet(item: $share) { payload in
            ActivityShareSheet(items: [payload.image]) { method in
                guard method != nil else { return }
                Analytics.capture(TrophyAnalytics.shareCompleted,
                                  TrophyAnalytics.shareProperties(achievement))
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var earnedLine: some View {
        if earned {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").foregroundStyle(Brand.Color.cyan)
                if let earnedDate {
                    Text("Earned \(earnedDate.formatted(.dateTime.month(.abbreviated).day().year()))")
                } else {
                    Text("Date unavailable")
                }
            }
            .font(Brand.Font.mono(size: 12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(Brand.Color.textSecondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func ladder(_ state: TrophyTrackState) -> some View {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let levels = state.track.levelIDs.compactMap { byID[$0] }
        return VStack(alignment: .leading, spacing: 12) {
            TrophyEyebrow(title: "LEVELS")
            ForEach(Array(levels.enumerated()), id: \.element.id) { idx, level in
                let done = level.isEarned(inputs: inputs)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TrophyTracks.roman(idx + 1))
                        .font(Brand.Font.mono(size: 12, weight: .bold, relativeTo: .caption))
                        .foregroundStyle(done ? Brand.Color.cyan : Brand.Color.textTertiary)
                        .frame(minWidth: 28, alignment: .leading)
                    Text(state.track.goalCopy(level.threshold))
                        .font(.subheadline)
                        .foregroundStyle(done ? Brand.Color.textPrimary : Brand.Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if done {
                        HStack(spacing: 5) {
                            if let date = dates[level.id] {
                                Text(date, format: .dateTime.month(.abbreviated).day().year())
                                    .font(Brand.Font.mono(size: 10, relativeTo: .caption2))
                                    .foregroundStyle(Brand.Color.textTertiary)
                            }
                            Image(systemName: "checkmark").foregroundStyle(Brand.Color.cyan)
                                .font(.caption.weight(.bold))
                        }
                        .fixedSize()
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Level \(idx + 1), \(state.track.goalCopy(level.threshold)), \(done ? "earned" : "locked")")
            }
            Divider().overlay(Brand.Color.textPrimary.opacity(0.08))
            if let goal = state.nextGoal {
                TrophyProgressBar(fill: state.fraction)
                HStack {
                    Text(TrophyCopy.trackCaption(state))
                    Spacer(minLength: 8)
                    Text(TrophyTracks.displayTitle(for: state.nextAchievement ?? achievement))
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(TrophyCopy.fraction(state.progress, goal)) to level \(TrophyTracks.roman(state.level + 1))")
            } else {
                Text("All levels complete")
                    .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(Brand.Color.cyan)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var featProgress: some View {
        let progress = achievement.currentProgress(inputs: inputs)
        return VStack(alignment: .leading, spacing: 8) {
            TrophyProgressBar(fill: Double(min(progress, achievement.threshold)) / Double(achievement.threshold))
            Text(TrophyCopy.fraction(progress, achievement.threshold))
                .font(Brand.Font.mono(size: 11, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var shareButton: some View {
        Button(action: startShare) {
            Label("Share", systemImage: "square.and.arrow.up")
                .font(Brand.Font.button)
                .foregroundStyle(Brand.Color.bgPrimary)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func startShare() {
        Analytics.capture(TrophyAnalytics.shareOpened, TrophyAnalytics.shareProperties(achievement))
        let card = TrophyShareCard(
            badge: badge, title: TrophyTracks.displayTitle(for: achievement),
            summary: TrophyTracks.displaySummary(for: achievement, units: units),
            earnedAt: earnedDate, handle: handle)
        guard let image = card.uiImage() else {
            Log.ui.error("Trophy share card failed to render for \(achievement.id, privacy: .public)")
            return
        }
        share = TrophySharePayload(image: image)
    }
}
