//
//  ChallengesModel.swift
//  Tailspot
//
//  The one observable object every Challenges screen reads: config verdict,
//  the open / history lists, cached details and catch logs, and the
//  small bits of local state the spec calls for (hub seen, results seen).
//  It owns no UI and no networking — it calls a `ChallengesService` and
//  publishes results. Reminder scheduling is a hook (`ChallengeReminderScheduling`)
//  so the UNUserNotificationCenter code can live in its own file with its
//  own tests, and the model's tests can inject a recorder.
//
//  Explain-as-we-go: `@Observable` (Observation framework, iOS 17+) makes
//  every stored property of this class observable by SwiftUI views with no
//  `@Published` and no `objectWillChange`; a view that reads `model.open`
//  re-renders when `open` changes and not when `history` does. `@MainActor`
//  pins every mutation to the main thread, which is what SwiftUI requires
//  and what the app's default isolation already assumes. The same shape as
//  `UnitPreferences`.
//

import Foundation
import Observation

/// Hook for the local reminder scheduler (phase 2, spec §4.7). The model
/// calls `sync` with the open challenges after every refresh, create and
/// join, and `cancel` after leave / cancel. A no-op default keeps the model
/// usable in previews and tests.
@MainActor
protocol ChallengeReminderScheduling: AnyObject {
    func sync(open: [ChallengeSummary])
    func cancel(challengeId: String)
    /// Put the notification permission prompt up if it has never been shown
    /// and challenge reminders are switched on. Returns whether reminders
    /// can be delivered afterwards. The model calls this once, after the
    /// first create or join — see `requestReminderAuthorizationIfNeeded`.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool
}

@MainActor
final class NoopChallengeReminderScheduler: ChallengeReminderScheduling {
    func sync(open: [ChallengeSummary]) {}
    func cancel(challengeId: String) {}
    func requestAuthorizationIfNeeded() async -> Bool { false }
}

@Observable
@MainActor
final class ChallengesModel {

    // MARK: Dependencies

    let service: ChallengesService
    /// This build's CFBundleVersion, compared with the server's `minBuild`.
    /// DEBUG bin/deploy builds carry build 1 (CI bumps it), so the
    /// integration passes `Int.max` there — see ChallengeBuildGate.
    let currentBuild: Int
    let reminders: ChallengeReminderScheduling
    /// Injected clock so tests pin countdowns and status derivations.
    let now: () -> Date
    private let defaults: UserDefaults

    // MARK: Published state

    private(set) var config: ChallengesConfig?
    private(set) var verdict: ChallengeBuildGate.Verdict = .unknown

    private(set) var open: [ChallengeSummary] = []
    private(set) var history: [ChallengeSummary] = []
    /// True once `refreshList` has completed at least once (success or
    /// failure) — the hub shows a spinner before, content or error after.
    private(set) var hasLoadedList = false
    private(set) var listError: ChallengesError?
    private(set) var isRefreshingList = false

    private(set) var details: [String: ChallengeDetail] = [:]
    private(set) var detailErrors: [String: ChallengesError] = [:]
    /// Keyed "\(challengeId)/\(handle lowercased)".
    private(set) var logs: [String: ChallengeCatchLog] = [:]
    /// Per-log load failures, same key shape as `logs`. A row whose log
    /// failed must show a retry, not a spinner that never resolves.
    private(set) var logErrors: [String: ChallengesError] = [:]

    // MARK: Local flags (spec §3.4)

    static let hubSeenKey = "tailspot.challenges.hubSeen"
    static let seenResultsKey = "tailspot.challenges.seenResults"

    /// Whether the hub has ever been opened — drives the discovery dot on
    /// the Leaders toolbar flag.
    private(set) var hubSeen: Bool
    /// Finished challenge ids whose results screen has been viewed.
    private(set) var seenResultIds: Set<String>

    // MARK: Init

    /// `reminders` is optional rather than defaulted to `NoopChallengeReminderScheduler()`:
    /// default arguments evaluate in a nonisolated context, and that
    /// initializer is MainActor-isolated, so the default lives in the body.
    init(service: ChallengesService,
         currentBuild: Int = ChallengeBuildGate.currentBuild(),
         reminders: ChallengeReminderScheduling? = nil,
         now: @escaping () -> Date = Date.init,
         defaults: UserDefaults = .standard) {
        self.service = service
        self.currentBuild = currentBuild
        self.reminders = reminders ?? NoopChallengeReminderScheduler()
        self.now = now
        self.defaults = defaults
        self.hubSeen = defaults.bool(forKey: Self.hubSeenKey)
        self.seenResultIds = Set(defaults.stringArray(forKey: Self.seenResultsKey) ?? [])
    }

    // MARK: Derived

    var isAvailable: Bool { verdict == .available }

    var live: [ChallengeSummary] {
        open.filter { ChallengeTiming.status(startsAt: $0.startsAt, endsAt: $0.endsAt, cancelledAt: nil, now: now()) == .live }
    }

    var upcoming: [ChallengeSummary] {
        open.filter { ChallengeTiming.status(startsAt: $0.startsAt, endsAt: $0.endsAt, cancelledAt: nil, now: now()) == .upcoming }
    }

    /// Finished, decided or no-contest, whose results the user hasn't seen.
    var unseenResults: [ChallengeSummary] {
        history.filter { $0.status == .finished && !seenResultIds.contains($0.id) }
    }

    /// The one line the Profile tile and the Leaders strip show (spec §3.4):
    /// a live challenge wins, then an unseen result, then an upcoming one.
    enum Headline: Equatable {
        case live(ChallengeSummary)
        case resultsReady(ChallengeSummary)
        case upcoming(ChallengeSummary)
        case none
    }

    var headline: Headline {
        if let l = live.first { return .live(l) }
        if let r = unseenResults.first { return .resultsReady(r) }
        if let u = upcoming.first { return .upcoming(u) }
        return .none
    }

    // MARK: Config

    /// Fetch the config and recompute the verdict. Failure keeps the last
    /// verdict (a stale "available" beats hiding the feature on a blip);
    /// with no prior config the verdict stays `.unknown` and screens fail soft.
    func refreshConfig() async {
        do {
            let c = try await service.config()
            config = c
            verdict = ChallengeBuildGate.verdict(config: c, currentBuild: currentBuild)
        } catch {
            if config == nil { verdict = .unknown }
        }
    }

    // MARK: Invite links (spec §11, universal links)

    /// A code that arrived from `https://tailspot.app/c/CODE` and hasn't
    /// been handed to a screen yet. The hub reads it, opens the join
    /// sheet with it and clears it; nothing else consumes it. Kept on the
    /// model rather than in a view because the link can land while no
    /// Challenges screen exists — and because the verdict that decides
    /// what to do with it lives here too.
    private(set) var pendingInviteCode: String?

    /// What a pending code should do, given what we know about the
    /// feature. Pure — see `inviteRoute(verdict:code:)`.
    nonisolated enum InviteRoute: Equatable {
        /// Open the join sheet for this code.
        case join(code: String)
        /// This build is too old for the current challenge rules.
        case updateRequired(minBuild: Int)
        /// Kill switch is on — say so, don't open anything.
        case unavailable
        /// Config not fetched yet; hold the code until it is.
        case waitForConfig
    }

    /// The whole routing decision, as one pure function of (verdict, code)
    /// so it can be tested without a view, a network or a clock. `nil`
    /// means "no invite in flight" — every other state is a route.
    nonisolated static func inviteRoute(verdict: ChallengeBuildGate.Verdict,
                                        code: String?) -> InviteRoute? {
        guard let code else { return nil }
        switch verdict {
        case .available:                   return .join(code: code)
        case .updateRequired(let minBuild): return .updateRequired(minBuild: minBuild)
        case .disabled:                    return .unavailable
        case .unknown:                     return .waitForConfig
        }
    }

    /// The route for the code currently in hand.
    var inviteRoute: InviteRoute? {
        Self.inviteRoute(verdict: verdict, code: pendingInviteCode)
    }

    /// A universal link landed. Park the code, and if we don't yet know
    /// whether Challenges is usable, go find out — otherwise a link opened
    /// on a cold launch would sit at `.waitForConfig` until the scene-phase
    /// refresh happened to finish.
    func openInvite(code: String) async {
        pendingInviteCode = code
        if verdict == .unknown {
            await refreshConfig()
        }
    }

    /// Drop the pending code because we've told the user why it can't be
    /// opened (too-old build, kill switch). The happy path goes through
    /// `consumePendingInvite(for:)` instead.
    func clearPendingInvite() {
        pendingInviteCode = nil
    }

    /// The ONE hub source allowed to take a pending invite code: the hub
    /// the link itself opened. It's also the spec's §12 source vocabulary
    /// value for a link (leaders_flag, leaders_strip, profile_tile,
    /// reveal_line, deep_link).
    nonisolated static let inviteSource = "deep_link"

    /// Which hub, if any, may take this code. Pure, so the rule is one
    /// line and one test rather than a condition repeated per screen.
    nonisolated static func consumableInviteCode(source: String,
                                                 route: InviteRoute?) -> String? {
        guard source == inviteSource, case .join(let code) = route else { return nil }
        return code
    }

    /// Take the pending code, but only for the hub the link opened.
    ///
    /// Why the guard: a hub can already be on screen under the Profile or
    /// Leaders sheet when a link lands. Without this, that hub and the
    /// link's own hub both watch the same route, and the losing one
    /// consumes the code during its sheet's teardown — the new hub then
    /// opens with nothing. One owner, named explicitly.
    func consumePendingInvite(for source: String) -> String? {
        guard let code = Self.consumableInviteCode(source: source, route: inviteRoute) else {
            return nil
        }
        pendingInviteCode = nil
        return code
    }

    // MARK: Lists

    /// Bumped on every `refreshList` call; only the call holding the latest
    /// value is allowed to write the list state.
    ///
    /// Explain-as-we-go — a *generation counter* is the standard fix for
    /// overlapping async work writing the same state. The hub's `.task`, its
    /// pull-to-refresh and the scene-phase handler in `TailspotApp` can all
    /// be in flight at once; whichever response arrives LAST would otherwise
    /// win, so a slow, stale (or failed) one could overwrite a fresh list, or
    /// clear the spinner for a refresh still running. Each call takes a
    /// ticket, and on return checks whether a newer call took one since — if
    /// so it drops its result on the floor and touches nothing.
    private var listGeneration = 0

    func refreshList() async {
        listGeneration &+= 1
        let generation = listGeneration
        isRefreshingList = true
        defer {
            if generation == listGeneration {
                isRefreshingList = false
                hasLoadedList = true
            }
        }
        do {
            let list = try await service.list()
            guard generation == listGeneration else { return }
            open = list.open
            history = list.history
            listError = nil
            reminders.sync(open: open)
        } catch {
            guard generation == listGeneration else { return }
            listError = Self.mapped(error, verdict: verdict)
        }
    }

    /// Re-plan the local reminders from the list already in memory — used by
    /// the Settings toggle, which changes whether they may be scheduled at
    /// all but has no reason to hit the network.
    func resyncReminders() {
        reminders.sync(open: open)
    }

    // MARK: Detail + log

    func loadDetail(id: String) async {
        do {
            let d = try await service.detail(id: id)
            details[id] = d
            detailErrors[id] = nil
            absorb(d.challenge)
        } catch {
            detailErrors[id] = Self.mapped(error, verdict: verdict)
        }
    }

    func loadLog(id: String, handle: String) async throws {
        let key = Self.logKey(id: id, handle: handle)
        logErrors[key] = nil
        do {
            let log = try await service.catchLog(id: id, handle: handle)
            logs[key] = log
        } catch {
            let mapped = Self.mapped(error, verdict: verdict)
            logErrors[key] = mapped
            throw mapped
        }
    }

    func log(id: String, handle: String) -> ChallengeCatchLog? {
        logs[Self.logKey(id: id, handle: handle)]
    }

    /// The load error for one spotter's log, if the last attempt failed.
    func logError(id: String, handle: String) -> ChallengesError? {
        logErrors[Self.logKey(id: id, handle: handle)]
    }

    static func logKey(id: String, handle: String) -> String {
        "\(id)/\(handle.lowercased())"
    }

    // MARK: Mutations

    @discardableResult
    func create(_ request: ChallengeCreateRequest) async throws -> ChallengeDetail {
        do {
            let d = try await service.create(request)
            details[d.challenge.id] = d
            open.removeAll { $0.id == d.challenge.id }
            open.insert(d.challenge, at: 0)
            reminders.sync(open: open)
            await requestReminderAuthorizationIfNeeded()
            return d
        } catch {
            throw Self.mapped(error, verdict: verdict)
        }
    }

    func invitePreview(code: String) async throws -> ChallengeInvitePreview {
        do { return try await service.invitePreview(code: code) }
        catch { throw Self.mapped(error, verdict: verdict) }
    }

    @discardableResult
    func join(code: String) async throws -> ChallengeDetail {
        do {
            let d = try await service.join(code: code)
            details[d.challenge.id] = d
            open.removeAll { $0.id == d.challenge.id }
            open.insert(d.challenge, at: 0)
            reminders.sync(open: open)
            await requestReminderAuthorizationIfNeeded()
            return d
        } catch {
            throw Self.mapped(error, verdict: verdict)
        }
    }

    func leave(id: String) async throws {
        do {
            try await service.leave(id: id)
            open.removeAll { $0.id == id }
            details[id] = nil
            reminders.cancel(challengeId: id)
        } catch {
            throw Self.mapped(error, verdict: verdict)
        }
    }

    func cancel(id: String) async throws {
        do {
            try await service.cancel(id: id)
            let known = open.first(where: { $0.id == id })
            if let s = known {
                open.removeAll { $0.id == id }
                let cancelled = s.with(status: .cancelled)
                history.insert(cancelled, at: 0)
            }
            details[id] = nil
            reminders.cancel(challengeId: id)
            // Cancelled from a screen reached by a link or push, with the
            // list never loaded (or already stale): there is no local row to
            // move into history, so the row would simply vanish. Re-read the
            // list instead of leaving the hub lying.
            if known == nil {
                await refreshList()
            }
        } catch {
            throw Self.mapped(error, verdict: verdict)
        }
    }

    // MARK: Reminder permission

    /// UserDefaults latch for "we have asked once after a create/join".
    static let remindersAskedKey = "tailspot.challenges.remindersAsked"

    /// The contextual permission ask (spec D17 rides the streak prompt, but
    /// a user who never saw that prompt got NO challenge reminders at all).
    /// Runs once per install, right after the first successful create or
    /// join — the one moment where "tell me when it starts" is obviously
    /// what the user wants. The scheduler itself no-ops unless the toggle is
    /// on and iOS has never shown the prompt, so this can't nag.
    func requestReminderAuthorizationIfNeeded() async {
        guard !defaults.bool(forKey: Self.remindersAskedKey) else { return }
        defaults.set(true, forKey: Self.remindersAskedKey)
        await reminders.requestAuthorizationIfNeeded()
        // Re-plan: everything that was skipped for want of authorization is
        // schedulable now.
        reminders.sync(open: open)
    }

    // MARK: Local flags

    func markHubSeen() {
        guard !hubSeen else { return }
        hubSeen = true
        defaults.set(true, forKey: Self.hubSeenKey)
    }

    func markResultsSeen(id: String) {
        guard !seenResultIds.contains(id) else { return }
        seenResultIds.insert(id)
        defaults.set(Array(seenResultIds).sorted(), forKey: Self.seenResultsKey)
    }

    // MARK: Helpers

    /// Keep the list rows in step with a fresher detail (status flips,
    /// participant count) without a full list refresh.
    private func absorb(_ summary: ChallengeSummary) {
        if let i = open.firstIndex(where: { $0.id == summary.id }) {
            if summary.status == .finished || summary.status == .cancelled {
                open.remove(at: i)
                history.removeAll { $0.id == summary.id }
                history.insert(summary, at: 0)
            } else {
                open[i] = summary
            }
        } else if let i = history.firstIndex(where: { $0.id == summary.id }) {
            history[i] = summary
        }
    }

    /// Wrap non-`ChallengesError`s (URLError etc.) and turn a 404 into
    /// `.unavailable` when the config says the feature is off.
    static func mapped(_ error: Error, verdict: ChallengeBuildGate.Verdict) -> ChallengesError {
        if let e = error as? ChallengesError {
            if e == .notFound, verdict == .disabled { return .unavailable }
            return e
        }
        if (error as? URLError) != nil { return .network(error.localizedDescription) }
        return .network(error.localizedDescription)
    }
}
