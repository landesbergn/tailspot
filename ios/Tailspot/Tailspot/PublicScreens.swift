//
//  PublicScreens.swift
//  Tailspot
//
//  Public surfaces:
//
//   - LeaderboardScreen — live global leaderboard from the backend, now
//     windowed (dynamic-leaderboards PR2): WEEK (default) / MONTH / ALL TIME
//     tabs, a reset countdown, and a LAST WEEK'S CHAMPION banner on the week
//     tab. Shows rank/handle/points/catches, highlights "me" row (works
//     even handle-less, with a "claim a handle to appear" hint).
//     Loading / error / empty states follow Brand patterns.
//     Pull-to-refresh supported.
//
//     FAIL-SOFT: the pre-windows backend never sends the `window` key —
//     when it's absent the tabs hide entirely and the screen renders the
//     all-time board exactly as before (see LeaderboardResponse.supportsWindows).
//     Per-window responses are cached for the screen's lifetime so flipping
//     back to a tab shows its last data instantly and refreshes silently
//     (the ProfileScreen cached-standing pattern, scoped to one appearance).
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

    @State private var selectedWindow: LeaderboardWindow = .week
    /// Per-window response cache — the last data a tab showed. Flipping back
    /// to a cached tab renders instantly; `.task(id:)` still re-fetches and
    /// swaps the data in silently (no spinner churn).
    @State private var responses: [LeaderboardWindow: LeaderboardResponse] = [:]
    /// Per-window load failure. Only set when the window has NO cached data —
    /// a failed silent refresh keeps showing the stale board instead.
    @State private var errors: [LeaderboardWindow: String] = [:]
    /// nil until the first response ever lands; true = windows-aware backend
    /// (show tabs); false = old backend (fail-soft: hide tabs, the board is
    /// the all-time board).
    @State private var windowsSupported: Bool? = nil

    private let client = TailspotAccountClient()
    /// True when a DEBUG init pre-seeded fixture data — network loads are
    /// skipped so snapshots render deterministically.
    private let debugSeeded: Bool

    init() {
        debugSeeded = false
    }

    #if DEBUG
    /// Snapshot/visual-pass seam — start the screen pre-loaded with fixture
    /// entries so the List renders without a live backend
    /// (`ProfileSettingsSnapshotTests` pattern). This variant renders the
    /// OLD-BACKEND board (no `window` key → tabs hidden), preserving the
    /// pre-windows snapshots. DEBUG-only; production always goes through
    /// the no-arg init + `load()`.
    init(_debugEntries entries: [LeaderboardEntry], me: MyStanding?) {
        _responses = State(initialValue: [.week: LeaderboardResponse(entries: entries, me: me)])
        _windowsSupported = State(initialValue: false)
        debugSeeded = true
    }

    /// Windowed snapshot seam: seed any subset of window responses and pick
    /// the selected tab. `windowsSupported` derives from the selected
    /// window's response (so an old-payload fixture exercises fail-soft).
    init(_debugWindows responses: [LeaderboardWindow: LeaderboardResponse],
         selected: LeaderboardWindow = .week) {
        _responses = State(initialValue: responses)
        _selectedWindow = State(initialValue: selected)
        _windowsSupported = State(initialValue: responses[selected]?.supportsWindows ?? true)
        debugSeeded = true
    }
    #endif

    var body: some View {
        List {
            if windowsSupported == true {
                switcherSection
            }
            if let response = responses[selectedWindow] {
                if selectedWindow == .week, windowsSupported == true,
                   let champions = response.champions {
                    championSection(champions)
                }
                if response.entries.isEmpty {
                    emptySection
                } else {
                    if response.entries.count >= 3 {
                        Section {
                            podium(entries: response.entries)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    rankSection(entries: response.entries)
                    meHintSection(me: response.me)
                }
            } else if let msg = errors[selectedWindow] {
                errorSection(msg)
            } else {
                loadingSection
            }
        }
        .listStyle(.insetGrouped)
        // Brand the list like SettingsScreen/SetsScreen — without this the
        // List renders system grouped chrome instead of the fixed dark
        // Brand palette.
        .scrollContentBackground(.hidden)
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(selectedWindow) }
        // Runs on appear AND whenever the selected tab changes: a fresh tab
        // fetches (spinner — it has no data yet); a cached tab re-fetches
        // silently behind its stale board.
        .task(id: selectedWindow) {
            guard !debugSeeded else { return }
            await load(selectedWindow)
        }
        .onChange(of: selectedWindow) { _, newValue in
            Analytics.capture("leaderboard_window_switched", [
                "window": .string(newValue.rawValue),
            ])
        }
        .onAppear {
            // leaderboard_viewed fires each time the screen becomes visible.
            // entry_count is 0 until load() completes — this is intentional:
            // we want to know how many times the user opens the screen, not just
            // after data arrives. has_handle distinguishes identified vs. anonymous.
            let hasHandle = localHandle != SpotterHandle.defaultPlaceholder && !localHandle.isEmpty
            Analytics.capture("leaderboard_viewed", [
                "entry_count": .int(responses[selectedWindow]?.entries.count ?? 0),
                "has_handle":  .bool(hasHandle),
                "window":      .string(selectedWindow.rawValue),
            ])
        }
    }

    // MARK: - Load

    private func load(_ window: LeaderboardWindow) async {
        do {
            let response = try await client.leaderboard(window: window)
            responses[window] = response
            errors[window] = nil
            windowsSupported = response.supportsWindows
            // Absorb the server-fact fields (weeklyWins/everToppedAllTime)
            // from EVERY response that carries them — they're window-
            // independent lifetime facts, and this screen may be the only
            // fetch that runs (the Profile laurel + the Top Flight/Dynasty/
            // Chart Topper trophies all read this cache).
            if let me = response.me {
                LeaderboardStandingCache().update(from: me)
            }
        } catch {
            // Keep stale data when we have it — a failed silent refresh must
            // not blank a board the user is looking at.
            if responses[window] == nil {
                errors[window] = error.localizedDescription
            }
        }
    }

    // MARK: - Window switcher + countdown

    private var switcherSection: some View {
        Section {
            VStack(spacing: 6) {
                LeaderboardWindowSwitcher(selection: $selectedWindow)
                if let line = countdownLine {
                    Text(line)
                        .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.textTertiary)
                        .padding(.bottom, 2)
                }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    /// "RESETS MONDAY · 2D 14H LEFT" (week) / "RESETS AUG 1" (month), in the
    /// device's locale + timezone. Recomputed per render — countdown text
    /// refreshes on appear/tab-flip/refresh; no live ticking timer.
    private var countdownLine: String? {
        guard let resetsAt = responses[selectedWindow]?.resetsAtDate else { return nil }
        switch selectedWindow {
        case .week:  return LeaderboardCountdown.weekLabel(resetsAt: resetsAt, now: Date())
        case .month: return LeaderboardCountdown.monthLabel(resetsAt: resetsAt)
        case .all:   return nil  // resetsAt is null for all-time anyway
        }
    }

    // MARK: - Champion banner (week tab)

    /// Gold-accented banner above the podium. Three states: crowned (one or
    /// more champions — a shared crown lists names side by side), and the
    /// quiet zero-champion week. (`champions == nil` — old backend or a
    /// non-week window — never reaches here.)
    @ViewBuilder
    private func championSection(_ champions: [LeaderboardChampion]) -> some View {
        Section {
            if champions.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "laurel.leading")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChampionBanner.noChampionTitle)
                            .font(Brand.Font.mono(size: 11, weight: .bold, relativeTo: .caption2))
                            .tracking(1.0)
                            .foregroundStyle(Brand.Color.textSecondary)
                        Text(ChampionBanner.noChampionSubtitle)
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .listRowBackground(Brand.Color.bgElevated)
                .accessibilityElement(children: .combine)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "laurel.leading")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.Color.podiumGold)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ChampionBanner.eyebrow(count: champions.count))
                            .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                            .tracking(1.2)
                            .foregroundStyle(Brand.Color.podiumGold)
                        (Text(ChampionBanner.names(champions))
                            .foregroundStyle(Brand.Color.textPrimary)
                         + Text(" · \(champions[0].points.formatted(.number)) PTS")
                            .foregroundStyle(Brand.Color.podiumGold))
                            .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    }
                    Spacer()
                    Image(systemName: "laurel.trailing")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Brand.Color.podiumGold)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 6)
                .listRowBackground(Brand.Color.podiumGold.opacity(0.12))
                .accessibilityElement(children: .combine)
            }
        }
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
                    .font(Brand.Font.body.weight(.semibold))
                    .foregroundStyle(Brand.Color.alertCaution)
                Text(msg)
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
                Button("Try again") {
                    errors[selectedWindow] = nil
                    Task { await load(selectedWindow) }
                }
                .font(Brand.Font.body.weight(.semibold))
                .foregroundStyle(Brand.Color.cyan)
                // Text-only button — the expanded hit shape carries the
                // 44 pt target without growing the error card.
                .contentShape(Rectangle().inset(by: -12))
            }
            .padding(.vertical, 6)
            .listRowBackground(Brand.Color.bgElevated)
        }
    }

    /// Empty board. Windowed tabs get the fresh-window copy ("the race just
    /// reset"); all-time / the old backend keeps the claim-a-handle hint
    /// (an empty all-time board means nobody has a handle yet).
    @ViewBuilder
    private var emptySection: some View {
        Section {
            if windowsSupported == true && selectedWindow != .all {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selectedWindow == .week
                         ? "No catches this week yet"
                         : "No catches this month yet")
                        .font(Brand.Font.body.weight(.semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("The sky's wide open.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Brand.Color.bgElevated)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No handles yet")
                        .font(Brand.Font.body.weight(.semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                    Text("Be the first to claim a handle in Profile → Settings to appear here.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 6)
                .listRowBackground(Brand.Color.bgElevated)
            }
        }
    }

    /// Top-3 podium block.
    private func podium(entries: [LeaderboardEntry]) -> some View {
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
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .heavy, relativeTo: .footnote))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: Brand.Radius.chip).fill(tint.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: Brand.Radius.chip).strokeBorder(tint, lineWidth: 1))
                // The big numeral stays fixed — it's a graphic inside the
                // fixed-height podium block, and the rank is already spoken
                // via the combined label below.
                Text("\(rank)")
                    .font(Brand.Font.mono(size: 28, weight: .heavy))
                    .foregroundStyle(tint)
                    .padding(.top, 8)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.map {
            "Rank \(rank), \($0.handle), \($0.points) points"
        } ?? "Rank \(rank), empty")
    }

    /// Full ranked list.
    @ViewBuilder
    private func rankSection(entries: [LeaderboardEntry]) -> some View {
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
                .font(Brand.Font.mono(size: 14, weight: .bold, relativeTo: .subheadline))
                .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textTertiary)
                .monospacedDigit()
                .frame(width: 30, alignment: .leading)
            Text("@\(entry.handle)")
                .font(Brand.Font.mono(size: 14, weight: isMe ? .bold : .regular, relativeTo: .subheadline))
                .foregroundStyle(Brand.Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(entry.points.formatted(.number))")
                    .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                    .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textPrimary)
                    .monospacedDigit()
                Text("\(entry.catches) catch\(entry.catches == 1 ? "" : "es")")
                    .font(Brand.Font.mono(size: 10, relativeTo: .caption2))
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            // The points column never yields to a long handle — the handle
            // shrinks/truncates instead (its minimumScaleFactor above).
            .layoutPriority(1)
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
        // One element per row; the fragments ("3", "@handle", "245"…) mean
        // nothing read separately.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Rank \(entry.rank), \(entry.handle), \(entry.points) points, "
            + "\(entry.catches) catch\(entry.catches == 1 ? "" : "es")"
            + (isMe ? ", you" : "")
        )
    }

    /// True when this entry is for the current user's handle.
    private func isMeEntry(_ entry: LeaderboardEntry) -> Bool {
        entry.handle.lowercased() == localHandle.lowercased()
    }

    /// Section header naming which race the standing is in — "you're #2
    /// THIS WEEK" is the whole point of the week tab.
    private var standingHeaderTitle: String {
        guard windowsSupported == true else { return "YOUR STANDING" }
        switch selectedWindow {
        case .week:  return "YOUR STANDING · THIS WEEK"
        case .month: return "YOUR STANDING · THIS MONTH"
        case .all:   return "YOUR STANDING · ALL TIME"
        }
    }

    /// "Me" section shown below the ranked list: either the me row from the
    /// API (when the device has a handle), or a prompt to claim one.
    @ViewBuilder
    private func meHintSection(me: MyStanding?) -> some View {
        let myLocalPoints = ProfileStats(catches: catches).totalPoints
        let hasHandle = !localHandle.isEmpty && localHandle != SpotterHandle.defaultPlaceholder

        if let meStanding = me {
            // Server confirmed our standing — show it.
            Section {
                HStack(spacing: 12) {
                    Text("\(meStanding.rank)")
                        .font(Brand.Font.mono(size: 14, weight: .bold, relativeTo: .subheadline))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                        .frame(width: 30, alignment: .leading)
                    Text(hasHandle ? "@\(localHandle)" : "(you)")
                        .font(Brand.Font.mono(size: 14, weight: .bold, relativeTo: .subheadline))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer()
                    Text("\(meStanding.points.formatted(.number))")
                        .font(Brand.Font.mono(size: 13, weight: .bold, relativeTo: .footnote))
                        .foregroundStyle(Brand.Color.cyan)
                        .monospacedDigit()
                        .layoutPriority(1)
                    Text("YOU")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Brand.Color.cyan, in: .capsule)
                }
                .padding(.vertical, 2)
                .listRowBackground(Brand.Color.cyan.opacity(0.12))
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Your standing: rank \(meStanding.rank), "
                    + "\(meStanding.points) points"
                )
                if !hasHandle {
                    Text("Claim a handle in Profile → Settings to appear in the list above.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .listRowBackground(Brand.Color.bgElevated)
                }
            } header: {
                sectionHeader(standingHeaderTitle)
            }
        } else if !hasHandle {
            // Not registered yet or no handle — hint. The local-points line
            // is an ALL-TIME number, so it only renders where it's honest
            // (the all-time tab / the old backend's single board).
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    if windowsSupported != true || selectedWindow == .all {
                        Text("You have \(myLocalPoints.formatted(.number)) points locally")
                            .font(Brand.Font.body.weight(.semibold))
                            .foregroundStyle(Brand.Color.textPrimary)
                    }
                    Text("Claim a handle in Profile → Settings to appear on the leaderboard.")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                .padding(.vertical, 4)
                .listRowBackground(Brand.Color.bgElevated)
            } header: {
                sectionHeader(standingHeaderTitle)
            }
        }
    }

    /// Mono ALL-CAPS section header — the app-wide style (SettingsScreen's
    /// SPOTTER/ABOUT headers), replacing the default system header look.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Brand.Font.mono(size: 10, weight: .semibold, relativeTo: .caption2))
            .tracking(1.2)
            .foregroundStyle(Brand.Color.textTertiary)
            .textCase(nil)
    }
}

// MARK: - Window switcher

/// WEEK / MONTH / ALL TIME segmented control — the shared
/// GlassSegmentedSlider (glass thumb tracks the finger; see that file's
/// construction notes) restyled to the leaderboard's mono readout voice.
/// Lives at the top of the List content; the screen keeps its
/// stock-but-branded system nav (Leaderboard is a UTILITY screen — see the
/// Brand chrome rule). The 40 pt segments + 4 pt track padding give a 48 pt
/// control, clearing the 44 pt HIG target.
struct LeaderboardWindowSwitcher: View {
    @Binding var selection: LeaderboardWindow

    var body: some View {
        GlassSegmentedSlider(
            selection: $selection,
            segments: LeaderboardWindow.allCases,
            segmentHeight: 40,
            trackPadding: 4,
            accessibilityTitle: "Leaderboard window",
            segmentTitle: { $0.label }
        ) { window, isSelected in
            Text(window.label)
                .font(Brand.Font.mono(size: 12, weight: isSelected ? .bold : .regular, relativeTo: .caption))
                .tracking(0.8)
                .foregroundStyle(isSelected ? Brand.Color.bgPrimary : Brand.Color.textSecondary)
        }
        .padding(.bottom, 4)
    }
}

#Preview("Leaderboard") {
    NavigationStack { LeaderboardScreen() }
        .modelContainer(for: Catch.self, inMemory: true)
}
