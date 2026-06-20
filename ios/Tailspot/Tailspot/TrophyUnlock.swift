//
//  TrophyUnlock.swift
//  Tailspot
//
//  The pure detection half of the unlock-moment machinery: diff the
//  user's current earned-state (derived from the Hangar) against the
//  `UserDefaultsTrophyLedger` (what they've already been shown), and
//  emit one event per *newly crossed* trophy.
//
//  Pure free functions — no side effects in `pending`, no UI — so they
//  unit-test directly against a fixture ledger on an isolated suite.
//  Consumed by `TrophyUnlockCenter` (the @MainActor queue/presenter).
//

import Foundation

/// What kind of crossing a `TrophyUnlockEvent` represents — drives the
/// celebration copy ("UNLOCKED" vs "NEW · SILVER").
nonisolated enum TrophyUnlockKind: Sendable, Equatable {
    /// A one-of-one badge went from locked to earned.
    case badgeEarned
    /// A leveled medal reached a new tier.
    case tierUp
}

/// One newly-unlocked trophy, ready to celebrate.
nonisolated struct TrophyUnlockEvent: Identifiable, Sendable, Equatable {
    let achievement: Achievement
    /// The tier just reached (highest reached when a single catch jumps
    /// multiple tiers — the diff collapses the jump to one event).
    let newTier: TrophyTier
    let kind: TrophyUnlockKind

    var achievementID: String { achievement.id }

    /// Dedupe + identity key: `achievementID#tierOrdinal`. Two enqueues of
    /// the same crossing collapse to one; SwiftUI uses it for `id`.
    var id: String { "\(achievement.id)#\(newTier.ordinal)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

nonisolated enum TrophyUnlock {

    /// Newly-crossed trophies: for each achievement whose current tier
    /// ordinal exceeds the ledger's acknowledged ordinal, one event at
    /// the current (highest-reached) tier. Deterministic roster order.
    /// Pure — reads the ledger, writes nothing.
    static func pending(
        inputs: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        ledger: UserDefaultsTrophyLedger
    ) -> [TrophyUnlockEvent] {
        var events: [TrophyUnlockEvent] = []
        for ach in roster {
            guard let current = ach.currentTier(inputs: inputs) else { continue }
            if current.ordinal > ledger.acknowledgedOrdinal(for: ach.id) {
                let kind: TrophyUnlockKind = ach.isOneShot ? .badgeEarned : .tierUp
                events.append(TrophyUnlockEvent(achievement: ach, newTier: current, kind: kind))
            }
        }
        return events
    }

    /// Seed the ledger to the current earned-state, emitting nothing. Run
    /// once on first launch after this update so an existing tester's
    /// already-earned trophies don't flood them with celebrations — only
    /// crossings *after* seeding produce moments. Marks the ledger seeded.
    static func seed(
        inputs: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        into ledger: UserDefaultsTrophyLedger
    ) {
        for ach in roster {
            if let current = ach.currentTier(inputs: inputs) {
                ledger.setAcknowledged(current.ordinal, for: ach.id)
            }
        }
        ledger.markSeeded()
    }
}
