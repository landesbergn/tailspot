//
//  WeeklyRankMomentTests.swift
//  TailspotTests
//
//  The weekly-rank landing moment's arbitration gate and rank mapping
//  (plan U3): the card waits for every prior claimant of the post-catch
//  sequence, and the backend's rank-0 "unranked" sentinel never renders
//  as a place.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("WeeklyRankMoment")
struct WeeklyRankMomentTests {

    private func canPresent(
        armed: Bool = true,
        revealUp: Bool = false,
        suspectUp: Bool = false,
        trophies: Bool = false,
        sheetUp: Bool = false,
        showing: Bool = false,
        resolving: Bool = false
    ) -> Bool {
        WeeklyRankArbitration.canPresent(
            armed: armed,
            revealUp: revealUp,
            suspectReviewUp: suspectUp,
            trophiesPending: trophies,
            sheetUp: sheetUp,
            alreadyShowing: showing,
            resolving: resolving
        )
    }

    @Test func presentsOnlyWhenEverythingSettled() {
        #expect(canPresent())
    }

    @Test func waitsForRevealSuspectAndTrophiesInAnyCombination() {
        // AE10/KTD4: arbitration order suspect → trophies → rank holds
        // with all pending — each claimant alone blocks the card.
        #expect(!canPresent(revealUp: true))
        #expect(!canPresent(suspectUp: true))
        #expect(!canPresent(trophies: true))
        #expect(!canPresent(revealUp: true, suspectUp: true, trophies: true))
    }

    @Test func neverDoublePresentsOrFightsASheet() {
        #expect(!canPresent(sheetUp: true))
        #expect(!canPresent(showing: true))
        #expect(!canPresent(resolving: true))
        #expect(!canPresent(armed: false))
    }

    // MARK: - Rank mapping (AE6, the rank-0 wrinkle)

    @Test func positiveRankDisplays() {
        let standing = MyStanding(rank: 4, points: 120)
        #expect(WeeklyRankArbitration.displayRank(standing) == 4)
    }

    @Test func rankZeroIsUnrankedNotAPlace() {
        // backend/src/identity/store.ts: zero in-window points → rank 0.
        // Rendering "#0 this week" would be nonsense — fall back (A5).
        let standing = MyStanding(rank: 0, points: 0)
        #expect(WeeklyRankArbitration.displayRank(standing) == nil)
    }

    @Test func missingStandingFallsBack() {
        #expect(WeeklyRankArbitration.displayRank(nil) == nil)
    }
}
