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
}

@MainActor
final class NoopChallengeReminderScheduler: ChallengeReminderScheduling {
    func sync(open: [ChallengeSummary]) {}
    func cancel(challengeId: String) {}
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

    // MARK: Lists

    func refreshList() async {
        isRefreshingList = true
        defer { isRefreshingList = false; hasLoadedList = true }
        do {
            let list = try await service.list()
            open = list.open
            history = list.history
            listError = nil
            reminders.sync(open: open)
        } catch {
            listError = Self.mapped(error, verdict: verdict)
        }
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
        let log = try await service.catchLog(id: id, handle: handle)
        logs["\(id)/\(handle.lowercased())"] = log
    }

    func log(id: String, handle: String) -> ChallengeCatchLog? {
        logs["\(id)/\(handle.lowercased())"]
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
            if let s = open.first(where: { $0.id == id }) {
                open.removeAll { $0.id == id }
                let cancelled = ChallengeFixtures.summary(from: s, status: .cancelled)
                history.insert(cancelled, at: 0)
            }
            details[id] = nil
            reminders.cancel(challengeId: id)
        } catch {
            throw Self.mapped(error, verdict: verdict)
        }
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
