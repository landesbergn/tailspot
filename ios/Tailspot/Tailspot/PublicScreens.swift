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
//  (The profile share is a plain text + tailspot.app link ShareLink in
//  ProfileScreen — a rendered stat-card artboard was tried 2026-07-08 and
//  cut as too much; see git history / PLAN §9 #10 Spotter Pass.)
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

    init() {}

    #if DEBUG
    /// Snapshot/visual-pass seam — start the screen pre-loaded with fixture
    /// entries so the List renders without a live backend
    /// (`ProfileSettingsSnapshotTests` pattern). DEBUG-only; production
    /// always goes through the no-arg init + `load()`.
    init(_debugEntries entries: [LeaderboardEntry], me: MyStanding?) {
        _entries = State(initialValue: entries)
        _me = State(initialValue: me)
        _loadState = State(initialValue: .loaded)
    }
    #endif

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
        // Brand the list like SettingsScreen/SetsScreen — without this the
        // List renders system grouped chrome, which flips white in light
        // mode against the fixed dark Brand palette.
        .scrollContentBackground(.hidden)
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
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
            .listRowBackground(Brand.Color.bgElevated)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("No handles yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Be the first to claim a handle in Profile → Settings to appear here.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            .padding(.vertical, 6)
            .listRowBackground(Brand.Color.bgElevated)
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
                    Text("Claim a handle in Profile → Settings to appear in the list above.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .listRowBackground(Brand.Color.bgElevated)
                }
            } header: {
                sectionHeader("YOUR STANDING")
            }
        } else if !hasHandle {
            // Not registered yet or no handle — hint.
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("You have \(myLocalPoints.formatted(.number)) points locally")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Claim a handle in Profile → Settings to appear on the leaderboard.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Brand.Color.bgElevated)
            } header: {
                sectionHeader("YOUR STANDING")
            }
        }
    }

    /// Mono ALL-CAPS section header — the app-wide style (SettingsScreen's
    /// SPOTTER/ABOUT headers), replacing the default system header look.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Brand.Font.mono(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Brand.Color.textTertiary)
            .textCase(nil)
    }
}

#Preview("Leaderboard") {
    NavigationStack { LeaderboardScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}

