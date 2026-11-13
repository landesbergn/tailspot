//
//  TrophyTabModel.swift
//  Tailspot
//
//  Pure derivation behind the Trophies tab: what each of its three
//  sections shows and in what order, plus the property builders for the
//  tab's analytics events. No SwiftUI and no state, so the rules ("a
//  secret stays masked until earned", "earned feats lead") are unit-tested
//  without a view, and the views can be fed synthetic inputs.
//

import Foundation

/// One feat cell: the achievement plus the two facts the grid needs.
nonisolated struct TrophyFeatItem: Identifiable, Sendable {
    let achievement: Achievement
    let earned: Bool
    /// Secret and still locked: shown as "???", no name, no detail.
    var masked: Bool { achievement.secret && !earned }
    var id: String { achievement.id }
}

/// One chase card: the chase plus the ring it draws.
nonisolated struct TrophyChaseItem: Identifiable, Sendable {
    let chase: TrophyChase
    let badge: TrophyBadgeSpec
    var id: String { chase.id }
}

/// Everything the tab renders, derived once per data change.
nonisolated struct TrophyTabContent: Sendable {
    let inputs: TrophyProgressInputs
    let roster: [Achievement]
    let chases: [TrophyChaseItem]
    let tracks: [TrophyTrackState]
    let feats: [TrophyFeatItem]
    /// Earned roster entries that are track levels / feats.
    let levelsEarned: Int
    let featsEarned: Int

    var earned: Int { levelsEarned + featsEarned }

    static func make(inputs: TrophyProgressInputs, roster: [Achievement] = Trophies.roster) -> TrophyTabContent {
        let tracks = TrophyTrackState.all(inputs: inputs, roster: roster)
        let trackByID = Dictionary(tracks.map { ($0.track.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chases = TrophyChases.pick(inputs: inputs, roster: roster).map { chase -> TrophyChaseItem in
            if let track = chase.track, let state = trackByID[track.id] {
                return TrophyChaseItem(chase: chase, badge: TrophyBadgeSpec(state: state))
            }
            return TrophyChaseItem(chase: chase, badge: TrophyBadgeSpec(feat: chase.achievement, earned: false))
        }
        let feats = ordered(feats: TrophyTracks.feats(roster: roster), inputs: inputs)
        let levels = roster.filter { TrophyTracks.track(forAchievementID: $0.id) != nil && $0.isEarned(inputs: inputs) }.count
        return TrophyTabContent(
            inputs: inputs, roster: roster, chases: chases, tracks: tracks, feats: feats,
            levelsEarned: levels, featsEarned: feats.filter(\.earned).count)
    }

    /// Earned feats first, then locked ones, then locked secrets last (they
    /// are placeholders). Roster order is kept inside each group.
    static func ordered(feats: [Achievement], inputs: TrophyProgressInputs) -> [TrophyFeatItem] {
        let items = feats.map { TrophyFeatItem(achievement: $0, earned: $0.isEarned(inputs: inputs)) }
        return items.filter(\.earned)
            + items.filter { !$0.earned && !$0.masked }
            + items.filter(\.masked)
    }

    /// The achievement a track opens its detail on: the level in progress
    /// when nothing is earned, otherwise the level the player holds.
    static func focusAchievement(for state: TrophyTrackState, roster: [Achievement]) -> Achievement? {
        let byID = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let levels = state.track.levelIDs.compactMap { byID[$0] }
        guard !levels.isEmpty else { return nil }
        return levels[max(0, min(levels.count - 1, state.level - 1))]
    }
}

/// Where a detail sheet was opened from (the `source` property).
nonisolated enum TrophyDetailSource: String, Sendable {
    case chase, track, feat
}

/// Analytics property builders for the Trophies tab events, pure so they
/// are pinned in tests (the `TrophyUnlockCenter.unlockProperties` pattern).
nonisolated enum TrophyAnalytics {
    static let tabViewed = "trophies_tab_viewed"
    static let detailOpened = "trophy_detail_opened"
    static let shareOpened = "trophy_share_opened"
    static let shareCompleted = "trophy_share_completed"
    /// The reveal strip (which track the catch moved) was displayed.
    static let progressShown = "trophy_progress_shown"

    static func progressShownProperties(_ advance: TrophyAdvance) -> [String: AnalyticsValue] {
        [
            "track": .string(advance.track.id),
            "level": .int(advance.level),
            "progress": .int(advance.progress),
            "goal": .int(advance.goal),
        ]
    }

    static func tabViewedProperties(_ content: TrophyTabContent) -> [String: AnalyticsValue] {
        [
            "earned": .int(content.earned),
            "levels_earned": .int(content.levelsEarned),
            "feats_earned": .int(content.featsEarned),
            "chases": .string(content.chases.map(\.id).joined(separator: ",")),
        ]
    }

    /// `track` + `level` only for a track level.
    private static func identity(_ a: Achievement) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = ["achievement": .string(a.id)]
        if let track = TrophyTracks.track(forAchievementID: a.id),
           let level = TrophyTracks.level(ofAchievementID: a.id) {
            props["track"] = .string(track.id)
            props["level"] = .int(level)
        }
        return props
    }

    static func detailOpenedProperties(
        _ a: Achievement, earned: Bool, source: TrophyDetailSource
    ) -> [String: AnalyticsValue] {
        var props = identity(a)
        props["earned"] = .bool(earned)
        props["secret"] = .bool(a.secret)
        props["source"] = .string(source.rawValue)
        return props
    }

    /// Shared by `trophy_share_opened` and `trophy_share_completed`.
    static func shareProperties(_ a: Achievement) -> [String: AnalyticsValue] {
        identity(a)
    }
}
