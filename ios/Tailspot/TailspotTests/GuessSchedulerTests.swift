//
//  GuessSchedulerTests.swift
//  TailspotTests
//
//  Pins the ROUTE bonus-round cadence rules (plan 2026-07-09-001 D3;
//  route-only per Noah 2026-07-09; re-balanced more frequent 2026-08-25 and
//  again 2026-11-11 per Noah): ~2-in-3 roll on eligible catches, no forced
//  gap after a round, never the
//  user's very first catch, eligibility = fresh single non-duplicate
//  non-suspect with a renderable route. Everything runs against SeededRNG so
//  the distribution assertions are exact replays, not flakes.
//

import Foundation
import Testing
@testable import Tailspot

/// RNG that always returns the same raw value. `value: 0` makes every
/// `Double.random(in: 0..<1)` come out 0.0 — i.e. the probability roll
/// ALWAYS fires — which isolates the deterministic guards from it.
/// `nonisolated` so the RandomNumberGenerator conformance isn't
/// MainActor-isolated under the repo's default-isolation setting.
private nonisolated struct ConstantRNG: RandomNumberGenerator {
    let value: UInt64
    mutating func next() -> UInt64 { value }
}

@Suite("GuessScheduler — pure cadence core")
struct GuessSchedulerCoreTests {

    /// Baseline inputs: an eligible catch that is allowed to fire.
    private func decide(
        isFreshSingle: Bool = true,
        isDuplicate: Bool = false,
        isSuspect: Bool = false,
        routeAvailable: Bool = true,
        priorCatchCount: Int = 10,
        catchesSinceLastRound: Int? = nil,
        rng: inout some RandomNumberGenerator
    ) -> GuessKind? {
        GuessScheduler.decide(
            isFreshSingle: isFreshSingle,
            isDuplicate: isDuplicate,
            isSuspect: isSuspect,
            routeAvailable: routeAvailable,
            priorCatchCount: priorCatchCount,
            catchesSinceLastRound: catchesSinceLastRound,
            using: &rng
        )
    }

    // ── Eligibility guards (deterministic — always-fire RNG) ────────────

    @Test func firesForAnEligibleCatchWhenTheRollHits() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(rng: &rng) != nil)
    }

    @Test func neverOnTheVeryFirstCatch() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(priorCatchCount: 0, rng: &rng) == nil)
        #expect(decide(priorCatchCount: 1, rng: &rng) != nil)
    }

    @Test func duplicateNeverFires() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(isDuplicate: true, rng: &rng) == nil)
    }

    @Test func suspectCatchNeverFires() {
        // Legacy gate-flagged rows remain ineligible for compatibility.
        var rng = ConstantRNG(value: 0)
        #expect(decide(isSuspect: true, rng: &rng) == nil)
    }

    @Test func multiCatchMemberNeverFires() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(isFreshSingle: false, rng: &rng) == nil)
    }

    @Test func noRenderableRouteNeverFires() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(routeAvailable: false, rng: &rng) == nil)
    }

    // ── Minimum gap ─────────────────────────────────────────────────────

    @Test func noForcedGapAfterARound() {
        var rng = ConstantRNG(value: 0)
        // Gap is 0 since 2026-11-11: the catch right after a round may fire
        // too — only the roll paces rounds now.
        #expect(GuessScheduler.minimumGapCatches == 0)
        #expect(decide(catchesSinceLastRound: 0, rng: &rng) != nil)
        #expect(decide(catchesSinceLastRound: 1, rng: &rng) != nil)
        #expect(decide(catchesSinceLastRound: 2, rng: &rng) != nil)
        // nil = never fired → no gap constraint.
        #expect(decide(catchesSinceLastRound: nil, rng: &rng) != nil)
    }

    @Test func firesRouteWhenEligible() {
        var rng = ConstantRNG(value: 0)
        #expect(decide(rng: &rng) == .route)
    }

    // ── Cadence distribution ────────────────────────────────────────────

    @Test func cadenceIsRoughlyTwoInThreeWhenUnconstrained() {
        // Pure roll probability, gap constraint out of the picture
        // (catchesSinceLastRound: nil each time).
        var rng = SeededRNG(seed: 42)
        var fired = 0
        let trials = 30_000
        for _ in 0..<trials where decide(rng: &rng) != nil { fired += 1 }
        let rate = Double(fired) / Double(trials)
        #expect(abs(rate - GuessScheduler.fireProbability) < 0.01,
                "fire rate \(rate) drifted from \(GuessScheduler.fireProbability)")
    }

    @Test func seededDeterminism() {
        func run(seed: UInt64) -> [GuessKind?] {
            var rng = SeededRNG(seed: seed)
            return (0..<200).map { _ in decide(rng: &rng) }
        }
        #expect(run(seed: 99) == run(seed: 99))
        #expect(run(seed: 99) != run(seed: 100))
    }
}

@Suite("GuessScheduler — UserDefaults wrapper")
@MainActor
struct GuessSchedulerWrapperTests {

    /// Isolated UserDefaults per test so parallel suites can't cross-talk
    /// and nothing leaks into the app's real counters.
    private func makeDefaults() -> UserDefaults {
        let name = "GuessSchedulerTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func recordCatch(
        _ scheduler: GuessScheduler,
        isDuplicate: Bool = false,
        rng: inout some RandomNumberGenerator
    ) -> GuessKind? {
        scheduler.decideForRecordedCatch(
            isFreshSingle: true,
            isDuplicate: isDuplicate,
            isSuspect: false,
            routeAvailable: true,
            using: &rng
        )
    }

    @Test func firstCatchNeverFiresAndCountersAdvance() {
        let defaults = makeDefaults()
        let scheduler = GuessScheduler(defaults: defaults)
        var rng = ConstantRNG(value: 0)

        // Catch #1: guarded. Catch #2: the roll (always-fire RNG) hits.
        #expect(recordCatch(scheduler, rng: &rng) == nil)
        #expect(recordCatch(scheduler, rng: &rng) != nil)
        #expect(defaults.integer(forKey: GuessScheduler.catchCountKey) == 2)
    }

    @Test func backToBackRoundsAllowedAcrossCalls() {
        let defaults = makeDefaults()
        let scheduler = GuessScheduler(defaults: defaults)
        var rng = ConstantRNG(value: 0)

        _ = recordCatch(scheduler, rng: &rng)                     // #1 guarded
        #expect(recordCatch(scheduler, rng: &rng) != nil)         // #2 fires
        #expect(recordCatch(scheduler, rng: &rng) != nil)         // #3 no gap → fires
        #expect(defaults.object(forKey: GuessScheduler.sinceLastRoundKey) as? Int == 0)
    }

    @Test func duplicatesArePureNoOps() {
        let defaults = makeDefaults()
        let scheduler = GuessScheduler(defaults: defaults)
        var rng = ConstantRNG(value: 0)

        #expect(recordCatch(scheduler, isDuplicate: true, rng: &rng) == nil)
        #expect(defaults.integer(forKey: GuessScheduler.catchCountKey) == 0)
        // A duplicate doesn't burn the first-catch guard either: the next
        // real catch is still the user's first.
        #expect(recordCatch(scheduler, rng: &rng) == nil)
    }

    @Test func countersPersistAcrossInstances() {
        let defaults = makeDefaults()
        var rng = ConstantRNG(value: 0)

        _ = recordCatch(GuessScheduler(defaults: defaults), rng: &rng)   // #1
        #expect(recordCatch(GuessScheduler(defaults: defaults), rng: &rng) != nil)  // #2 fires
        // Fresh instance, same defaults → it sees both counters from before.
        #expect(defaults.integer(forKey: GuessScheduler.catchCountKey) == 2)
        #expect(defaults.object(forKey: GuessScheduler.sinceLastRoundKey) as? Int == 0)
        _ = recordCatch(GuessScheduler(defaults: defaults), rng: &rng)   // #3
        #expect(defaults.integer(forKey: GuessScheduler.catchCountKey) == 3)
    }

    @Test func longRunNeverViolatesGapAndLandsNearBudget() {
        let defaults = makeDefaults()
        let scheduler = GuessScheduler(defaults: defaults)
        var rng = SeededRNG(seed: 2026)

        var firedAt: [Int] = []
        let catches = 6_000
        for i in 0..<catches where recordCatch(scheduler, rng: &rng) != nil {
            firedAt.append(i)
        }
        // No two rounds closer than the minimum gap (0 since 2026-11-11, so
        // this only rules out two rounds on the same catch).
        for pair in zip(firedAt, firedAt.dropFirst()) {
            #expect(pair.1 - pair.0 > GuessScheduler.minimumGapCatches)
        }
        // Long-run rate: no gap, so every catch after the first rolls at 2/3.
        // Assert a band — more frequent since 2026-11-11, but still clearly
        // not every catch.
        let rate = Double(firedAt.count) / Double(catches)
        #expect(rate > 0.62 && rate < 0.71, "long-run round rate \(rate) out of band")
    }
}
