//
//  TrophyUnlockCenter.swift
//  Tailspot
//
//  The @MainActor owner of the unlock-moment queue: diffs the Hangar
//  against the `UserDefaultsTrophyLedger`, holds the pending celebration
//  events (and the one-time recap), and commits acknowledgments.
//
//  Owned once at the app root (`@StateObject`) so it survives the Hangar
//  sheet lifecycle and seeds exactly once. The celebration overlay
//  (`TrophyUnlockView`) reads `head` / `pendingRecap` and drives the queue
//  via `markShown` / `advance` / `dismissRecap`.
//
//  Pure-state class — uses `@Published` without importing SwiftUI, so it
//  imports Combine explicitly (CLAUDE.md convention).
//

import Foundation
import Combine

/// The one-time "trophy case" summary shown on first launch after this
/// update, so existing testers learn the feature exists without a
/// per-trophy celebration flood.
nonisolated struct TrophyRecap: Equatable, Sendable {
    let medals: Int
    let badges: Int
}

@MainActor
final class TrophyUnlockCenter: ObservableObject {
    /// FIFO queue of newly-crossed trophies awaiting their moment.
    @Published private(set) var pendingEvents: [TrophyUnlockEvent] = []
    /// A pending one-time recap, or nil. Presented before the queue.
    @Published private(set) var pendingRecap: TrophyRecap?

    private let ledger: UserDefaultsTrophyLedger
    private let roster: [Achievement]

    init(
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        roster: [Achievement] = Trophies.roster
    ) {
        self.ledger = ledger
        self.roster = roster
    }

    var head: TrophyUnlockEvent? { pendingEvents.first }
    var hasPending: Bool { pendingRecap != nil || !pendingEvents.isEmpty }

    /// Diff the Hangar against the ledger and queue newly-crossed trophies.
    ///
    /// The FIRST call on an unseeded ledger **seeds instead of diffing** (and
    /// may queue the one-time recap), so no path — catch flow or tab-open
    /// fallback — can flood an existing tester. `pending()` therefore never
    /// runs against an unseeded ledger. Callers should fire this once at app
    /// launch so the seed lands before the user's first crossing.
    func enqueueNewUnlocks(from catches: [Catch]) {
        let inputs = Trophies.inputs(from: catches)
        guard ledger.isSeeded else {
            TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
            queueRecapIfNeeded(inputs: inputs)
            return
        }
        let fresh = TrophyUnlock.pending(inputs: inputs, roster: roster, ledger: ledger)
        for event in fresh where !pendingEvents.contains(event) {
            pendingEvents.append(event)
        }
    }

    /// Commit-on-shown: the instant a celebration is presented, record its
    /// tier as acknowledged. A crash mid-celebration can then at worst
    /// re-show an in-progress moment — never re-fire a fully-seen one.
    func markShown(_ event: TrophyUnlockEvent) {
        ledger.setAcknowledged(event.newTier.ordinal, for: event.achievementID)
        Analytics.capture("trophy_unlocked", [
            "achievement": .string(event.achievementID),
            "tier": .string(event.newTier.label),
            "kind": .string(event.kind == .badgeEarned ? "badge" : "tier_up"),
            "hidden": .bool(event.achievement.hidden),
        ])
    }

    /// Pop the head after it's been seen (tap-to-dismiss advances the queue).
    func advance() {
        if !pendingEvents.isEmpty { pendingEvents.removeFirst() }
    }

    /// Skip-all: acknowledge and clear the whole queue in one go.
    func skipAll() {
        for event in pendingEvents {
            ledger.setAcknowledged(event.newTier.ordinal, for: event.achievementID)
        }
        pendingEvents.removeAll()
    }

    /// Dismiss the one-time recap (and never show it again).
    func dismissRecap() {
        if let recap = pendingRecap {
            Analytics.capture("trophy_recap_shown", [
                "medals": .int(recap.medals),
                "badges": .int(recap.badges),
            ])
        }
        ledger.markRecapShown()
        pendingRecap = nil
    }

    private func queueRecapIfNeeded(inputs: TrophyProgressInputs) {
        guard !ledger.recapShown else { return }
        let earned = roster.filter { !$0.isLocked(inputs: inputs) }
        // Nothing earned (fresh install) → no recap; mark shown so we don't
        // re-check on every launch.
        guard !earned.isEmpty else { ledger.markRecapShown(); return }
        pendingRecap = TrophyRecap(
            medals: earned.filter(\.isLeveled).count,
            badges: earned.filter(\.isOneShot).count
        )
    }

    #if DEBUG
    /// Force a sample event onto the queue so the celebration path (anim +
    /// haptic + a11y + hidden reveal) can be exercised on-device without
    /// waiting for an organic crossing — several new trophies are hard to
    /// trigger solo. Wired into the debug overlay.
    func debugEnqueueSample(hidden: Bool) {
        let id = hidden ? "redeye" : "catcher"
        guard let ach = roster.first(where: { $0.id == id }) ?? roster.first else { return }
        let tier = ach.tiers.first?.tier ?? .bronze
        let event = TrophyUnlockEvent(
            achievement: ach, newTier: tier,
            kind: ach.isOneShot ? .badgeEarned : .tierUp
        )
        if !pendingEvents.contains(event) { pendingEvents.append(event) }
    }
    #endif
}
