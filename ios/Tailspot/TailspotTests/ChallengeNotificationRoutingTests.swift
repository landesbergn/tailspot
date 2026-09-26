//
//  ChallengeNotificationRoutingTests.swift
//  TailspotTests
//
//  The two pure decisions a challenge notification triggers — foreground
//  presentation (the never-cover-the-viewfinder rule) and tap routing — plus
//  the model's park/consume of the tapped challenge id. No notification
//  center, no views: the delegate hands these functions a string and a
//  dictionary, which is exactly what the tests hand them.
//

import Foundation
import Testing
import UserNotifications
@testable import Tailspot

@Suite("Challenge notification routing")
struct ChallengeNotificationRoutingTests {

    /// What the backend's remote push carries (contract, see
    /// `ChallengeNotificationRouting`'s header).
    private let remoteUserInfo: [AnyHashable: Any] = [
        "challengeId": "c-remote",
        "kind": "overtaken",
    ]

    /// What the local scheduler puts on every request it adds.
    private func localUserInfo(id: String, kind: String) -> [AnyHashable: Any] {
        ["challengeId": id, "kind": kind]
    }

    // MARK: - is it ours

    @Test func localChallengeIdentifiersAreRecognized() {
        for moment in ChallengeReminders.Moment.allCases where moment != .daily {
            let identifier = ChallengeReminders.identifier(challengeId: "c1", moment: moment)
            #expect(ChallengeNotificationRouting.isChallengeNotification(
                identifier: identifier, userInfo: [:]))
        }
        #expect(ChallengeNotificationRouting.isChallengeNotification(
            identifier: ChallengeReminders.identifier(challengeId: "c1", moment: .daily,
                                                      dayKey: "2026-09-29"),
            userInfo: [:]))
    }

    /// A remote push's identifier is an APNs id we never chose, so the
    /// userInfo is the only evidence — which is why both pushes carry it.
    @Test func remotePushesAreRecognizedByUserInfoAlone() {
        #expect(ChallengeNotificationRouting.isChallengeNotification(
            identifier: "9F1B2C3D-APNS", userInfo: remoteUserInfo))
    }

    @Test func theStreakReminderIsNotAChallengeNotification() {
        #expect(!ChallengeNotificationRouting.isChallengeNotification(
            identifier: StreakReminders.notificationId, userInfo: [:]))
    }

    @Test func foreignNotificationsAreNotOurs() {
        #expect(!ChallengeNotificationRouting.isChallengeNotification(
            identifier: "com.apple.something", userInfo: [:]))
        // An empty id is not an id.
        #expect(!ChallengeNotificationRouting.isChallengeNotification(
            identifier: "com.apple.something", userInfo: ["challengeId": ""]))
    }

    // MARK: - foreground presentation (camera silence)

    @Test func challengeBannersAreSilentOnTheCamera() {
        let identifier = ChallengeReminders.identifier(challengeId: "c1", moment: .endingSoon)
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: identifier, userInfo: [:], cameraFrontmost: true) == [])
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: identifier, userInfo: [:], cameraFrontmost: false) == [.banner, .sound])
    }

    @Test func remotePushesObeyTheSameCameraRule() {
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: "9F1B2C3D-APNS", userInfo: remoteUserInfo, cameraFrontmost: true) == [])
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: "9F1B2C3D-APNS", userInfo: remoteUserInfo,
            cameraFrontmost: false) == [.banner, .sound])
    }

    /// nil means "not ours" — the delegate then keeps its own default, and
    /// the streak reminder's own path is untouched either way.
    @Test func nonChallengeNotificationsGetNoOpinion() {
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: StreakReminders.notificationId, userInfo: [:],
            cameraFrontmost: true) == nil)
        #expect(ChallengeNotificationRouting.foregroundPresentation(
            identifier: "com.apple.something", userInfo: [:], cameraFrontmost: false) == nil)
    }

    /// The challenge rule IS the streak rule, not a copy of it.
    @Test func theCameraRuleIsSharedWithTheStreakReminder() {
        for onCamera in [true, false] {
            #expect(ChallengeNotificationRouting.foregroundPresentation(
                identifier: ChallengeReminders.identifier(challengeId: "c1", moment: .starts),
                userInfo: [:], cameraFrontmost: onCamera)
                    == StreakReminders.foregroundPresentation(cameraFrontmost: onCamera))
        }
    }

    // MARK: - tap route

    @Test func localReminderTapsCarryTheirMoment() {
        for moment in ChallengeReminders.Moment.allCases where moment != .daily {
            let identifier = ChallengeReminders.identifier(challengeId: "c1", moment: moment)
            let route = ChallengeNotificationRouting.route(
                identifier: identifier, userInfo: localUserInfo(id: "c1", kind: moment.rawValue))
            #expect(route == .init(challengeId: "c1", moment: moment.rawValue))
        }
    }

    @Test func dailyTapsRouteToTheChallengeNotTheDay() {
        let identifier = ChallengeReminders.identifier(
            challengeId: "c1", moment: .daily, dayKey: "2026-09-29")
        let route = ChallengeNotificationRouting.route(identifier: identifier, userInfo: [:])
        #expect(route == .init(challengeId: "c1", moment: "daily"))
    }

    @Test func remoteTapsRouteOnUserInfoAlone() {
        let route = ChallengeNotificationRouting.route(
            identifier: "9F1B2C3D-APNS", userInfo: remoteUserInfo)
        #expect(route == .init(challengeId: "c-remote", moment: "overtaken"))
    }

    /// A `kind` this build has never heard of still opens the challenge —
    /// dropping the tap would be the worse failure, and the analytics
    /// property is a string.
    @Test func anUnknownRemoteKindStillRoutes() {
        let route = ChallengeNotificationRouting.route(
            identifier: "9F1B2C3D-APNS",
            userInfo: ["challengeId": "c-remote", "kind": "something_new"])
        #expect(route == .init(challengeId: "c-remote", moment: "something_new"))
    }

    @Test func aRemotePushWithNoKindStillRoutes() {
        let route = ChallengeNotificationRouting.route(
            identifier: "9F1B2C3D-APNS", userInfo: ["challengeId": "c-remote"])
        #expect(route == .init(challengeId: "c-remote", moment: "unknown"))
    }

    @Test func nonChallengeNotificationsHaveNoRoute() {
        #expect(ChallengeNotificationRouting.route(
            identifier: StreakReminders.notificationId, userInfo: [:]) == nil)
    }
}

// MARK: - the model's park / consume

@Suite("Challenge notification tap → model")
@MainActor
struct ChallengeNotificationTapModelTests {

    private func makeModel() -> ChallengesModel {
        ChallengesModel(
            service: FixtureChallengesService(),
            currentBuild: 100,
            reminders: NoopChallengeReminderScheduler(),
            defaults: UserDefaults(suiteName: "ChallengeTapTests.\(UUID().uuidString)")!)
    }

    @Test func openChallengeParksTheId() {
        let model = makeModel()
        #expect(model.pendingDetailId == nil)
        model.openChallenge(id: "c-live")
        #expect(model.pendingDetailId == "c-live")
    }

    @Test func anEmptyIdIsNotParked() {
        let model = makeModel()
        model.openChallenge(id: "")
        #expect(model.pendingDetailId == nil)
    }

    /// One owner: only the hub the tap's own sheet presented may take it.
    @Test func onlyTheDeepLinkHubMayConsumeIt() {
        let model = makeModel()
        model.openChallenge(id: "c-live")

        #expect(model.consumePendingDetail(for: "profile_tile") == nil)
        #expect(model.consumePendingDetail(for: "leaders_flag") == nil)
        #expect(model.pendingDetailId == "c-live", "a losing hub must not clear it")

        #expect(model.consumePendingDetail(for: ChallengesModel.inviteSource) == "c-live")
        #expect(model.pendingDetailId == nil)
        #expect(model.consumePendingDetail(for: ChallengesModel.inviteSource) == nil)
    }

    @Test func theConsumeRuleIsPure() {
        #expect(ChallengesModel.consumableDetailId(
            source: ChallengesModel.inviteSource, detailId: "c1") == "c1")
        #expect(ChallengesModel.consumableDetailId(
            source: "profile_tile", detailId: "c1") == nil)
        #expect(ChallengesModel.consumableDetailId(
            source: ChallengesModel.inviteSource, detailId: nil) == nil)
        #expect(ChallengesModel.consumableDetailId(
            source: ChallengesModel.inviteSource, detailId: "") == nil)
    }

    @Test func clearDropsThePendingDetail() {
        let model = makeModel()
        model.openChallenge(id: "c-live")
        model.clearPendingDetail()
        #expect(model.pendingDetailId == nil)
    }
}
