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
//  Stats derived entirely from the on-device Hangar — no server
//  required for v1.
//

import SwiftUI
import SwiftData

struct ProfileScreen: View {
    @Query(sort: \Catch.caughtAt, order: .reverse) private var catches: [Catch]
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SpotterHandle.storageKey) private var handle: String = SpotterHandle.defaultPlaceholder
    @State private var showingShare = false

    private var stats: ProfileStats { ProfileStats(catches: catches) }
    private var inputs: TrophyProgressInputs { Trophies.inputs(from: catches) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    identityHeader
                    statsRow
                    rarityStrip
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

    private var identityHeader: some View {
        VStack(spacing: 14) {
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
                Text("PUBLIC")
                    .font(Brand.Font.mono(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(Brand.Color.alertNormal)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Brand.Color.alertNormal.opacity(0.14), in: .capsule)
                    .overlay(Capsule().strokeBorder(Brand.Color.alertNormal.opacity(0.45), lineWidth: 1))
            }
            HStack(spacing: 16) {
                VStack(spacing: 2) {
                    Text(stats.totalPoints.formatted(.number))
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
                    Text("—")
                        .font(Brand.Font.mono(size: 32, weight: .heavy))
                        .foregroundStyle(Brand.Color.textPrimary)
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

    private var statsRow: some View {
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

    private var rarityStrip: some View {
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
            divider
            sectionLink(label: "Notifications", systemImage: "bell") { NotificationsScreen() }
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
