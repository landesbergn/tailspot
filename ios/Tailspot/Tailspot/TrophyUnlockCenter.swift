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

/// The one-time "trophy case" recap shown on first launch after a roster
/// expansion (or the very first seed), so existing testers get one
/// celebratory moment instead of a per-trophy celebration flood. Carries
/// the full earned set so the recap sheet can render the actual trophies,
/// not just a count.
nonisolated struct TrophyRecap: Equatable, Sendable {
    /// Every achievement earned under the CURRENT roster, in roster order
    /// (earned secrets included — earning reveals them, house rule).
    let achievements: [Achievement]
    var earned: Int { achievements.count }
}

@MainActor
final class TrophyUnlockCenter: ObservableObject {
    /// FIFO queue of newly-crossed trophies awaiting their moment.
    @Published private(set) var pendingEvents: [TrophyUnlockEvent] = []
    /// A pending one-time recap, or nil. Presented before the queue.
    @Published private(set) var pendingRecap: TrophyRecap?

    private let ledger: UserDefaultsTrophyLedger
    private let roster: [Achievement]
    /// Event-based trophy inputs (e.g. the grounded easter egg's
    /// `triedGroundedCatch`) — injectable so tests stay suite-isolated.
    private let events: TrophyEventStore
    /// The roster generation this build ships (injectable for tests). See
    /// `Trophies.rosterVersion` for the stamp/reseed/recap contract.
    private let rosterVersion: Int

    init(
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        roster: [Achievement] = Trophies.roster,
        events: TrophyEventStore = TrophyEventStore(),
        rosterVersion: Int = Trophies.rosterVersion
    ) {
        self.ledger = ledger
        self.roster = roster
        self.events = events
        self.rosterVersion = rosterVersion
    }

    var head: TrophyUnlockEvent? { pendingEvents.first }
    var hasPending: Bool { pendingRecap != nil || !pendingEvents.isEmpty }

    /// Diff the Hangar against the ledger and queue newly-crossed trophies.
    ///
    /// Two paths bypass the diff and (re)seed instead:
    ///  • an UNSEEDED ledger (first launch with the unlock machinery), so no
    ///    path — catch flow or tab-open fallback — can flood an existing
    ///    tester; `pending()` never runs against an unseeded ledger.
    ///  • a STALE ROSTER STAMP (`ledger.rosterVersion < rosterVersion`): the
    ///    roster grew since this device last seeded, so newly-added trophies
    ///    the user already qualifies for (e.g. Four Figures on an existing
    ///    2,000-point Hangar) are acknowledged silently and recapped as ONE
    ///    "trophy case" moment instead of a toast flood.
    /// Both stamp the current roster version and queue the recap only when
    /// something is actually earned — a fresh install never sees it.
    /// Callers should fire this once at app launch so the seed lands before
    /// the user's first crossing.
    func enqueueNewUnlocks(from catches: [Catch]) {
        let inputs = Trophies.inputs(from: catches, events: events)
        guard ledger.isSeeded, ledger.rosterVersion >= rosterVersion else {
            TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
            ledger.markRosterVersion(rosterVersion)
            queueRecapIfNeeded(inputs: inputs)
            return
        }
        let fresh = TrophyUnlock.pending(inputs: inputs, roster: roster, ledger: ledger)
        for event in fresh where !pendingEvents.contains(event) {
            pendingEvents.append(event)
        }
    }

    /// After a bulk Hangar restore, silently re-align the ledger with the
    /// restored collection: acknowledge every currently-earned tier (the same
    /// seed used on first launch) and drop anything queued, so the diff task
    /// that fires when the restored rows land finds nothing to celebrate.
    /// Restored trophies live in the trophy case — they were earned long ago
    /// and must not re-toast one by one. Deliberately NO recap either: the
    /// restore success screen is the moment; a second overlay would pile on.
    func reseedAfterRestore(from catches: [Catch]) {
        let inputs = Trophies.inputs(from: catches, events: events)
        TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
        // A restore only ever runs on an empty Hangar, so anything pending
        // predates it and is now stale relative to the seeded state.
        pendingEvents.removeAll()
    }

    /// Commit-on-shown: the instant a celebration is presented, record its
    /// tier as acknowledged. A crash mid-celebration can then at worst
    /// re-show an in-progress moment — never re-fire a fully-seen one.
    func markShown(_ event: TrophyUnlockEvent) {
        // Fire analytics exactly once per crossing. If the tier is already
        // acknowledged, this is a re-presentation (the overlay unmounted and
        // remounted — e.g. a sheet opened and closed while the event was
        // parked at the head), so commit silently without a duplicate event.
        let alreadyShown = ledger.acknowledgedOrdinal(for: event.achievementID) >= event.newTier.ordinal
        ledger.setAcknowledged(event.newTier.ordinal, for: event.achievementID)
        guard !alreadyShown else { return }
        Analytics.capture("trophy_unlocked", [
            "achievement": .string(event.achievementID),
            "secret": .bool(event.achievement.secret),
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

    /// Dismiss the one-time recap. One-time-ness lives in the roster-version
    /// stamp (written at reseed time, before presentation) — a crash mid-recap
    /// loses the moment rather than ever re-flooding, the same trade the
    /// seeding path has always made.
    func dismissRecap() {
        if let recap = pendingRecap {
            Analytics.capture("trophy_recap_shown", [
                "earned": .int(recap.earned),
                "roster_version": .int(rosterVersion),
            ])
        }
        pendingRecap = nil
    }

    private func queueRecapIfNeeded(inputs: TrophyProgressInputs) {
        let earned = roster.filter { $0.isEarned(inputs: inputs) }
        // Nothing earned (fresh install, or an install that never caught) →
        // no recap; the version stamp is already written, so no re-check.
        guard !earned.isEmpty else { return }
        pendingRecap = TrophyRecap(achievements: earned)
    }

    #if DEBUG
    /// Force a sample event onto the queue so the celebration path (anim +
    /// haptic + a11y + hidden reveal) can be exercised on-device without
    /// waiting for an organic crossing — several new trophies are hard to
    /// trigger solo. Wired into the debug overlay.
    func debugEnqueueSample(secret: Bool) {
        let id = secret ? "redeye" : "catcher"
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
