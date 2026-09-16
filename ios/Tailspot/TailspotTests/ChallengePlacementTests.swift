//
//  ChallengePlacementTests.swift
//  TailspotTests
//
//  Competition ranking (section 5 "Ties": 100/100/60 → 1, 1, 3, everyone
//  tied at the top wins) and the No Contest threshold (section 5 "No
//  Contest": fewer than two accepted participants, or no participant with
//  any points).
//

import Testing
@testable import Tailspot

@Suite("Challenge placement")
struct ChallengePlacementTests {

    @Test func tiesShareThePlacementAndSkipTheNext() {
        let ranked = ChallengePlacement.rank(points: ["a": 100, "b": 100, "c": 60])
        let byHandle = Dictionary(uniqueKeysWithValues: ranked.map { ($0.handle, $0.placement) })
        #expect(byHandle["a"] == 1)
        #expect(byHandle["b"] == 1)
        #expect(byHandle["c"] == 3)
    }

    @Test func noTiesIsStrictOrdering() {
        let ranked = ChallengePlacement.rank(points: ["a": 10, "b": 30, "c": 20])
        let byHandle = Dictionary(uniqueKeysWithValues: ranked.map { ($0.handle, $0.placement) })
        #expect(byHandle["b"] == 1)
        #expect(byHandle["c"] == 2)
        #expect(byHandle["a"] == 3)
    }

    @Test func equalPointsBreakTiesByHandleAscendingForStableOrder() {
        // Handle ordering doesn't affect placement (both still tie for 1st)
        // but does fix iteration order, matching the server's ORDER BY.
        let ranked = ChallengePlacement.rank(points: ["zoe": 50, "amy": 50])
        #expect(ranked.map(\.handle) == ["amy", "zoe"])
        #expect(ranked.allSatisfy { $0.placement == 1 })
    }

    @Test func emptyPointsRanksToNothing() {
        #expect(ChallengePlacement.rank(points: [:]).isEmpty)
    }

    @Test func winnersAreEveryoneTiedAtFirst() {
        let winners = ChallengePlacement.winners(["a": 100, "b": 100, "c": 60])
        #expect(Set(winners) == ["a", "b"])
    }

    @Test func winnersWithNoTieIsOnePerson() {
        #expect(ChallengePlacement.winners(["a": 10, "b": 30]) == ["b"])
    }

    @Test func winnersOfEmptyPointsIsEmpty() {
        #expect(ChallengePlacement.winners([:]).isEmpty)
    }

    @Test func noContestWhenFewerThanTwoParticipants() {
        #expect(ChallengePlacement.isNoContest(activeParticipants: 1, totalPoints: 50))
        #expect(ChallengePlacement.isNoContest(activeParticipants: 0, totalPoints: 0))
    }

    @Test func noContestWhenNobodyScored() {
        #expect(ChallengePlacement.isNoContest(activeParticipants: 4, totalPoints: 0))
    }

    @Test func notNoContestWithTwoOrMoreParticipantsAndSomePoints() {
        #expect(!ChallengePlacement.isNoContest(activeParticipants: 2, totalPoints: 10))
    }
}
