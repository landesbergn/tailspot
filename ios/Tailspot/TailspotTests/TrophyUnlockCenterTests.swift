//
//  TrophyUnlockCenterTests.swift
//  TailspotTests
//
//  The queue/ledger logic of TrophyUnlockCenter: seed-on-first-enqueue
//  (no flood), dedupe, commit-on-shown survives a "crash" (a fresh center
//  over the same ledger), and the one-time recap. The SwiftUI overlay
//  itself is device-verified; its driving logic lives here.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("TrophyUnlockCenter")
@MainActor
struct TrophyUnlockCenterTests {

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
        UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.center.\(UUID().uuidString)")!)
    }

    /// `n` generic catches (each +1 to totalCatches); the last `legendary` of
    /// them are legendary-tier (drive the badge).
    private func catches(_ n: Int, legendary: Int = 0) -> [Catch] {
        (0..<n).map { i in
            let isLegendary = i >= n - legendary
            return Catch(
                icao24: String(UUID().uuidString.prefix(6)),
                callsign: nil,
                model: isLegendary ? "B-2" : "737-800",
                manufacturer: isLegendary ? "NORTHROP" : "BOEING",
                operatorName: nil,
                caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
                observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
                // Tier resolves only from the typecode table (single-source rule,
                // U3): B2 → legendary, B738 → common. The old VC-25/USAF string
                // path no longer yields a legendary tier.
                typecode: isLegendary ? "B2" : "B738"
            )
        }
    }

    // MARK: - Seeding (no flood)

    @Test func firstEnqueueSeedsAndEmitsNothing() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        // The very first op over a non-empty Hangar (3 catches → medal gold)
        // seeds rather than flooding.
        center.enqueueNewUnlocks(from: catches(3))
        #expect(center.pendingEvents.isEmpty)
        #expect(ledger.isSeeded)
    }

    // MARK: - Diff + dedupe

    @Test func enqueueAppendsCrossingThenDedupes() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        center.enqueueNewUnlocks(from: catches(1))   // seed at bronze
        center.enqueueNewUnlocks(from: catches(2))   // now silver → one event
        #expect(center.pendingEvents.count == 1)
        #expect(center.head?.achievementID == "m")
        #expect(center.head?.newTier == .silver)
        // Second identical diff (not yet shown) adds nothing.
        center.enqueueNewUnlocks(from: catches(2))
        #expect(center.pendingEvents.count == 1)
    }

    @Test func markShownThenAdvanceCommitsAndDoesNotResurface() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        center.enqueueNewUnlocks(from: catches(1))   // seed bronze
        center.enqueueNewUnlocks(from: catches(2))   // silver event
        let head = center.head!
        center.markShown(head)
        center.advance()
        #expect(center.pendingEvents.isEmpty)
        // Re-diffing the same state must not resurface it (ledger committed).
        center.enqueueNewUnlocks(from: catches(2))
        #expect(center.pendingEvents.isEmpty)
    }

    @Test func skipAllCommitsAndClears() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        center.enqueueNewUnlocks(from: catches(1))            // seed
        center.enqueueNewUnlocks(from: catches(3, legendary: 1))  // medal gold + badge → 2 events
        #expect(center.pendingEvents.count == 2)
        center.skipAll()
        #expect(center.pendingEvents.isEmpty)
        center.enqueueNewUnlocks(from: catches(3, legendary: 1))
        #expect(center.pendingEvents.isEmpty)   // both committed
    }

    // MARK: - Crash survival (commit-on-shown)

    @Test func shownButNotAdvancedSurvivesReconstruction() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        center.enqueueNewUnlocks(from: catches(1))   // seed bronze
        center.enqueueNewUnlocks(from: catches(2))   // silver event
        center.markShown(center.head!)               // commit, but no advance ("crash")

        // A fresh center over the SAME ledger must not re-emit the seen event.
        let revived = TrophyUnlockCenter(ledger: ledger, roster: roster)
        revived.enqueueNewUnlocks(from: catches(2))
        #expect(revived.pendingEvents.isEmpty)
    }

    // MARK: - Recap (once per roster generation)

    @Test func recapQueuedOnceForExistingTester() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        // First enqueue over an already-earned Hangar (2 catches → medal silver)
        // seeds AND queues exactly one recap carrying the earned set.
        center.enqueueNewUnlocks(from: catches(2))
        #expect(center.pendingRecap != nil)
        #expect(center.pendingRecap?.earned == 1)   // medal "m" earned at 2 catches
        #expect(center.pendingRecap?.achievements.map(\.id) == ["m"])
        #expect(ledger.rosterVersion == Trophies.rosterVersion)   // stamped at seed

        center.dismissRecap()
        #expect(center.pendingRecap == nil)

        // A fresh center over the same (now seeded + stamped) ledger shows no recap.
        let revived = TrophyUnlockCenter(ledger: ledger, roster: roster)
        revived.enqueueNewUnlocks(from: catches(2))
        #expect(revived.pendingRecap == nil)
    }

    @Test func noRecapForFreshInstall() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster)
        center.enqueueNewUnlocks(from: [])   // nothing earned
        #expect(center.pendingRecap == nil)
        // Stamped anyway, so nothing re-checks (and a later roster bump still works).
        #expect(ledger.rosterVersion == Trophies.rosterVersion)
    }

    // MARK: - Roster-version reseed (the 2026-07-10 expansion path)

    /// An EXISTING tester: seeded ledger, but stamped behind the current
    /// roster generation. The next enqueue must RESEED — silently
    /// acknowledging trophies the new roster hands them — and present ONE
    /// recap instead of an unlock flood.
    @Test func staleRosterStampReseedsAndRecapsWithoutFlood() {
        let ledger = freshLedger()
        // Yesterday's build: seeded under roster version 1 (a center pinned
        // to version 1 over the SAME ledger + roster).
        let old = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 1)
        old.enqueueNewUnlocks(from: catches(3, legendary: 1))   // seeds; medal gold + badge earned
        #expect(ledger.rosterVersion == 1)

        // Today's build (version 2). Same Hangar → reseed + recap, NO events.
        let new = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 2)
        new.enqueueNewUnlocks(from: catches(3, legendary: 1))
        #expect(new.pendingEvents.isEmpty, "version bump must absorb, not flood")
        #expect(new.pendingRecap?.earned == 2)
        #expect(ledger.rosterVersion == 2)

        // After the stamp, normal diffing resumes (no recap re-queues).
        new.dismissRecap()
        new.enqueueNewUnlocks(from: catches(3, legendary: 1))
        #expect(new.pendingRecap == nil)
        #expect(new.pendingEvents.isEmpty)
    }

    /// A seeded-but-stale ledger with NOTHING earned (installed, never
    /// caught) gets the stamp but never the recap.
    @Test func staleStampWithZeroEarnedStampsSilently() {
        let ledger = freshLedger()
        let old = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 1)
        old.enqueueNewUnlocks(from: [])
        let new = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 2)
        new.enqueueNewUnlocks(from: [])
        #expect(new.pendingRecap == nil)
        #expect(ledger.rosterVersion == 2)
    }

    /// After the version-bump reseed, genuinely new crossings still fire as
    /// normal unlock moments.
    @Test func crossingAfterVersionBumpStillFires() {
        let ledger = freshLedger()
        let old = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 1)
        old.enqueueNewUnlocks(from: catches(1))   // seed at bronze
        let new = TrophyUnlockCenter(ledger: ledger, roster: roster, rosterVersion: 2)
        new.enqueueNewUnlocks(from: catches(1))   // reseed + recap (bronze earned)
        new.dismissRecap()
        new.enqueueNewUnlocks(from: catches(2))   // silver crossing — a real event
        #expect(new.pendingEvents.count == 1)
        #expect(new.head?.newTier == .silver)
    }

    // MARK: - Winner trophies (server facts — dynamic-leaderboards PR3)

    /// A suite-isolated defaults so host-app standing/event state can't leak
    /// into these real-roster tests.
    private func isolatedSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.standing.\(UUID().uuidString)")!
    }

    /// The rosterVersion 2→3 upgrade on a device whose server facts already
    /// carry wins (e.g. Noah's historical crown backfill): the reseed must
    /// silently absorb Top Flight + Dynasty + Chart Topper into the ONE
    /// recap — never a per-trophy toast flood.
    @Test func versionBumpAbsorbsServerEarnedWinnerTrophies() {
        let ledger = freshLedger()
        let suite = isolatedSuite()
        let standing = LeaderboardStandingCache(defaults: suite)
        let events = TrophyEventStore(defaults: suite)
        standing.update(from: MyStanding(rank: 1, points: 2755,
                                         weeklyWins: 3, everToppedAllTime: true))

        // Yesterday's build: version-2 roster WITHOUT the winner trophies
        // (they didn't exist), seeded and stamped at 2.
        let oldRoster = Trophies.roster.filter {
            !["topflight", "dynasty", "charttopper"].contains($0.id)
        }
        let old = TrophyUnlockCenter(ledger: ledger, roster: oldRoster,
                                     events: events, standing: standing, rosterVersion: 2)
        old.enqueueNewUnlocks(from: [])
        #expect(ledger.rosterVersion == 2)

        // Today's build: full roster, version 3, wins already banked server-side.
        let new = TrophyUnlockCenter(ledger: ledger, events: events, standing: standing)
        new.enqueueNewUnlocks(from: [])
        #expect(new.pendingEvents.isEmpty, "reseed must absorb pre-earned server trophies, not flood")
        #expect(new.pendingRecap?.achievements.map(\.id).sorted()
                == ["charttopper", "dynasty", "topflight"])
        #expect(ledger.rosterVersion == Trophies.rosterVersion)

        // And after the recap, re-diffing the same facts stays quiet.
        new.dismissRecap()
        new.enqueueNewUnlocks(from: [])
        #expect(new.pendingEvents.isEmpty)
        #expect(new.pendingRecap == nil)
    }

    /// Live crossings on an already-seeded device: each threshold fires its
    /// own moment exactly once as leaderboard fetches move the cached facts
    /// (the Monday-board-refresh path).
    @Test func liveWeeklyWinCrossingsFireOnceEach() {
        let ledger = freshLedger()
        let suite = isolatedSuite()
        let standing = LeaderboardStandingCache(defaults: suite)
        let events = TrophyEventStore(defaults: suite)
        let center = TrophyUnlockCenter(ledger: ledger, events: events, standing: standing)
        center.enqueueNewUnlocks(from: [])   // fresh install: seed, nothing earned
        #expect(center.pendingEvents.isEmpty)
        #expect(center.pendingRecap == nil)

        // First crown lands → Top Flight fires (once).
        standing.update(from: MyStanding(rank: 1, points: 100, weeklyWins: 1))
        center.enqueueNewUnlocks(from: [])
        #expect(center.pendingEvents.map(\.achievementID) == ["topflight"])
        #expect(center.head?.kind == .badgeEarned)
        center.markShown(center.head!)
        center.advance()

        // Third crown → Dynasty (the secret) fires; Top Flight stays quiet.
        standing.update(from: MyStanding(rank: 1, points: 300, weeklyWins: 3))
        center.enqueueNewUnlocks(from: [])
        #expect(center.pendingEvents.map(\.achievementID) == ["dynasty"])
        center.markShown(center.head!)
        center.advance()

        // Ever-topped flag flips → Chart Topper fires.
        standing.update(from: MyStanding(rank: 1, points: 300, everToppedAllTime: true))
        center.enqueueNewUnlocks(from: [])
        #expect(center.pendingEvents.map(\.achievementID) == ["charttopper"])
    }

    /// The real-roster late-backfill case (U6): Mr. Worldwide doesn't cross
    /// until `country` is stamped post-save, so the second enqueue (fired by
    /// ContentView's post-geocode task) must pick it up.
    @Test func lateCountryBackfillCrossesMrWorldwide() {
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger)   // real roster
        let plain = { (icao: String) in
            Catch(icao24: icao, callsign: nil, model: nil, manufacturer: nil,
                  caughtAt: Date(timeIntervalSince1970: 1_716_000_000),
                  observerLat: 0, observerLon: 0, slantDistanceMeters: 0)
        }
        let c1 = plain("aaa111"); let c2 = plain("bbb222")
        center.enqueueNewUnlocks(from: [c1, c2])   // seed; no countries yet
        #expect(center.pendingEvents.contains { $0.achievementID == "mrworldwide" } == false)

        c1.country = "US"; c2.country = "CA"       // late backfill → 2 countries
        center.enqueueNewUnlocks(from: [c1, c2])
        #expect(center.pendingEvents.contains { $0.achievementID == "mrworldwide" })
    }

    // MARK: - Inputs memo (2026-10 large-Hangar perf)

    /// Re-diffing an unchanged Hangar (sheet close, grounded tap with no new
    /// event) reuses the memoized inputs: no second full pass.
    @Test func unchangedRediffReusesInputs() {
        let suite = isolatedSuite()
        let center = TrophyUnlockCenter(ledger: freshLedger(), roster: roster,
                                        events: TrophyEventStore(defaults: suite),
                                        standing: LeaderboardStandingCache(defaults: suite))
        let hangar = catches(3)
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.fullInputsPasses == 1)
        center.enqueueNewUnlocks(from: hangar)
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.fullInputsPasses == 1)
    }

    /// A memo hit still runs the ledger diff, so an event parked at the head
    /// survives and a crossing that was queued isn't lost or duplicated.
    @Test func memoHitStillDiffsAgainstTheLedger() {
        let suite = isolatedSuite()
        let ledger = freshLedger()
        let center = TrophyUnlockCenter(ledger: ledger, roster: roster,
                                        events: TrophyEventStore(defaults: suite),
                                        standing: LeaderboardStandingCache(defaults: suite))
        let one = catches(1)
        center.enqueueNewUnlocks(from: one)                 // seed bronze
        let two = one + catches(1)
        center.enqueueNewUnlocks(from: two)                 // silver event
        #expect(center.pendingEvents.map(\.newTier) == [.silver])
        center.enqueueNewUnlocks(from: two)                 // memo hit: deduped, not dropped
        #expect(center.pendingEvents.map(\.newTier) == [.silver])
        center.markShown(center.head!)
        center.advance()
        center.enqueueNewUnlocks(from: two)                 // memo hit: acknowledged stays quiet
        #expect(center.pendingEvents.isEmpty)
        #expect(center.fullInputsPasses == 2)
    }

    /// The bonus round stamps `guessCorrect` after the row is saved, and
    /// `CatchFingerprint` doesn't hash it. The memo key must, or a correct
    /// call would never celebrate Sharp Eye-style trophies.
    @Test func lateGuessVerdictBustsTheMemo() {
        let suite = isolatedSuite()
        let guessRoster = [Achievement(
            id: "g", title: "Guesser", summary: "", iconName: "catcher",
            tiers: [.init(tier: .silver, at: 1)],
            progress: { $0.correctGuesses }
        )]
        let center = TrophyUnlockCenter(ledger: freshLedger(), roster: guessRoster,
                                        events: TrophyEventStore(defaults: suite),
                                        standing: LeaderboardStandingCache(defaults: suite))
        let hangar = catches(2)
        center.enqueueNewUnlocks(from: hangar)              // seed: no guesses yet
        #expect(center.pendingEvents.isEmpty)
        hangar[1].guessCorrect = true                       // the reveal's verdict
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.pendingEvents.map(\.achievementID) == ["g"])
        #expect(center.fullInputsPasses == 2)
    }

    /// The grounded easter egg records an event and re-diffs the SAME
    /// Hangar; the event count is in the memo key, so Ground Stop fires now.
    @Test func groundedEventBustsTheMemo() {
        let suite = isolatedSuite()
        let events = TrophyEventStore(defaults: suite)
        let center = TrophyUnlockCenter(ledger: freshLedger(), events: events,
                                        standing: LeaderboardStandingCache(defaults: suite))
        let hangar = catches(1)
        center.enqueueNewUnlocks(from: hangar)              // seed
        events.record(.groundedCatchAttempt)
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.pendingEvents.contains { $0.achievementID == "groundstop" })
    }

    /// Typecode backfill (CatchBackfill / CatchDetailView) changes rarity on
    /// an existing row without changing the count — the memo must recompute.
    @Test func typecodeBackfillBustsTheMemo() {
        let suite = isolatedSuite()
        let center = TrophyUnlockCenter(ledger: freshLedger(), roster: roster,
                                        events: TrophyEventStore(defaults: suite),
                                        standing: LeaderboardStandingCache(defaults: suite))
        let hangar = catches(3)
        center.enqueueNewUnlocks(from: hangar)              // seed: no legendary
        hangar[0].typecode = "B2"                           // backfill → legendary tier
        center.enqueueNewUnlocks(from: hangar)
        #expect(center.pendingEvents.map(\.achievementID) == ["b"])
    }

    /// Legacy rows (no frozen day key) bucket in the CURRENT zone, and the
    /// hour-of-day trophies always do, so the token carries the zone.
    @Test func tokenTracksTimeZoneAndDayKey() {
        let hangar = catches(2)
        let suite = isolatedSuite()
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let bali = TimeZone(identifier: "Asia/Makassar")!
        let base = TrophyInputsToken.of(hangar, events: events, standing: standing, timeZone: la)
        #expect(TrophyInputsToken.of(hangar, events: events, standing: standing, timeZone: la) == base)
        #expect(TrophyInputsToken.of(hangar, events: events, standing: standing, timeZone: bali) != base)
        hangar[0].caughtDayKey = nil
        #expect(TrophyInputsToken.of(hangar, events: events, standing: standing, timeZone: la) != base)
    }
}
