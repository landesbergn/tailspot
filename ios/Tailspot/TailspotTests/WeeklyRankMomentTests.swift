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
        streakAskUp: Bool = false,
        sheetUp: Bool = false,
        showing: Bool = false,
        resolving: Bool = false
    ) -> Bool {
        WeeklyRankArbitration.canPresent(
            armed: armed,
            revealUp: revealUp,
            suspectReviewUp: suspectUp,
            trophiesPending: trophies,
            streakAskUp: streakAskUp,
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

    @Test func waitsForTheStreakNotificationAsk() {
        // Review finding: on a default-settings first catch the streak ask
        // (day-1 eligible since #213) claims the post-reveal moment — the
        // rank card must wait for it, never stack on it.
        #expect(!canPresent(streakAskUp: true))
        #expect(canPresent(streakAskUp: false))
    }

    // MARK: - Prewarm budget race (the A5 bound)

    @MainActor
    @Test func awaitRankReturnsCachedResultImmediately() async {
        let prewarm = WeeklyRankPrewarm()
        prewarm.resolved = .some(7)
        #expect(await prewarm.awaitRank(budgetSeconds: 3) == 7)
    }

    @MainActor
    @Test func awaitRankFallsBackWhenNothingResolvesInBudget() async {
        // The bound is the point (review finding: the old task-group race
        // could block ~90 s on a slow connection). No wall-clock assertion:
        // the suite's long-running MainActor render tests can starve this
        // test for tens of seconds, which is scheduler contention, not an
        // unbounded await — the deadline-poll shape is what bounds it.
        let prewarm = WeeklyRankPrewarm()
        let rank = await prewarm.awaitRank(budgetSeconds: 0.3)
        #expect(rank == nil)
    }

    @MainActor
    @Test func awaitRankPicksUpALateResolutionWithinBudget() async {
        // Generous budget so MainActor contention from parallel suite
        // members can't push the setter past the deadline.
        let prewarm = WeeklyRankPrewarm()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            prewarm.resolved = .some(12)
        }
        #expect(await prewarm.awaitRank(budgetSeconds: 30) == 12)
    }

    @MainActor
    @Test func cancelClearsAStaleResolvedValue() async {
        // A cancelled start (discard path) must not leave a stale resolved
        // value behind for the next arm.
        let prewarm = WeeklyRankPrewarm()
        prewarm.resolved = .some(4)
        prewarm.cancel()
        #expect(prewarm.resolved == nil)
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
