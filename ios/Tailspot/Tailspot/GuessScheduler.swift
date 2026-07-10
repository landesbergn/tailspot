//
//  GuessScheduler.swift
//  Tailspot
//
//  Decides whether a freshly-recorded catch gets a pre-reveal BONUS ROUND
//  ("Where's it headed?" / "Call the type"), and which question kind.
//
//  The one hard product constraint (plan 2026-07-09-001 §A1, decision D3):
//  guessing is an occasional treat, never a per-catch tax. The field-polished
//  catch→reveal pacing is protected by cadence, not by a timer:
//    - only ELIGIBLE catches can fire: a fresh single catch — not a duplicate
//      ("already caught" awards no points, so there's nothing to bonus), not
//      part of a multi-catch, and not gate-suspect (don't stack a game on top
//      of the post-reveal Keep/Discard question);
//    - ~1-in-3 roll on eligible catches;
//    - minimum 2-catch gap after a round fires;
//    - never on the user's very first catch (protect activation).
//
//  Kind pick: when the catch is route-eligible (frozen route on the row AND
//  the option builder can render honest airport chips) it's a 50/50 between
//  route and type; otherwise type. Type itself requires a typecode with a
//  resolvable canonical name — a round we can't render honest options for
//  simply doesn't fire.
//
//  Split design, per the repo's testability convention (ADSBSource,
//  AnalyticsSink): a PURE nonisolated core (`decide`) that takes every input
//  explicitly — including the RNG, so tests are deterministic via SeededRNG —
//  and a thin MainActor wrapper that owns the two UserDefaults counters.
//

import Foundation

// MARK: - GuessKind

/// The bonus-round question kinds. Raw values are the wire enum for
/// `POST /v1/catches` `guess.kind` and the stored `Catch.guessKind` string —
/// they must match the backend's `GuessKind` in backend/src/catches/points.ts.
nonisolated enum GuessKind: String, CaseIterable, Sendable {
    case route
    case type
}

// MARK: - SeededRNG

/// Deterministic `RandomNumberGenerator` (SplitMix64) so scheduler and
/// option-set behavior is reproducible in tests and replayable in the field.
/// Production call sites use `SystemRandomNumberGenerator` via the
/// convenience overloads; SeededRNG exists for injection.
nonisolated struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - GuessScheduler

@MainActor
final class GuessScheduler {

    /// Probability an eligible, gap-clear, non-first catch fires a round
    /// (D3: "~1-in-3 eligible catches"). One constant — the kill switch the
    /// plan's risk #1 calls for lives here.
    nonisolated static let fireProbability: Double = 1.0 / 3.0

    /// Minimum number of recorded catches BETWEEN two rounds (D3: "min gap
    /// 2"). A round on catch N means catches N+1 and N+2 can never fire;
    /// N+3 is the first that can roll again.
    nonisolated static let minimumGapCatches = 2

    // MARK: Pure core

    /// The pure cadence + kind decision. Everything is an explicit input;
    /// same inputs + same RNG state → same decision, forever.
    ///
    /// - Parameters:
    ///   - isFreshSingle: a brand-new single-catch row (not part of a
    ///     `MultiCatchReveal` batch).
    ///   - isDuplicate: the tap re-caught an already-caught airframe (no new
    ///     row, no points — nothing to bonus).
    ///   - isSuspect: the authenticity gates flagged the catch
    ///     (`Catch.suspectReason != nil`) — the post-reveal Keep/Discard
    ///     question owns that moment.
    ///   - routeAvailable: frozen route on the row AND
    ///     `GuessOptions.routeAvailable` says honest chips can be built.
    ///   - typeAvailable: `GuessOptions.typeAvailable` — typecode with a
    ///     resolvable canonical name.
    ///   - priorCatchCount: recorded catches BEFORE this one (0 → this is the
    ///     user's very first catch → never fire).
    ///   - catchesSinceLastRound: recorded catches since a round last fired,
    ///     nil if no round has ever fired.
    /// - Returns: the question kind to ask, or nil for the (common) no-round
    ///   path.
    nonisolated static func decide(
        isFreshSingle: Bool,
        isDuplicate: Bool,
        isSuspect: Bool,
        routeAvailable: Bool,
        typeAvailable: Bool,
        priorCatchCount: Int,
        catchesSinceLastRound: Int?,
        using rng: inout some RandomNumberGenerator
    ) -> GuessKind? {
        // Eligibility guards — cheap, RNG-free, so an ineligible catch never
        // perturbs the random sequence (keeps seeded replays stable).
        guard isFreshSingle, !isDuplicate, !isSuspect else { return nil }
        guard routeAvailable || typeAvailable else { return nil }
        // Never the user's very first catch (activation protection).
        guard priorCatchCount >= 1 else { return nil }
        // Minimum gap after the last fired round.
        if let gap = catchesSinceLastRound, gap < minimumGapCatches { return nil }

        // The ~1-in-3 roll.
        guard Double.random(in: 0..<1, using: &rng) < fireProbability else { return nil }

        // Kind pick (D3): route-eligible → 50/50 route/type; else type.
        if routeAvailable && typeAvailable {
            return Bool.random(using: &rng) ? .route : .type
        }
        return routeAvailable ? .route : .type
    }

    // MARK: Stateful wrapper (UserDefaults counters)

    /// Total recorded (non-duplicate) catches seen by the scheduler.
    nonisolated static let catchCountKey = "guessScheduler.catchCount"
    /// Recorded catches since the last fired round. Absent = never fired.
    nonisolated static let sinceLastRoundKey = "guessScheduler.catchesSinceLastRound"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Decide for one catch event AND advance the persistent counters.
    /// Call exactly once per catch reveal (PR3 wires this into the
    /// `performCatch` → reveal sequencing).
    ///
    /// Counter semantics: duplicates are a pure no-op (no new row was
    /// recorded, so they neither count toward the total nor burn the gap).
    /// Every other catch — including ineligible ones like suspects and
    /// multi-catch members — advances both counters: pacing is about how
    /// many catches the user experienced, not how many were quiz-worthy.
    func decideForRecordedCatch(
        isFreshSingle: Bool,
        isDuplicate: Bool,
        isSuspect: Bool,
        routeAvailable: Bool,
        typeAvailable: Bool,
        using rng: inout some RandomNumberGenerator
    ) -> GuessKind? {
        let prior = defaults.integer(forKey: Self.catchCountKey)
        let gap = defaults.object(forKey: Self.sinceLastRoundKey) as? Int

        let kind = Self.decide(
            isFreshSingle: isFreshSingle,
            isDuplicate: isDuplicate,
            isSuspect: isSuspect,
            routeAvailable: routeAvailable,
            typeAvailable: typeAvailable,
            priorCatchCount: prior,
            catchesSinceLastRound: gap,
            using: &rng
        )

        if !isDuplicate {
            defaults.set(prior + 1, forKey: Self.catchCountKey)
            if kind != nil {
                defaults.set(0, forKey: Self.sinceLastRoundKey)
            } else if let gap {
                defaults.set(gap + 1, forKey: Self.sinceLastRoundKey)
            }
        }
        return kind
    }

    /// Production convenience — system RNG.
    func decideForRecordedCatch(
        isFreshSingle: Bool,
        isDuplicate: Bool,
        isSuspect: Bool,
        routeAvailable: Bool,
        typeAvailable: Bool
    ) -> GuessKind? {
        var rng = SystemRandomNumberGenerator()
        return decideForRecordedCatch(
            isFreshSingle: isFreshSingle,
            isDuplicate: isDuplicate,
            isSuspect: isSuspect,
            routeAvailable: routeAvailable,
            typeAvailable: typeAvailable,
            using: &rng
        )
    }
}
