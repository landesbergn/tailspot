import Foundation
import SwiftData
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

    @Test func upgradeRecoversThresholdDatesFromUnsortedHistoryWithoutCelebrations() async {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let rows = catches(7)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        center.enqueueNewUnlocks(from: rows.reversed())
        await center.finishAchievementDates()
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

    @Test func restoreUsesHistoricalDatesNotRestoreTime() async {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let rows = catches(5)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        center.reseedAfterRestore(from: rows)
        await center.finishAchievementDates()
        #expect(ledger.achievedDates["firstcatch"] == rows[0].caughtAt)
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

    // MARK: - 1.2.0 launch hang (big Hangar upgraded from a dateless build)

    /// A Hangar whose catches cross trophies at many different points:
    /// varied types, operators, places, countries, days and hours.
    private func variedCatches(_ count: Int) -> [Catch] {
        let types = ["B738", "A320", "B77W", "A388", "E75L", "C172", "B744", "A359"]
        let operators = ["United", "Delta", "Alaska", "Lufthansa", nil]
        return (0..<count).map { index in
            let row = Catch(icao24: String(format: "a%05x", index % (count / 2 + 1)),
                            callsign: nil, model: nil, manufacturer: nil,
                            operatorName: operators[index % operators.count],
                            caughtAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 7_919),
                            observerLat: 0, observerLon: 0,
                            slantDistanceMeters: Double(index % 40) * 1_000,
                            typecode: types[index % types.count])
            row.placeName = "Place \(index % 12)"
            row.country = ["US", "CA", "MX", "JP"][index % 4]
            return row
        }
    }

    private func isolatedInputs(_ rows: [Catch]) -> TrophyProgressInputs {
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        return Trophies.inputs(from: rows, events: TrophyEventStore(defaults: suite),
                               standing: LeaderboardStandingCache(defaults: suite))
    }

    @Test func launchPassIsBoundedAndTheBackfillFinishesTheSameDates() async {
        let rows = variedCatches(120)
        let inputs = isolatedInputs(rows)
        let reference = UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.dates.\(UUID())")!)
        #expect(TrophyAchievementDates.recordMissing(from: rows, inputs: inputs, ledger: reference))
        #expect(reference.achievedDates.count > 5, "fixture should date many trophies")

        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let center = TrophyUnlockCenter(ledger: ledger,
                                       events: TrophyEventStore(defaults: suite),
                                       standing: LeaderboardStandingCache(defaults: suite))
        // The launch task's synchronous half must stop short on an upgrade…
        center.enqueueNewUnlocks(from: rows.shuffled())
        #expect(ledger.achievedDates.count < reference.achievedDates.count)
        #expect(center.pendingEvents.isEmpty)
        // …and its async half lands exactly the dates the unbounded search finds.
        await center.finishAchievementDates()
        #expect(ledger.achievedDates == reference.achievedDates)
        // Nothing is left over, so the next launch does no date work.
        #expect(TrophyAchievementDates.recordMissing(from: rows, inputs: inputs, ledger: ledger,
                                                    maxEvaluations: 0))
    }

    /// The watchdog kill made 1.2.0 permanent: dates were written once, at
    /// the end, so every relaunch restarted from zero. Each found date must
    /// be persisted on its own, so an interrupted run keeps its progress.
    @Test func interruptedSearchKeepsTheDatesItAlreadyFound() {
        let rows = variedCatches(120)
        let inputs = isolatedInputs(rows)
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let events = TrophyEventStore(defaults: suite)
        var previous = 0
        var runs = 0
        // Relaunch-and-get-killed loop. Each "launch" survives just long
        // enough to finish one binary search from a cold cache (the newest-
        // catch probe + ⌈log₂ 120⌉ = 7 probes), then dies.
        while !TrophyAchievementDates.recordMissing(
            from: rows, inputs: inputs, ledger: UserDefaultsTrophyLedger(defaults: suite),
            events: events, maxEvaluations: 9) {
            let found = UserDefaultsTrophyLedger(defaults: suite).achievedDates.count
            #expect(found >= previous)
            previous = found
            runs += 1
            if runs >= 200 { Issue.record("the search must converge across interrupted runs"); break }
        }
        #expect(runs > 1, "fixture should need several bounded runs")
        let reference = UserDefaultsTrophyLedger(defaults: UserDefaults(suiteName: "test.dates.\(UUID())")!)
        TrophyAchievementDates.recordMissing(from: rows, inputs: inputs, ledger: reference)
        #expect(UserDefaultsTrophyLedger(defaults: suite).achievedDates == reference.achievedDates)
    }

    @Test func liveUnlockIsDatedWithinTheSynchronousBudget() {
        let rows = variedCatches(60)
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let events = TrophyEventStore(defaults: suite)
        let before = Array(rows.prefix(4))
        TrophyAchievementDates.recordMissing(from: before, inputs: isolatedInputs(before),
                                            ledger: ledger, events: events)
        // The fifth catch crosses Spotter: one prefix pass dates it.
        let after = Array(rows.prefix(5))
        let done = TrophyAchievementDates.recordMissing(from: after, inputs: isolatedInputs(after),
                                                       ledger: ledger, events: events,
                                                       maxEvaluations: 1)
        #expect(done)
        #expect(ledger.achievedDates["spotter"] == rows[4].caughtAt)
    }

    @Test func backfillStopsWhenARowIsDeletedMidRun() async throws {
        let container = try ModelContainer(for: Catch.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        TestContainerRetention.retain(container)
        let context = ModelContext(container)
        let rows = variedCatches(80)
        rows.forEach { context.insert($0) }
        try context.save()
        let inputs = isolatedInputs(rows)
        let suite = UserDefaults(suiteName: "test.dates.\(UUID())")!
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let run = Task {
            await TrophyAchievementDates.backfill(from: rows, inputs: inputs, ledger: ledger,
                                                  events: TrophyEventStore(defaults: suite),
                                                  pause: .milliseconds(300))
        }
        // A Hangar delete lands while the backfill is suspended between passes.
        try await Task.sleep(for: .milliseconds(50))
        context.delete(rows[10])
        try context.save()
        await run.value
        // It bailed at the first suspension instead of reading the deleted
        // row, so no prefix was ever searched.
        #expect(ledger.achievedDates.isEmpty)
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
