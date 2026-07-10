//
//  GuessRound.swift
//  Tailspot
//
//  The value types for the in-card ROUTE BONUS ROUND (game-layer PR3; route-only
//  per Noah 2026-07-09; redesigned in-card per Noah 2026-07-10). The player-facing
//  UI is NOT here — it lives ON the reveal card (`RouteBonusRound` inside
//  CatchRevealView), so the guess and the reveal are one fluid surface instead of
//  a separate pre-reveal screen (the old `GuessRoundView` full-screen cover was
//  removed). What survives here is the pure, off-MainActor logic:
//
//    - `GuessRoundQuestion` — the route prompt + 4 chips + correct value the card
//      renders. Built by ContentView from `GuessOptions`.
//    - `GuessRoundPlanner` — the pure eligibility translation (catch batch shape +
//      frozen route → GuessScheduler inputs), so ContentView's sequencing stays a
//      thin, unit-tested call.
//
//  Both are `nonisolated` per repo convention (pure value data / geometry).
//

import Foundation

// MARK: - GuessRoundQuestion

/// The route question the reveal card renders as its bonus round. Built by the
/// caller (ContentView) from `GuessOptions`, so the card stays a pure renderer of
/// a prompt + 4 chips + a resolution callback. `nonisolated` per repo convention
/// (pure value data wrapping a Sendable option set).
nonisolated struct GuessRoundQuestion: Equatable, Sendable {
    let route: GuessOptions.RouteQuestion

    /// The wire/stored kind — always `.route` (type guessing was cut).
    var kind: GuessKind { .route }

    /// The 4 shuffled option chips (correct answer embedded).
    var options: [GuessOptions.Option] { route.options }

    /// The correct option's `value` — the local verdict compares a tap's
    /// `value` against this (`tapped.value == correctValue`).
    var correctValue: String { route.correctValue }

    /// The prompt copy — keyed off the asked endpoint (the one farther from
    /// the observer).
    var prompt: String {
        switch route.endpoint {
        case .origin:      return "Where's it coming from?"
        case .destination: return "Where's it headed?"
        }
    }
}

// MARK: - GuessRoundPlanner

/// The pure translation from a catch batch + its single fresh row to the
/// `GuessScheduler` inputs — factored out of ContentView so the "should this
/// catch get a bonus round?" decision is unit-testable off the MainActor and
/// ContentView's sequencing stays a thin call. `nonisolated` per convention.
///
/// NOTE the round is offered ONLY for a fresh single catch (a duplicate awards
/// no points to bonus; a multi-catch owns its own `MultiCatchReveal`; a
/// suspect stacks a Keep/Discard question we don't game on top of). The
/// scheduler still owns cadence — this only derives its inputs.
nonisolated enum GuessRoundPlanner {

    /// The `GuessScheduler` inputs a catch batch produces.
    struct Inputs: Equatable, Sendable {
        /// Exactly one fresh row and no duplicates — the only shape eligible
        /// for a round (the batch gate).
        let isFreshSingle: Bool
        /// The row was gate-flagged (`Catch.suspectReason != nil`).
        let isSuspect: Bool
        /// A route question can be built from the row's frozen endpoints.
        let routeAvailable: Bool

        /// A round can only fire when the batch is a fresh single AND a route
        /// question can render honest options. (Cadence + the suspect guard
        /// are the scheduler's call, not this flag's.)
        var canOfferRound: Bool {
            isFreshSingle && routeAvailable
        }
    }

    static func inputs(
        freshCount: Int,
        duplicateCount: Int,
        suspectReason: String?,
        originIcao: String?,
        destIcao: String?
    ) -> Inputs {
        Inputs(
            isFreshSingle: freshCount == 1 && duplicateCount == 0,
            isSuspect: suspectReason != nil,
            routeAvailable: GuessOptions.routeAvailable(originIcao: originIcao, destIcao: destIcao)
        )
    }
}
