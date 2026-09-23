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

    // MARK: - who may consume the code

    /// The whole point of the guard: a hub that was already on screen
    /// under Profile or Leaders must not take the code, or it swallows it
    /// during its own sheet's teardown and the link's hub opens empty.
    @Test @MainActor func onlyTheLinksOwnHubConsumesTheCode() async {
        for source in ["profile_tile", "leaders_flag", "leaders_strip", "reveal_line"] {
            let model = makeModel()
            await model.refreshConfig()
            await model.openInvite(code: "K7M4QD2X")
            #expect(model.consumePendingInvite(for: source) == nil)
            #expect(model.pendingInviteCode == "K7M4QD2X", "\(source) cleared the code")
        }
    }

    @Test @MainActor func theDeepLinkHubConsumesTheCodeOnce() async {
        let model = makeModel()
        await model.refreshConfig()
        await model.openInvite(code: "K7M4QD2X")
        #expect(model.consumePendingInvite(for: ChallengesModel.inviteSource) == "K7M4QD2X")
        #expect(model.pendingInviteCode == nil)
        // Second hub (or a re-run of the same task) gets nothing.
        #expect(model.consumePendingInvite(for: ChallengesModel.inviteSource) == nil)
    }

    /// `deep_link` is the spec §12 source vocabulary value, not a new word.
    @Test func inviteSourceIsTheSpecVocabularyValue() {
        #expect(ChallengesModel.inviteSource == "deep_link")
    }

    /// Only a `.join` route is consumable — a blocked route's code belongs
    /// to the router, which explains it and then drops it.
    @Test func blockedRoutesAreNotConsumable() {
        let src = ChallengesModel.inviteSource
        #expect(ChallengesModel.consumableInviteCode(source: src, route: .join(code: "K7M4QD2X")) == "K7M4QD2X")
        #expect(ChallengesModel.consumableInviteCode(source: src, route: .updateRequired(minBuild: 9)) == nil)
        #expect(ChallengesModel.consumableInviteCode(source: src, route: .unavailable) == nil)
        #expect(ChallengesModel.consumableInviteCode(source: src, route: .waitForConfig) == nil)
        #expect(ChallengesModel.consumableInviteCode(source: src, route: nil) == nil)
        #expect(ChallengesModel.consumableInviteCode(source: "profile_tile", route: .join(code: "K7M4QD2X")) == nil)
    }

    // MARK: - presentation sequencing

    @Test func planDismissesFirstOnlyWhenSomethingIsPresented() {
        #expect(ChallengeInvitePresentation.plan(isPrimarySheetPresented: false) == .presentNow)
        #expect(ChallengeInvitePresentation.plan(isPrimarySheetPresented: true) == .dismissThenPresent)
    }

    /// With nothing in the way: present, then clear. Never the other way
    /// round — a message the user never saw must not take the invite.
    @Test @MainActor func presentNowPresentsBeforeClearing() async {
        var order: [String] = []
        await ChallengeInvitePresentation.run(
            plan: .presentNow,
            dismiss: { order.append("dismiss") },
            settle: { order.append("settle") },
            present: { order.append("present") },
            thenClear: { order.append("clear") })
        #expect(order == ["present", "clear"])
    }

    /// With a sheet up: close it, let the dismissal finish, and only then
    /// present — swapping `.sheet(item:)` cases directly races the
    /// dismissal, and an alert raised under a sheet is raised to nobody.
    @Test @MainActor func dismissThenPresentRunsInOrder() async {
        var order: [String] = []
        await ChallengeInvitePresentation.run(
            plan: .dismissThenPresent,
            dismiss: { order.append("dismiss") },
            settle: { order.append("settle") },
            present: { order.append("present") },
            thenClear: { order.append("clear") })
        #expect(order == ["dismiss", "settle", "present", "clear"])
    }

    /// The join route passes no `thenClear` — the hub consumes the code
    /// instead, so the default must be a no-op that still presents.
    @Test @MainActor func runWithoutClearStillPresents() async {
        var order: [String] = []
        await ChallengeInvitePresentation.run(
            plan: .dismissThenPresent,
            dismiss: { order.append("dismiss") },
            settle: { order.append("settle") },
            present: { order.append("present") })
        #expect(order == ["dismiss", "settle", "present"])
    }

    /// Long enough to clear the ~0.35 s system dismissal, short enough not
    /// to read as a hang.
    @Test func dismissSettleIsAboutHalfASecond() {
        #expect(ChallengeInvitePresentation.dismissSettle >= .milliseconds(400))
        #expect(ChallengeInvitePresentation.dismissSettle <= .milliseconds(600))
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
