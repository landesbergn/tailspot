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
}
