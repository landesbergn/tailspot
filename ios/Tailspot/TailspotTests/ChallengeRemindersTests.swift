//
//  ChallengeRemindersTests.swift
//  TailspotTests
//
//  ChallengeReminders.plan: which moments exist for each duration preset,
//  exact fire times, none when disabled/unauthorized, none for moments
//  already in the past, unique identifiers per challenge, and the
//  identifier prefix never colliding with StreakReminders.notificationId
//  (spec section 13).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Challenge reminders")
struct ChallengeRemindersTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - guardrails

    @Test func disabledSchedulesNothing() {
        let plans = ChallengeReminders.plan(
            challengeId: "c1", name: "Weekend Flyoff",
            startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(3600 * 25),
            durationPreset: "24h", now: now, enabled: false, authorized: true)
        #expect(plans.isEmpty)
    }

    @Test func unauthorizedSchedulesNothing() {
        let plans = ChallengeReminders.plan(
            challengeId: "c1", name: "Weekend Flyoff",
            startsAt: now.addingTimeInterval(3600), endsAt: now.addingTimeInterval(3600 * 25),
            durationPreset: "24h", now: now, enabled: true, authorized: false)
        #expect(plans.isEmpty)
    }

    // MARK: - 1h preset

    @Test func oneHourPresetMoments() {
        let starts = now.addingTimeInterval(60) // starts in 1 minute
        let ends = starts.addingTimeInterval(3600) // 1h window
        let plans = ChallengeReminders.plan(
            challengeId: "c1", name: "Quick Sprint",
            startsAt: starts, endsAt: ends,
            durationPreset: "1h", now: now, enabled: true, authorized: true)
        let byMoment = Dictionary(uniqueKeysWithValues: plans.map { ($0.identifier, $0) })
        #expect(plans.count == 3)
        #expect(byMoment["tailspot.challenge.c1.starts"]?.fireAt == starts)
        #expect(byMoment["tailspot.challenge.c1.starts"]?.body == "Quick Sprint starts now.")
        // 1h preset: ending-soon lead is 10 minutes, not 1 hour.
        #expect(byMoment["tailspot.challenge.c1.ending_soon"]?.fireAt == ends.addingTimeInterval(-600))
        #expect(byMoment["tailspot.challenge.c1.ending_soon"]?.body == "Ten minutes left in Quick Sprint.")
        #expect(byMoment["tailspot.challenge.c1.finished"]?.fireAt == ends)
        #expect(byMoment["tailspot.challenge.c1.finished"]?.body == "Quick Sprint just finished. See how you did.")
    }

    // MARK: - 24h/3d/7d presets get a 1-hour warning

    @Test func twentyFourHourPresetGetsOneHourWarning() {
        let starts = now.addingTimeInterval(60)
        let ends = starts.addingTimeInterval(24 * 3600)
        let plans = ChallengeReminders.plan(
            challengeId: "c2", name: "Weekend Flyoff",
            startsAt: starts, endsAt: ends,
            durationPreset: "24h", now: now, enabled: true, authorized: true)
        let byMoment = Dictionary(uniqueKeysWithValues: plans.map { ($0.identifier, $0) })
        #expect(byMoment["tailspot.challenge.c2.ending_soon"]?.fireAt == ends.addingTimeInterval(-3600))
        #expect(byMoment["tailspot.challenge.c2.ending_soon"]?.body == "One hour left in Weekend Flyoff.")
    }

    @Test func threeDayAndSevenDayPresetsAlsoGetOneHourWarning() {
        for preset in ["3d", "7d"] {
            let starts = now.addingTimeInterval(60)
            let ends = starts.addingTimeInterval(3 * 24 * 3600)
            let plans = ChallengeReminders.plan(
                challengeId: "c3", name: "Long Haul",
                startsAt: starts, endsAt: ends,
                durationPreset: preset, now: now, enabled: true, authorized: true)
            let endingSoon = plans.first { $0.identifier == "tailspot.challenge.c3.ending_soon" }
            #expect(endingSoon?.fireAt == ends.addingTimeInterval(-3600))
        }
    }

    // MARK: - past moments are dropped, not resurrected

    @Test func alreadyStartedChallengeHasNoStartsReminder() {
        let starts = now.addingTimeInterval(-100) // already started
        let ends = now.addingTimeInterval(3600 * 24)
        let plans = ChallengeReminders.plan(
            challengeId: "c4", name: "In Progress",
            startsAt: starts, endsAt: ends,
            durationPreset: "24h", now: now, enabled: true, authorized: true)
        #expect(!plans.contains { $0.identifier == "tailspot.challenge.c4.starts" })
        #expect(plans.contains { $0.identifier == "tailspot.challenge.c4.ending_soon" })
        #expect(plans.contains { $0.identifier == "tailspot.challenge.c4.finished" })
    }

    @Test func endingSoonAlreadyPassedIsDropped() {
        let starts = now.addingTimeInterval(-3600 * 23)
        let ends = now.addingTimeInterval(60) // ends very soon; -1h lead is in the past
        let plans = ChallengeReminders.plan(
            challengeId: "c5", name: "Almost Over",
            startsAt: starts, endsAt: ends,
            durationPreset: "24h", now: now, enabled: true, authorized: true)
        #expect(!plans.contains { $0.identifier == "tailspot.challenge.c5.ending_soon" })
        #expect(plans.contains { $0.identifier == "tailspot.challenge.c5.finished" })
    }

    @Test func fullyFinishedChallengeHasNoMoments() {
        let starts = now.addingTimeInterval(-3600 * 48)
        let ends = now.addingTimeInterval(-3600 * 24)
        let plans = ChallengeReminders.plan(
            challengeId: "c6", name: "Long Done",
            startsAt: starts, endsAt: ends,
            durationPreset: "24h", now: now, enabled: true, authorized: true)
        #expect(plans.isEmpty)
    }

    // MARK: - identifiers

    @Test func identifiersAreUniquePerChallenge() {
        let idsA = Set(ChallengeReminders.identifiers(challengeId: "a"))
        let idsB = Set(ChallengeReminders.identifiers(challengeId: "b"))
        #expect(idsA.isDisjoint(with: idsB))
        #expect(idsA.count == 3)
    }

    @Test func identifierPrefixNeverEqualsStreakReminderId() {
        #expect(ChallengeReminders.identifierPrefix != StreakReminders.notificationId)
        for id in ChallengeReminders.identifiers(challengeId: "c1") {
            #expect(id != StreakReminders.notificationId)
            #expect(!StreakReminders.isStreakReminder(id))
        }
        #expect(!ChallengeReminders.isChallengeIdentifier(StreakReminders.notificationId))
        #expect(ChallengeReminders.isChallengeIdentifier("tailspot.challenge.c1.starts"))
    }

    // MARK: - challengeId(fromNotificationIdentifier:)

    @Test func challengeIdRoundTripsSimpleIds() {
        for id in ChallengeReminders.identifiers(challengeId: "c1") {
            #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: id) == "c1")
        }
    }

    @Test func challengeIdRoundTripsIdsContainingDashes() {
        let uuid = "3f9a1c2e-1234-4abc-9def-0987654321ab"
        for id in ChallengeReminders.identifiers(challengeId: uuid) {
            #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: id) == uuid)
        }
    }

    @Test func challengeIdRejectsTheStreakIdentifier() {
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: StreakReminders.notificationId) == nil)
    }

    // MARK: - a Starts-Now create must not buzz one second later

    /// A "Starts now" challenge comes back with `startsAt` at, or within a
    /// second or two of, the moment the user pressed Create — the device
    /// clock and the server's never agree exactly. A "Challenge started"
    /// banner arriving while the creator is still looking at the share sheet
    /// is noise, so the moment needs a minute of daylight to be worth it.
    @Test func startsMomentIsSkippedWhenTheStartIsEffectivelyNow() {
        for offset in [-2.0, 0.0, 1.0, 30.0, 59.0] {
            let starts = now.addingTimeInterval(offset)
            let plans = ChallengeReminders.plan(
                challengeId: "c1", name: "Starts Now", startsAt: starts,
                endsAt: starts.addingTimeInterval(24 * 3600), durationPreset: "24h",
                now: now, enabled: true, authorized: true)
            #expect(!plans.contains { $0.identifier == "tailspot.challenge.c1.starts" },
                    "offset \(offset) should not schedule a starts reminder")
            // The other two moments are unaffected.
            #expect(plans.count == 2)
        }
    }

    @Test func startsMomentSurvivesAFullMinuteOfLead() {
        let starts = now.addingTimeInterval(ChallengeReminders.startsLead)
        let plans = ChallengeReminders.plan(
            challengeId: "c1", name: "Soon", startsAt: starts,
            endsAt: starts.addingTimeInterval(24 * 3600), durationPreset: "24h",
            now: now, enabled: true, authorized: true)
        #expect(plans.contains { $0.identifier == "tailspot.challenge.c1.starts" })
    }

    @Test func challengeIdRejectsForeignIdentifiers() {
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "com.apple.something.else") == nil)
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "tailspot.challenge.") == nil)
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "tailspot.challenge.c1.unknownmoment") == nil)
        #expect(ChallengeReminders.challengeId(fromNotificationIdentifier: "tailspot.challenge.c1") == nil)
    }
}
