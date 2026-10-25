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

/// The one-time "trophy case" recap shown on the very first seed (every
/// earned trophy, e.g. an older install meeting the unlock machinery), so
/// that user gets one celebratory moment instead of a per-trophy flood. A
/// roster-bump reseed does NOT use it: its few new grants get ordinary
/// unlock cards (see `enqueueNewUnlocks`). Carries the trophies
/// themselves so the recap sheet can render them, not just a count.
nonisolated struct TrophyRecap: Equatable, Sendable {
    /// The recapped achievements, in roster order (earned secrets included
    /// — earning reveals them, house rule).
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
/// Plus the two UserDefaults-backed stores (whether each easter-egg event
/// has occurred, cached leaderboard standing). Missing any of these would
/// serve stale inputs, and a stale input is a missed (or late) celebration.
///
/// ORDER-INDEPENDENT: each row is hashed on its own and the row hashes are
/// summed, so the same rows in any order give the same token. The callers
/// fetch in different orders (the app root's and the Trophies tab's
/// `@Query` are unsorted, Profile's is newest-first), and `Trophies.inputs`
/// itself doesn't care about order (its streak/window helpers sort by time
/// first). An order-sensitive token would make the shared `TrophyInputsMemo`
/// miss every time a different screen asked.
///
/// Cost: one cheap hashing pass over the rows — a few field reads each,
/// far less than one `inputs` pass (no rarity/type lookups, no set
/// matching, no calendar math).
enum TrophyInputsToken {
    static func of(
        _ catches: [Catch],
        events: TrophyEventStore = TrophyEventStore(),
        standing: LeaderboardStandingCache = LeaderboardStandingCache(),
        timeZone: TimeZone = .current
    ) -> Int {
        // `&+=` is wrapping addition: overflow wraps around instead of
        // trapping, which is what a hash sum wants. Addition commutes, so
        // the sum doesn't depend on row order.
        var rowSum = 0
        for c in catches {
            var row = Hasher()
            CatchFingerprint.combine(c, into: &row)
            row.combine(c.guessCorrect)
            row.combine(c.caughtDayKey)
            rowSum &+= row.finalize()
        }
        var hasher = Hasher()
        hasher.combine(catches.count)
        hasher.combine(rowSum)
        hasher.combine(timeZone.identifier)
        // `hasOccurred`, not `count(of:)`: the inputs only read whether an
        // event ever happened, and `record` bumps the counter on EVERY call.
        // Hashing the count made each grounded tap a guaranteed memo miss
        // (a hashing pass plus a full pass); hashing the flag makes only the
        // first tap — the one that can earn Ground Stop — miss.
        for event in TrophyEventStore.Event.allCases {
            hasher.combine(events.hasOccurred(event))
        }
        hasher.combine(standing.weeklyWins)
        hasher.combine(standing.everToppedAllTime)
        return hasher.finalize()
    }
}

/// One memoized `Trophies.inputs` result, keyed by `TrophyInputsToken`,
/// shared by everything that needs the inputs for the live Hangar: the
/// app-root `TrophyUnlockCenter`, the Hangar's Trophies tab and Profile.
///
/// Why shared: the center already computes the inputs at launch and after
/// each catch, but the Trophies tab and Profile each kept their own memo in
/// view `@State`, which dies when their sheet closes. So every Hangar or
/// Profile open re-ran the full pass the center had just done (~1 s on the
/// main thread at 10k catches in a Debug build). With one shared entry, an
/// open after the center's diff is a token compare.
///
/// One entry is enough: all three callers ask about the same Hangar, so
/// they all want the latest token. Tests build their own instance (the
/// center's default) so they never see the app's cached inputs.
@MainActor
final class TrophyInputsMemo {
    static let shared = TrophyInputsMemo()

    private var entry: (token: Int, inputs: TrophyProgressInputs)?

    /// `nonisolated` so it can be a default argument (`= TrophyInputsMemo()`
    /// on the center's init): Swift evaluates default arguments outside the
    /// main actor. Safe, since it only sets `entry` to nil.
    nonisolated init() {}

    func cached(for token: Int) -> TrophyProgressInputs? {
        guard let entry, entry.token == token else { return nil }
        return entry.inputs
    }

    func store(_ inputs: TrophyProgressInputs, for token: Int) {
        entry = (token, inputs)
    }

    /// The cached inputs for `token`, or `compute()`'s result (stored).
    func inputs(for token: Int, compute: () -> TrophyProgressInputs) -> TrophyProgressInputs {
        if let hit = cached(for: token) { return hit }
        let fresh = compute()
        store(fresh, for: token)
        return fresh
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
    /// `Trophies.rosterVersion` for the stamp/reseed contract.
    private let rosterVersion: Int
    /// Achievement dates the last synchronous pass ran out of budget for —
    /// drained by `finishAchievementDates()` off the launch path.
    private var pendingDateBackfill: (catches: [Catch], inputs: TrophyProgressInputs)?
    /// Memoized inputs, keyed by `TrophyInputsToken`. Most re-diffs see an
    /// unchanged Hangar — every sheet close, every grounded tap after the
    /// first — and on a big Hangar each full `Trophies.inputs` pass is
    /// hundreds of ms on the main thread (0.42 s at 4,600 catches). A token
    /// match reuses the inputs, so those re-diffs cost a hashing pass
    /// instead. The app passes `TrophyInputsMemo.shared`, so the Trophies tab
    /// and Profile reuse what this center computed (and vice versa).
    private let inputsMemo: TrophyInputsMemo
    /// The token the last bounded date pass ran for. A screen can fill the
    /// shared memo too, so "memo hit" no longer means "dates already
    /// attempted for these inputs"; this does.
    private var datesToken: Int?
    /// Whether the last bounded date pass (for `datesToken`) found nothing
    /// left to date. A hit skips that pass, which is only safe
    /// when the dates are done or the remainder is still parked: a
    /// `finishAchievementDates` run takes the parked work and may stop early
    /// (cancelled with its view, or a row deleted mid-run), and without this
    /// flag no later hit would re-park it, so those trophies would never get
    /// a date until some unrelated row change busted the memo.
    private var memoDatesDone = false

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
        rosterVersion: Int = Trophies.rosterVersion,
        inputsMemo: TrophyInputsMemo = TrophyInputsMemo()
    ) {
        self.inputsMemo = inputsMemo
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
    ///    2,000-point Hangar) are acknowledged in the ledger and each one is
    ///    queued as an ordinary "NEW TROPHY" card, the same card a live
    ///    unlock gets (with "SKIP ALL" when several are pending). Only what
    ///    the reseed newly acknowledged (earned now, not in the previous
    ///    ledger) is queued — a user with nothing new sees nothing — and
    ///    each fires `trophy_unlocked` with `via: "reseed"` here (the card's
    ///    `markShown` then stays silent because the tier is already
    ///    acknowledged), so the bump's effect is visible in analytics.
    /// Both stamp the current roster version. Only the first-ever seed queues
    /// the one-time "trophy case" recap (it can cover a whole Hangar, where
    /// per-trophy cards would flood), and only when something is earned — a
    /// fresh install never sees it.
    /// Callers should fire this once at app launch so the seed lands before
    /// the user's first crossing.
    ///
    /// Memoized: when the Hangar (and the event/standing stores) haven't
    /// changed since the inputs were last computed (here, or by a screen
    /// sharing the `TrophyInputsMemo`), they are reused and the
    /// bounded date pass is skipped — it already ran for these exact inputs
    /// — unless it left work that is no longer parked (a backfill that was
    /// interrupted), in which case it runs again to re-park the rest. The
    /// ledger diff itself always
    /// runs (it's cheap), so acknowledgments made since the last call count.
    ///
    /// Trade-off: the token is hashed on EVERY call, including the two that
    /// are certain to miss after a catch (the count task, then the
    /// post-geocode re-diff, which only fires when the geocoder stamped
    /// something). So the catch path pays two hashing passes on top of the
    /// full passes it already ran (LargeHangarBudgetTests logs the split).
    /// Skipping the hash on a count change was considered and rejected: the
    /// memo would then hold no token, and the next sheet close would pay a
    /// full pass instead of a hit — a launch diff followed by one sheet close
    /// would be two full passes every session. A save-notification or
    /// generation counter would remove the hash entirely; not built yet.
    func enqueueNewUnlocks(from catches: [Catch]) {
        let token = TrophyInputsToken.of(catches, events: events, standing: standing)
        let inputs = inputsMemo.cached(for: token) ?? computeInputs(catches, token: token)
        if datesToken != token {
            recordDatesWithinBudget(catches: catches, inputs: inputs, token: token)
        } else if !memoDatesDone, pendingDateBackfill == nil {
            // Resume an interrupted backfill (see `memoDatesDone`). Once the
            // dates are done this is skipped; until then each hit costs at
            // most one bounded probe, same as a miss.
            recordDatesWithinBudget(catches: catches, inputs: inputs, token: token)
        }
        guard ledger.isSeeded else {
            TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
            ledger.markRosterVersion(rosterVersion)
            queueRecap(roster.filter { $0.isEarned(inputs: inputs) })
            return
        }
        guard ledger.rosterVersion >= rosterVersion else {
            // Diff BEFORE the seed overwrites the ledger: these are the
            // trophies this reseed is about to acknowledge for the first time.
            let newlyAcknowledged = TrophyUnlock.pending(inputs: inputs, roster: roster, ledger: ledger)
            TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
            ledger.markRosterVersion(rosterVersion)
            // Present each grant as a normal "NEW TROPHY" card. The seed above
            // already acknowledged them, so `markShown` treats the card as a
            // re-presentation and fires nothing — the reseed event below is
            // the one `trophy_unlocked` per grant.
            for event in newlyAcknowledged where !pendingEvents.contains(event) {
                Analytics.capture("trophy_unlocked", Self.unlockProperties(event, via: "reseed"))
                pendingEvents.append(event)
            }
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
        recordDatesWithinBudget(catches: catches, inputs: inputs, token: token)
        TrophyUnlock.seed(inputs: inputs, roster: roster, into: ledger)
        // A restore only ever runs on an empty Hangar, so anything pending
        // predates it and is now stale relative to the seeded state.
        pendingEvents.removeAll()
    }

    /// The one place this center runs a full-Hangar `Trophies.inputs` pass;
    /// stores the result as the memo for `token`.
    private func computeInputs(_ catches: [Catch], token: Int) -> TrophyProgressInputs {
        let inputs = Trophies.inputs(from: catches, events: events, standing: standing)
        inputsMemo.store(inputs, for: token)
        #if DEBUG
        fullInputsPasses += 1
        #endif
        return inputs
    }

    /// Date what one prefix pass can — the newest-catch fast path, which
    /// covers every live unlock — and park the rest. Achievement dates must
    /// never block the caller: an upgrade with thousands of catches needs
    /// tens of full-Hangar passes (the 1.2.0 launch hang).
    private func recordDatesWithinBudget(catches: [Catch], inputs: TrophyProgressInputs, token: Int) {
        let done = TrophyAchievementDates.recordMissing(
            from: catches, inputs: inputs, roster: roster, ledger: ledger,
            events: events, maxEvaluations: 1)
        pendingDateBackfill = done ? nil : (catches, inputs)
        datesToken = token
        memoDatesDone = done
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
        Analytics.capture("trophy_unlocked", Self.unlockProperties(event))
    }

    /// `trophy_unlocked` properties. `via` is set only for unlocks a
    /// roster-bump reseed granted (`"reseed"`, fired at reseed time; the
    /// card shown for it later stays silent); a live unlock carries no
    /// `via`, the shape it has always had.
    static func unlockProperties(_ event: TrophyUnlockEvent, via: String? = nil) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "achievement": .string(event.achievementID),
            "title": .string(event.achievement.title),
            "tier": .string(event.newTier.rawValue),
            "kind": .string(event.kind == .badgeEarned ? "badge" : "tier_up"),
            "secret": .bool(event.achievement.secret),
        ]
        if let via { props["via"] = .string(via) }
        return props
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

    /// Dismiss the one-time recap. One-time-ness lives in the seeded flag +
    /// roster-version stamp (written at seed time, before presentation) — a crash mid-recap
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

    private func queueRecap(_ achievements: [Achievement]) {
        // Nothing to show (fresh install, or an install that never caught)
        // → no recap; the version stamp is already written, so no re-check.
        guard !achievements.isEmpty else { return }
        pendingRecap = TrophyRecap(achievements: achievements)
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
