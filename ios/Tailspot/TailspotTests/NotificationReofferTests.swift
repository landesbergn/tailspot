//
//  NotificationReofferTests.swift
//  TailspotTests
//
//  The one notification re-offer for "Not now" decliners (Noah,
//  2026-10-23), the weekly-board placement that can earn it, the one-time
//  decliner migration rule, and the Settings feedback / rating plumbing.
//  All pure: the ContentView funnel that consumes these is device-verified.
//

import Testing
import Foundation
import UserNotifications
@testable import Tailspot

@Suite("Notification re-offer")
struct NotificationReofferTests {

    private func reoffer(
        streak: Int = 3,
        placed: Bool = false,
        enabled: Bool = true,
        declined: Bool = true,
        used: Bool = false,
        status: UNAuthorizationStatus = .notDetermined
    ) -> StreakReminders.Reoffer? {
        StreakReminders.reoffer(
            currentStreak: streak, placedOnWeeklyBoard: placed, enabled: enabled,
            declined: declined, reofferUsed: used, authStatus: status)
    }

    @Test func threeDayStreakEarnsIt() {
        #expect(reoffer(streak: 3) == .init(trigger: .streak, routesToSettings: false))
        #expect(reoffer(streak: 2) == nil)
    }

    @Test func weeklyBoardEarnsItBeforeAThreeDayStreak() {
        #expect(reoffer(streak: 1, placed: true) == .init(trigger: .weeklyBoard, routesToSettings: false))
        // Placement was latched before this catch, so it came first.
        #expect(reoffer(streak: 3, placed: true)?.trigger == .weeklyBoard)
    }

    @Test func onlyForDeclinersAndOnlyOnce() {
        #expect(reoffer(declined: false) == nil)
        #expect(reoffer(used: true) == nil)
        #expect(reoffer(enabled: false) == nil)
    }

    /// "Not now" isn't re-asked the same day: a new spotter can decline on
    /// their first catch, open the Week board and catch again within
    /// minutes, which would otherwise earn the weekly-board re-offer.
    @Test func neverOnTheDayOfTheDecline() {
        #expect(StreakReminders.reoffer(
            currentStreak: 1, placedOnWeeklyBoard: true, enabled: true,
            declined: true, reofferUsed: false, authStatus: .notDetermined,
            declinedToday: true) == nil)
        #expect(StreakReminders.reoffer(
            currentStreak: 3, placedOnWeeklyBoard: false, enabled: true,
            declined: true, reofferUsed: false, authStatus: .denied,
            declinedToday: true) == nil)
        // The next day the same placement earns it.
        #expect(StreakReminders.reoffer(
            currentStreak: 1, placedOnWeeklyBoard: true, enabled: true,
            declined: true, reofferUsed: false, authStatus: .notDetermined,
            declinedToday: false)?.trigger == .weeklyBoard)
    }

    @Test func iosDenialRoutesToSettings() {
        #expect(reoffer(status: .denied) == .init(trigger: .streak, routesToSettings: true))
    }

    @Test func nothingToOfferOnceGranted() {
        #expect(reoffer(status: .authorized) == nil)
        #expect(reoffer(status: .provisional) == nil)
        #expect(reoffer(status: .ephemeral) == nil)
    }

    @Test func twentySecondSeparationEitherOrder() {
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(StreakReminders.isSeparated(now: t, from: nil))
        #expect(!StreakReminders.isSeparated(now: t, from: t.addingTimeInterval(-19)))
        #expect(StreakReminders.isSeparated(now: t, from: t.addingTimeInterval(-20)))
        // A timestamp ahead of now (clock change) still counts as close.
        #expect(!StreakReminders.isSeparated(now: t, from: t.addingTimeInterval(5)))
    }

    /// The migration marks only people the app asked whom iOS never asked.
    @Test func legacyDeclinerRule() {
        #expect(StreakReminders.isLegacyDecliner(asked: true, authStatus: .notDetermined))
        #expect(!StreakReminders.isLegacyDecliner(asked: false, authStatus: .notDetermined))
        #expect(!StreakReminders.isLegacyDecliner(asked: true, authStatus: .denied))
        #expect(!StreakReminders.isLegacyDecliner(asked: true, authStatus: .authorized))
    }

    @Test func reofferTelemetryCarriesTriggerAndRoute() {
        let props = StreakTelemetry.reofferProperties(
            .init(trigger: .weeklyBoard, routesToSettings: true), streakDays: 2, accepted: false)
        #expect(props["trigger"]?.jsonValue as? String == "weekly_board")
        #expect(props["route"]?.jsonValue as? String == "ios_settings")
        #expect(props["streak_days"]?.jsonValue as? Int == 2)
        #expect(props["accepted"]?.jsonValue as? Bool == false)
        let shown = StreakTelemetry.reofferProperties(
            .init(trigger: .streak, routesToSettings: false), streakDays: 3)
        #expect(shown["trigger"]?.jsonValue as? String == "streak_3_day")
        #expect(shown["route"]?.jsonValue as? String == "system_prompt")
        #expect(shown["accepted"] == nil)
    }
}

@Suite("Weekly-board placement")
struct WeeklyPlacementTests {

    @Test func weekWindowWithARankIsAPlacement() {
        #expect(LeaderboardStandingCache.isWeeklyPlacement(window: "week", rank: 7))
        #expect(!LeaderboardStandingCache.isWeeklyPlacement(window: "week", rank: 0))
        #expect(!LeaderboardStandingCache.isWeeklyPlacement(window: "all", rank: 1))
        // Pre-windows backend: no echo, so we can't tell it's the week board.
        #expect(!LeaderboardStandingCache.isWeeklyPlacement(window: nil, rank: 1))
    }

    @Test func placementLatches() {
        let defaults = UserDefaults(suiteName: "test.placement.\(UUID().uuidString)")!
        let cache = LeaderboardStandingCache(defaults: defaults)
        #expect(!cache.everPlacedWeekly)
        cache.notePlacement(window: "week", me: MyStanding(rank: 0, points: 0))
        #expect(!cache.everPlacedWeekly)
        cache.notePlacement(window: "week", me: MyStanding(rank: 4, points: 120))
        #expect(cache.everPlacedWeekly)
        // A later unranked week doesn't un-place.
        cache.notePlacement(window: "week", me: MyStanding(rank: 0, points: 0))
        #expect(cache.everPlacedWeekly)
    }
}

@Suite("Settings feedback + rating")
struct SettingsFeedbackTests {

    @Test func writeReviewURLTargetsTheApp() {
        #expect(AppStoreListing.writeReviewURL.absoluteString
                == "https://apps.apple.com/app/id6773470079?action=write-review")
    }

    @Test func campaignURLStillUsesTheSameId() {
        #expect(AppStoreListing.url(campaign: "x").absoluteString
            .hasPrefix("https://apps.apple.com/app/apple-store/id6773470079?"))
    }

    @Test func mailtoCarriesSubjectAndVersionLine() throws {
        let url = try #require(FeedbackMail.mailtoURL(versionLine: "Tailspot 1.2.3 (build 108)"))
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "support@tailspot.app")
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"] == "Tailspot feedback")
        #expect(items["body"]?.hasSuffix("Tailspot 1.2.3 (build 108)") == true)
        // Spaces and newlines are percent-encoded, not raw.
        #expect(!url.absoluteString.contains(" "))
        #expect(!url.absoluteString.contains("\n"))
    }

    @Test func rowTappedProperties() {
        let rate = SettingsTelemetry.rowTappedProperties(row: "rate_tailspot", route: nil)
        #expect(rate.count == 1)
        #expect(rate["row"]?.jsonValue as? String == "rate_tailspot")
        let feedback = SettingsTelemetry.rowTappedProperties(row: "send_feedback", route: .mailto)
        #expect(feedback["row"]?.jsonValue as? String == "send_feedback")
        #expect(feedback["route"]?.jsonValue as? String == "mailto")
    }
}
