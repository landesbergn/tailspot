//
//  ChallengeScreensSnapshotTests.swift
//  TailspotTests
//
//  Visual-pass harness for every Challenges screen state (spec §6), in the
//  ProfileSettingsSnapshotTests pattern: host in a real UIWindow at
//  iPhone-16 points, drawHierarchy, write a PNG to /private/tmp/tailspot_snaps,
//  pass. Every screen runs against FixtureChallengesService with a fixed
//  clock, so countdowns and "today at" copy are stable between runs and no
//  test ever touches the network.
//

#if DEBUG
import Testing
import SwiftUI
import UIKit
@testable import Tailspot

@MainActor
@Suite("Challenge screens snapshots (visual pass)", .serialized)
struct ChallengeScreensSnapshotTests {

    private static let snapDir = URL(fileURLWithPath: "/private/tmp/tailspot_snaps", isDirectory: true)

    /// A Tuesday at 10:00 local — same anchor as the logic tests.
    static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 15; c.hour = 10; c.minute = 0
        return Calendar.current.date(from: c)!
    }()

    private func snapshot<V: View>(_ view: V, as name: String, settle: TimeInterval = 0.6) {
        try? FileManager.default.createDirectory(at: Self.snapDir, withIntermediateDirectories: true)
        let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: bounds)
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        let png = renderer.pngData { _ in
            host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? png.write(to: Self.snapDir.appendingPathComponent("\(name).png"))
        window.isHidden = true
    }

    private func makeModel(state: FixtureChallengesService.State? = nil,
                           currentBuild: Int = 100,
                           preloaded: Bool = true,
                           seenResults: [String] = []) async -> (ChallengesModel, FixtureChallengesService) {
        let service = FixtureChallengesService(state: state ?? ChallengeFixtures.demoState(now: Self.now))
        let defaults = UserDefaults(suiteName: "ChallengeScreensSnapshotTests-\(UUID().uuidString)")!
        defaults.set(seenResults, forKey: ChallengesModel.seenResultsKey)
        let model = ChallengesModel(service: service, currentBuild: currentBuild, now: { Self.now }, defaults: defaults)
        if preloaded {
            await model.refreshConfig()
            await model.refreshList()
        }
        return (model, service)
    }

    private func hub(_ model: ChallengesModel) -> some View {
        NavigationStack { ChallengesHub(source: "snapshot") }.environment(model)
    }

    private func detail(_ model: ChallengesModel, id: String, reduceMotion: Bool? = nil, expanded: Set<String> = []) -> some View {
        NavigationStack {
            ChallengeDetailScreen(id: id, _debugReduceMotion: reduceMotion, _debugExpanded: expanded)
        }
        .environment(model)
    }

    // MARK: Hub

    @Test func hubLoaded() async {
        let (model, _) = await makeModel()
        snapshot(hub(model), as: "challenges_hub")
        snapshot(hub(model).dynamicTypeSize(.accessibility2), as: "challenges_hub_a11y2")
    }

    @Test func hubEmpty() async {
        let (model, _) = await makeModel(state: ChallengeFixtures.emptyState())
        snapshot(hub(model), as: "challenges_hub_empty")
    }

    @Test func hubHistoryOnly() async {
        var s = ChallengeFixtures.demoState(now: Self.now)
        s.open = []
        let (model, _) = await makeModel(state: s)
        snapshot(hub(model), as: "challenges_hub_history_only")
    }

    @Test func hubLoading() async {
        let (model, _) = await makeModel(state: nil, preloaded: false)
        // Stall the list so the spinner is what renders.
        let stalling = StallingService()
        let slow = ChallengesModel(service: stalling, currentBuild: 100, now: { Self.now },
                                   defaults: UserDefaults(suiteName: "stall-\(UUID().uuidString)")!)
        _ = model
        snapshot(hub(slow), as: "challenges_hub_loading", settle: 0.4)
    }

    @Test func hubErrorAndOfflineCache() async {
        // Error, nothing cached.
        let (m1, s1) = await makeModel(preloaded: false)
        await m1.refreshConfig()
        s1.fail("list", with: .network("offline"))
        snapshot(hub(m1), as: "challenges_hub_error")
        // Offline with a cached list: preload, then make the next refresh fail.
        let (m2, s2) = await makeModel()
        s2.fail("list", with: .network("offline"))
        snapshot(hub(m2), as: "challenges_hub_offline_cache")
    }

    @Test func hubUnavailableAndUpdateRequired() async {
        var disabled = ChallengeFixtures.demoState(now: Self.now)
        disabled.config = ChallengesConfig(enabled: false, availability: "public", minBuild: 1, appStoreURL: nil)
        let (m1, _) = await makeModel(state: disabled)
        snapshot(hub(m1), as: "challenges_hub_unavailable")

        var old = ChallengeFixtures.demoState(now: Self.now)
        old.config = ChallengesConfig(enabled: true, availability: "public", minBuild: 999,
                                      appStoreURL: "https://apps.apple.com/app/id6773470079")
        let (m2, _) = await makeModel(state: old, currentBuild: 95)
        snapshot(hub(m2), as: "challenges_hub_update_required")
    }

    // MARK: Create sheet

    @Test func createSheetStates() async {
        let (model, _) = await makeModel()
        snapshot(ChallengeCreateSheet(onCreated: { _ in }, _debugNow: Self.now).environment(model),
                 as: "challenge_create_default")
        snapshot(ChallengeCreateSheet(onCreated: { _ in }, _debugName: "Hi", _debugNow: Self.now).environment(model),
                 as: "challenge_create_invalid_name")
        snapshot(ChallengeCreateSheet(onCreated: { _ in }, _debugStartMode: .scheduled, _debugNow: Self.now).environment(model),
                 as: "challenge_create_scheduled")
    }

    // MARK: Join sheet

    @Test func joinSheetStates() async {
        let (model, service) = await makeModel()
        let invites = service.withState { $0.invites }
        typealias P = ChallengeJoinSheet.Phase
        func sheet(_ phase: P, code: String? = nil) -> some View {
            ChallengeJoinSheet(code: code, via: "code_entry", onJoined: { _ in }, _debugPhase: phase).environment(model)
        }
        snapshot(sheet(.entry), as: "challenge_join_entry")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.joinable]!), code: ChallengeFixtures.Codes.joinable), as: "challenge_join_preview")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.needsHandle]!), code: ChallengeFixtures.Codes.needsHandle), as: "challenge_join_needs_handle")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.full]!)), as: "challenge_join_full")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.ended]!)), as: "challenge_join_ended")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.cancelled]!)), as: "challenge_join_cancelled")
        snapshot(sheet(P.from(preview: invites[ChallengeFixtures.Codes.alreadyIn]!)), as: "challenge_join_already_in")
        snapshot(sheet(.failed(.notFound)), as: "challenge_join_not_found")
        snapshot(sheet(.failed(.unavailable)), as: "challenge_join_unavailable")
    }

    // MARK: Detail

    @Test func detailUpcomingCreatorAndParticipant() async {
        let (model, _) = await makeModel()
        await model.loadDetail(id: "c-upcoming")
        snapshot(detail(model, id: "c-upcoming"), as: "challenge_detail_upcoming_creator")

        // The same challenge as a non-creator participant.
        var s = ChallengeFixtures.demoState(now: Self.now)
        let base = s.details["c-upcoming"]!
        let asGuest = ChallengeFixtures.summary(
            id: "c-upcoming-guest", name: base.challenge.name, creator: "eli", code: base.challenge.code,
            startsAt: base.challenge.startsAt, endsAt: base.challenge.endsAt, preset: base.challenge.durationPreset,
            status: .upcoming, participantCount: 3, isCreator: false)
        s.open.append(asGuest)
        s.details["c-upcoming-guest"] = ChallengeDetail(challenge: asGuest, standings: base.standings, me: base.me,
                                                        winners: [], alreadyIn: nil, newDevice: nil)
        let (m2, _) = await makeModel(state: s)
        await m2.loadDetail(id: "c-upcoming-guest")
        snapshot(detail(m2, id: "c-upcoming-guest"), as: "challenge_detail_upcoming_participant")
    }

    @Test func detailLive() async {
        let (model, _) = await makeModel()
        await model.loadDetail(id: "c-live")
        try? await model.loadLog(id: "c-live", handle: "noah")
        snapshot(detail(model, id: "c-live"), as: "challenge_detail_live")
        snapshot(detail(model, id: "c-live", expanded: ["noah"]), as: "challenge_detail_live_expanded")
        snapshot(detail(model, id: "c-live").dynamicTypeSize(.accessibility2), as: "challenge_detail_live_a11y2")
    }

    @Test func detailResults() async {
        // First view: nothing seen yet.
        let (first, _) = await makeModel()
        await first.loadDetail(id: "c-won")
        snapshot(detail(first, id: "c-won", reduceMotion: false), as: "challenge_detail_results_first", settle: 1.0)
        #expect(first.seenResultIds.contains("c-won"), "opening the results must mark them seen")

        // Reduce Motion: laurels are simply present.
        let (rm, _) = await makeModel()
        await rm.loadDetail(id: "c-won")
        snapshot(detail(rm, id: "c-won", reduceMotion: true), as: "challenge_detail_results_first_reduce_motion")

        // Quiet: already seen.
        let (quiet, _) = await makeModel(seenResults: ["c-won"])
        await quiet.loadDetail(id: "c-won")
        snapshot(detail(quiet, id: "c-won"), as: "challenge_detail_results_quiet")

        // Lost, with a shared crown up top.
        let (lost, _) = await makeModel(seenResults: ["c-lost"])
        await lost.loadDetail(id: "c-lost")
        snapshot(detail(lost, id: "c-lost"), as: "challenge_detail_results_lost")
    }

    @Test func detailNoContestAndCancelled() async {
        let (model, _) = await makeModel(seenResults: ["c-nocontest", "c-cancelled"])
        await model.loadDetail(id: "c-nocontest")
        snapshot(detail(model, id: "c-nocontest"), as: "challenge_detail_no_contest")
        await model.loadDetail(id: "c-cancelled")
        snapshot(detail(model, id: "c-cancelled"), as: "challenge_detail_cancelled")
    }

    @Test func shareSheet() async {
        let s = ChallengeFixtures.demoState(now: Self.now)
        snapshot(ChallengeShareSheet(challenge: s.open[1], now: { Self.now }), as: "challenge_share_sheet")
    }
}

/// A service whose reads never return — renders the loading state.
private final class StallingService: ChallengesService, @unchecked Sendable {
    func config() async throws -> ChallengesConfig {
        ChallengesConfig(enabled: true, availability: "public", minBuild: 1, appStoreURL: nil)
    }
    func list() async throws -> ChallengeList {
        try await Task.sleep(for: .seconds(30))
        return ChallengeList(open: [], history: [])
    }
    func detail(id: String) async throws -> ChallengeDetail { throw ChallengesError.notFound }
    func catchLog(id: String, handle: String) async throws -> ChallengeCatchLog { throw ChallengesError.notFound }
    func create(_ request: ChallengeCreateRequest) async throws -> ChallengeDetail { throw ChallengesError.unavailable }
    func invitePreview(code: String) async throws -> ChallengeInvitePreview { throw ChallengesError.notFound }
    func join(code: String) async throws -> ChallengeDetail { throw ChallengesError.notFound }
    func leave(id: String) async throws {}
    func cancel(id: String) async throws {}
}
#endif
