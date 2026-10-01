//
//  ChallengesEntry.swift
//  Tailspot
//
//  The small entry points into Challenges that live on OTHER screens
//  (spec §3.3–3.4): the Leaderboard's toolbar flag (a count badge of the
//  challenges you're in, or a one-time discovery dot) and the count badge
//  the Profile tile shares with it. Plus the production factory for the
//  app-wide `ChallengesModel`.
//
//  2026-09-27: the Profile tile's subtitle line and the Leaders live strip
//  were replaced by the count badge, and the copy function that fed both
//  (`ChallengesEntryCopy`) went with them.
//

import SwiftUI

// MARK: - Production model

enum ChallengesAppModel {
    /// The one app-wide model: real client, real reminder scheduler. DEBUG
    /// builds from `bin/deploy` carry CFBundleVersion 1 (CI bumps it), so
    /// they pass `Int.max` and never read as "update required" against the
    /// server's `minBuild`; Release builds compare their real build number.
    /// DEBUG launch argument that swaps the real client for the fixture
    /// demo world (live challenge with a tie, upcoming, won, lost, No
    /// Contest, cancelled, and a code for every joinability outcome), so
    /// the whole feature can be toured on a phone before the backend is
    /// live. Synthetic INPUTS at the one shared funnel, never faked
    /// outputs; the hub badges itself DEMO DATA while it is on. Pass it
    /// with `xcrun devicectl device process launch … -- -challengesFixture`.
    static let fixtureLaunchArgument = "-challengesFixture"

    @MainActor
    static var usesFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(fixtureLaunchArgument)
        #else
        return false
        #endif
    }

    @MainActor
    static func make() -> ChallengesModel {
        #if DEBUG
        let build = Int.max
        let service: ChallengesService = usesFixture ? FixtureChallengesService() : ChallengesClient()
        #else
        let build = ChallengeBuildGate.currentBuild()
        let service: ChallengesService = ChallengesClient()
        #endif
        return ChallengesModel(
            service: service,
            currentBuild: build,
            reminders: ChallengeReminderScheduler()
        )
    }
}

// MARK: - Leaders toolbar flag

/// The checkered flag on the Leaderboard's toolbar. A cyan dot marks it
/// until the hub has been opened once (the Profile tile carries the same
/// dot — no NEW pill, no coachmark). Hidden entirely when the server has
/// the feature off.
struct ChallengesFlagButton: View {
    @Environment(ChallengesModel.self) private var model: ChallengesModel?

    static func accessibilityLabel(active: Int, hubSeen: Bool) -> String {
        if active > 0 { return "Challenges, \(active) active" }
        return hubSeen ? "Challenges" : "Challenges, new"
    }

    var body: some View {
        // `.available` only: with the config unknown (server not reachable,
        // or the feature not deployed yet) the entry point stays hidden
        // rather than opening onto an error — ChallengeBuildGate's own rule.
        if let model, model.verdict == .available {
            NavigationLink {
                ChallengesHub(source: "leaders_flag")
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "flag.checkered")
                    switch ChallengeEntryIndicator(active: model.activeCount, hubSeen: model.hubSeen) {
                    case .count(let n):
                        ChallengeCountBadge(count: n)
                            .offset(x: 10, y: -9)
                    case .discovery:
                        ChallengeDiscoveryDot()
                            .offset(x: 4, y: -4)
                    case .none:
                        EmptyView()
                    }
                }
            }
            .accessibilityLabel(Self.accessibilityLabel(active: model.activeCount, hubSeen: model.hubSeen))
        }
    }
}

// MARK: - Indicator rule

/// What sits on a Challenges entry point's icon. The Leaders flag and the
/// Profile tile share one rule so they never disagree: the count of
/// challenges you're in wins; the discovery dot only shows while there's
/// nothing to count and the hub has never been opened.
///
/// The dot used to live on the flag alone, and the flag sits inside the
/// Leaderboard sheet, so someone who never opened Leaders never learned
/// Challenges existed. The Profile tile got the same dot on 2026-09-30.
enum ChallengeEntryIndicator: Equatable {
    case count(Int)
    case discovery
    case none

    init(active: Int, hubSeen: Bool) {
        if active > 0 { self = .count(active) }
        else if !hubSeen { self = .discovery }
        else { self = .none }
    }

    /// VoiceOver value for the Profile tile ("2 active", "new", or nothing).
    var accessibilityValue: String {
        switch self {
        case .count(let n): return "\(n) active"
        case .discovery: return "new"
        case .none: return ""
        }
    }
}

extension ChallengesModel {
    /// The catch screen's Leaders button carries the dot for discovery
    /// only, never a count: the AR view stays quiet once Challenges has
    /// been seen. Same `.available` gate as the other entry points, so a
    /// dot never leads to a hub that would open onto an error.
    var showsBarDiscoveryDot: Bool {
        verdict == .available
            && ChallengeEntryIndicator(active: activeCount, hubSeen: hubSeen) == .discovery
    }
}

/// The small cyan "you haven't looked yet" dot. The bgPrimary ring keeps
/// it legible where it overlaps the glyph. 7 pt on the toolbar flag and
/// the Profile tile; the catch screen's 56 pt bar chip takes a bigger one.
struct ChallengeDiscoveryDot: View {
    var diameter: CGFloat = 7
    var ring: CGFloat = 1.5

    var body: some View {
        Circle()
            .fill(Brand.Color.cyan)
            .frame(width: diameter, height: diameter)
            .overlay { Circle().strokeBorder(Brand.Color.bgPrimary, lineWidth: ring) }
            .accessibilityHidden(true)
    }
}

// MARK: - Count badge

/// The small cyan count on the Profile tile icon and the Leaderboard flag:
/// how many challenges you're in right now (live + upcoming). Replaced the
/// Leaders strip and the tile's subtitle line (Noah, 2026-09-27) — the
/// number says "you have something going on" without a sentence to fit.
struct ChallengeCountBadge: View {
    let count: Int

    var body: some View {
        Text(count > 9 ? "9+" : "\(count)")
            .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
            .monospacedDigit()
            .foregroundStyle(Brand.Color.bgPrimary)
            .padding(.horizontal, 5)
            .frame(minWidth: 17, minHeight: 17)
            .background(Brand.Color.cyan, in: .capsule)
            .overlay { Capsule().strokeBorder(Brand.Color.bgPrimary, lineWidth: 1.5) }
            .fixedSize()
            .accessibilityHidden(true)
    }
}
