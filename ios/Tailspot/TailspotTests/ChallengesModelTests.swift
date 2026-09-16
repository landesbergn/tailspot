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

    func sync(open: [ChallengeSummary]) { syncedOpen.append(open) }
    func cancel(challengeId: String) { cancelledIds.append(challengeId) }
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
}
