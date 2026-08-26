//
//  ReviewPromptTests.swift
//  TailspotTests
//
//  The review-ask machinery (v1.1 R7): the pure stickiness policy (3+
//  catches across 2+ distinct days — prod-data derivation in
//  ReviewPrompt.swift) and the prompter's once-per-version stamp
//  (committed on request, since StoreKit never says whether the sheet
//  showed). The ContentView funnel priority (toast/streak/suspect/trophy
//  claim the moment first) is device-verified — its conditions live in
//  `maybeRequestReview`.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("ReviewPromptPolicy")
struct ReviewPromptPolicyTests {

    @Test func belowCatchFloorNeverAsks() {
        #expect(!ReviewPromptPolicy.shouldRequest(
            totalCatches: ReviewPromptPolicy.minimumCatches - 1,
            distinctCatchDays: 2,
            currentVersion: "1.1.0", lastPromptedVersion: nil))
    }

    /// The airport rapid-fire triple: 3 catches, all on day one. Not
    /// sticky yet — the comeback is the signal.
    @Test func singleDayTripleIsNotStickyYet() {
        #expect(!ReviewPromptPolicy.shouldRequest(
            totalCatches: 3,
            distinctCatchDays: 1,
            currentVersion: "1.1.0", lastPromptedVersion: nil))
    }

    @Test func floorPlusSecondDayAsks() {
        #expect(ReviewPromptPolicy.shouldRequest(
            totalCatches: ReviewPromptPolicy.minimumCatches,
            distinctCatchDays: ReviewPromptPolicy.minimumCatchDays,
            currentVersion: "1.1.0", lastPromptedVersion: nil))
    }

    @Test func samePromptedVersionStaysQuiet() {
        #expect(!ReviewPromptPolicy.shouldRequest(
            totalCatches: 50, distinctCatchDays: 10,
            currentVersion: "1.1.0", lastPromptedVersion: "1.1.0"))
    }

    @Test func newVersionReArms() {
        #expect(ReviewPromptPolicy.shouldRequest(
            totalCatches: 50, distinctCatchDays: 10,
            currentVersion: "1.2.0", lastPromptedVersion: "1.1.0"))
    }
}

@Suite("ReviewPrompter")
@MainActor
struct ReviewPrompterTests {

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.review.\(UUID().uuidString)")!
    }

    @Test func firesOnceThenStampsTheVersion() {
        let defaults = freshDefaults()
        var fired = 0
        let prompter = ReviewPrompter(
            defaults: defaults, currentVersion: "1.1.0", request: { fired += 1 })

        prompter.catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        #expect(fired == 1)
        #expect(prompter.lastPromptedVersion == "1.1.0")

        // Same version, later reveal: stays quiet.
        prompter.catchMomentEnded(totalCatches: 9, distinctCatchDays: 4)
        #expect(fired == 1)
    }

    @Test func ineligibleUserDoesNotFireOrStamp() {
        let defaults = freshDefaults()
        var fired = 0
        let prompter = ReviewPrompter(
            defaults: defaults, currentVersion: "1.1.0", request: { fired += 1 })

        // Day-1 triple: below the day floor. The stamp must stay clear so
        // the ask isn't burned before it's allowed — eligibility arrives
        // on a later reveal.
        prompter.catchMomentEnded(totalCatches: 3, distinctCatchDays: 1)
        #expect(fired == 0)
        #expect(prompter.lastPromptedVersion == nil)
        prompter.catchMomentEnded(totalCatches: 4, distinctCatchDays: 2)
        #expect(fired == 1)
    }

    @Test func versionBumpReArmsAcrossLaunches() {
        let defaults = freshDefaults()
        var fired = 0
        ReviewPrompter(defaults: defaults, currentVersion: "1.1.0",
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        #expect(fired == 1)

        // "Next release" — a fresh prompter over the SAME defaults.
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.0",
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        #expect(fired == 2)
        #expect(defaults.string(forKey: "reviewPromptLastVersion") == "1.2.0")
    }
}
