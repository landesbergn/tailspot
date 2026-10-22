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

/// Content token for everything `Trophies.inputs` reads, so a caller can
/// memoize the inputs and skip the full-Hangar pass when nothing changed.
///
/// `CatchFingerprint` covers the row fields the Hangar views read, but
/// `Trophies.inputs` reads three more things it doesn't hash:
///  • `guessCorrect` — the bonus round sets it AFTER the row is saved, and
///    it drives Sharp Eye / Hot Streak;
///  • `caughtDayKey` — the frozen streak day (nil on legacy rows, which
///    then bucket in the CURRENT time zone);
///  • the current time zone itself — the hour-of-day trophies (night,
///    red-eye, dawn, weekend) read `caughtAt` through a calendar in the
///    phone's zone, so flying home can change them without a row edit.
/// Plus the two UserDefaults-backed stores (grounded easter-egg events,
/// cached leaderboard standing). Missing any of these would serve stale
/// inputs, and a stale input is a missed (or late) celebration.
///
/// Cost: two cheap hashing passes over the rows — a few field reads each,
/// far less than one `inputs` pass (no rarity/type lookups, no set
/// matching, no calendar math).
enum TrophyInputsToken {
    static func of(
        _ catches: [Catch],
        events: TrophyEventStore = TrophyEventStore(),
        standing: LeaderboardStandingCache = LeaderboardStandingCache(),
        timeZone: TimeZone = .current
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(CatchFingerprint.of(catches))
        for c in catches {
            hasher.combine(c.guessCorrect)
            hasher.combine(c.caughtDayKey)
        }
        hasher.combine(timeZone.identifier)
        for event in TrophyEventStore.Event.allCases {
            hasher.combine(events.count(of: event))
        }
        hasher.combine(standing.weeklyWins)
        hasher.combine(standing.everToppedAllTime)
        return hasher.finalize()
    }
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
    /// Server-fact trophy inputs (weekly wins / ever-topped-all-time, cached
    /// from leaderboard fetches) — injectable for the same suite isolation.
    private let standing: LeaderboardStandingCache
    /// The roster generation this build ships (injectable for tests). See
    /// `Trophies.rosterVersion` for the stamp/reseed/recap contract.
    private let rosterVersion: Int
    /// Achievement dates the last synchronous pass ran out of budget for —
    /// drained by `finishAchievementDates()` off the launch path.
    private var pendingDateBackfill: (catches: [Catch], inputs: TrophyProgressInputs)?
    /// The last inputs this center computed, keyed by `TrophyInputsToken`.
    /// Most re-diffs see an unchanged Hangar — every sheet close, a grounded
    /// tap, the second diff of a catch whose geocode found nothing new — and
    /// on a big Hangar each full `Trophies.inputs` pass is hundreds of ms on
    /// the main thread (0.42 s at 4,600 catches). A token match reuses these
    /// inputs, so those re-diffs cost a hashing pass instead.
    private var memo: (token: Int, inputs: TrophyProgressInputs)?

    #if DEBUG
    /// How many full-Hangar `Trophies.inputs` passes this center has run
    /// (memo misses). Test-only instrumentation: LargeHangarBudgetTests pins
    /// "an unchanged diff does 0 passes, one new catch does exactly 1" so
    /// the next per-catch cost slip fails a test instead of a big Hangar.
    private(set) var fullInputsPasses = 0
    #endif

    init(
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        roster: [Achievement] = Trophies.roster,
        events: TrophyEventStore = TrophyEventStore(),
        standing: LeaderboardStandingCache = LeaderboardStandingCache(),
        rosterVersion: Int = Trophies.rosterVersion
    ) {
        self.ledger = ledger
        self.roster = roster
        self.events = events
        self.standing = standing
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
    ///
    /// Memoized: when the Hangar (and the event/standing stores) haven't
    /// changed since the last call, the previous inputs are reused and the
    /// bounded date pass is skipped — it already ran for these exact inputs,
    /// and anything it parked is still parked. The ledger diff itself always
    /// runs (it's cheap), so acknowledgments made since the last call count.
    func enqueueNewUnlocks(from catches: [Catch]) {
        let token = TrophyInputsToken.of(catches, events: events, standing: standing)
        let inputs: TrophyProgressInputs
        if let memo, memo.token == token {
            inputs = memo.inputs
        } else {
            inputs = computeInputs(catches, token: token)
            recordDatesWithinBudget(catches: catches, inputs: inputs)
        }
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
        let token = TrophyInputsToken.of(catches, events: events, standing: standing)
        let inputs = computeInputs(catches, token: token)
        recordDatesWithinBudget(catches: catches, inputs: inputs)
        TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
        // A restore only ever runs on an empty Hangar, so anything pending
        // predates it and is now stale relative to the seeded state.
        pendingEvents.removeAll()
    }

    /// The one place this center runs a full-Hangar `Trophies.inputs` pass;
    /// stores the result as the memo for `token`.
    private func computeInputs(_ catches: [Catch], token: Int) -> TrophyProgressInputs {
        let inputs = Trophies.inputs(from: catches, events: events, standing: standing)
        memo = (token, inputs)
        #if DEBUG
        fullInputsPasses += 1
        #endif
        return inputs
    }

    /// Date what one prefix pass can — the newest-catch fast path, which
    /// covers every live unlock — and park the rest. Achievement dates must
    /// never block the caller: an upgrade with thousands of catches needs
    /// tens of full-Hangar passes (the 1.2.0 launch hang).
    private func recordDatesWithinBudget(catches: [Catch], inputs: TrophyProgressInputs) {
        let done = TrophyAchievementDates.recordMissing(
            from: catches, inputs: inputs, roster: roster, ledger: ledger,
            events: events, maxEvaluations: 1)
        pendingDateBackfill = done ? nil : (catches, inputs)
    }

    /// Finish the dates the last `enqueueNewUnlocks`/`reseedAfterRestore`
    /// left over, yielding to the UI between passes. Call from a `.task` so
    /// it is cancelled with its view; a cancelled run keeps what it found.
    func finishAchievementDates() async {
        guard let pending = pendingDateBackfill else { return }
        pendingDateBackfill = nil
        await TrophyAchievementDates.backfill(
            from: pending.catches, inputs: pending.inputs, roster: roster,
            ledger: ledger, events: events)
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
            "title": .string(event.achievement.title),
            "tier": .string(event.newTier.rawValue),
            "kind": .string(event.kind == .badgeEarned ? "badge" : "tier_up"),
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
