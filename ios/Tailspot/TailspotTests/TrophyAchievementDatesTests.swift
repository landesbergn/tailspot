import Foundation
import Testing
@testable import Tailspot

@MainActor
@Suite("Trophy achievement dates")
struct TrophyAchievementDatesTests {
    private func catches(_ count: Int) -> [Catch] {
        (0..<count).map { index in
            Catch(icao24: "abc\(index)", callsign: nil, model: nil, manufacturer: nil,
                  operatorName: nil,
                  caughtAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 86_400),
                  observerLat: 0, observerLon: 0, slantDistanceMeters: 0, typecode: "B738")
        }
    }

    @Test func upgradeRecoversThresholdDatesFromUnsortedHistoryWithoutCelebrations() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let rows = catches(7)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        center.enqueueNewUnlocks(from: rows.reversed())
        #expect(ledger.achievedDates["firstcatch"] == rows[0].caughtAt)
        #expect(ledger.achievedDates["spotter"] == rows[4].caughtAt)
        #expect(ledger.achievedDates["catcher"] == nil)
        #expect(center.pendingEvents.isEmpty)
    }

    @Test func newUnlockRecordsDateBeforeCelebrationAndPreservesItAfterDeletion() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        let rows = catches(7)
        center.enqueueNewUnlocks(from: [])
        center.enqueueNewUnlocks(from: Array(rows.prefix(5)))
        #expect(center.pendingEvents.contains { $0.achievementID == "spotter" })
        #expect(ledger.achievedDates["spotter"] == rows[4].caughtAt)
        center.skipAll()
        center.enqueueNewUnlocks(from: Array(rows.dropFirst(2)))
        let revived = UserDefaultsTrophyLedger(defaults: suite)
        #expect(revived.achievedDates["spotter"] == rows[4].caughtAt)
    }

    @Test func restoreUsesHistoricalDatesNotRestoreTime() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let rows = catches(5)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        center.reseedAfterRestore(from: rows)
        #expect(ledger.achievedDates["spotter"] == rows[4].caughtAt)
        #expect(center.pendingEvents.isEmpty)
    }

    @Test func guessStreakDateIsTheFirstCompletedRun() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let rows = catches(7)
        for (row, answer) in zip(rows, [true, false, true, true, true, false, true]) {
            row.guessCorrect = answer
            row.guessKind = GuessKind.route.rawValue
        }
        let inputs = Trophies.inputs(from: rows, events: TrophyEventStore(defaults: suite),
                                    standing: LeaderboardStandingCache(defaults: suite))
        TrophyAchievementDates.recordMissing(from: rows, inputs: inputs, ledger: ledger,
                                            events: TrophyEventStore(defaults: suite))
        #expect(ledger.achievedDates["calledit"] == rows[0].caughtAt)
        #expect(ledger.achievedDates["hotstreak"] == rows[4].caughtAt)
    }

    @Test func externalAchievementsNeverInheritAnUnrelatedCatchDate() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        let eventDate = Date(timeIntervalSince1970: 1_790_000_000)
        events.record(.groundedCatchAttempt, at: eventDate)
        events.record(.groundedCatchAttempt, at: eventDate.addingTimeInterval(500))
        standing.update(from: MyStanding(rank: 1, points: 0, weeklyWins: 3, everToppedAllTime: true))
        let rows = catches(5)
        TrophyAchievementDates.recordMissing(
            from: rows, inputs: Trophies.inputs(from: rows, events: events, standing: standing),
            ledger: ledger, events: events)
        #expect(ledger.achievedDates["groundstop"] == eventDate)
        for id in ["topflight", "dynasty", "charttopper"] {
            #expect(ledger.achievedDates[id] == nil)
        }
    }

    @Test func legacyGroundedEventRemainsUndatedAfterRepeat() {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        suite.set(2, forKey: "trophy.events.v1.groundedCatchAttempt")
        let events = TrophyEventStore(defaults: suite)
        events.record(.groundedCatchAttempt)
        #expect(events.count(of: .groundedCatchAttempt) == 3)
        #expect(events.firstOccurredAt(.groundedCatchAttempt) == nil)
    }
}
