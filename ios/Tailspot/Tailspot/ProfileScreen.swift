//
//  ProfileScreen.swift
//  Tailspot
//
//  The gamification hub: total points, global rank (placeholder
//  pending backend), four-stat grid, rarity breakdown strip, plus
//  navigation entries to Sets, Map, Leaderboard, Rarity / Types
//  reference, Settings, and Share. Trophies have moved into the
//  Hangar's Trophies segment (Spec § 4.2, § 7) and no longer have
//  an entry on this screen.
//
//  The HEADLINE total-points + global-rank read the server's authoritative
//  standing (GET /v1/leaderboard `me`) so the profile and the public
//  leaderboard always show the SAME number — points are scored server-side and
//  re-derivable (see backend catches/rescore.ts), not a local recompute that
//  can drift. They fall back to the on-device Hangar total when offline / before
//  the fetch lands. The rest of the stats (counts, rarity breakdown, medals)
//  stay local — they're collection visuals, not the competitive score.
//

import SwiftUI
import SwiftData
import os

struct ProfileScreen: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    @State private var showingShare = false

    /// Last server-authoritative standing, CACHED in app storage so the headline
    /// shows the known server points + rank INSTANTLY on every open (no flash from
    /// the local fallback), then refreshes silently in the background. Sentinels:
    /// points `-1` / rank `0` = "never fetched" → the first-ever open shows the
    /// local Hangar total + "—" until the first fetch lands.
    @AppStorage("tailspot.standing.points") private var cachedServerPoints: Int = -1
    @AppStorage("tailspot.standing.rank") private var cachedServerRank: Int = 0
    private let accountClient = TailspotAccountClient()

    var body: some View {
        // Aggregate the Hangar ONCE per render. `stats` and `inputs` used to be
        // computed properties (`{ ProfileStats(catches:) }` / `{ Trophies.inputs(
        // from:) }`) that re-ran on EVERY access — and the body accessed them many
        // times over: `statsRow` filtered the whole trophy roster, re-deriving
        // `inputs` across all catches once PER trophy, and `rarityStrip` read
        // `stats` inside two per-tier loops. On a 50–200 catch Hangar that was
        // thousands of resolvedRarity + Calendar passes on the main thread every
        // time the sheet built or tore down — the synchronous "freeze, then jump"
        // on open/close. Computing each once collapses it to a single O(n) pass,
        // then we thread the values down to the sections.
        let stats = ProfileStats(catches: catches)
        let inputs = Trophies.inputs(from: catches)
        return NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    identityHeader(stats: stats)
                    statsRow(stats: stats, inputs: inputs)
                    rarityStrip(stats: stats)
                    quickLinks
                    sectionLinks
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Brand.Color.bgPrimary.ignoresSafeArea())
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadStanding() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingShare = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareCardSheet(stats: stats, handle: handle)
            }
        }
    }

    // MARK: - Standing fetch

    /// Pull the server-authoritative standing (rank + total points). We only
    /// need `me`, so request the smallest possible board (limit 1). On any
    /// failure (offline, not yet registered) we keep the local Hangar fallback —
    /// this is best-effort, never an error state on the profile.
    private func loadStanding() async {
        do {
            let response = try await accountClient.leaderboard(limit: 1)
            if let me = response.me {
                cachedServerPoints = me.points
                cachedServerRank = me.rank
            }
        } catch {
            Log.ui.debug("ProfileScreen: standing fetch failed (keeping local fallback): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Locale-aware ordinal for the rank display: 1 → "1st", 2 → "2nd", 3 → "3rd",
    /// 11 → "11th", 21 → "21st". The formatter is cached (creating one per render
    /// is needless work).
    private static let ordinalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    private static func ordinalRank(_ n: Int) -> String {
        ordinalFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Identity

    /// First-letter initials for the avatar disc. Uses the first two
    /// non-symbol characters of the handle.
    private var initials: String {
        let cleaned = handle.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(cleaned.prefix(2)).uppercased()
    }

    /// Heuristic "joined" date — earliest catch in the Hangar.
    /// Returns nil when the user has no catches yet; falls back to
    /// the omitted state.
    private var joinedDateLabel: String? {
        guard let oldest = catches.map(\.caughtAt).min() else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        return "joined " + fmt.string(from: oldest)
    }

    private func identityHeader(stats: ProfileStats) -> some View {
        // Cached server standing (instant, no flash); local Hangar total / "—"
        // only until the very first fetch ever lands.
        let displayPoints = cachedServerPoints >= 0 ? cachedServerPoints : stats.totalPoints
        let rankLabel = cachedServerRank >= 1 ? Self.ordinalRank(cachedServerRank) : "—"
        return VStack(spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Brand.Color.bgPrimary)
                    Circle()
                        .strokeBorder(Brand.Color.cyan.opacity(0.40), lineWidth: 1.5)
                    Text(initials)
                        .font(Brand.Font.mono(size: 18, weight: .bold))
                        .foregroundStyle(Brand.Color.cyan)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("@\(handle)")
                        .font(Brand.Font.mono(size: 20, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Brand.Color.textPrimary)
                    if let joined = joinedDateLabel {
                        Text(joined)
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    } else {
                        Text("ready to spot")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text(displayPoints.formatted(.number))
                        .font(Brand.Font.mono(size: 32, weight: .heavy))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                    Text("TOTAL POINTS")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
                Rectangle()
                    .fill(Brand.Color.bgPrimary.opacity(0.55))
                    .frame(width: 1, height: 40)
                VStack(spacing: 2) {
                    Text(rankLabel)
                        .font(Brand.Font.mono(size: 32, weight: .heavy))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .monospacedDigit()
                    Text("GLOBAL RANK")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 18))
    }

    // MARK: - Stats grid

    private func statsRow(stats: ProfileStats, inputs: TrophyProgressInputs) -> some View {
        // `inputs` is the precomputed value passed in — the filter closure now
        // reads that single snapshot instead of re-deriving it per trophy.
        let earnedMedals = Trophies.roster.filter { !$0.isLocked(inputs: inputs) }.count
        return HStack(spacing: 8) {
            statTile(value: stats.totalCatches, label: "Catches")
            statTile(value: stats.uniqueAirframes, label: "Unique")
            statTile(value: stats.rarePlusUnique, label: "Rare+", valueColor: Brand.Color.alertAdvisory)
            statTile(value: earnedMedals, label: "Medals")
        }
    }

    private func statTile(value: Int, label: String, valueColor: Color = Brand.Color.textPrimary) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(Brand.Font.mono(size: 22, weight: .bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Brand.Font.mono(size: 8, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 12))
    }

    // MARK: - Rarity strip

    private func rarityStrip(stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BREAKDOWN BY RARITY")
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
            HStack(spacing: 0) {
                ForEach(Rarity.allCases, id: \.self) { r in
                    let count = stats.countsByRarity[r] ?? 0
                    let proportion = stats.totalCatches == 0
                        ? 0
                        : Double(count) / Double(stats.totalCatches)
                    Rectangle()
                        .fill(count > 0 ? r.tint : Brand.Color.bgSurface)
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        // Each tier carries its proportion of the row,
                        // but we render equal segments to keep
                        // empty tiers visible. A more honest layout
                        // would weight by proportion — try that if you
                        // want the strip to read as data.
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(r.tint.opacity(count == 0 ? 0 : 0.6))
                                    .frame(width: geo.size.width * CGFloat(proportion))
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                ForEach(Rarity.allCases, id: \.self) { r in
                    let count = stats.countsByRarity[r] ?? 0
                    VStack(spacing: 1) {
                        Text("\(count)")
                            .font(Brand.Font.mono(size: 13, weight: .bold))
                            .foregroundStyle(count > 0 ? r.tint : Brand.Color.textTertiary)
                            .monospacedDigit()
                        Text(r.label)
                            .font(Brand.Font.mono(size: 7, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
    }

    // MARK: - Quick links

    private var quickLinks: some View {
        HStack(spacing: 10) {
            quickLink(label: "Sets", glyph: "rectangle.stack") { SetsScreen() }
            quickLink(label: "Map", glyph: "map") { MapScreen() }
            quickLink(label: "Leaders", glyph: "list.number") { LeaderboardScreen() }
        }
    }

    private func quickLink<Dest: View>(label: String, glyph: String, @ViewBuilder destination: @escaping () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Brand.Color.cyan)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section links (reference / settings)

    private var sectionLinks: some View {
        VStack(spacing: 0) {
            sectionLink(label: "Rarity reference", systemImage: "diamond") { RarityReferenceScreen() }
            divider
            sectionLink(label: "Types reference", systemImage: "rectangle.3.group") { TypesReferenceScreen() }
            divider
            sectionLink(label: "Settings", systemImage: "gear") { SettingsScreen() }
        }
        .background(Brand.Color.bgElevated, in: .rect(cornerRadius: 14))
    }

    private var divider: some View {
        Rectangle()
            .fill(Brand.Color.bgPrimary.opacity(0.5))
            .frame(height: 1)
            .padding(.leading, 52)
    }

    private func sectionLink<Dest: View>(label: String, systemImage: String, @ViewBuilder destination: @escaping () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.Color.cyan)
                    .frame(width: 22)
                Text(label)
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Profile stats

/// Pre-aggregated totals derived from the Hangar. Pure value type;
/// reads everything off the in-memory `[Catch]` slice the @Query
/// already produced.
struct ProfileStats {
    let totalCatches: Int
    let uniqueAirframes: Int
    let rarePlusUnique: Int
    let longestSlantKm: Double
    let totalPoints: Int
    let countsByRarity: [Rarity: Int]

    init(catches: [Catch]) {
        var unique = Set<String>()
        var rarePlusUnique = Set<String>()
        var longest: Double = 0
        var total = 0
        var counts: [Rarity: Int] = [:]
        for c in catches {
            unique.insert(c.icao24)
            let r = c.resolvedRarity
            counts[r, default: 0] += 1
            total += r.basePoints
            if r.ordinal >= Rarity.rare.ordinal {
                rarePlusUnique.insert(c.icao24)
            }
            let km = c.slantDistanceMeters / 1000
            if km > longest { longest = km }
        }
        self.totalCatches = catches.count
        self.uniqueAirframes = unique.count
        self.rarePlusUnique = rarePlusUnique.count
        self.longestSlantKm = longest
        self.totalPoints = total
        self.countsByRarity = counts
    }
}

// MARK: - Spotter handle (stored)

enum SpotterHandle {
    static let storageKey = "tailspot.spotter.handle"
    /// The handle value the backend has confirmed for THIS device. Written by
    /// the claim paths (onboarding/Settings) on success and by `HandleSyncer`.
    /// When it differs from `storageKey`, the handle still needs syncing.
    static let confirmedKey = "tailspot.spotter.handle.confirmed"
    static let defaultPlaceholder = "spotter_42"
}

#Preview {
    ProfileScreen()
        .modelContainer(for: Catch.self, inMemory: true)
}
