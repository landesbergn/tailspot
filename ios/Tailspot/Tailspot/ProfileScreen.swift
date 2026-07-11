//
//  ProfileScreen.swift
//  Tailspot
//
//  The gamification hub, reorganized 2026-07-08 ("Direction A" of the
//  profile layout exploration — docs/reviews). Hierarchy, in priority
//  order: identity + server-authoritative standing (points/rank hero),
//  ONE quiet collection-stat strip, then navigation (Sets/Map/Leaders +
//  reference/settings links). The four loud stat tiles and the rarity
//  breakdown strip were removed — the census detail lives in the Hangar
//  and the references; the strip was also data-dishonest (equal segments
//  regardless of counts). Trophies live in the Hangar's Trophies segment
//  and have no entry here; the stat strip says TROPHIES (the system's
//  one user-facing name — "medals" was this screen's invention).
//
//  Surfaces are iOS 26 Liquid Glass (`.glassEffect`) tinted to the brand
//  dark; untinted glass renders too bright against the fixed dark
//  palette. The backdrop adds two faint radial glows so the glass has
//  something to refract.
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

    /// Last server-authoritative standing, CACHED in app storage so the headline
    /// shows the known server points + rank INSTANTLY on every open (no flash from
    /// the local fallback), then refreshes silently in the background. Sentinels:
    /// points `-1` / rank `0` = "never fetched" → the first-ever open shows the
    /// local Hangar total + "—" until the first fetch lands.
    @AppStorage("tailspot.standing.points") private var cachedServerPoints: Int = -1
    @AppStorage("tailspot.standing.rank") private var cachedServerRank: Int = 0
    /// Weekly-champion crowns (dynamic-leaderboards L6), cached like the
    /// standing so the laurel renders offline. 0 = none/never fetched — the
    /// row simply doesn't render, so no sentinel dance is needed.
    @AppStorage("tailspot.standing.weeklyWins") private var cachedWeeklyWins: Int = 0
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
                // GlassEffectContainer is load-bearing, not cosmetic: each
                // bare `.glassEffect` hosts its glass in a separate layer
                // ABOVE the surrounding hierarchy, and those layers can
                // swallow taps on non-glass siblings below them — the
                // Rarity reference / Settings rows were untappable because
                // the quickLinks' glass layers sat over them (field bug,
                // 2026-07-10). The container merges every child glass
                // surface into one coordinated layer with correct hit
                // testing.
                GlassEffectContainer {
                    VStack(spacing: 16) {
                        identityHeader(stats: stats)
                        if cachedWeeklyWins >= 1 {
                            championLaurelRow
                        }
                        statsStrip(stats: stats, inputs: inputs)
                        if let best = Self.bestCatch(in: catches) {
                            bestCatchCard(best)
                        }
                        quickLinks
                        sectionLinks
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(glassBackdrop)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .task { await loadStanding() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Share is the page's one action, so it gets the brand's
                    // CTA treatment (cyan disc, dark glyph) instead of the
                    // bare system tint — same accent grammar as the reveal's
                    // CTA and the planned Spotter Pass share (PLAN §9 #10).
                    // A direct ShareLink, deliberately minimal (Noah,
                    // 2026-07-08): one tap → the system share sheet with a
                    // short invite + the tailspot.app link. Messages renders
                    // the link as a rich preview from the site's OG tags; a
                    // rendered stat-card image was tried and cut as too much.
                    ShareLink(
                        item: Self.inviteURL,
                        message: Text("Join me on Tailspot:")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .padding(7)
                            .background(Brand.Color.cyan, in: .circle)
                    }
                    .accessibilityLabel("Share profile")
                    // ShareLink exposes no tap callback; a simultaneous
                    // gesture gives the share-funnel signal (opened, not
                    // necessarily completed — completion isn't observable).
                    .simultaneousGesture(TapGesture().onEnded {
                        Analytics.capture("profile_share_opened", [
                            "points": .int(cachedServerPoints >= 0 ? cachedServerPoints : stats.totalPoints),
                            "has_rank": .bool(cachedServerRank >= 1),
                        ])
                    })
                }
            }
        }
    }

    /// Where an invited friend lands. The site carries install instructions
    /// now (TestFlight) and becomes the App Store pointer at GA. Real invite
    /// attribution (per-user codes, the invite trophy) is PLAN §9 #10.
    private static let inviteURL = URL(string: "https://tailspot.app")!

    // MARK: - Standing fetch

    /// Pull the server-authoritative standing (rank + total points). We only
    /// need `me`, so request the smallest possible board (limit 1). On any
    /// failure (offline, not yet registered) we keep the local Hangar fallback —
    /// this is best-effort, never an error state on the profile.
    private func loadStanding() async {
        do {
            // Explicit all-time window: the headline is lifetime points/rank
            // (the windows-aware backend would otherwise pick its own default;
            // the old backend ignores the param).
            let response = try await accountClient.leaderboard(window: .all, limit: 1)
            if let me = response.me {
                cachedServerPoints = me.points
                cachedServerRank = me.rank
                if let wins = me.weeklyWins {
                    cachedWeeklyWins = wins
                }
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

    /// Whether the stored handle is a real user choice. Until it is, the
    /// header must not render the "spotter_42" placeholder as if it were a
    /// claimed identity — unclaimed is an honest designed state (Noah,
    /// 2026-07-10 polish sweep) with a CLAIM YOUR HANDLE affordance that
    /// routes to the Settings SPOTTER section.
    private var isHandleClaimed: Bool {
        AnalyticsIdentity.isClaimedHandle(handle, placeholder: SpotterHandle.defaultPlaceholder)
    }

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
                    if isHandleClaimed {
                        Text(initials)
                            .font(Brand.Font.mono(size: 18, weight: .bold))
                            .foregroundStyle(Brand.Color.cyan)
                    } else {
                        // No initials to show yet — a quiet person glyph,
                        // not fake "SP" initials off the placeholder.
                        Image(systemName: "person")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    if isHandleClaimed {
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
                    } else {
                        // Unclaimed: a designed affordance, not "@spotter_42"
                        // masquerading as a handle. Taps into the existing
                        // claim flow (Settings → SPOTTER).
                        NavigationLink {
                            SettingsScreen()
                        } label: {
                            HStack(spacing: 6) {
                                Text("CLAIM YOUR HANDLE")
                                    .font(Brand.Font.mono(size: 13, weight: .bold))
                                    .tracking(1.2)
                                    .foregroundStyle(Brand.Color.cyan)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Brand.Color.cyan.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                        Text("shown on the global leaderboard")
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
        .glassEffect(Self.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    // MARK: - Weekly-champion laurel (dynamic-leaderboards L6)

    /// Quiet gold laurel under the identity header — renders only once the
    /// device has at least one weekly-champion crown ("WEEKLY CHAMPION",
    /// "WEEKLY CHAMPION ×3"…). Deliberately a flat non-glass row: a new
    /// glass surface would have to live inside the GlassEffectContainer
    /// above (the hit-testing lesson), and a trophy accent doesn't need to
    /// refract anything.
    private var championLaurelRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "laurel.leading")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.podiumGold)
            Text(cachedWeeklyWins > 1
                 ? "WEEKLY CHAMPION ×\(cachedWeeklyWins)"
                 : "WEEKLY CHAMPION")
                .font(Brand.Font.mono(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.podiumGold)
            Image(systemName: "laurel.trailing")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Brand.Color.podiumGold)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Brand.Color.podiumGold.opacity(0.10), in: .rect(cornerRadius: Brand.Radius.row))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .strokeBorder(Brand.Color.podiumGold.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Glass treatment

    /// Liquid Glass anchored to the brand's elevated dark tone. Untinted
    /// `.regular` glass resolves too bright over `bgPrimary` and washes
    /// out the fixed light-on-dark text palette.
    private static let brandGlass: Glass = .regular.tint(Brand.Color.bgElevated.opacity(0.88))

    /// Two faint radial glows under the glass surfaces — pure decoration,
    /// but glass over a flat color has nothing to refract and reads matte.
    private var glassBackdrop: some View {
        ZStack {
            Brand.Color.bgPrimary
            RadialGradient(colors: [Brand.Color.cyan.opacity(0.10), .clear],
                           center: .init(x: 0.85, y: 0.05), startRadius: 10, endRadius: 420)
            RadialGradient(colors: [Brand.Color.alertAdvisory.opacity(0.05), .clear],
                           center: .init(x: 0.1, y: 0.75), startRadius: 10, endRadius: 380)
        }
        .ignoresSafeArea()
    }

    // MARK: - Stats strip

    /// One quiet row for the collection counts — deliberately smaller type
    /// than the points/rank hero above it so the two never compete.
    private func statsStrip(stats: ProfileStats, inputs: TrophyProgressInputs) -> some View {
        // `inputs` is the precomputed value passed in — the filter closure
        // reads that single snapshot instead of re-deriving it per trophy.
        let earnedTrophies = Trophies.roster.filter { !$0.isLocked(inputs: inputs) }.count
        return HStack(spacing: 0) {
            statCell(value: stats.totalCatches, label: "Catches")
            statCell(value: stats.uniqueAirframes, label: "Unique")
            statCell(value: stats.rarePlusUnique, label: "Rare+", valueColor: Brand.Color.alertAdvisory)
            statCell(value: earnedTrophies, label: "Trophies")
        }
        .padding(.vertical, 12)
        .glassEffect(Self.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func statCell(value: Int, label: String, valueColor: Color = Brand.Color.textPrimary) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(Brand.Font.mono(size: 20, weight: .bold))
                .foregroundStyle(valueColor)
                .monospacedDigit()
            Text(label.uppercased())
                .font(Brand.Font.mono(size: 9, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Best catch

    /// The collection's proudest airframe (highest rarity, most recent on
    /// ties) — the "Progression" element Noah kept from the layout
    /// exploration's Direction B. Tapping opens the catch detail.
    private struct BestCatch {
        let top: Catch
        let name: String
        let rarity: Rarity
    }

    private static func bestCatch(in catches: [Catch]) -> BestCatch? {
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
        return BestCatch(top: top, name: name, rarity: top.resolvedRarity)
    }

    private func bestCatchCard(_ best: BestCatch) -> some View {
        NavigationLink {
            // Single-catch row, the MapScreen pin-sheet pattern.
            CatchDetailView(row: HangarRow(
                icao24: best.top.icao24,
                mostRecent: best.top,
                count: 1,
                allCatches: [best.top]
            ))
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(best.rarity.tint)
                    .frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("BEST CATCH")
                        .font(Brand.Font.mono(size: 8, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                    Text(best.name)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    Text(best.rarity.label)
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(best.rarity.tint)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(Self.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Quick links

    // "Sets" deliberately absent: the Hangar's default segment IS Sets, so
    // the quick card was a duplicate door (Noah, 2026-07-08).
    private var quickLinks: some View {
        HStack(spacing: 10) {
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
            .glassEffect(Self.brandGlass, in: .rect(cornerRadius: Brand.Radius.card))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Section links (reference / settings)

    private var sectionLinks: some View {
        VStack(spacing: 0) {
            sectionLink(label: "Rarity reference", systemImage: "diamond") { RarityReferenceScreen() }
            divider
            sectionLink(label: "Settings", systemImage: "gear") { SettingsScreen() }
        }
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
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
            // The Spacer gap between label and chevron is transparent and
            // therefore not hit-testable by default — make the whole row
            // one tap target.
            .contentShape(Rectangle())
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
