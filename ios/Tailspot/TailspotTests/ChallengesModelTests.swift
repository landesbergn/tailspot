//
//  ChallengesModelTests.swift
//  TailspotTests
//
//  `ChallengesModel` against `FixtureChallengesService`: config verdicts
//  (including the fail-soft rules), list refresh + reminder sync, the
//  mutation flows (create/join/leave/cancel), the finished-challenge
//  absorb from open into history, headline priority, and the two local
//  UserDefaults flags round-tripping through a real `UserDefaults` suite.
//

import Foundation
import Testing
@testable import Tailspot

/// Records every call the model makes to the reminder hook, in order.
@MainActor
final class RecordingReminderScheduler: ChallengeReminderScheduling {
    private(set) var syncedOpen: [[ChallengeSummary]] = []
    private(set) var cancelledIds: [String] = []
    private(set) var authorizationRequests = 0
    /// What `requestAuthorizationIfNeeded` answers.
    var grantsAuthorization = true

    func sync(open: [ChallengeSummary]) { syncedOpen.append(open) }
    func cancel(challengeId: String) { cancelledIds.append(challengeId) }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        authorizationRequests += 1
        return grantsAuthorization
    }
}

@Suite("Challenges model")
@MainActor
struct ChallengesModelTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ChallengesModelTests.\(UUID().uuidString)")!
    }

    /// `reminders` is optional rather than defaulted to `RecordingReminderScheduler()`:
    /// default argument expressions evaluate in a nonisolated context even
    /// inside a `@MainActor` type (the same reason `ChallengesModel.init`
    /// itself takes an optional `reminders` rather than defaulting it).
    private func makeModel(
        service: ChallengesService,
        currentBuild: Int = 100,
        reminders: ChallengeReminderScheduling? = nil,
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults? = nil
    ) -> ChallengesModel {
        ChallengesModel(
            service: service, currentBuild: currentBuild,
            reminders: reminders ?? RecordingReminderScheduler(),
            now: now, defaults: defaults ?? freshDefaults()
        )
    }

    // MARK: - refreshConfig

    @Test func refreshConfigSetsAvailableVerdict() async {
        var state = ChallengeFixtures.demoState()
        state.config = ChallengesConfig(enabled: true, availability: "public", minBuild: 5, appStoreURL: nil)
        let model = makeModel(service: FixtureChallengesService(state: state), currentBuild: 10)
        await model.refreshConfig()
        #expect(model.verdict == .available)
        #expect(model.isAvailable)
    }

    @Test func refreshConfigSetsDisabledVerdict() async {
        var state = ChallengeFixtures.demoState()
        state.config = ChallengesConfig(enabled: false, availability: "public", minBuild: 5, appStoreURL: nil)
        let model = makeModel(service: FixtureChallengesService(state: state), currentBuild: 10)
        await model.refreshConfig()
        #expect(model.verdict == .disabled)
        #expect(!model.isAvailable)
    }

    @Test func refreshConfigSetsUpdateRequiredVerdict() async {
        var state = ChallengeFixtures.demoState()
        state.config = ChallengesConfig(enabled: true, availability: "public", minBuild: 50, appStoreURL: nil)
        let model = makeModel(service: FixtureChallengesService(state: state), currentBuild: 10)
        await model.refreshConfig()
        #expect(model.verdict == .updateRequired(minBuild: 50))
    }

    @Test func refreshConfigFailureWithNoPriorConfigIsUnknown() async {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        fixture.fail("config", with: .network("boom"))
        let model = makeModel(service: fixture)
        await model.refreshConfig()
        #expect(model.verdict == .unknown)
        #expect(model.config == nil)
    }

    @Test func refreshConfigFailureWithPriorConfigKeepsLastVerdict() async {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, currentBuild: 10)
        await model.refreshConfig()
        #expect(model.verdict == .available)
        fixture.fail("config", with: .network("boom"))
        await model.refreshConfig()
        #expect(model.verdict == .available)
    }

    // MARK: - refreshList

    @Test func refreshListPopulatesAndSyncsReminders() async {
        let reminders = RecordingReminderScheduler()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, reminders: reminders)
        #expect(!model.hasLoadedList)
        await model.refreshList()
        #expect(model.hasLoadedList)
        #expect(!model.open.isEmpty)
        #expect(!model.history.isEmpty)
        #expect(model.listError == nil)
        #expect(reminders.syncedOpen.count == 1)
        #expect(reminders.syncedOpen.first?.count == model.open.count)
    }

    @Test func listErrorMapsNotFoundToUnavailableWhenDisabled() async {
        var state = ChallengeFixtures.demoState()
        state.config = ChallengesConfig(enabled: false, availability: "public", minBuild: 1, appStoreURL: nil)
        let fixture = FixtureChallengesService(state: state)
        let model = makeModel(service: fixture)
        await model.refreshConfig()
        #expect(model.verdict == .disabled)
        fixture.fail("list", with: .notFound)
        await model.refreshList()
        #expect(model.listError == ChallengesError.unavailable)
    }

    // MARK: - join / leave / cancel

    @Test func joinInsertsIntoOpenAndSyncsReminders() async throws {
        let reminders = RecordingReminderScheduler()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, reminders: reminders)
        let detail = try await model.join(code: ChallengeFixtures.Codes.joinable)
        #expect(model.open.contains { $0.id == detail.challenge.id })
        #expect(reminders.syncedOpen.count == 1)
    }

    @Test func leaveRemovesAndCancelsReminders() async throws {
        let reminders = RecordingReminderScheduler()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, reminders: reminders)
        await model.refreshList()
        let id = try #require(model.open.first?.id)
        try await model.leave(id: id)
        #expect(!model.open.contains { $0.id == id })
        #expect(model.details[id] == nil)
        #expect(reminders.cancelledIds == [id])
    }

    @Test func cancelMovesToHistoryAsCancelled() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        await model.refreshList()
        // "c-upcoming" is the one I created, before start — cancellable
        // (fixture rule: creator + still upcoming).
        try await model.cancel(id: "c-upcoming")
        #expect(!model.open.contains { $0.id == "c-upcoming" })
        let cancelled = try #require(model.history.first { $0.id == "c-upcoming" })
        #expect(cancelled.status == .cancelled)
    }

    // MARK: - loadDetail absorb

    @Test func loadDetailAbsorbsFinishedChallengeFromOpenToHistory() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ChallengeFixtures.emptyState()
        // The list believes this challenge is still live...
        state.open = [ChallengeFixtures.summary(
            id: "c-flip", name: "Just Ended", creator: "noah", code: nil,
            startsAt: now.addingTimeInterval(-3600), endsAt: now.addingTimeInterval(-1),
            preset: "1h", status: .live, participantCount: 2, isCreator: true)]
        // ...but its detail response is fresher and has already flipped.
        let finishedSummary = ChallengeFixtures.summary(
            id: "c-flip", name: "Just Ended", creator: "noah", code: nil,
            startsAt: now.addingTimeInterval(-3600), endsAt: now.addingTimeInterval(-1),
            preset: "1h", status: .finished, participantCount: 2, isCreator: true, outcome: "decided")
        state.details["c-flip"] = ChallengeDetail(
            challenge: finishedSummary, standings: [], me: nil, winners: [], alreadyIn: nil, newDevice: nil)
        let fixture = FixtureChallengesService(state: state)
        let model = makeModel(service: fixture, now: { now })
        await model.refreshList()
        #expect(model.open.contains { $0.id == "c-flip" })
        await model.loadDetail(id: "c-flip")
        #expect(!model.open.contains { $0.id == "c-flip" })
        #expect(model.history.contains { $0.id == "c-flip" && $0.status == .finished })
    }

    // MARK: - headline priority

    private func summaryForHeadline(
        id: String, creator: String, startsAt: Date, endsAt: Date,
        status: ChallengeStatus, outcome: String? = nil, isCreator: Bool = false
    ) -> ChallengeSummary {
        ChallengeFixtures.summary(
            id: id, name: id, creator: creator, code: nil,
            startsAt: startsAt, endsAt: endsAt, preset: "1h", status: status,
            participantCount: 2, isCreator: isCreator, outcome: outcome)
    }

    @Test func headlinePrefersLiveOverResultsAndUpcoming() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ChallengeFixtures.emptyState()
        state.open = [
            summaryForHeadline(id: "c-live", creator: "maya",
                                startsAt: now.addingTimeInterval(-100), endsAt: now.addingTimeInterval(100),
                                status: .live),
            summaryForHeadline(id: "c-up", creator: "noah",
                                startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(7200),
                                status: .upcoming, isCreator: true),
        ]
        state.history = [
            summaryForHeadline(id: "c-fin", creator: "eli",
                                startsAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-3600),
                                status: .finished, outcome: "decided"),
        ]
        let model = makeModel(service: FixtureChallengesService(state: state), now: { now })
        await model.refreshList()
        guard case .live(let s) = model.headline else {
            Issue.record("expected .live headline, got \(model.headline)")
            return
        }
        #expect(s.id == "c-live")
    }

    @Test func headlinePrefersUnseenResultsOverUpcomingWhenNothingLive() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ChallengeFixtures.emptyState()
        state.open = [
            summaryForHeadline(id: "c-up", creator: "noah",
                                startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(7200),
                                status: .upcoming, isCreator: true),
        ]
        state.history = [
            summaryForHeadline(id: "c-fin", creator: "eli",
                                startsAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-3600),
                                status: .finished, outcome: "decided"),
        ]
        let model = makeModel(service: FixtureChallengesService(state: state), now: { now })
        await model.refreshList()
        guard case .resultsReady(let s) = model.headline else {
            Issue.record("expected .resultsReady headline, got \(model.headline)")
            return
        }
        #expect(s.id == "c-fin")
    }

    @Test func headlineFallsBackToUpcomingWhenNoLiveOrUnseenResults() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ChallengeFixtures.emptyState()
        state.open = [
            summaryForHeadline(id: "c-up", creator: "noah",
                                startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(7200),
                                status: .upcoming, isCreator: true),
        ]
        let model = makeModel(service: FixtureChallengesService(state: state), now: { now })
        await model.refreshList()
        guard case .upcoming(let s) = model.headline else {
            Issue.record("expected .upcoming headline, got \(model.headline)")
            return
        }
        #expect(s.id == "c-up")
    }

    @Test func headlineIsNoneWhenEverythingIsEmptyOrSeen() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = ChallengeFixtures.emptyState()
        state.history = [
            summaryForHeadline(id: "c-fin", creator: "eli",
                                startsAt: now.addingTimeInterval(-7200), endsAt: now.addingTimeInterval(-3600),
                                status: .finished, outcome: "decided"),
        ]
        let defaults = freshDefaults()
        let model = makeModel(service: FixtureChallengesService(state: state), now: { now }, defaults: defaults)
        await model.refreshList()
        model.markResultsSeen(id: "c-fin")
        #expect(model.headline == .none)
    }

    // MARK: - local flags

    @Test func markHubSeenPersistsAndReloadsFromDefaults() {
        let defaults = freshDefaults()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, defaults: defaults)
        #expect(!model.hubSeen)
        model.markHubSeen()
        #expect(model.hubSeen)
        let reloaded = makeModel(service: fixture, defaults: defaults)
        #expect(reloaded.hubSeen)
    }

    @Test func markResultsSeenPersistsAndReloadsFromDefaults() {
        let defaults = freshDefaults()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, defaults: defaults)
        #expect(!model.seenResultIds.contains("c-won"))
        model.markResultsSeen(id: "c-won")
        #expect(model.seenResultIds.contains("c-won"))
        let reloaded = makeModel(service: fixture, defaults: defaults)
        #expect(reloaded.seenResultIds.contains("c-won"))
    }

    // MARK: - create

    @Test func createInsertsAtTopOfOpen() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        await model.refreshList()
        let before = model.open.count
        let detail = try await model.create(.startingNow(name: "New Race", duration: "1h"))
        #expect(model.open.first?.id == detail.challenge.id)
        #expect(model.open.count == before + 1)
    }

    // MARK: - catch-log errors (a failed log must not spin for ever)

    @Test func loadLogRecordsPerKeyErrorAndClearsItOnRetry() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        fixture.fail("catchLog", with: .network("offline"))
        await #expect(throws: ChallengesError.network("offline")) {
            try await model.loadLog(id: "c-live", handle: "maya")
        }
        #expect(model.logError(id: "c-live", handle: "maya") == .network("offline"))
        #expect(model.log(id: "c-live", handle: "maya") == nil)

        // Retry succeeds: the error clears and the log lands.
        try await model.loadLog(id: "c-live", handle: "maya")
        #expect(model.logError(id: "c-live", handle: "maya") == nil)
        #expect(model.log(id: "c-live", handle: "maya") != nil)
    }

    @Test func logErrorIsPerSpotterNotPerChallenge() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        fixture.fail("catchLog", with: .rateLimited)
        try? await model.loadLog(id: "c-live", handle: "maya")
        try await model.loadLog(id: "c-live", handle: "eli")
        #expect(model.logError(id: "c-live", handle: "maya") == .rateLimited)
        #expect(model.logError(id: "c-live", handle: "eli") == nil)
    }

    // MARK: - refreshList generation guard

    /// Two refreshes in flight; the FIRST one answers LAST. Without the
    /// generation counter its stale list would overwrite the fresh one.
    @Test func staleRefreshDoesNotOverwriteANewerOne() async {
        let service = GatedListService()
        service.result(forCall: 1, .success(ChallengeList(open: [Self.row(id: "stale", name: "Stale")], history: [])))
        service.result(forCall: 2, .success(ChallengeList(open: [Self.row(id: "fresh", name: "Fresh")], history: [])))
        let model = makeModel(service: service)

        let first = Task { await model.refreshList() }
        await service.waitForCalls(1)
        let second = Task { await model.refreshList() }
        await service.waitForCalls(2)

        service.release(2)          // the newer call answers first,
        service.release(1)          // the older one straggles in after it.
        await first.value
        await second.value

        #expect(model.open.map(\.id) == ["fresh"])
        #expect(model.listError == nil)
        #expect(!model.isRefreshingList)
        #expect(model.hasLoadedList)
    }

    /// Same race, but the straggler FAILED: its error must not land either.
    @Test func staleRefreshFailureDoesNotClobberAFreshList() async {
        let service = GatedListService()
        service.result(forCall: 1, .failure(.network("stale")))
        service.result(forCall: 2, .success(ChallengeList(open: [Self.row(id: "fresh", name: "Fresh")], history: [])))
        let model = makeModel(service: service)

        let first = Task { await model.refreshList() }
        await service.waitForCalls(1)
        let second = Task { await model.refreshList() }
        await service.waitForCalls(2)
        service.release(2)
        service.release(1)
        await first.value
        await second.value

        #expect(model.listError == nil)
        #expect(model.open.map(\.id) == ["fresh"])
    }

    // MARK: - reminder permission + resync

    @Test func firstCreateAsksForNotificationPermissionExactlyOnce() async throws {
        let reminders = RecordingReminderScheduler()
        let model = makeModel(service: FixtureChallengesService(state: ChallengeFixtures.demoState()),
                              reminders: reminders)
        _ = try await model.create(.startingNow(name: "First Race", duration: "1h"))
        #expect(reminders.authorizationRequests == 1)
        // Second create: the ask is a one-shot, not a nag.
        _ = try await model.create(.startingNow(name: "Second Race", duration: "1h"))
        #expect(reminders.authorizationRequests == 1)
    }

    @Test func firstJoinAsksForNotificationPermission() async throws {
        let reminders = RecordingReminderScheduler()
        let model = makeModel(service: FixtureChallengesService(state: ChallengeFixtures.demoState()),
                              reminders: reminders)
        _ = try await model.join(code: ChallengeFixtures.Codes.joinable)
        #expect(reminders.authorizationRequests == 1)
    }

    /// The latch is stored, so a relaunch doesn't re-ask.
    @Test func permissionAskLatchSurvivesANewModel() async throws {
        let defaults = freshDefaults()
        let first = RecordingReminderScheduler()
        let m1 = makeModel(service: FixtureChallengesService(state: ChallengeFixtures.demoState()),
                           reminders: first, defaults: defaults)
        _ = try await m1.create(.startingNow(name: "Race", duration: "1h"))
        #expect(first.authorizationRequests == 1)

        let second = RecordingReminderScheduler()
        let m2 = makeModel(service: FixtureChallengesService(state: ChallengeFixtures.demoState()),
                           reminders: second, defaults: defaults)
        _ = try await m2.create(.startingNow(name: "Race again", duration: "1h"))
        #expect(second.authorizationRequests == 0)
    }

    @Test func resyncRemindersReplansTheOpenListWithoutANetworkCall() async {
        let reminders = RecordingReminderScheduler()
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture, reminders: reminders)
        await model.refreshList()
        let syncsAfterRefresh = reminders.syncedOpen.count
        let callsAfterRefresh = fixture.calls.count

        model.resyncReminders()
        #expect(reminders.syncedOpen.count == syncsAfterRefresh + 1)
        #expect(reminders.syncedOpen.last?.map(\.id) == model.open.map(\.id))
        #expect(fixture.calls.count == callsAfterRefresh)
    }

    // MARK: - cancel

    @Test func cancelOfARowTheListNeverSawRefreshesTheList() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        // Deep-linked straight into a detail: `open` is empty, so there is
        // no local row to move into history.
        #expect(model.open.isEmpty)
        try await model.cancel(id: "c-upcoming")
        #expect(fixture.calls.contains("list"))
        #expect(model.hasLoadedList)
    }

    @Test func cancelOfAKnownRowMovesItToHistoryWithoutRefetching() async throws {
        let fixture = FixtureChallengesService(state: ChallengeFixtures.demoState())
        let model = makeModel(service: fixture)
        await model.refreshList()
        let listCalls = fixture.calls.filter { $0 == "list" }.count
        try await model.cancel(id: "c-upcoming")
        #expect(!model.open.contains { $0.id == "c-upcoming" })
        #expect(model.history.first?.id == "c-upcoming")
        #expect(fixture.calls.filter { $0 == "list" }.count == listCalls)
    }

    // MARK: - helpers

    private static func row(id: String, name: String) -> ChallengeSummary {
        ChallengeFixtures.summary(
            id: id, name: name, creator: "maya", code: nil,
            startsAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_086_400),
            preset: "24h", status: .live, participantCount: 2)
    }
}

/// A `list()` that only answers when the test says so, one gate per call,
/// so an overlapping-refresh race can be replayed deterministically.
private final class GatedListService: ChallengesService, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var results: [Int: Result<ChallengeList, ChallengesError>] = [:]

    var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }

    func result(forCall index: Int, _ result: Result<ChallengeList, ChallengesError>) {
        lock.lock(); results[index] = result; lock.unlock()
    }

    /// Let call number `index` return.
    func release(_ index: Int) {
        lock.lock()
        if let gate = gates.removeValue(forKey: index) {
            lock.unlock()
            gate.resume()
        } else {
            released.insert(index)
            lock.unlock()
        }
    }

    /// Spin the cooperative pool until `count` calls have arrived at the gate.
    func waitForCalls(_ count: Int) async {
        for _ in 0..<10_000 {
            if calls >= count { return }
            await Task.yield()
        }
    }

    func list() async throws -> ChallengeList {
        lock.lock()
        callCount += 1
        let index = callCount
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released.remove(index) != nil {
                lock.unlock()
                continuation.resume()
            } else {
                gates[index] = continuation
                lock.unlock()
            }
        }
        lock.lock()
        let result = results[index] ?? .success(ChallengeList(open: [], history: []))
        lock.unlock()
        return try result.get()
    }

    func config() async throws -> ChallengesConfig {
        ChallengesConfig(enabled: true, availability: "public", minBuild: 1, appStoreURL: nil)
    }
    func detail(id: String) async throws -> ChallengeDetail { throw ChallengesError.notFound }
    func catchLog(id: String, handle: String) async throws -> ChallengeCatchLog { throw ChallengesError.notFound }
    func create(_ request: ChallengeCreateRequest) async throws -> ChallengeDetail { throw ChallengesError.unavailable }
    func invitePreview(code: String) async throws -> ChallengeInvitePreview { throw ChallengesError.notFound }
    func join(code: String) async throws -> ChallengeDetail { throw ChallengesError.notFound }
    func leave(id: String) async throws {}
    func cancel(id: String) async throws {}
}
