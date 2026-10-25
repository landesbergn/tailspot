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

    @Test func spacingBlocksUntil120Days() {
        let asked = Date(timeIntervalSince1970: 1_790_000_000)
        func check(_ days: Double) -> Bool {
            ReviewPromptPolicy.shouldRequest(
                totalCatches: 50, distinctCatchDays: 10,
                currentVersion: "1.3.0", lastPromptedVersion: "1.2.0",
                lastPromptedAt: asked, now: asked.addingTimeInterval(days * 86_400))
        }
        #expect(!check(1))
        #expect(!check(119.9))
        #expect(check(120))
        #expect(check(400))
    }

    @Test func legacySeedOnlyForVersionStampWithoutDate() {
        #expect(ReviewPromptPolicy.needsLegacySeed(lastPromptedVersion: "1.2.2", lastPromptedAt: nil))
        #expect(!ReviewPromptPolicy.needsLegacySeed(lastPromptedVersion: nil, lastPromptedAt: nil))
        #expect(!ReviewPromptPolicy.needsLegacySeed(lastPromptedVersion: "1.2.2", lastPromptedAt: Date()))
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

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func days(_ n: Double) -> TimeInterval { n * 86_400 }

    /// A new version AND 120+ days: asks again.
    @Test func versionBumpReArmsAfterSpacing() {
        let defaults = freshDefaults()
        var fired = 0
        ReviewPrompter(defaults: defaults, currentVersion: "1.1.0", now: { self.t0 },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        #expect(fired == 1)

        // "Next release" — a fresh prompter over the SAME defaults.
        let later = t0.addingTimeInterval(days(121))
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.0", now: { later },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        #expect(fired == 2)
        #expect(defaults.string(forKey: "reviewPromptLastVersion") == "1.2.0")
        #expect(defaults.object(forKey: ReviewPrompter.lastRequestedAtKey) as? Date == later)
    }

    /// The patch-release case that burned Apple's budget: a new version
    /// inside 120 days stays quiet, and doesn't consume the version stamp.
    @Test func versionBumpInsideSpacingStaysQuiet() {
        let defaults = freshDefaults()
        var fired = 0
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.2", now: { self.t0 },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 5, distinctCatchDays: 3)
        let soon = t0.addingTimeInterval(days(119))
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.3", now: { soon },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 9, distinctCatchDays: 5)
        #expect(fired == 1)
        #expect(defaults.string(forKey: "reviewPromptLastVersion") == "1.2.2")
    }

    /// Asked by a pre-spacing build (version stamp, no date): the first
    /// moment seeds the date instead of asking; 120 days on, it asks.
    @Test func legacyStampSeedsTheDateInsteadOfAsking() {
        let defaults = freshDefaults()
        defaults.set("1.2.2", forKey: "reviewPromptLastVersion")
        var fired = 0
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.3", now: { self.t0 },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 20, distinctCatchDays: 8)
        #expect(fired == 0)
        #expect(defaults.object(forKey: ReviewPrompter.lastRequestedAtKey) as? Date == t0)

        let later = t0.addingTimeInterval(days(120))
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.3", now: { later },
                       request: { fired += 1 })
            .catchMomentEnded(totalCatches: 21, distinctCatchDays: 9)
        #expect(fired == 1)
    }
}
