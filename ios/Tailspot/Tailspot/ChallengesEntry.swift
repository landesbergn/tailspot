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
/// until the hub has been opened once (the whole first-run discovery
/// story — no NEW pill, no coachmark). Hidden entirely when the server has
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
                    // The count of challenges you're in wins; the discovery
                    // dot only shows while there's nothing to count.
                    if model.activeCount > 0 {
                        ChallengeCountBadge(count: model.activeCount)
                            .offset(x: 10, y: -9)
                    } else if !model.hubSeen {
                        Circle()
                            .fill(Brand.Color.cyan)
                            .frame(width: 7, height: 7)
                            .overlay { Circle().strokeBorder(Brand.Color.bgPrimary, lineWidth: 1.5) }
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel(Self.accessibilityLabel(active: model.activeCount, hubSeen: model.hubSeen))
        }
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
