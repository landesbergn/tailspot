//
//  ChallengeInviteRouteTests.swift
//  TailspotTests
//
//  What a tapped `https://tailspot.app/c/CODE` link does, as a pure
//  function of (config verdict, pending code), plus the model state the
//  link handler and the hub hand back and forth. The presentation on top
//  of this — ChallengeInviteRouter, PrimarySheet.challenges, the hub's
//  auto-presented join sheet — is views; this is the decision.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("Challenge invite routing")
struct ChallengeInviteRouteTests {

    // MARK: - route(verdict:code:) — every verdict

    @Test func noCodeMeansNoRoute() {
        #expect(ChallengesModel.inviteRoute(verdict: .available, code: nil) == nil)
        #expect(ChallengesModel.inviteRoute(verdict: .disabled, code: nil) == nil)
        #expect(ChallengesModel.inviteRoute(verdict: .unknown, code: nil) == nil)
        #expect(ChallengesModel.inviteRoute(verdict: .updateRequired(minBuild: 99), code: nil) == nil)
    }

    @Test func availableJoins() {
        #expect(ChallengesModel.inviteRoute(verdict: .available, code: "K7M4QD2X")
                == .join(code: "K7M4QD2X"))
    }

    @Test func disabledIsUnavailable() {
        #expect(ChallengesModel.inviteRoute(verdict: .disabled, code: "K7M4QD2X")
                == .unavailable)
    }

    /// The minimum build travels with the route so the alert can log which
    /// build the server wanted, not just that it wanted a newer one.
    @Test func updateRequiredCarriesMinBuild() {
        #expect(ChallengesModel.inviteRoute(verdict: .updateRequired(minBuild: 120), code: "K7M4QD2X")
                == .updateRequired(minBuild: 120))
    }

    /// The cold-launch case: the link beat the config fetch. Holding is
    /// the whole point — showing "not available" here would be a lie the
    /// user would have to work out for themselves.
    @Test func unknownWaitsForConfig() {
        #expect(ChallengesModel.inviteRoute(verdict: .unknown, code: "K7M4QD2X")
                == .waitForConfig)
    }

    // MARK: - pendingInviteCode on the model

    @MainActor
    private func makeModel(enabled: Bool = true, minBuild: Int = 5,
                           currentBuild: Int = 100) -> ChallengesModel {
        var state = ChallengeFixtures.demoState()
        state.config = ChallengesConfig(enabled: enabled, availability: "public",
                                        minBuild: minBuild, appStoreURL: nil)
        return ChallengesModel(
            service: FixtureChallengesService(state: state),
            currentBuild: currentBuild,
            reminders: NoopChallengeReminderScheduler(),
            defaults: UserDefaults(suiteName: "ChallengeInviteRouteTests.\(UUID().uuidString)")!
        )
    }

    @Test @MainActor func startsWithNoPendingInvite() {
        let model = makeModel()
        #expect(model.pendingInviteCode == nil)
        #expect(model.inviteRoute == nil)
    }

    /// With the config already known, opening a link parks the code and
    /// resolves straight to `.join`.
    @Test @MainActor func openInviteParksTheCode() async {
        let model = makeModel()
        await model.refreshConfig()
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.pendingInviteCode == "K7M4QD2X")
        #expect(model.inviteRoute == .join(code: "K7M4QD2X"))
    }

    /// Cold launch: verdict `.unknown` at the moment the link lands, so
    /// `openInvite` fetches the config itself rather than leaving the code
    /// stuck at `.waitForConfig` until something else happens to refresh.
    @Test @MainActor func openInviteResolvesAnUnknownVerdict() async {
        let model = makeModel()
        #expect(model.verdict == .unknown)
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.verdict == .available)
        #expect(model.inviteRoute == .join(code: "K7M4QD2X"))
    }

    /// The kill switch survives the link: the code is still parked (the
    /// router clears it after telling the user), but the route says no.
    @Test @MainActor func openInviteWithKillSwitchOnIsUnavailable() async {
        let model = makeModel(enabled: false)
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.verdict == .disabled)
        #expect(model.inviteRoute == .unavailable)
    }

    @Test @MainActor func openInviteOnTooOldABuildAsksForAnUpdate() async {
        let model = makeModel(minBuild: 200, currentBuild: 100)
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.inviteRoute == .updateRequired(minBuild: 200))
    }

    /// The hub clears the code as soon as it has it, so a dismissed join
    /// sheet doesn't re-present on the next state change.
    @Test @MainActor func clearPendingInviteDropsTheCodeAndTheRoute() async {
        let model = makeModel()
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.inviteRoute != nil)
        model.clearPendingInvite()
        #expect(model.pendingInviteCode == nil)
        #expect(model.inviteRoute == nil)
    }

    /// A second link replaces the first — the newest tap is the one the
    /// user is waiting on.
    @Test @MainActor func aSecondInviteReplacesTheFirst() async {
        let model = makeModel()
        await model.refreshConfig()
        await model.openInvite(code: "K7M4QD2X")
        await model.openInvite(code: "P9RTVW34")
        #expect(model.pendingInviteCode == "P9RTVW34")
    }

    // MARK: - end to end from a URL

    /// The whole link path, minus the views: URL → code → route.
    @Test @MainActor func aTappedLinkRoutesToItsJoin() async throws {
        let model = makeModel()
        let url = URL(string: "https://www.tailspot.app/c/k7m4qd2x/")!
        let code = try #require(InviteCode.parse(url: url))
        await model.openInvite(code: code)
        #expect(model.inviteRoute == .join(code: "K7M4QD2X"))
    }
}
