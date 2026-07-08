//
//  PublicScreens.swift
//  Tailspot
//
//  Public surfaces:
//
//   - LeaderboardScreen — live global leaderboard from the backend.
//     Shows rank/handle/points/catches, highlights "me" row (works
//     even handle-less, with a "claim a handle to appear" hint).
//     Loading / error / empty states follow Brand patterns.
//     Pull-to-refresh supported.
//
//   - ProfileShareCard — the shareable profile artboard (Direction-B
//     "Progression" language: standing hero, NEXT UP goal ring, best
//     catch). Rendered to an Image by ProfileScreen and handed to a
//     direct toolbar ShareLink — there is no preview sheet.
//
//  PublicHangarScreen was removed (backend not ready; the NavigationLink
//  it was reachable via has also been removed).
//

import SwiftUI
import SwiftData

// MARK: - Leaderboard (live)

struct LeaderboardScreen: View {
    @AppStorage(SpotterHandle.storageKey) private var localHandle: String = SpotterHandle.defaultPlaceholder

    // Fetch total local points so we can show them in the "me" row
    // when the backend hasn't replied yet, or when not registered.
    @Query private var catches: [Catch]

    // MARK: State
    @State private var entries: [LeaderboardEntry] = []
    @State private var me: MyStanding? = nil
    @State private var loadState: LoadState = .idle
    @State private var isRefreshing = false

    private let client = TailspotAccountClient()

    enum LoadState {
        case idle, loading, loaded, error(String)
    }

    var body: some View {
        List {
            switch loadState {
            case .idle, .loading:
                loadingSection
            case .error(let msg):
                errorSection(msg)
            case .loaded:
                if entries.isEmpty {
                    emptySection
                } else {
                    if entries.count >= 3 {
                        Section {
                            podium
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    rankSection
                    meHintSection
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { if case .idle = loadState { await load() } }
        .onAppear {
            // leaderboard_viewed fires each time the screen becomes visible.
            // entry_count is 0 until load() completes — this is intentional:
            // we want to know how many times the user opens the screen, not just
            // after data arrives. has_handle distinguishes identified vs. anonymous.
            let hasHandle = localHandle != SpotterHandle.defaultPlaceholder && !localHandle.isEmpty
            Analytics.capture("leaderboard_viewed", [
                "entry_count": .int(entries.count),
                "has_handle":  .bool(hasHandle),
            ])
        }
    }

    // MARK: - Load

    private func load() async {
        isRefreshing = true
        if case .idle = loadState { loadState = .loading }
        do {
            let response = try await client.leaderboard()
            entries = response.entries
            me = response.me
            loadState = .loaded
        } catch {
            loadState = .error(error.localizedDescription)
        }
        isRefreshing = false
    }

    // MARK: - Sections

    private var loadingSection: some View {
        Section {
            HStack {
                Spacer()
                ProgressView()
                    .tint(Brand.Color.cyan)
                    .padding(.vertical, 32)
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
    }

    private func errorSection(_ msg: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't load leaderboard", systemImage: "wifi.slash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.alertCaution)
                Text(msg)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Button("Try again") {
                    loadState = .idle
                    Task { await load() }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.cyan)
            }
            .padding(.vertical, 6)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("No handles yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Be the first to claim a handle in Settings → Identity to appear here.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            .padding(.vertical, 6)
        }
    }

    /// Top-3 podium block.
    private var podium: some View {
        HStack(alignment: .bottom, spacing: 8) {
            podiumColumn(entry: entries.first(where: { $0.rank == 2 }), height: 90,  rank: 2)
            podiumColumn(entry: entries.first(where: { $0.rank == 1 }), height: 130, rank: 1)
            podiumColumn(entry: entries.first(where: { $0.rank == 3 }), height: 70,  rank: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .background(Brand.Color.bgElevated)
    }

    private func podiumColumn(entry: LeaderboardEntry?, height: CGFloat, rank: Int) -> some View {
        let tint: Color = {
            switch rank {
            case 1: return Brand.Color.podiumGold
            case 2: return Brand.Color.podiumSilver
            case 3: return Brand.Color.podiumBronze
            default: return Brand.Color.textTertiary
            }
        }()
        return VStack(spacing: 6) {
            if let entry {
                Text("@\(entry.handle)")
                    .font(Brand.Font.mono(size: 10, weight: .bold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .heavy))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6).fill(tint.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint, lineWidth: 1))
                Text("\(rank)")
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(tint)
                    .padding(.top, 8)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
    }

    /// Full ranked list.
    @ViewBuilder
    private var rankSection: some View {
        Section {
            ForEach(entries) { entry in
                leaderRow(entry)
            }
        } footer: {
            Text("Anonymous global. Handles are public; identities aren't tied to Apple ID.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }

    private func leaderRow(_ entry: LeaderboardEntry) -> some View {
        let isMe = isMeEntry(entry)
        return HStack(spacing: 12) {
            Text("\(entry.rank)")
                .font(Brand.Font.mono(size: 14, weight: .bold))
                .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textTertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
            Text("@\(entry.handle)")
                .font(Brand.Font.mono(size: 14, weight: isMe ? .bold : .regular))
                .foregroundStyle(Brand.Color.textPrimary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .bold))
                    .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("\(entry.catches) catch\(entry.catches == 1 ? "" : "es")")
                    .font(Brand.Font.mono(size: 10))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            if isMe {
                Text("YOU")
                    .font(Brand.Font.mono(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Brand.Color.cyan, in: .capsule)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isMe
            ? Brand.Color.cyan.opacity(0.12)
            : Color.clear)
    }

    /// True when this entry is for the current user's handle.
    private func isMeEntry(_ entry: LeaderboardEntry) -> Bool {
        entry.handle.lowercased() == localHandle.lowercased()
    }

    /// "Me" section shown below the ranked list: either the me row from the
    /// API (when the device has a handle), or a prompt to claim one.
    @ViewBuilder
    private var meHintSection: some View {
        let myLocalPoints = ProfileStats(catches: catches).totalPoints
        let hasHandle = !localHandle.isEmpty && localHandle != SpotterHandle.defaultPlaceholder

        if let meStanding = me {
            // Server confirmed our standing — show it.
            Section {
                HStack(spacing: 12) {
                    Text("\(meStanding.rank)")
                        .font(Brand.Font.mono(size: 14, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .leading)
                    Text(hasHandle ? "@\(localHandle)" : "(you)")
                        .font(Brand.Font.mono(size: 14, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    Text("\(meStanding.points.formatted(.number))")
                        .font(Brand.Font.mono(size: 13, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                    Text("YOU")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Brand.Color.cyan, in: .capsule)
                }
                .padding(.vertical, 2)
                .listRowBackground(Brand.Color.cyan.opacity(0.12))
                if !hasHandle {
                    Text("Claim a handle in Settings → Identity to appear in the list above.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            } header: {
                Text("Your standing")
            }
        } else if !hasHandle {
            // Not registered yet or no handle — hint.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You have \(myLocalPoints.formatted(.number)) points locally")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Claim a handle in Settings → Identity to appear on the leaderboard.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Your standing")
            }
        }
    }
}

// MARK: - Share card

/// The shareable profile artboard, redesigned 2026-07-08 in the
/// "Progression" language from the profile layout exploration (Direction
/// B): the card leads with the points/rank standing, then tells a LIVE
/// story — the nearest goal as a tier-metal progress ring and the
/// collection's best catch — instead of a static stat dump. Shared
/// directly from the Profile toolbar via `ShareLink` (the old preview
/// sheet was an extra tap that showed what the share preview shows).
struct ProfileShareCard: View {
    let stats: ProfileStats
    let handle: String
    /// Server rank label ("1st"); nil before the first standing fetch.
    let rankLabel: String?
    /// Nearest incomplete trophy, from `nearestGoal(inputs:)`.
    let goal: ShareGoal?
    /// Highest-rarity airframe in the Hangar, from `bestCatch(in:)`.
    let best: BestCatch?

    /// The trophy tier closest to completion: highest progress fraction
    /// against its next threshold. Zero-progress goals are excluded so a
    /// fresh Hangar doesn't showcase "0/5".
    nonisolated struct ShareGoal {
        let title: String
        let done: Int
        let total: Int
        let tier: TrophyTier

        var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
        /// Ring in the metal of the tier being chased (gold ring for a
        /// gold tier) — same grammar as the trophy icons.
        var ringTint: Color { SwiftUI.Color(hex: tier.outerHex) }
    }

    nonisolated struct BestCatch {
        let name: String
        let rarity: Rarity
    }

    nonisolated static func nearestGoal(inputs: TrophyProgressInputs) -> ShareGoal? {
        var best: (fraction: Double, goal: ShareGoal)?
        for achievement in Trophies.roster where !achievement.secret {
            let progress = achievement.progress(inputs)
            guard progress > 0,
                  let next = achievement.tiers.first(where: { progress < $0.at })
            else { continue }
            let fraction = Double(progress) / Double(next.at)
            if best == nil || fraction > best!.fraction {
                best = (fraction, ShareGoal(title: achievement.title,
                                            done: progress, total: next.at,
                                            tier: next.tier))
            }
        }
        return best?.goal
    }

    nonisolated static func bestCatch(in catches: [Catch]) -> BestCatch? {
        guard let top = catches.max(by: {
            ($0.resolvedRarity.ordinal, $0.caughtAt.timeIntervalSince1970)
                < ($1.resolvedRarity.ordinal, $1.caughtAt.timeIntervalSince1970)
        }) else { return nil }
        let canonical = AircraftNaming.canonical(
            typecode: top.typecode,
            manufacturer: top.manufacturer,
            model: top.model
        )
        let name = canonical.displayName ?? top.callsign ?? top.icao24.uppercased()
        return BestCatch(name: name, rarity: top.resolvedRarity)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.Color.bgElevated, Brand.Color.bgSurface],
                startPoint: .top, endPoint: .bottom
            )
            // Subtle cyan radial bloom.
            RadialGradient(
                gradient: Gradient(colors: [Brand.Color.cyan.opacity(0.20), .clear]),
                center: UnitPoint(x: 0.5, y: 0.30),
                startRadius: 0,
                endRadius: 280
            )
            .blendMode(.screen)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "airplane")
                        .foregroundStyle(Brand.Color.cyan)
                        .font(.system(size: 20))
                    Text("TAILSPOT")
                        .font(Brand.Font.mono(size: 18, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(Brand.Color.textPrimary)
                    Spacer()
                    Text("@\(handle)")
                        .font(Brand.Font.mono(size: 13, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                }

                // Standing hero: points + rank on one baseline.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(stats.totalPoints.formatted(.number))
                        .font(Brand.Font.mono(size: 46, weight: .heavy))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .monospacedDigit()
                    if let rankLabel {
                        Text(rankLabel.uppercased())
                            .font(Brand.Font.mono(size: 20, weight: .bold))
                            .foregroundStyle(Brand.Color.podiumGold)
                    }
                }
                Text(rankLabel == nil ? "TOTAL POINTS" : "TOTAL POINTS · GLOBAL RANK")
                    .font(Brand.Font.mono(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Brand.Color.textTertiary)

                Spacer(minLength: 0)

                // The live story: what's about to be earned…
                if let goal {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().stroke(goal.ringTint.opacity(0.18), lineWidth: 4.5)
                            Circle().trim(from: 0, to: goal.fraction)
                                .stroke(goal.ringTint,
                                        style: .init(lineWidth: 4.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(goal.done)/\(goal.total)")
                                .font(Brand.Font.mono(size: 8, weight: .bold))
                                .foregroundStyle(goal.ringTint)
                        }
                        .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("NEXT UP")
                                .font(Brand.Font.mono(size: 8, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Brand.Color.textTertiary)
                            Text(goal.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.Color.textPrimary)
                            Text("\(goal.total - goal.done) to go")
                                .font(Brand.Font.caption)
                                .foregroundStyle(Brand.Color.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Brand.Color.bgPrimary.opacity(0.45), in: .rect(cornerRadius: 12))
                }

                // …and the proudest thing already caught.
                if let best {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(best.rarity.tint)
                            .frame(width: 4, height: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("BEST CATCH")
                                .font(Brand.Font.mono(size: 8, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Brand.Color.textTertiary)
                            Text(best.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Brand.Color.textPrimary)
                                .lineLimit(1)
                            Text(best.rarity.label)
                                .font(Brand.Font.mono(size: 9, weight: .bold))
                                .tracking(0.8)
                                .foregroundStyle(best.rarity.tint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Brand.Color.bgPrimary.opacity(0.45), in: .rect(cornerRadius: 12))
                }

                Spacer(minLength: 0)
                Divider().background(Brand.Color.textTertiary.opacity(0.3))
                HStack {
                    statTile(label: "Catches", value: stats.totalCatches)
                    Spacer()
                    statTile(label: "Unique",  value: stats.uniqueAirframes)
                    Spacer()
                    statTile(label: "Rare+",   value: stats.rarePlusUnique, tint: Brand.Color.alertAdvisory)
                }
                Text("Catch every plane you see. Build a hangar of them.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            .padding(22)
        }
        .frame(width: 320, height: 480)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Brand.Color.cyan.opacity(0.40), lineWidth: 1)
        )
    }

    private func statTile(label: String, value: Int, tint: Color = Brand.Color.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Brand.Font.mono(size: 22, weight: .heavy))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
        }
    }
}

#Preview("Leaderboard") {
    NavigationStack { LeaderboardScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}

#Preview("Share card") {
    ProfileShareCard(
        stats: ProfileStats(catches: []),
        handle: "preview",
        rankLabel: "1st",
        goal: .init(title: "Centurion", done: 84, total: 100, tier: .gold),
        best: .init(name: "C-17 Globemaster III", rarity: .epic)
    )
    .padding()
    .background(Brand.Color.bgPrimary)
}
