//
//  ReviewPromptTests.swift
//  TailspotTests
//
//  The review-ask machinery (v1.1 R7): the pure eligibility policy, the
//  prompter's once-per-version stamp (committed on request, since StoreKit
//  never says whether the sheet showed), and the TrophyUnlockCenter drain
//  hook — fires only on a tap-through drain, never on skipAll, never on an
//  empty-queue advance.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("ReviewPromptPolicy")
struct ReviewPromptPolicyTests {

    @Test func belowCatchFloorNeverAsks() {
        #expect(!ReviewPromptPolicy.shouldRequest(
            totalCatches: ReviewPromptPolicy.minimumCatches - 1,
            currentVersion: "1.1.0", lastPromptedVersion: nil))
    }

    @Test func atFloorWithNoPriorAskAsks() {
        #expect(ReviewPromptPolicy.shouldRequest(
            totalCatches: ReviewPromptPolicy.minimumCatches,
            currentVersion: "1.1.0", lastPromptedVersion: nil))
    }

    @Test func samePromptedVersionStaysQuiet() {
        #expect(!ReviewPromptPolicy.shouldRequest(
            totalCatches: 50,
            currentVersion: "1.1.0", lastPromptedVersion: "1.1.0"))
    }

    @Test func newVersionReArms() {
        #expect(ReviewPromptPolicy.shouldRequest(
            totalCatches: 50,
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

        prompter.celebrationCompleted(totalCatches: 5)
        #expect(fired == 1)
        #expect(prompter.lastPromptedVersion == "1.1.0")

        // Same version, later celebration: stays quiet.
        prompter.celebrationCompleted(totalCatches: 9)
        #expect(fired == 1)
    }

    @Test func belowFloorDoesNotFireOrStamp() {
        let defaults = freshDefaults()
        var fired = 0
        let prompter = ReviewPrompter(
            defaults: defaults, currentVersion: "1.1.0", request: { fired += 1 })

        prompter.celebrationCompleted(totalCatches: 1)
        #expect(fired == 0)
        // The stamp must stay clear so the ask isn't burned before it's
        // allowed — the user reaches the floor on a later celebration.
        #expect(prompter.lastPromptedVersion == nil)
        prompter.celebrationCompleted(totalCatches: ReviewPromptPolicy.minimumCatches)
        #expect(fired == 1)
    }

    @Test func versionBumpReArmsAcrossLaunches() {
        let defaults = freshDefaults()
        var fired = 0
        ReviewPrompter(defaults: defaults, currentVersion: "1.1.0",
                       request: { fired += 1 })
            .celebrationCompleted(totalCatches: 5)
        #expect(fired == 1)

        // "Next release" — a fresh prompter over the SAME defaults.
        ReviewPrompter(defaults: defaults, currentVersion: "1.2.0",
                       request: { fired += 1 })
            .celebrationCompleted(totalCatches: 5)
        #expect(fired == 2)
        #expect(defaults.string(forKey: "reviewPromptLastVersion") == "1.2.0")
    }
}

@Suite("TrophyUnlockCenter → review drain hook")
@MainActor
struct TrophyUnlockDrainHookTests {

    /// Two achievements so a single enqueue can hold TWO queued events (a
    /// multi-tier jump on ONE achievement collapses to a single event at the
    /// highest tier — the diff's documented contract — so a two-event queue
    /// needs two distinct crossings).
    private let roster: [Achievement] = [
        Achievement(
            id: "m", title: "Medal", summary: "", iconName: "catcher",
            tiers: [.init(tier: .bronze, at: 1), .init(tier: .silver, at: 2), .init(tier: .gold, at: 3)],
            progress: { $0.totalCatches }
        ),
        Achievement(
            id: "b", title: "Badge", summary: "", iconName: "crown",
            tiers: [.init(tier: .silver, at: 1)],
            progress: { min(1, $0.legendaryTierCatches) }
        ),
    ]

    private func freshLedger() -> UserDefaultsTrophyLedger {
        UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.drain.\(UUID().uuidString)")!)
    }

    /// `n` generic catches; the last `legendary` of them are legendary-tier
    /// (tier resolves from the typecode table — B2 → legendary).
    private func catches(_ n: Int, legendary: Int = 0) -> [Catch] {
        (0..<n).map { i in
            let isLegendary = i >= n - legendary
            return Catch(
                icao24: String(UUID().uuidString.prefix(6)), callsign: nil,
                model: isLegendary ? "B-2" : "737-800",
                manufacturer: isLegendary ? "NORTHROP" : "BOEING",
                operatorName: nil,
                caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
                observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
                typecode: isLegendary ? "B2" : "B738")
        }
    }

    @Test func tapThroughDrainFiresOnceWithCatchCount() {
        var drained: [Int] = []
        let center = TrophyUnlockCenter(
            ledger: freshLedger(), roster: roster,
            onCelebrationCompleted: { drained.append($0) })
        center.enqueueNewUnlocks(from: catches(1))   // seed at bronze
        center.enqueueNewUnlocks(from: catches(2))   // silver → one event
        center.markShown(center.head!)
        center.advance()
        #expect(drained == [2])
    }

    @Test func multiEventQueueFiresOnlyAtFinalAdvance() {
        var drained: [Int] = []
        let center = TrophyUnlockCenter(
            ledger: freshLedger(), roster: roster,
            onCelebrationCompleted: { drained.append($0) })
        center.enqueueNewUnlocks(from: catches(1))                  // seed bronze
        center.enqueueNewUnlocks(from: catches(2, legendary: 1))    // medal silver + badge → 2 events
        #expect(center.pendingEvents.count == 2)
        center.markShown(center.head!)
        center.advance()
        #expect(drained.isEmpty, "mid-queue advance is not a completed celebration")
        center.markShown(center.head!)
        center.advance()
        #expect(drained == [2])
    }

    @Test func skipAllNeverFires() {
        var drained: [Int] = []
        let center = TrophyUnlockCenter(
            ledger: freshLedger(), roster: roster,
            onCelebrationCompleted: { drained.append($0) })
        center.enqueueNewUnlocks(from: catches(1))
        center.enqueueNewUnlocks(from: catches(2, legendary: 1))    // 2 events
        #expect(center.pendingEvents.count == 2)
        center.skipAll()
        #expect(drained.isEmpty, "skipping signals a hurry — no ask")
    }

    @Test func emptyQueueAdvanceNeverFires() {
        var drained: [Int] = []
        let center = TrophyUnlockCenter(
            ledger: freshLedger(), roster: roster,
            onCelebrationCompleted: { drained.append($0) })
        center.enqueueNewUnlocks(from: catches(1))   // seed only — no events
        center.advance()
        #expect(drained.isEmpty)
    }
}
