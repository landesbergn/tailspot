//
//  ChallengesHub.swift
//  Tailspot
//
//  The Challenges hub (spec §3.1, §6): IN FLIGHT (live), ON DECK (upcoming,
//  including ones I created), FLIGHT LOG (finished and cancelled), plus
//  Create and Join with code. Pushed inside whichever NavigationStack the
//  caller owns (Profile's, or the Leaders sheet's) — it never creates one.
//
//  It reads `ChallengesModel` from the environment. Explain-as-we-go:
//  `@Environment(ChallengesModel.self)` is the Observation-framework form of
//  environment objects — the integration injects the model once with
//  `.environment(model)` on the presenting stack and every screen below
//  reads it; the view re-renders only for the properties it actually
//  touches. Tests inject a model built on `FixtureChallengesService`.
//

import SwiftUI

struct ChallengesHub: View {
    @Environment(ChallengesModel.self) private var model

    /// Where the user came from, for `challenges_hub_viewed`
    /// (leaders_flag, leaders_strip, profile_tile, reveal_line, deep_link).
    let source: String

    @State private var showCreate = false
    @State private var showJoin = false
    /// A just-created or just-joined challenge to push straight into.
    @State private var pushDetailId: String?
    /// True once the first config fetch has come back (either way), so an
    /// `.unknown` verdict reads as "couldn't reach the server" rather than
    /// the initial spinner.
    @State private var configAttempted = false
    /// A code that arrived from a `tailspot.app/c/CODE` link, taken off
    /// `ChallengesModel.pendingInviteCode`. Its own sheet slot, separate
    /// from `showJoin`, so the analytics `via` stays honest
    /// (universal_link vs code_entry) without a second flag to keep in step.
    @State private var linkCode: InviteLinkCode?

    init(source: String) {
        self.source = source
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(ChallengeBackdrop())
        // The "lying screen" badge: on when the DEBUG fixture launch
        // argument swapped the real client for the demo world.
        .overlay(alignment: .bottom) {
            if ChallengesAppModel.usesFixture {
                Text("DEMO DATA")
                    .font(Brand.Font.mono(size: 9, weight: .bold, relativeTo: .caption2))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.bgPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Brand.Color.alertCaution, in: .capsule)
                    .padding(.bottom, 8)
                    .accessibilityLabel("Demo data")
            }
        }
        .navigationTitle("Challenges")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showJoin = true } label: {
                    Image(systemName: "number")
                }
                .accessibilityLabel("Join with code")
                .disabled(!model.isAvailable)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create challenge")
                .disabled(!model.isAvailable)
            }
        }
        .refreshable { await refresh() }
        .task {
            await refresh()
            fireViewed()
            model.markHubSeen()
        }
        .sheet(isPresented: $showCreate) {
            ChallengeCreateSheet { detail in
                pushDetailId = detail.challenge.id
            }
            .environment(model)
        }
        .sheet(isPresented: $showJoin) {
            ChallengeJoinSheet(code: nil, via: "code_entry") { detail in
                pushDetailId = detail.challenge.id
            }
            .environment(model)
        }
        // Universal link: the hub the link opened takes the parked code
        // and opens the join sheet with it — the one place that already
        // knows how to preview, join and push the detail.
        //
        // `consumePendingInvite(for:)` enforces that "the hub the link
        // opened" means exactly `source == deep_link`. A hub already on
        // screen under Profile or Leaders sees the same route change, and
        // without the guard it could swallow the code during its own
        // sheet's teardown, leaving the link's hub empty.
        //
        // Keyed on the ROUTE, not the code: a code parked while the config
        // was still unknown has to open once this hub's own refresh makes
        // the verdict `.available`, and the code itself never changed.
        // `.task(id:)` also runs on appear (the usual case here) and runs
        // after the view update rather than inside it.
        .task(id: model.inviteRoute) {
            if let code = model.consumePendingInvite(for: source) {
                linkCode = InviteLinkCode(id: code)
            }
        }
        // Notification tap: the hub the tap's own sheet presented takes the
        // parked challenge id and pushes straight to its detail. Same
        // one-owner rule as the invite code above — `consumePendingDetail`
        // only answers the `deep_link` hub, so a hub already on screen under
        // Profile or Leaders can't swallow it.
        .task(id: model.pendingDetailId) {
            guard let id = model.consumePendingDetail(for: source) else { return }
            guard pushDetailId != id else { return }
            if pushDetailId != nil {
                // Already showing a DIFFERENT challenge's detail. A
                // `navigationDestination(isPresented:)` stays presented
                // across an id change — the binding never goes false, so
                // SwiftUI never builds the new destination and the second
                // tap looks ignored. Pop to root, let the pop finish, then
                // push. `try?` because the task is invalidated if another
                // tap lands mid-pop, and that tap's own run should win.
                pushDetailId = nil
                try? await ChallengeInvitePresentation.sleepForPop()
                guard !Task.isCancelled else { return }
            }
            pushDetailId = id
        }
        .sheet(item: $linkCode) { link in
            ChallengeJoinSheet(code: link.id, via: "universal_link") { detail in
                pushDetailId = detail.challenge.id
            }
            .environment(model)
        }
        .navigationDestination(isPresented: Binding(
            get: { pushDetailId != nil },
            set: { if !$0 { pushDetailId = nil } }
        )) {
            if let id = pushDetailId {
                ChallengeDetailScreen(id: id)
            }
        }
    }

    private func refresh() async {
        await model.refreshConfig()
        configAttempted = true
        if model.isAvailable {
            await model.refreshList()
        }
    }

    /// Once per push: popping back from a detail re-runs `.task`, and a
    /// create → detail → back round trip must not log two hub views.
    @State private var didFireViewed = false

    private func fireViewed() {
        guard !didFireViewed else { return }
        didFireViewed = true
        Analytics.capture("challenges_hub_viewed", [
            "source": .string(source),
            "live_count": .int(model.live.count),
            "upcoming_count": .int(model.upcoming.count),
            "history_count": .int(model.history.count),
            "first_visit": .bool(!model.hubSeen),
        ])
    }

    // MARK: - Content by state

    @ViewBuilder
    private var content: some View {
        switch model.verdict {
        case .disabled:
            notice(title: "Challenges aren't available right now",
                   body: "Tailspot has switched them off for a bit. Your challenges are safe; check back soon.")
        case .updateRequired:
            notice(title: "Update Tailspot to keep using Challenges",
                   body: "This version of the app is too old for the current challenge rules.")
            if let raw = model.config?.appStoreURL, let url = URL(string: raw) {
                Link(destination: url) {
                    primaryButtonLabel("Open the App Store")
                }
                .buttonStyle(.plain)
            }
        case .unknown:
            if configAttempted || model.hasLoadedList || model.config != nil {
                notice(title: "Challenges aren't available right now",
                       body: "Tailspot couldn't reach the server. Pull down to try again.")
            } else {
                loading
            }
        case .available:
            availableContent
        }
    }

    @ViewBuilder
    private var availableContent: some View {
        if !model.hasLoadedList {
            loading
        } else if let error = model.listError, model.open.isEmpty, model.history.isEmpty {
            notice(title: "Couldn't load your challenges", body: ChallengeCopy.message(for: error))
            Button { Task { await refresh() } } label: { primaryButtonLabel("Try again") }
                .buttonStyle(.plain)
        } else if model.open.isEmpty && model.history.isEmpty {
            emptyState
        } else {
            if let error = model.listError {
                Text(ChallengeCopy.message(for: error) + " Showing what you had.")
                    .font(Brand.Font.caption)
                    .foregroundStyle(Brand.Color.textTertiary)
                    .padding(.horizontal, 4)
            }
            if !model.live.isEmpty {
                ChallengeSectionLabel(title: "IN FLIGHT")
                rowsCard(model.live) { liveRow($0) }
            }
            if !model.upcoming.isEmpty {
                ChallengeSectionLabel(title: "ON DECK")
                rowsCard(model.upcoming) { upcomingRow($0) }
            }
            if !model.history.isEmpty {
                ChallengeSectionLabel(title: "FLIGHT LOG")
                rowsCard(model.history) { historyRow($0) }
            }
            joinFooter
        }
    }

    private var loading: some View {
        HStack {
            Spacer()
            ProgressView().tint(Brand.Color.cyan)
            Spacer()
        }
        .padding(.top, 60)
        .accessibilityLabel("Loading challenges")
    }

    private func notice(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Brand.Font.cardTitle)
                .foregroundStyle(Brand.Color.textPrimary)
            Text(body)
                .font(Brand.Font.body)
                .foregroundStyle(Brand.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Spot with friends")
                    .brandDisplayFont()
                    .foregroundStyle(Brand.Color.textPrimary)
                Text("Invite up to 10 friends for a head-to-head spotting challenge.")
                    .font(Brand.Font.body)
                    .foregroundStyle(Brand.Color.textSecondary)
            }
            VStack(spacing: 10) {
                Button { showCreate = true } label: { primaryButtonLabel("Create a challenge") }
                    .buttonStyle(.plain)
                Button { showJoin = true } label: { secondaryButtonLabel("Join with code") }
                    .buttonStyle(.plain)
            }
        }
        .padding(18)
        .glassEffect(ChallengeStyle.glass, in: .rect(cornerRadius: Brand.Radius.card))
    }

    private var joinFooter: some View {
        Button { showJoin = true } label: { secondaryButtonLabel("Join with code") }
            .buttonStyle(.plain)
            .padding(.top, 4)
    }

    private func primaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(Brand.Font.button)
            .foregroundStyle(Brand.Color.bgPrimary)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(Brand.Color.cyan, in: .rect(cornerRadius: Brand.Radius.row))
            .contentShape(Rectangle())
    }

    private func secondaryButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(Brand.Font.button)
            .foregroundStyle(Brand.Color.cyan)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 46)
            .background(Brand.Color.cyan.opacity(0.12), in: .rect(cornerRadius: Brand.Radius.row))
            .contentShape(Rectangle())
    }

    // MARK: - Live row

    /// One compact row per live challenge (Noah, 2026-09-27 — the big
    /// card with the place / points / catches trio was too much for a
    /// list): my placement disc, the name, and "1st · 10 pts · 22h left".
    /// The full trio lives on the detail.
    private func liveRow(_ s: ChallengeSummary) -> some View {
        let me = model.details[s.id]?.me ?? s.myResult
        let tie = model.details[s.id].map(ChallengeCopy.isTie) ?? false
        return NavigationLink {
            ChallengeDetailScreen(id: s.id)
        } label: {
            HStack(spacing: 12) {
                if let me {
                    PlacementDisc(placement: me.placement)
                } else {
                    ZStack {
                        Circle().fill(Brand.Color.cyan.opacity(0.13))
                        Image(systemName: "airplane")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.Color.cyan)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(Brand.Font.body.weight(.semibold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    Text(Self.liveDetail(me: me, tie: tie, endsAt: s.endsAt, now: model.now()))
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // A live list row carries no `myResult` (that is the FROZEN result,
        // history only), so the placement needs the detail. Fetch it once
        // per row; until it lands the row shows the plane glyph.
        .task(id: s.id) {
            if model.details[s.id] == nil { await model.loadDetail(id: s.id) }
        }
    }

    /// "T-1st · 10 pts · 22h 19m left"; without a standing yet, just the
    /// time left.
    static func liveDetail(me: ChallengeMyResult?, tie: Bool, endsAt: Date, now: Date) -> String {
        var parts: [String] = []
        if let me {
            parts.append(ChallengeTiming.placementLabel(placement: me.placement, isTie: tie))
            parts.append("\(me.points.formatted(.number)) pts")
        }
        parts.append(ChallengeTiming.timeRemainingCopy(until: endsAt, now: now).lowercased())
        return parts.joined(separator: " · ")
    }

    // MARK: - Rows

    private func rowsCard<Content: View>(_ items: [ChallengeSummary],
                                         @ViewBuilder row: @escaping (ChallengeSummary) -> Content) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Brand.Color.bgPrimary.opacity(0.5))
                        .frame(height: 1)
                        .padding(.leading, 58)
                }
                row(item)
            }
        }
        .background(Brand.Color.bgElevated.opacity(0.75), in: .rect(cornerRadius: Brand.Radius.card))
    }

    private func upcomingRow(_ s: ChallengeSummary) -> some View {
        NavigationLink {
            ChallengeDetailScreen(id: s.id)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: Brand.Radius.chip)
                        .fill(Brand.Color.cyan.opacity(0.13))
                    Image(systemName: "clock")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.Color.cyan)
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(Brand.Font.cardTitle)
                        .foregroundStyle(Brand.Color.textPrimary)
                        .lineLimit(1)
                    Text("\(ChallengeCopy.startsLine(startsAt: s.startsAt, now: model.now())) · \(ChallengeCopy.spotters(s.participantCount))\(s.isCreator ? " · yours" : "")")
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func historyRow(_ s: ChallengeSummary) -> some View {
        let label = ChallengeCopy.historyLabel(s)
        let placement = s.myResult?.placement
        let dim = s.status == .cancelled || s.isNoContest
        return NavigationLink {
            ChallengeDetailScreen(id: s.id)
        } label: {
            HStack(spacing: 12) {
                if let placement, !dim {
                    PlacementDisc(placement: placement)
                } else {
                    ZStack {
                        Circle().fill(Brand.Color.textTertiary.opacity(0.12))
                        Image(systemName: s.status == .cancelled ? "xmark" : "minus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Brand.Color.textTertiary)
                    }
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(Brand.Font.body.weight(.semibold))
                        .foregroundStyle(dim ? Brand.Color.textSecondary : Brand.Color.textPrimary)
                        .lineLimit(1)
                    Text(historyDetail(s, label: label))
                        .font(Brand.Font.caption)
                        .foregroundStyle(Brand.Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Brand.Color.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func historyDetail(_ s: ChallengeSummary, label: String) -> String {
        var parts = [label]
        if let mine = s.myResult, s.status != .cancelled {
            parts.append("\(mine.points.formatted(.number)) pts")
        }
        parts.append(ChallengeCopy.shortDate(s.endsAt))
        return parts.joined(separator: " · ")
    }
}
