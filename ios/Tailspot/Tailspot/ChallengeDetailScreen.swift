//
//  ChallengeDetailScreen.swift
//  Tailspot
//
//  One pushed screen for a challenge in every state (spec §4.4–4.6): an
//  upcoming one (share the link; cancel if it's yours, leave if not), a
//  live one (countdown, standings, share, leave), and a finished one (the
//  results — a winner moment the first time, a quiet board after). The
//  header changes with the state; the standings card is the same view
//  throughout, with each row expandable into that spotter's rarity
//  breakdown and catch log.
//
//  Explain-as-we-go: `.confirmationDialog` is the iOS action sheet — the
//  right control for a destructive, reversible-only-by-rejoining action
//  like Leave; `.sensoryFeedback(.success, trigger:)` fires the haptic when
//  the trigger value changes, which is why the first-view flag flips once.
//

import SwiftUI
import UIKit

struct ChallengeDetailScreen: View {
    @Environment(ChallengesModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    let id: String
    /// After Create: put the share sheet up as soon as the screen appears.
    let presentShareOnAppear: Bool
    /// Snapshot seam — the environment value is read-only in a harness.
    private let debugReduceMotion: Bool?

    @State private var showShare = false
    @State private var confirmLeave = false
    @State private var confirmCancel = false
    @State private var actionError: ChallengesError?
    @State private var expanded: Set<String> = []
    @State private var copied = false
    /// Flips once on the first results view; drives the haptic and the
    /// laurel animation.
    @State private var firstViewTick = 0
    @State private var laurelsShown = false
    @State private var isBusy = false

    /// `_debugExpanded` pre-opens standings rows for the snapshot harness.
    init(id: String, presentShareOnAppear: Bool = false,
         _debugReduceMotion: Bool? = nil, _debugExpanded: Set<String> = []) {
        self.id = id
        self.presentShareOnAppear = presentShareOnAppear
        self.debugReduceMotion = _debugReduceMotion
        _expanded = State(initialValue: _debugExpanded)
    }

    private var reduceMotion: Bool { debugReduceMotion ?? systemReduceMotion }

    // MARK: Derived

    private var detail: ChallengeDetail? { model.details[id] }

    /// The list row while the detail is still loading.
    private var summary: ChallengeSummary? {
        detail?.challenge ?? model.open.first { $0.id == id } ?? model.history.first { $0.id == id }
    }

    private var status: ChallengeStatus {
        guard let s = summary else { return .unknown }
        if s.status == .cancelled { return .cancelled }
        return ChallengeTiming.status(startsAt: s.startsAt, endsAt: s.endsAt, cancelledAt: nil, now: model.now())
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 16) {
                    if let s = summary {
                        header(s)
                        if status == .finished, let d = detail { results(d) }
                        if status == .upcoming || status == .live { shareCard(s) }
                        if let d = detail { standings(d) } else if let e = model.detailErrors[id] { errorCard(e) } else { loading }
                        if let actionError {
                            Label(ChallengeCopy.message(for: actionError), systemImage: "exclamationmark.circle.fill")
                                .font(Brand.Font.caption)
                                .foregroundStyle(Brand.Color.alertCaution)
                        }
                        actions(s)
                    } else if let e = model.detailErrors[id] {
                        errorCard(e)
                    } else {
                        loading
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(ChallengeBackdrop())
        .navigationTitle(summary?.name ?? "Challenge")
        .navigationBarTitleDisplayMode(.inline)
        // `onLoaded` runs after EVERY load, not just the first: its own
        // latch makes it once-per-push, and the first load can fail — a
        // pull-to-refresh that finally succeeds must still fire the view
        // analytics and mark the results seen.
        .refreshable {
            await model.loadDetail(id: id)
            onLoaded()
        }
        .task {
            await model.loadDetail(id: id)
            onLoaded()
            if presentShareOnAppear { showShare = true }
            await pollWhileRelevant()
        }
        .sensoryFeedback(.success, trigger: firstViewTick)
        .sheet(isPresented: $showShare) {
            if let s = summary { ChallengeShareSheet(challenge: s, now: model.now) }
        }
        .confirmationDialog("Leave this challenge?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await leave() } }
        } message: {
            Text("Your catches drop off the standings. You can rejoin with the link until it ends.")
        }
        .confirmationDialog("Cancel this challenge?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel challenge", role: .destructive) { Task { await cancel() } }
        } message: {
            Text("Everyone who joined loses it. This can't be undone.")
        }
    }

    // MARK: Polling

    /// How often a live challenge re-reads its standings.
    static let livePollInterval: TimeInterval = 60
    /// The longest a single sleep waits for an upcoming challenge to start.
    /// A start can be 14 days out; waiting that long in one `Task.sleep`
    /// would also mean 14 days without noticing a cancel or a new joiner,
    /// so the wait is capped and the loop re-evaluates.
    static let upcomingPollCap: TimeInterval = 300

    /// How long to wait before the next refresh, or nil when there is
    /// nothing left to poll. Pure so the cadence is testable without a
    /// clock or a view.
    ///
    /// `hasDetail == false` means the screen is showing an error card: the
    /// load failed and there is nothing to decide a status from. That case
    /// must keep retrying on the live cadence — the old unconditional
    /// `while` loop did, and an error card that can never heal itself is a
    /// worse bug than the over-polling this method exists to stop. Only a
    /// KNOWN-finished or known-cancelled challenge stops the loop, because
    /// only then is there provably nothing left to fetch.
    static func pollWait(status: ChallengeStatus, secondsUntilStart: TimeInterval?,
                         hasDetail: Bool) -> TimeInterval? {
        guard hasDetail else { return livePollInterval }
        switch status {
        case .live:
            return livePollInterval
        case .upcoming:
            let untilStart = secondsUntilStart ?? livePollInterval
            return min(max(untilStart, 1), upcomingPollCap)
        case .unknown:
            // Status we don't recognize (a future server value): keep
            // refreshing rather than freezing on a screen we can't reason
            // about.
            return livePollInterval
        case .finished, .cancelled:
            return nil
        }
    }

    /// The view-analytics latch: fire only on a load that produced a detail,
    /// and only once per push. A first load that FAILED must leave the latch
    /// down so a later pull-to-refresh still counts the view.
    static func shouldFireViewed(hasDetail: Bool, alreadyFired: Bool) -> Bool {
        hasDetail && !alreadyFired
    }

    /// Refresh while there is something to refresh. A LIVE challenge's
    /// standings move, so poll it every minute. An UPCOMING one can't score
    /// until it starts: sleep until the start instant (capped, and
    /// cancellable like every `Task.sleep`), refresh once there, and fall
    /// through to live polling. Anything finished or cancelled is frozen —
    /// the loop returns and the task ends rather than burning a request a
    /// minute on a result that can never change. A failed load keeps
    /// retrying, so the error card heals itself when the network comes
    /// back without the user pulling to refresh.
    private func pollWhileRelevant() async {
        while !Task.isCancelled {
            let untilStart = summary.map { $0.startsAt.timeIntervalSince(model.now()) }
            guard let wait = Self.pollWait(status: status, secondsUntilStart: untilStart,
                                           hasDetail: detail != nil) else { return }
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await model.loadDetail(id: id)
            onLoaded()
        }
    }

    // MARK: Appear

    /// Once per push — a pop back from an expanded log re-runs `.task`.
    @State private var didFireViewed = false

    private func onLoaded() {
        guard let d = detail,
              Self.shouldFireViewed(hasDetail: true, alreadyFired: didFireViewed) else { return }
        didFireViewed = true
        Analytics.capture("challenge_viewed", [
            "challenge_id": .string(id),
            "state": .string(stateLabel.lowercased()),
            "my_placement": .int(d.me?.placement ?? 0),
            "participants": .int(d.challenge.participantCount),
        ])
        if status == .finished {
            let first = !model.seenResultIds.contains(id)
            Analytics.capture("challenge_results_viewed", [
                "challenge_id": .string(id),
                "outcome": .string(outcomeLabel(d)),
                "placement": .int(d.me?.placement ?? 0),
                "participants": .int(d.challenge.participantCount),
                "first_view": .bool(first),
            ])
            if first && d.challenge.isDecided {
                firstViewTick += 1
                if reduceMotion {
                    laurelsShown = true
                } else {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.65)) { laurelsShown = true }
                }
            } else {
                laurelsShown = true
            }
            model.markResultsSeen(id: id)
        }
    }

    private func outcomeLabel(_ d: ChallengeDetail) -> String {
        if d.challenge.isNoContest { return "no_contest" }
        guard let me = d.me else { return "finished" }
        if me.placement == 1 { return ChallengeCopy.isTie(d) ? "tied" : "won" }
        return "lost"
    }

    private var stateLabel: String {
        switch status {
        case .upcoming: return "Upcoming"
        case .live: return "Live"
        case .finished: return (summary?.isNoContest ?? false) ? "No contest" : "Finished"
        case .cancelled: return "Cancelled"
        case .unknown: return "Challenge"
        }
    }

    // MARK: Header

    private func header(_ s: ChallengeSummary) -> some View {
        let me = detail?.me ?? s.myResult
        let tie = detail.map(ChallengeCopy.isTie) ?? false
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(headerTag, systemImage: headerGlyph)
                    .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                    .tracking(1.1)
                    .foregroundStyle(headerTint)
                Spacer()
                if status == .live {
                    ChallengeCountdown(endsAt: s.endsAt, now: model.now)
                } else if status == .upcoming {
                    Text(ChallengeTiming.startsInCopy(startsAt: s.startsAt, now: model.now()))
                        .font(Brand.Font.mono(size: 10, weight: .bold, relativeTo: .caption2))
                        .tracking(1.1)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(s.name)
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                Text(subtitle(s))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            if status == .live || (status == .finished && !s.isNoContest), let me {
                trio(me: me, tie: tie)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(headerTint.opacity(status == .live ? 0.07 : 0.0), in: .rect(cornerRadius: Brand.Radius.card))
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(headerTint.opacity(status == .live ? 0.22 : 0.0), lineWidth: 1)
        }
    }

    private var headerTag: String {
        switch status {
        case .upcoming: return "ON DECK"
        case .live: return "IN FLIGHT"
        case .finished: return (summary?.isNoContest ?? false) ? "NO CONTEST" : "FINISHED"
        case .cancelled: return "CANCELLED"
        case .unknown: return "CHALLENGE"
        }
    }

    private var headerGlyph: String {
        switch status {
        case .upcoming: return "clock"
        case .live: return "airplane"
        case .finished: return "flag.checkered"
        case .cancelled: return "xmark"
        case .unknown: return "flag"
        }
    }

    private var headerTint: Color {
        switch status {
        case .live: return Brand.Color.cyan
        case .finished: return (summary?.isNoContest ?? false) ? Brand.Color.textTertiary : Brand.Color.podiumGold
        default: return Brand.Color.textSecondary
        }
    }

    private func subtitle(_ s: ChallengeSummary) -> String {
        let who = ChallengeCopy.spotters(s.participantCount)
        switch status {
        case .upcoming: return "\(who) · \(ChallengeCopy.startsLine(startsAt: s.startsAt, now: model.now())) · \(ChallengeCopy.durationLabel(s.durationPreset))"
        case .live: return "\(who) · \(ChallengeCopy.endsLine(endsAt: s.endsAt, now: model.now()))"
        case .finished: return "\(who) · ended \(ChallengeCopy.relativeMoment(s.endsAt, now: model.now()))"
        case .cancelled: return "cancelled by @\(s.creatorHandle) before it started"
        case .unknown: return who
        }
    }

    @ViewBuilder
    private func trio(me: ChallengeMyResult, tie: Bool) -> some View {
        let cells: [(String, String, Color)] = [
            (ChallengeTiming.placementLabel(placement: me.placement, isTie: tie), "PLACE", ChallengeStyle.placementTint(me.placement)),
            (me.points.formatted(.number), "POINTS", Brand.Color.cyan),
            ("\(me.catches)", "CATCHES", Brand.Color.textPrimary),
        ]
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(cells, id: \.1) { cell in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        metricValue(cell.0, color: cell.2); metricLabel(cell.1)
                    }
                }
            }
        } else {
            HStack(spacing: 0) {
                ForEach(cells, id: \.1) { cell in
                    VStack(spacing: 2) { metricValue(cell.0, color: cell.2); metricLabel(cell.1) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func metricValue(_ value: String, color: Color) -> some View {
        Text(value)
            .font(Brand.Font.mono(size: 23, weight: .bold, relativeTo: .title3))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func metricLabel(_ label: String) -> some View {
        Text(label)
            .font(Brand.Font.mono(size: 8, weight: .semibold, relativeTo: .caption2))
            .tracking(1.1)
            .foregroundStyle(Brand.Color.textTertiary)
    }

    // MARK: Results

    private func results(_ d: ChallengeDetail) -> some View {
        let verdict = ChallengeCopy.verdict(d)
        let winners = d.winners.isEmpty ? d.standings.filter { $0.placement == 1 }.map(\.handle) : d.winners
        let decided = d.challenge.isDecided && !winners.isEmpty
        return VStack(spacing: 10) {
            if decided {
                HStack(spacing: 10) {
                    Image(systemName: "laurel.leading")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Brand.Color.podiumGold)
                        .accessibilityHidden(true)
                    VStack(spacing: 2) {
                        Text(winners.count > 1 ? "CO-WINNERS" : "WINNER")
                            .font(Brand.Font.mono(size: 9, weight: .bold, relativeTo: .caption2))
                            .tracking(1.1)
                            .foregroundStyle(Brand.Color.podiumGold)
                        Text(winners.map { "@\($0)" }.joined(separator: " · "))
                            .font(Brand.Font.mono(size: 15, weight: .bold, relativeTo: .body))
                            .foregroundStyle(Brand.Color.textPrimary)
                            .multilineTextAlignment(.center)
                    }
                    Image(systemName: "laurel.trailing")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Brand.Color.podiumGold)
                        .accessibilityHidden(true)
                }
                // A scale pop only — opacity stays 1 so the block is legible
                // in any frame of the spring, and Reduce Motion simply skips
                // the scale (the flag is set without animation there).
                .scaleEffect(laurelsShown || reduceMotion ? 1 : 0.6)
            }
            Text(verdict)
                .brandDisplayFont()
                .foregroundStyle(Brand.Color.textPrimary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(Brand.Color.podiumGold.opacity(decided ? 0.08 : 0.0), in: .rect(cornerRadius: Brand.Radius.card))
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Brand.Color.podiumGold.opacity(decided ? 0.22 : 0.0), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(decided ? "\(winners.count > 1 ? "Co-winners" : "Winner") \(winners.joined(separator: ", ")). \(verdict)" : verdict)
    }

    // MARK: Share

    private func shareCard(_ s: ChallengeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ChallengeSectionLabel(title: "INVITE")
            ChallengeShareControls(challenge: s, now: model.now, copied: $copied)
        }
    }

    // MARK: Standings

    private func standings(_ d: ChallengeDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ChallengeSectionLabel(title: status == .finished ? "FINAL STANDINGS" : (status == .upcoming ? "WHO'S IN" : "STANDINGS"))
            if status == .upcoming && !d.standings.isEmpty {
                // Nobody has scored yet, so no placements: everyone would
                // read "T-1st", which is nonsense before the start. Just the
                // roster, creator first.
                VStack(spacing: 0) {
                    ForEach(Array(d.standings.enumerated()), id: \.element.handle) { index, row in
                        if index > 0 {
                            Rectangle().fill(Brand.Color.bgPrimary.opacity(0.5)).frame(height: 1).padding(.leading, 60)
                        }
                        rosterRow(row, creator: d.challenge.creatorHandle)
                    }
                }
                .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
            } else if d.standings.isEmpty {
                Text(status == .cancelled ? "Nothing was scored." : "Nobody's in yet. Share the link.")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(d.standings.enumerated()), id: \.element.handle) { index, row in
                        if index > 0 {
                            Rectangle().fill(Brand.Color.bgPrimary.opacity(0.5)).frame(height: 1).padding(.leading, 60)
                        }
                        standingRow(row, in: d)
                    }
                }
                .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
            }
        }
    }

    private func standingRow(_ row: ChallengeStanding, in d: ChallengeDetail) -> some View {
        let tie = d.standings.filter { $0.placement == row.placement }.count > 1
        let isMe = row.isMe == true
        let isExpanded = expanded.contains(row.handle)
        return VStack(spacing: 0) {
            Button {
                toggle(row.handle, in: d)
            } label: {
                HStack(spacing: 12) {
                    PlacementDisc(placement: row.placement, isTie: tie)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("@\(row.handle)")
                                .font(Brand.Font.mono(size: 14, weight: isMe ? .bold : .regular, relativeTo: .subheadline))
                                .foregroundStyle(Brand.Color.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if isMe {
                                Text("YOU")
                                    .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                                    .foregroundStyle(Brand.Color.bgPrimary)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Brand.Color.cyan, in: .capsule)
                            }
                        }
                        Text(CountCopy.phrase(row.catches, singular: "catch", plural: "catches"))
                            .font(Brand.Font.mono(size: 10, relativeTo: .caption2))
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                    Spacer()
                    Text(row.points.formatted(.number))
                        .font(Brand.Font.mono(size: 14, weight: .bold, relativeTo: .subheadline))
                        .foregroundStyle(isMe ? Brand.Color.cyan : Brand.Color.textPrimary)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.Color.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(rowLabel(row, tie: tie, isMe: isMe))
            .accessibilityHint(isExpanded ? "Collapses the catch log" : "Shows the rarity breakdown and catch log")
            .accessibilityAddTraits(.isButton)

            if isExpanded {
                expandedRow(row, in: d)
            }
        }
        .background(isMe ? Brand.Color.cyan.opacity(0.07) : .clear)
    }

    private func rosterRow(_ row: ChallengeStanding, creator: String) -> some View {
        let isMe = row.isMe == true
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.Color.cyan.opacity(0.12))
                Image(systemName: row.handle == creator ? "flag.fill" : "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Brand.Color.cyan)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text("@\(row.handle)")
                    .font(Brand.Font.mono(size: 14, weight: isMe ? .bold : .regular, relativeTo: .subheadline))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                if isMe {
                    Text("YOU")
                        .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Brand.Color.cyan, in: .capsule)
                }
            }
            Spacer()
            Text(row.handle == creator ? "started it" : "in")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .background(isMe ? Brand.Color.cyan.opacity(0.07) : .clear)
        .accessibilityElement(children: .combine)
    }

    private func rowLabel(_ row: ChallengeStanding, tie: Bool, isMe: Bool) -> String {
        let place = tie ? "tied \(ChallengeTiming.placementLabel(placement: row.placement, isTie: false))"
                        : ChallengeTiming.placementLabel(placement: row.placement, isTie: false)
        let catches = CountCopy.phrase(row.catches, singular: "catch", plural: "catches")
        return "\(place), @\(row.handle), \(row.points) points, \(catches)\(isMe ? ", you" : "")"
    }

    private func toggle(_ handle: String, in d: ChallengeDetail) {
        if expanded.contains(handle) {
            expanded.remove(handle)
            return
        }
        expanded.insert(handle)
        Analytics.capture("challenge_log_viewed", [
            "challenge_id": .string(id),
            "own": .bool(d.standings.first { $0.handle == handle }?.isMe == true),
        ])
        if model.log(id: id, handle: handle) == nil {
            loadLog(handle: handle)
        }
    }

    /// Fire-and-forget log load. The throw is swallowed here because the
    /// model records it in `logErrors`, which is what the row renders.
    private func loadLog(handle: String) {
        Task { try? await model.loadLog(id: id, handle: handle) }
    }

    private func expandedRow(_ row: ChallengeStanding, in d: ChallengeDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !row.rarityBreakdown.isEmpty {
                FlowChips(items: Rarity.allCases.compactMap { tier in
                    row.rarityBreakdown[tier.rawValue].map { (tier.rawValue, $0) }
                })
            }
            if let log = model.log(id: id, handle: row.handle) {
                if log.catches.isEmpty {
                    Text("no catches yet")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textTertiary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(log.catches.enumerated()), id: \.offset) { _, entry in
                            logRow(entry)
                        }
                    }
                }
            } else if model.logError(id: id, handle: row.handle) != nil {
                // A failed log used to leave the spinner up for ever — the
                // load is fire-and-forget (`try?`), so nothing ever came
                // back to clear it. Say so, and make the line the retry.
                Button {
                    loadLog(handle: row.handle)
                } label: {
                    Label("Couldn't load catches. Tap to retry.", systemImage: "arrow.clockwise")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.alertCaution)
                        .frame(minHeight: 32, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Loads this spotter's catches again")
            } else {
                HStack { ProgressView().controlSize(.small).tint(Brand.Color.cyan); Text("loading catches").font(Brand.Font.caption).foregroundStyle(Brand.Color.textTertiary) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.leading, 46)
    }

    private func logRow(_ entry: ChallengeCatchLogEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.aircraft ?? "Aircraft")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textPrimary)
                    .lineLimit(1)
                Text(ChallengeCopy.relativeMoment(entry.caughtAt, now: model.now()))
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            Spacer()
            Text(ChallengeStyle.rarityLabel(entry.rarity))
                .font(Brand.Font.mono(size: 8, weight: .bold, relativeTo: .caption2))
                .tracking(0.8)
                .foregroundStyle(ChallengeStyle.rarityTint(entry.rarity))
            Text("+\(entry.points)")
                .font(Brand.Font.mono(size: 12, weight: .bold, relativeTo: .caption))
                .foregroundStyle(Brand.Color.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ s: ChallengeSummary) -> some View {
        switch status {
        case .upcoming where s.isCreator:
            destructiveButton("Cancel challenge") { confirmCancel = true }
        case .upcoming, .live:
            destructiveButton("Leave challenge") { confirmLeave = true }
        default:
            EmptyView()
        }
    }

    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Brand.Font.button)
                .foregroundStyle(Brand.Color.alertWarning)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 46)
                .background(Brand.Color.alertWarning.opacity(0.10), in: .rect(cornerRadius: Brand.Radius.row))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .padding(.top, 8)
    }

    private func leave() async {
        isBusy = true
        defer { isBusy = false }
        let elapsed = summary.map { s -> Double in
            let total = s.endsAt.timeIntervalSince(s.startsAt)
            return max(0, min(1, model.now().timeIntervalSince(s.startsAt) / max(total, 1)))
        } ?? 0
        do {
            try await model.leave(id: id)
            Analytics.capture("challenge_left", [
                "challenge_id": .string(id),
                "state": .string(stateLabel.lowercased()),
                "elapsed_fraction": .double(elapsed),
            ])
            dismiss()
        } catch let e as ChallengesError {
            actionError = e
        } catch {
            actionError = .network(error.localizedDescription)
        }
    }

    private func cancel() async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await model.cancel(id: id)
            Analytics.capture("challenge_cancelled", [
                "challenge_id": .string(id),
                "state": .string(stateLabel.lowercased()),
                "elapsed_fraction": .double(0),
            ])
            dismiss()
        } catch let e as ChallengesError {
            actionError = e
        } catch {
            actionError = .network(error.localizedDescription)
        }
    }

    // MARK: Loading / error

    private var loading: some View {
        HStack { Spacer(); ProgressView().tint(Brand.Color.cyan); Spacer() }
            .padding(.vertical, 40)
            .accessibilityLabel("Loading standings")
    }

    private func errorCard(_ e: ChallengesError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(e == .notFound ? "You're not in this challenge any more" : "Couldn't load the standings")
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text(ChallengeCopy.message(for: e))
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }
}

// MARK: - Share controls

/// The code in large mono, Share link (system share sheet) and Copy link.
/// Used inline on the detail and inside `ChallengeShareSheet` after Create.
struct ChallengeShareControls: View {
    let challenge: ChallengeSummary
    let now: () -> Date
    @Binding var copied: Bool
    @State private var showActivity = false

    private var url: URL? {
        if let raw = challenge.inviteURL, let u = URL(string: raw) { return u }
        return challenge.code.map { InviteCode.inviteURL(for: $0) }
    }

    private var shareMessage: String {
        ChallengeCopy.shareMessage(name: challenge.name, preset: challenge.durationPreset,
                                   startsAt: challenge.startsAt, now: now())
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("CODE")
                    .font(Brand.Font.mono(size: 9, weight: .semibold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(challenge.code ?? "—")
                    .font(Brand.Font.mono(size: 28, weight: .bold, relativeTo: .title2))
                    .tracking(3)
                    .foregroundStyle(Brand.Color.cyan)
                    .accessibilityLabel("Invite code \((challenge.code ?? "").map(String.init).joined(separator: " "))")
            }
            HStack(spacing: 10) {
                if let url {
                    // Was a `ShareLink` whose tap gesture fired
                    // `challenge_invite_shared` — i.e. the event counted
                    // sheet OPENINGS, including the ones dismissed without
                    // sharing. `ActivityShareSheet` reports the real
                    // outcome, so the event now means what its name says
                    // and `method` names the app the link went to.
                    Button {
                        showActivity = true
                    } label: {
                        Label("Share link", systemImage: "square.and.arrow.up")
                            .font(Brand.Font.button)
                            .foregroundStyle(Brand.Color.bgPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .sheet(isPresented: $showActivity) {
                        ActivityShareSheet(items: [shareMessage, url]) { method in
                            guard let method else { return }
                            Analytics.capture("challenge_invite_shared", [
                                "challenge_id": .string(challenge.id), "method": .string(method),
                            ])
                        }
                    }
                    Button {
                        UIPasteboard.general.string = url.absoluteString
                        copied = true
                        Analytics.capture("challenge_invite_shared", [
                            "challenge_id": .string(challenge.id), "method": .string("copy_link"),
                        ])
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Brand.Font.button)
                            .foregroundStyle(Brand.Color.cyan)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 46)
                            .background(Brand.Color.cyan.opacity(0.12), in: .rect(cornerRadius: Brand.Radius.row))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Anyone with the link can join until it ends, up to \(challenge.maxParticipants) spotters.")
                .font(Brand.Font.caption)
                .foregroundStyle(Brand.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }
}

/// Presented right after Create: the same controls in their own sheet so the
/// first thing the creator does is send the link.
struct ChallengeShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let challenge: ChallengeSummary
    let now: () -> Date
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("You're in. Now invite someone.")
                            .brandDisplayFont()
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("\(challenge.name) · \(ChallengeCopy.durationLabel(challenge.durationPreset)) · \(ChallengeCopy.startsLine(startsAt: challenge.startsAt, now: now()))")
                            .font(Brand.Font.caption)
                            .foregroundStyle(Brand.Color.textSecondary)
                    }
                    ChallengeShareControls(challenge: challenge, now: now, copied: $copied)
                }
                .padding(16)
            }
            .background(ChallengeBackdrop())
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Wrapping row of rarity chips.
struct FlowChips: View {
    let items: [(String, Int)]

    var body: some View {
        // A simple wrapping layout: chips are short, so an HStack that wraps
        // via Layout is overkill — use a lazy grid with adaptive columns.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { tier, count in
                RarityChip(tier: tier, count: count)
            }
        }
    }
}
