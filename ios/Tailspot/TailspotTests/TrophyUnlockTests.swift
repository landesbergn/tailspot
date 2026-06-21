//
//  TrophyUnlockTests.swift
//  TailspotTests
//
//  Pin the pure unlock-detection: `TrophyUnlock.pending` diffing current
//  earned-state against the `UserDefaultsTrophyLedger`, plus the
//  silent-seeding path that prevents a first-launch celebration flood.
//
//  Uses a tiny purpose-built test roster (one leveled medal + one badge)
//  so threshold tweaks to the real roster can't drift these assertions,
//  and a fresh isolated `UserDefaults` suite per test so the ledger never
//  touches `.standard` (CI clone safety).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("TrophyUnlock")
@MainActor
struct TrophyUnlockTests {

    // MARK: - Fixtures

    /// A leveled medal (bronze@1 / silver@2 / gold@3 on totalCatches) and a
    /// one-shot badge (silver@1 on a legendary catch).
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

    private func inputs(total: Int = 0, legendary: Int = 0) -> TrophyProgressInputs {
        TrophyProgressInputs(
            totalCatches: total, uniqueAirframes: 0,
            wideBodyCatches: 0, regionalCatches: 0, heritageCatches: 0,
            rareTierCatches: 0, epicTierCatches: 0, legendaryTierCatches: legendary,
            rarePlusUnique: 0, longestSlantKm: 0,
            bestMultiCatchCount: 0, nightCatches: 0
        )
    }

    /// Fresh ledger on a unique suite — no cross-test or `.standard` bleed.
    private func freshLedger() -> UserDefaultsTrophyLedger {
        let suite = "test.trophy.\(UUID().uuidString)"
        return UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: suite)!)
    }

    // MARK: - pending()

    @Test func pendingEmptyWhenLedgerMatchesCurrent() {
        let ledger = freshLedger()
        // Acknowledge medal=bronze(0), badge=silver(1) to match the inputs below.
        ledger.setAcknowledged(TrophyTier.bronze.ordinal, for: "m")
        ledger.setAcknowledged(TrophyTier.silver.ordinal, for: "b")
        let events = TrophyUnlock.pending(inputs: inputs(total: 1, legendary: 1), roster: roster, ledger: ledger)
        #expect(events.isEmpty)
    }

    @Test func medalTierUpYieldsOneEvent() {
        let ledger = freshLedger()
        ledger.setAcknowledged(TrophyTier.bronze.ordinal, for: "m")  // acked bronze
        let events = TrophyUnlock.pending(inputs: inputs(total: 2), roster: roster, ledger: ledger)  // now silver
        #expect(events.count == 1)
        #expect(events.first?.achievementID == "m")
        #expect(events.first?.newTier == .silver)
        #expect(events.first?.kind == .tierUp)
    }

    @Test func badgeEarnedYieldsOneEventAndStillLockedYieldsNone() {
        let earnedEvents = TrophyUnlock.pending(inputs: inputs(legendary: 1), roster: roster, ledger: freshLedger())
        let badge = earnedEvents.first { $0.achievementID == "b" }
        #expect(badge != nil)
        #expect(badge?.kind == .badgeEarned)

        let lockedEvents = TrophyUnlock.pending(inputs: inputs(legendary: 0), roster: roster, ledger: freshLedger())
        #expect(lockedEvents.contains { $0.achievementID == "b" } == false)
    }

    @Test func twoTierJumpCollapsesToOneEventAtHighest() {
        // Unacknowledged ledger; totalCatches=3 jumps straight to gold.
        let events = TrophyUnlock.pending(inputs: inputs(total: 3), roster: roster, ledger: freshLedger())
        let medal = events.filter { $0.achievementID == "m" }
        #expect(medal.count == 1)
        #expect(medal.first?.newTier == .gold)
    }

    @Test func twoCrossingsYieldTwoEventsInRosterOrder() {
        let events = TrophyUnlock.pending(inputs: inputs(total: 1, legendary: 1), roster: roster, ledger: freshLedger())
        #expect(events.map(\.achievementID) == ["m", "b"])  // roster order
    }

    @Test func acknowledgeOmitsOnNextPending() {
        let ledger = freshLedger()
        let first = TrophyUnlock.pending(inputs: inputs(total: 1), roster: roster, ledger: ledger)
        #expect(first.contains { $0.achievementID == "m" })
        // Commit what we showed, then re-diff: medal should be gone.
        for e in first { ledger.setAcknowledged(e.newTier.ordinal, for: e.achievementID) }
        let second = TrophyUnlock.pending(inputs: inputs(total: 1), roster: roster, ledger: ledger)
        #expect(second.contains { $0.achievementID == "m" } == false)
    }

    @Test func lowerCurrentThanAcknowledgedEmitsNothing() {
        let ledger = freshLedger()
        ledger.setAcknowledged(TrophyTier.gold.ordinal, for: "m")   // acked gold
        let events = TrophyUnlock.pending(inputs: inputs(total: 1), roster: roster, ledger: ledger)  // now only bronze
        #expect(events.contains { $0.achievementID == "m" } == false)
    }

    // MARK: - seed()

    @Test func seedAcknowledgesCurrentStateAndEmitsNothingAfter() {
        let ledger = freshLedger()
        let earned = inputs(total: 3, legendary: 1)  // medal gold, badge silver
        #expect(ledger.isSeeded == false)
        TrophyUnlock.seed(inputs: earned, roster: roster, into: ledger)
        #expect(ledger.isSeeded)
        #expect(ledger.acknowledgedOrdinal(for: "m") == TrophyTier.gold.ordinal)
        #expect(ledger.acknowledgedOrdinal(for: "b") == TrophyTier.silver.ordinal)
        // No flood: nothing pending right after seeding the same state.
        #expect(TrophyUnlock.pending(inputs: earned, roster: roster, ledger: ledger).isEmpty)
    }

    @Test func seedDoesNotAcknowledgeUnearnedTrophies() {
        let ledger = freshLedger()
        TrophyUnlock.seed(inputs: inputs(total: 0, legendary: 0), roster: roster, into: ledger)
        // Nothing earned → nothing acknowledged; a later crossing still fires.
        #expect(ledger.acknowledgedOrdinal(for: "m") == -1)
        let later = TrophyUnlock.pending(inputs: inputs(total: 1), roster: roster, ledger: ledger)
        #expect(later.contains { $0.achievementID == "m" })
    }
}
