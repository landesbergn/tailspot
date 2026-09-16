//
//  ChallengesEntry.swift
//  Tailspot
//
//  The three small entry points into Challenges that live on OTHER
//  screens (spec §3.3–3.4): the Profile tile's subtitle, the Leaderboard's
//  toolbar flag with its one-time discovery dot, and the slim live strip
//  under the leaderboard's window switcher. Plus the production factory
//  for the app-wide `ChallengesModel`.
//
//  The copy is a pure, clock-injected function so the tile and the strip
//  can never disagree and the tests pin every headline case.
//

import SwiftUI

/// What the Profile tile and the Leaders strip say for a given headline.
nonisolated enum ChallengesEntryCopy {
    struct Line: Equatable {
        /// Mono ALL-CAPS state word ("IN FLIGHT"), nil for the cold state.
        let state: String?
        /// The human line ("Weekend Flyoff · 2nd · 48M LEFT").
        let detail: String
    }

    /// `me` is the caller's cached standing for the headline challenge
    /// (the list rows carry `myResult` only for finished challenges; a live
    /// placement comes from the detail the hub or strip already loaded).
    static func line(for headline: ChallengesModel.Headline, now: Date,
                     me: ChallengeMyResult? = nil) -> Line {
        switch headline {
        case .live(let c):
            var parts = [c.name]
            if let mine = c.myResult ?? me {
                parts.append(ChallengeTiming.placementLabel(placement: mine.placement, isTie: false))
            }
            parts.append(ChallengeTiming.timeRemainingCopy(until: c.endsAt, now: now))
            return Line(state: "IN FLIGHT", detail: parts.joined(separator: " · "))
        case .resultsReady(let c):
            return Line(state: "FINISHED", detail: "\(c.name) · see results")
        case .upcoming(let c):
            return Line(state: "ON DECK", detail: "\(c.name) · \(ChallengeTiming.startsInCopy(startsAt: c.startsAt, now: now))")
        case .none:
            return Line(state: nil, detail: "Race a friend")
        }
    }

    /// The challenge a headline points at, for the strip's destination.
    static func challengeId(for headline: ChallengesModel.Headline) -> String? {
        switch headline {
        case .live(let c), .resultsReady(let c), .upcoming(let c): return c.id
        case .none: return nil
        }
    }
}

// MARK: - Production model

enum ChallengesAppModel {
    /// The one app-wide model: real client, real reminder scheduler. DEBUG
    /// builds from `bin/deploy` carry CFBundleVersion 1 (CI bumps it), so
    /// they pass `Int.max` and never read as "update required" against the
    /// server's `minBuild`; Release builds compare their real build number.
    @MainActor
    static func make() -> ChallengesModel {
        #if DEBUG
        let build = Int.max
        #else
        let build = ChallengeBuildGate.currentBuild()
        #endif
        return ChallengesModel(
            service: ChallengesClient(),
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

    var body: some View {
        if let model, model.verdict != .disabled {
            NavigationLink {
                ChallengesHub(source: "leaders_flag")
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "flag.checkered")
                    if !model.hubSeen {
                        Circle()
                            .fill(Brand.Color.cyan)
                            .frame(width: 7, height: 7)
                            .overlay { Circle().strokeBorder(Brand.Color.bgPrimary, lineWidth: 1.5) }
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
            }
            .accessibilityLabel(model.hubSeen ? "Challenges" : "Challenges, new")
        }
    }
}

// MARK: - Leaders live strip

/// One slim row under the window switcher while you are in a challenge
/// (spec §3.3, D2): the hot-state entry. Absent in the cold state, so the
/// leaderboard looks exactly as it did before Challenges existed.
struct ChallengesStrip: View {
    @Environment(ChallengesModel.self) private var model: ChallengesModel?

    var body: some View {
        if let model, model.verdict != .disabled,
           let id = ChallengesEntryCopy.challengeId(for: model.headline) {
            let line = ChallengesEntryCopy.line(for: model.headline, now: model.now(),
                                                me: model.details[id]?.me)
            NavigationLink {
                ChallengeDetailScreen(id: id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .accessibilityHidden(true)
                    if let state = line.state {
                        Text(state)
                            .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                            .tracking(1.1)
                            .foregroundStyle(Brand.Color.cyan)
                    }
                    Text(line.detail)
                        .font(Brand.Font.mono(size: 11, weight: .regular, relativeTo: .caption))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 36)
                .background(Brand.Color.cyan.opacity(0.09), in: .rect(cornerRadius: Brand.Radius.row))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.row)
                        .strokeBorder(Brand.Color.cyan.opacity(0.22), lineWidth: 1)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .padding(.top, 2)
        }
    }
}
