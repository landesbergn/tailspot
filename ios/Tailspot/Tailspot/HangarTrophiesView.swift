//
//  HangarTrophiesView.swift
//  Tailspot
//
//  Trophies segment of the Hangar sheet. Rebuilt 2026-11 around three
//  sections in one scroll (see STRATEGY: collection & progression):
//
//    CHASING NOW  up to three live goals side by side (a vertical stack of
//                 full-width rows at accessibility text sizes),
//    TRACKS       one row per ladder (Heavies I-III…): badge at the current
//                 level, level pips, progress to the next,
//    FEATS        a 3-column grid of one-offs, earned first; secrets stay
//                 a "???" until earned.
//
//  Every card, row and cell is a Button that opens `TrophyDetailSheet`.
//  Badges are `TrophyBadge` (art direction "C": one monoline symbol in a
//  segmented ring).
//
//  Structure: `TrophiesTabContentView` is a plain function of
//  `TrophyTabContent` (so snapshots feed it synthetic inputs); the thin
//  `HangarTrophiesView` wrapper owns the @Query, the memo (a token compare
//  when nothing changed), the date backfill, analytics and the sheet.
//

import SwiftUI
import SwiftData

// MARK: - Wrapper (data + presentation)

/// The sheet's subject: an achievement plus where it was opened from.
struct TrophyDetailTarget: Identifiable {
    let achievement: Achievement
    let source: TrophyDetailSource
    var id: String { achievement.id }
}

struct HangarTrophiesView: View {
    /// True while the Trophies segment is the visible page. HangarView keeps
    /// every segment alive in a paged TabView, so `onAppear` fires at sheet
    /// open whichever segment is showing; this flag is what "became visible"
    /// keys off.
    var isActive: Bool = true

    @Query private var catches: [Catch]
    @AppStorage(UserDefaultsTrophyLedger.achievedDatesKey) private var achievedDatesData = Data()
    /// Memoizes the derived content so segment switches (which re-eval this
    /// kept-alive page's body) render from cache — see HangarDerivedCache.
    @State private var cache = DerivedCacheBox<TrophyTabContent>()
    @State private var detail: TrophyDetailTarget?

    /// The memo key: `TrophyInputsToken`, the same key TrophyUnlockCenter
    /// and ProfileScreen use. It covers every input `Trophies.inputs` reads
    /// (rows incl. the late `guessCorrect` stamp and `caughtDayKey`, the time
    /// zone, the event and standing stores), so this tab and Profile can't
    /// disagree.
    static func memoKey(
        _ catches: [Catch],
        events: TrophyEventStore = TrophyEventStore(),
        standing: LeaderboardStandingCache = LeaderboardStandingCache(),
        timeZone: TimeZone = .current
    ) -> Int {
        TrophyInputsToken.of(catches, events: events, standing: standing, timeZone: timeZone)
    }

    var body: some View {
        // One hashing pass per body eval, shared by the memo and the task id.
        let token = Self.memoKey(catches)
        // The inputs come from the shared memo: the app-root unlock center
        // has usually computed them for this exact token already (launch
        // diff, post-catch diff), so opening the Hangar is a token compare
        // instead of a full pass. This box only keeps the derived content.
        let content = cache.value(for: token) {
            let inputs = TrophyInputsMemo.shared.inputs(for: token) { Trophies.inputs(from: catches) }
            return TrophyTabContent.make(inputs: inputs)
        }
        let dates = UserDefaultsTrophyLedger.achievedDates(from: achievedDatesData)
        return TrophiesTabContentView(content: content, dates: dates, units: UnitPreferences.shared.units) { ach, source in
            let earned = ach.isEarned(inputs: content.inputs)
            Analytics.capture(TrophyAnalytics.detailOpened,
                              TrophyAnalytics.detailOpenedProperties(ach, earned: earned, source: source))
            detail = TrophyDetailTarget(achievement: ach, source: source)
        }
        .task(id: token) {
            await TrophyAchievementDates.backfill(from: catches, inputs: content.inputs)
        }
        // Fires each time the segment becomes visible (and once at sheet
        // open when Trophies is the remembered segment).
        .onChange(of: isActive, initial: true) { _, active in
            guard active else { return }
            Analytics.capture(TrophyAnalytics.tabViewed, TrophyAnalytics.tabViewedProperties(content))
        }
        .sheet(item: $detail) { target in
            TrophyDetailSheet(
                achievement: target.achievement, inputs: content.inputs, dates: dates,
                units: UnitPreferences.shared.units
            ) { detail = nil }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Brand.Color.bgPrimary)
        }
    }
}

// MARK: - The tab body

struct TrophiesTabContentView: View {
    let content: TrophyTabContent
    var dates: [String: Date] = [:]
    var units: DisplayUnits = UnitPreferences.shared.units
    var onOpen: (Achievement, TrophyDetailSource) -> Void = { _, _ in }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                chasing
                tracks
                feats
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .background(Brand.Color.bgPrimary)
    }

    // MARK: CHASING NOW

    @ViewBuilder
    private var chasing: some View {
        if !content.chases.isEmpty {
            TrophyEyebrow(title: "CHASING NOW", trailing: "\(content.chases.count) LIVE")
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    ForEach(content.chases) { chaseCard($0, wide: true) }
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(content.chases) { chaseCard($0, wide: false) }
                }
            }
        }
    }

    private func chaseCard(_ item: TrophyChaseItem, wide: Bool) -> some View {
        Button { onOpen(item.chase.achievement, .chase) } label: {
            TrophyChaseCard(item: item, units: units, wide: wide)
        }
        .buttonStyle(.plain)
    }

    // MARK: TRACKS

    @ViewBuilder
    private var tracks: some View {
        TrophyEyebrow(
            title: "TRACKS",
            trailing: "\(content.levelsEarned) \(content.levelsEarned == 1 ? "LEVEL" : "LEVELS")"
        ).padding(.top, 10)
        VStack(spacing: 8) {
            ForEach(content.tracks, id: \.track.id) { state in
                Button {
                    if let focus = TrophyTabContent.focusAchievement(for: state, roster: content.roster) {
                        onOpen(focus, .track)
                    }
                } label: {
                    TrophyTrackRow(state: state)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: FEATS

    @ViewBuilder
    private var feats: some View {
        TrophyEyebrow(title: "FEATS", trailing: "\(content.featsEarned) OF \(content.feats.count)")
            .padding(.top, 10)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
                            count: typeSize.isAccessibilitySize ? 2 : 3)
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(content.feats) { item in
                Button { onOpen(item.achievement, .feat) } label: {
                    TrophyFeatCell(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 6)
        .background(Brand.Color.bgElevated.opacity(0.5), in: .rect(cornerRadius: Brand.Radius.card))
    }
}

// MARK: - Pieces

/// Section header: mono label + trailing count.
struct TrophyEyebrow: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title)
                .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption))
                .tracking(1.4)
                .foregroundStyle(Brand.Color.textSecondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(Brand.Font.mono(size: 11, relativeTo: .caption))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }
}

struct TrophyProgressBar: View {
    let fill: Double
    var tint: Color = Brand.Color.cyan
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.Color.bgSurface)
                Capsule().fill(tint)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fill))))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Copy shared by the tab, the detail sheet and their accessibility labels.
nonisolated enum TrophyCopy {
    /// "27 / 30"
    static func fraction(_ progress: Int, _ goal: Int) -> String {
        "\(TrophyTracks.grouped(min(progress, goal))) / \(TrophyTracks.grouped(goal))"
    }

    /// "27 / 30 to level 3", or "All levels complete".
    static func trackCaption(_ state: TrophyTrackState) -> String {
        guard let goal = state.nextGoal else { return "All levels complete" }
        return "\(fraction(state.progress, goal)) to level \(state.level + 1)"
    }
}

struct TrophyChaseCard: View {
    let item: TrophyChaseItem
    let units: DisplayUnits
    var wide = false

    private var chase: TrophyChase { item.chase }
    private var isFeat: Bool { chase.kind == .feat }
    private var title: String { TrophyTracks.displayTitle(for: chase.achievement) }
    private var blurb: String {
        isFeat ? TrophyTracks.displaySummary(for: chase.achievement, units: units) : chase.blurb
    }
    private var footer: String { isFeat ? "FEAT" : TrophyCopy.fraction(chase.progress, chase.goal) }

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .top, spacing: 14) {
                    TrophyBadge(item.badge, size: 46)
                    text(reservesBlurb: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TrophyBadge(item.badge, size: 46)
                    text(reservesBlurb: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.card)
            .strokeBorder(Brand.Color.cyan.opacity(0.25), lineWidth: 1))
        .contentShape(.rect(cornerRadius: Brand.Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chasing \(title). \(blurb)\(isFeat ? "" : ", \(chase.progress) of \(chase.goal)")")
        .accessibilityAddTraits(.isButton)
    }

    private var blurbText: some View {
        Text(blurb)
            .font(.caption)
            .foregroundStyle(Brand.Color.textSecondary)
            .multilineTextAlignment(.leading)
    }

    private func text(reservesBlurb: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                // Two lines, reserved in the three-up row so the cards stay
                // aligned: "Heritage Level 2" doesn't fit one line there.
                .lineLimit(2, reservesSpace: !wide)
            if reservesBlurb {
                blurbText.lineLimit(2, reservesSpace: true)
            } else {
                blurbText
            }
            TrophyProgressBar(fill: isFeat ? 0 : chase.fraction)
            Text(footer)
                .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                .tracking(isFeat ? 1 : 0)
                .foregroundStyle(Brand.Color.textTertiary)
                .monospacedDigit()
        }
    }
}

struct TrophyTrackRow: View {
    let state: TrophyTrackState

    @Environment(\.dynamicTypeSize) private var typeSize
    private var earned: Bool { state.level > 0 }

    var body: some View {
        HStack(spacing: 12) {
            TrophyBadge(TrophyBadgeSpec(state: state), size: 50)
            VStack(alignment: .leading, spacing: 6) {
                // One decision for every row (not per-row ViewThatFits), so
                // rows don't flip layout individually at large text sizes.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 4) {
                        name
                        pips
                    }
                } else {
                    HStack(alignment: .firstTextBaseline) {
                        name
                        Spacer(minLength: 8)
                        pips
                    }
                }
                TrophyProgressBar(fill: state.fraction)
                Text(TrophyCopy.trackCaption(state))
                    .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.Color.bgElevated.opacity(earned ? 1 : 0.5), in: .rect(cornerRadius: Brand.Radius.card))
        .contentShape(.rect(cornerRadius: Brand.Radius.card))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.track.name), \(state.level) of \(state.levelCount) levels. \(TrophyCopy.trackCaption(state))")
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        Text(state.track.name)
            .font(Brand.Font.cardTitle)
            .foregroundStyle(earned ? Brand.Color.textPrimary : Brand.Color.textSecondary)
    }

    private var pips: some View {
        // "Level 3 of 4" in words; the ring beside the name already shows
        // the same thing as lit segments.
        Text(state.level == 0 ? "\(state.levelCount) levels" : "Level \(state.level) of \(state.levelCount)")
            .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption2))
            .foregroundStyle(state.level > 0 ? Brand.Color.cyan : Brand.Color.textTertiary)
            .fixedSize()
    }
}

struct TrophyFeatCell: View {
    let item: TrophyFeatItem

    private var title: String { item.masked ? "???" : item.achievement.title }

    var body: some View {
        VStack(spacing: 6) {
            TrophyBadge(TrophyBadgeSpec(feat: item.achievement, earned: item.earned), size: 62)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.earned ? Brand.Color.textPrimary : Brand.Color.textTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.masked ? "Hidden feat, locked"
                            : "\(item.achievement.title), \(item.earned ? "earned" : "locked")")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    NavigationStack {
        HangarTrophiesView()
    }
    .modelContainer(for: Catch.self, inMemory: true)
}
