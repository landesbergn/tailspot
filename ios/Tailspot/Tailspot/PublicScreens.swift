//
//  PublicScreens.swift
//  Tailspot
//
//  Public surfaces:
//
//   - LeaderboardScreen — live global leaderboard from the backend, now
//     windowed (dynamic-leaderboards PR2): WEEK (default) / MONTH / ALL TIME
//     tabs, reset countdowns, and previous-period champion banners on the week
//     and month tabs. Shows rank/handle/points/catches, highlights "me" row (works
//     in the list). The fixed header carries one centred sentence for the
//     selected tab under the switcher: "You're 18th this week" over
//     "10 points behind @x · resets in 2d 9h" — see StandingLine in
//     LeaderboardWindows.swift. A handle-less device gets the
//     "claim a handle" hint instead of a goal.
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
    /// The handle the server has acknowledged (HandleSyncer's marker) — the
    /// standing card's make-the-board goal is hidden for a stranded handle.
    @AppStorage(SpotterHandle.confirmedKey) private var confirmedHandle: String?

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
    /// Standing line per window, computed once per load (and when the
    /// local handle changes) rather than on every render. The header shows
    /// the selected window's line.
    @State private var standingLines: [LeaderboardWindow: StandingLine] = [:]
    /// `RaceGap.reportKey(window:)`s already reported as
    /// `leaderboard_gap_shown` this screen visit. Not cleared on disappear:
    /// that also fires when Challenges is pushed over the board, and coming
    /// back isn't a new visit. A new visit is a new view, so fresh state.
    @State private var reportedGapKeys: Set<String> = []

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
        let responses: [LeaderboardWindow: LeaderboardResponse] =
            [.week: LeaderboardResponse(entries: entries, me: me)]
        _responses = State(initialValue: responses)
        _windowsSupported = State(initialValue: false)
        _standingLines = State(initialValue: Self.debugStandingLines(responses))
        debugSeeded = true
    }

    /// Fixture lines for the debug seams: `load()` never runs there, so
    /// compute from the seeded responses and the handle in UserDefaults
    /// (what `@AppStorage localHandle` will read).
    private static func debugStandingLines(
        _ responses: [LeaderboardWindow: LeaderboardResponse]
    ) -> [LeaderboardWindow: StandingLine] {
        let defaults = UserDefaults.standard
        let handle = SpotterHandle.publicHandle(defaults.string(forKey: SpotterHandle.storageKey))
        let confirmed = SpotterHandle.isConfirmed(
            handle, confirmed: defaults.string(forKey: SpotterHandle.confirmedKey))
        return responses.reduce(into: [:]) { lines, pair in
            lines[pair.key] = StandingLine.compute(response: pair.value, window: pair.key,
                                                   myHandle: handle, handleConfirmed: confirmed)
        }
    }

    /// Windowed snapshot seam: seed any subset of window responses and pick
    /// the selected tab. `windowsSupported` derives from the selected
    /// window's response (so an old-payload fixture exercises fail-soft).
    init(_debugWindows responses: [LeaderboardWindow: LeaderboardResponse],
         selected: LeaderboardWindow = .week) {
        _responses = State(initialValue: responses)
        _selectedWindow = State(initialValue: selected)
        _windowsSupported = State(initialValue: responses[selected]?.supportsWindows ?? true)
        _standingLines = State(initialValue: Self.debugStandingLines(responses))
        debugSeeded = true
    }
    #endif

    var body: some View {
        // Windows-aware backend → the Hangar pager structure (2026-07-19,
        // Noah: the leaderboard toggle felt different from the Hangar's —
        // it was: content swapped in-place inside one List, which both
        // hitched the slider thumb with a full-List relayout and gave no
        // page swipe). Now the switcher is a fixed header and each window
        // is its own List inside a paged TabView — the kept-alive pages
        // swap via UIKit's page view (smooth next to the thumb animation)
        // and swiping between boards comes free, matching the Hangar.
        // Fail-soft (old backend / nothing loaded yet): one plain board,
        // no switcher, no pager — exactly the pre-windows rendering.
        Group {
            if windowsSupported == true {
                VStack(spacing: 0) {
                    switcherHeader
                    TabView(selection: $selectedWindow) {
                        ForEach(LeaderboardWindow.allCases) { window in
                            windowList(window)
                                .tag(window)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                }
            } else {
                // Old backend: no switcher, but the standing line still
                // sits above the board (no goal — see StandingLine).
                VStack(spacing: 0) {
                    if let line = standingLines[selectedWindow] {
                        standingLineView(line, reset: nil)
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                    }
                    windowList(selectedWindow)
                }
            }
        }
        .background(Brand.Color.bgPrimary.ignoresSafeArea())
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        // Challenges (2026-09-15): the checkered flag is the cold-state
        // entry; the strip under the switcher is the hot-state one. Both
        // render nothing when no ChallengesModel is in the environment
        // (snapshot harness) or the server has the feature off.
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ChallengesFlagButton() }
        }
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
            Analytics.capture("leaderboard_viewed", [
                "entry_count": .int(responses[selectedWindow]?.entries.count ?? 0),
                "has_handle":  .bool(myHandle != nil),
                "window":      .string(selectedWindow.rawValue),
            ])
        }
        // A handle claimed/changed elsewhere moves "me" on the cached boards.
        .onChange(of: localHandle) { _, _ in recomputeStandingLines() }
        .onChange(of: confirmedHandle) { _, _ in recomputeStandingLines() }
    }

    // MARK: - Load

    private func load(_ window: LeaderboardWindow) async {
        do {
            let response = try await client.leaderboard(window: window, limit: LeaderboardResponse.displayLimit)
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
            // `leaderboard_gap_shown` is NOT fired here: a load isn't a
            // view (the pager loads neighbouring tabs too). The header line
            // reports it — see `reportGapShown`.
            standingLines[window] = standingLine(for: response, window: window)
        } catch {
            // Keep stale data when we have it — a failed silent refresh must
            // not blank a board the user is looking at. The stored message
            // is ErrorCopy prose, never the raw transport string (which
            // could be developer copy like AccountError.notRegistered).
            if responses[window] == nil {
                errors[window] = ErrorCopy.prose(for: error)
            }
        }
    }

    // MARK: - Per-window board

    /// One window's full board as its own List — a kept-alive page in the
    /// body's TabView. Sections are unchanged from the pre-pager rendering;
    /// each page pulls from its OWN window's cache/error slot, so a swipe
    /// shows the neighbor's last data instantly while `.task(id:
    /// selectedWindow)` refreshes it.
    private func windowList(_ window: LeaderboardWindow) -> some View {
        List {
            if let response = responses[window] {
                let entries = response.displayedEntries
                if windowsSupported == true {
                    if window == .week, let champions = response.champions {
                        championSection(champions, window: .week)
                    } else if window == .month,
                              let champions = response.monthlyChampions {
                        championSection(champions, window: .month)
                    }
                }
                if entries.isEmpty {
                    emptySection
                } else {
                    if entries.count >= 3 {
                        Section {
                            podium(entries: entries)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    rankSection(entries: entries, additionalCatchers: response.additionalCatchers)
                }
            } else if let msg = errors[window] {
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
        // Vertical density (Noah, 2026-10-23): inset-grouped's default
        // section gaps (~35 pt) and its 44 pt row floor spread the board
        // out. Compact section spacing, a small top margin under the fixed
        // header, and slimmer row insets (in leaderRow) fit more rows on screen.
        .listSectionSpacing(.compact)
        .contentMargins(.top, 4, for: .scrollContent)
        .refreshable { await load(window) }
    }

    // MARK: - Window switcher + countdown

    /// The slider + standing line as a fixed header ABOVE the pager (Noah,
    /// 2026-10-22: your standing and the gap to the place above belong
    /// where they're seen without scrolling). No longer a List Section —
    /// the slider shouldn't scroll away with the board, and outside the
    /// List its drag gesture no longer competes with the List's scroll
    /// pan. Horizontal padding matches the inset-grouped row margins so
    /// the track aligns with the cards below.
    ///
    /// The reset countdown lives in the standing line's subtitle (it used
    /// to be its own "RESETS SUNDAY · 2D 9H LEFT" mono line), so an
    /// unregistered device still gets the reset, alone.
    private var switcherHeader: some View {
        VStack(spacing: 6) {
            // The live-challenge strip that sat here is gone (Noah,
            // 2026-09-27): the flag button's count badge is the entry now.
            LeaderboardWindowSwitcher(selection: $selectedWindow)
            standingLineView(standingLines[selectedWindow], reset: resetCountdown)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    /// "resets in 2d 14h" (week) / "resets Aug 1" (month), in the device's
    /// locale + timezone, with its VoiceOver form. Recomputed per render —
    /// it refreshes on appear/tab-flip/refresh; no live ticking timer.
    private var resetCountdown: (text: String, spoken: String)? {
        guard let resetsAt = responses[selectedWindow]?.resetsAtDate else { return nil }
        let now = Date()
        switch selectedWindow {
        case .week:
            return (LeaderboardCountdown.weekProse(resetsAt: resetsAt, now: now),
                    LeaderboardCountdown.weekSpoken(resetsAt: resetsAt, now: now))
        case .month:
            let text = LeaderboardCountdown.monthProse(resetsAt: resetsAt)
            return (text, text)
        case .all:
            return nil  // resetsAt is null for all-time anyway
        }
    }

    // MARK: - Champion banner (week/month tabs)

    /// Gold-accented banner above the podium. Three states: crowned (one or
    /// more champions — a shared crown lists names side by side), and the
    /// quiet zero-champion week. (`champions == nil` — old backend or a
    /// non-week window — never reaches here.)
    @ViewBuilder
    private func championSection(_ champions: [LeaderboardChampion],
                                 window: LeaderboardWindow) -> some View {
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
                        Text(ChampionBanner.noChampionSubtitle(window: window))
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
                        Text(ChampionBanner.eyebrow(count: champions.count, window: window))
                            .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                            .tracking(1.2)
                            .foregroundStyle(Brand.Color.podiumGold)
                        Text("\(Text(ChampionBanner.names(champions)).foregroundStyle(Brand.Color.textPrimary))\(Text(" · \(champions[0].points.formatted(.number)) PTS").foregroundStyle(Brand.Color.podiumGold))")
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
            podiumColumn(entry: entries.first(where: { $0.rank == 2 }), height: 60, rank: 2)
            podiumColumn(entry: entries.first(where: { $0.rank == 1 }), height: 84, rank: 1)
            podiumColumn(entry: entries.first(where: { $0.rank == 3 }), height: 44, rank: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
        return VStack(spacing: 4) {
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
                    .font(Brand.Font.mono(size: 22, weight: .heavy))
                    .foregroundStyle(tint)
                    .padding(.top, 6)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.map {
            "Rank \(rank), \($0.handle), \($0.points) points"
        } ?? "Rank \(rank), empty")
    }

    /// Top 50 public catchers, with the qualifying remainder below the list.
    @ViewBuilder
    private func rankSection(entries: [LeaderboardEntry], additionalCatchers: Int) -> some View {
        Section {
            ForEach(entries) { entry in
                leaderRow(entry)
            }
        } footer: {
            if additionalCatchers > 0 {
                Text("\(additionalCatchers.formatted(.number)) more \(additionalCatchers == 1 ? "catcher" : "catchers")")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
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
            // YOU sits right after the name (Noah, 2026-10-23): at the far
            // end it crowded the points column and read as part of it.
            if isMe {
                Text("YOU")
                    .font(Brand.Font.mono(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Brand.Color.cyan, in: .capsule)
                    .fixedSize()
            }
            Spacer(minLength: 8)
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
        }
        .listRowInsets(.vertical, 10)
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
        LeaderboardEntry.isMe(entry, myHandle: myHandle,
                              handleConfirmed: SpotterHandle.isConfirmed(myHandle, confirmed: confirmedHandle))
    }

    /// The local handle, or nil while the device still has the placeholder
    /// (or nothing) — the "has a handle" test the whole screen uses.
    private var myHandle: String? { SpotterHandle.publicHandle(localHandle) }

    private func standingLine(for response: LeaderboardResponse,
                              window: LeaderboardWindow) -> StandingLine? {
        StandingLine.compute(response: response, window: window, myHandle: myHandle,
                             handleConfirmed: SpotterHandle.isConfirmed(myHandle, confirmed: confirmedHandle))
    }

    private func recomputeStandingLines() {
        for (window, response) in responses {
            standingLines[window] = standingLine(for: response, window: window)
        }
    }

    /// One `leaderboard_gap_shown` per goal per window per screen visit,
    /// fired when the header line shows a gap for the selected tab — not per
    /// load (the pager loads neighbouring tabs the user isn't looking at).
    private func reportGapShown(_ gap: RaceGap, window: LeaderboardWindow) {
        guard reportedGapKeys.insert(gap.reportKey(window: window)).inserted else { return }
        Analytics.capture("leaderboard_gap_shown", [
            "gap_pts":       .int(gap.points),
            "catches_equiv": .int(gap.catchesEquivalent),
            "target":        .string(gap.analyticsTarget),
            "window":        .string(window.rawValue),
        ])
    }

    /// The standing line in the fixed header (Noah's option "D · One
    /// sentence", 2026-10-23), centred under the switcher:
    ///
    ///         You're 18th this week
    ///   10 points behind @randy98 · resets in 2d 9h
    ///
    /// The heading is the app's one prose head (`.brandDisplayFont()`) with
    /// the ordinal in cyan; the subtitle is body text. Both wrap rather than
    /// truncate at large type (`fixedSize(vertical:)` lets the header grow).
    /// With no standing (unregistered) only the reset shows; with neither,
    /// nothing does.
    @ViewBuilder
    private func standingLineView(_ line: StandingLine?,
                                  reset: (text: String, spoken: String)?) -> some View {
        let subtitle = StandingLine.subtitle(detail: line?.detail, reset: reset?.text)
        if line != nil || subtitle != nil {
            let window = selectedWindow
            VStack(spacing: 4) {
                if let line {
                    standingHeading(line)
                        .brandDisplayFont()
                        .foregroundStyle(Brand.Color.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Brand.Font.body)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 8)
            // One element, read as sentences ("You're 18th this week. 10
            // points behind randy98. Resets in 2 days, 9 hours.").
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StandingLine.spoken(line, spokenReset: reset?.spoken))
            // Re-runs when the tab or the goal changes; the key set dedups
            // repeat views within one visit. Only gaps (pass / make the
            // board) are reported — a lead isn't a goal.
            .task(id: line?.raceGap?.reportKey(window: window)) {
                if let gap = line?.raceGap {
                    reportGapShown(gap, window: window)
                }
            }
        }
    }

    /// "You're **18th** this week" with the ordinal in Brand cyan.
    private func standingHeading(_ line: StandingLine) -> Text {
        guard let ordinal = line.ordinal else { return Text(line.heading) }
        return Text("You're \(Text(ordinal).foregroundStyle(Brand.Color.cyan))\(line.headingSuffix)")
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
