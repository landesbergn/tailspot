//
//  LargeHangarBudgetTests.swift
//  TailspotTests
//
//  Performance budgets at the size the heaviest real Hangars are heading
//  for (the largest had ~8,900 lifetime catch events in 2026-10, adding
//  ~255 a day). The only public hotfix so far (1.2.0 → 1.2.1) was a
//  large-Hangar hang that no test exercised; these make the next slip fail
//  here instead of on the biggest users' phones.
//
//  Three kinds of check, most deterministic first:
//   1. Pass counts. `TrophyUnlockCenter` counts its full-Hangar
//      `Trophies.inputs` passes (DEBUG only). An unchanged re-diff (every
//      sheet close) must do 0, one new catch exactly 1. Exact, never flaky.
//   2. Wall-clock budgets on the three heavy derivations, as the MINIMUM of
//      3 runs (the least-disturbed run) against ~5x headroom over what the
//      Debug simulator measured. Loose on purpose: CI is a shared runner
//      running other suites in parallel, and a flapping required check gets
//      loosened until it's useless.
//   3. Growth: doubling the rows (10k → 20k) must cost under 3x. Catches an
//      accidental O(N²) without depending on the machine's absolute speed.
//      Only for operations above ~100 ms, where the ratio is stable.
//
//  Deliberately NOT timed: a full `TrophyAchievementDates.recordMissing`
//  (tens of prefix passes — minutes at this size in Debug). Its launch-path
//  bound is pinned structurally in TrophyAchievementDatesTests.
//
//  Fixture: synthetic rows in an in-memory SwiftData container (fetched
//  back, so property reads go through the store like an @Query's do),
//  shaped like real data — repeat airframes, ~300 days, 40 countries, and
//  260 distinct typecodes so set matching (the 1.2.0 hot spot) is real work.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Large Hangar budgets", .serialized)
@MainActor
struct LargeHangarBudgetTests {

    // MARK: - Fixture

    /// 20,000 managed rows, built once for the whole suite (insert + fetch is
    /// several seconds in Debug). The 10k cases take every other row, NOT a
    /// prefix: the rows are newest-first, so a prefix would cover only the
    /// newest half of the 300 days and be a differently shaped Hangar.
    private static let hangar20k: [Catch] = makeHangar(count: 20_000)
    private static let hangar10k: [Catch] = stride(from: 0, to: hangar20k.count, by: 2).map { hangar20k[$0] }

    /// Deterministic generator (SplitMix64) so every run times the same data.
    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private static func makeHangar(count: Int) -> [Catch] {
        var rng = SeededRNG(state: 0x7A11_5B07)
        // Typecodes: 200 set entries' representative codes (so many slots
        // are fillable and Set Master has real work), then 60 more from a
        // spread of the bundled DOC 8643 table that no set lists.
        var pool: [String] = []
        for family in CardSets.families {
            for entry in family.entries {
                if let tc = entry.representativeTypecode, !pool.contains(tc) { pool.append(tc) }
            }
        }
        pool = Array(pool.prefix(200))
        let table = AircraftNaming.table.keys.sorted()
        var i = 0
        while pool.count < 260, i < table.count {
            let tc = table[(i * 37) % table.count]
            if !pool.contains(tc) { pool.append(tc) }
            i += 1
        }
        // Skewed pick: real Hangars are dominated by a few airliner types,
        // with a long tail of one-offs.
        func skewed(_ n: Int) -> Int {
            let u = Double.random(in: 0..<1, using: &rng)
            return min(n - 1, Int(pow(u, 2.5) * Double(n)))
        }

        let countries = (0..<40).map { "Country \($0)" }
        let places = (0..<200).map { "Place \($0)" }
        let operators = (0..<80).map { "Operator \($0)" }
        // ~4 catches per airframe on average: the repeat-customer shape.
        struct Airframe { let icao: String; let typecode: String?; let op: String? }
        let airframes: [Airframe] = (0..<(count / 4)).map { n in
            let unknown = Int.random(in: 0..<100, using: &rng) < 3
            return Airframe(
                icao: String(format: "%06x", 0xA00000 + n),
                typecode: unknown ? nil : pool[skewed(pool.count)],
                op: Int.random(in: 0..<10, using: &rng) == 0 ? nil : operators[skewed(operators.count)]
            )
        }
        let newest = Date(timeIntervalSince1970: 1_760_000_000)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        let context = container.mainContext
        for _ in 0..<count {
            let frame = airframes[skewed(airframes.count)]
            let name = frame.typecode.flatMap { AircraftNaming.table[$0] }
            let row = Catch(
                icao24: frame.icao,
                callsign: frame.op.map { "\($0.suffix(2))\(Int.random(in: 1...999, using: &rng))" },
                model: name?.model ?? (frame.typecode == nil ? "Homebuilt" : nil),
                manufacturer: name?.make,
                operatorName: frame.op,
                caughtAt: newest.addingTimeInterval(-Double.random(in: 0..<(300 * 86_400), using: &rng)),
                observerLat: 37.87, observerLon: -122.27,
                slantDistanceMeters: Double.random(in: 500..<60_000, using: &rng),
                typecode: frame.typecode,
                altitudeMeters: Double.random(in: 0..<12_500, using: &rng),
                velocityMps: Double.random(in: 30..<290, using: &rng),
                placeName: places[skewed(places.count)],
                country: countries[skewed(countries.count)]
            )
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: row.guessCorrect = true
            case 1: row.guessCorrect = false
            default: break
            }
            context.insert(row)
        }
        try! context.save()
        // Read back in the Hangar's @Query order (newest first).
        let fetch = FetchDescriptor<Catch>(sortBy: [SortDescriptor(\.caughtAt, order: .reverse)])
        return try! context.fetch(fetch)
    }

    /// A freshly caught row that isn't in the store (an unmanaged @Model is
    /// fine to read), so the shared fixture is never mutated.
    private func newCatch(icao: String = "f00d01") -> Catch {
        Catch(icao24: icao, callsign: "UAL1", model: "737-800", manufacturer: "BOEING",
              caughtAt: Date(timeIntervalSince1970: 1_760_000_100),
              observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 8_000,
              typecode: "B738", country: "Country 0")
    }

    private func isolatedCenter() -> TrophyUnlockCenter {
        let suite = UserDefaults(suiteName: "test.budget.\(UUID().uuidString)")!
        return TrophyUnlockCenter(
            ledger: UserDefaultsTrophyLedger(defaults: suite),
            events: TrophyEventStore(defaults: suite),
            standing: LeaderboardStandingCache(defaults: suite))
    }

    // MARK: - Timing helpers

    /// Keeps results alive so a measured call can't be optimized out.
    private static var sink = 0

    /// The fastest of `runs` timings, in seconds.
    private func fastest(runs: Int = 3, _ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<runs {
            let elapsed = clock.measure(body)
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            best = min(best, seconds)
        }
        return best
    }

    // MARK: - Fixture sanity

    @Test func fixtureIsShapedLikeARealBigHangar() {
        let rows = Self.hangar10k
        #expect(rows.count == 10_000)
        #expect(rows.first?.modelContext != nil, "rows must be store-backed, like @Query's")
        #expect(Set(rows.map(\.icao24)).count < rows.count / 2, "repeat airframes")
        #expect(Set(rows.compactMap(\.typecode)).count >= 150, "enough types to exercise sets")
        #expect(Set(rows.compactMap(\.country)).count >= 35)
        #expect(Set(rows.map { Streaks.dayKey(for: $0) }).count >= 250)
        let inputs = Trophies.inputs(from: rows)
        #expect(inputs.completedSets > 0, "some families complete, so Set Master is live work")
    }

    // MARK: - 1. Pass counts (deterministic)

    @Test func unchangedRediffDoesNoInputsPass() {
        let center = isolatedCenter()
        let rows = Self.hangar10k
        center.enqueueNewUnlocks(from: rows)          // launch: seed
        let afterLaunch = center.fullInputsPasses
        #expect(afterLaunch == 1)
        // Three sheet closes with nothing new: all hits. (Repeat grounded
        // taps are pinned separately in repeatGroundedTapsAreMemoHits.)
        center.enqueueNewUnlocks(from: rows)
        center.enqueueNewUnlocks(from: rows)
        center.enqueueNewUnlocks(from: rows)
        #expect(center.fullInputsPasses == afterLaunch)
    }

    /// The grounded easter egg records an event and re-diffs on EVERY tap of
    /// a parked plane. Only the first tap can change the inputs (Ground Stop
    /// reads "ever happened", not a count), so only the first may pay a pass.
    @Test func repeatGroundedTapsAreMemoHits() {
        let suite = UserDefaults(suiteName: "test.budget.\(UUID().uuidString)")!
        let events = TrophyEventStore(defaults: suite)
        let center = TrophyUnlockCenter(
            ledger: UserDefaultsTrophyLedger(defaults: suite),
            events: events,
            standing: LeaderboardStandingCache(defaults: suite))
        let rows = Self.hangar10k
        center.enqueueNewUnlocks(from: rows)          // launch: seed
        let afterLaunch = center.fullInputsPasses
        events.record(.groundedCatchAttempt)          // first tap
        center.enqueueNewUnlocks(from: rows)
        #expect(center.fullInputsPasses == afterLaunch + 1)
        #expect(center.pendingEvents.contains { $0.achievementID == "groundstop" })
        events.record(.groundedCatchAttempt)          // second and third taps
        center.enqueueNewUnlocks(from: rows)
        events.record(.groundedCatchAttempt)
        center.enqueueNewUnlocks(from: rows)
        #expect(center.fullInputsPasses == afterLaunch + 1)
    }

    @Test func oneNewCatchDoesExactlyOneInputsPass() {
        let center = isolatedCenter()
        let rows = Self.hangar10k
        center.enqueueNewUnlocks(from: rows)
        let before = center.fullInputsPasses
        let caught = [newCatch()] + rows              // the catch-count task
        center.enqueueNewUnlocks(from: caught)
        #expect(center.fullInputsPasses == before + 1)
        // A re-diff of the same rows (a sheet close after the catch). The
        // post-geocode re-diff only fires after a stamp, so it always misses;
        // lateStampOnTheNewCatchDoesOneMorePass covers that.
        center.enqueueNewUnlocks(from: caught)
        #expect(center.fullInputsPasses == before + 1)
    }

    @Test func lateStampOnTheNewCatchDoesOneMorePass() {
        let center = isolatedCenter()
        let fresh = newCatch(icao: "f00d02")
        fresh.country = nil
        let rows = [fresh] + Self.hangar10k
        center.enqueueNewUnlocks(from: rows)
        let before = center.fullInputsPasses
        fresh.country = "Country 39"                  // the geocode's late stamp
        center.enqueueNewUnlocks(from: rows)
        #expect(center.fullInputsPasses == before + 1)
    }

    /// Profile re-renders on every @AppStorage write (`loadStanding` writes
    /// points + rank on each open). Those writes must not change the memo
    /// key; a weekly-win change (a trophy input) must.
    @Test func profileTokenIgnoresPointsAndRankWrites() {
        let suite = UserDefaults(suiteName: "test.budget.profile.\(UUID().uuidString)")!
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        let rows = Self.hangar10k
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let box = DerivedCacheBox<ProfileDerived>()
        var computes = 0
        func render() {
            _ = box.value(for: ProfileDerived.token(catches: rows, events: events,
                                                    standing: standing, now: now)) {
                computes += 1
                return ProfileDerived(catches: rows, events: events, standing: standing, now: now)
            }
        }
        render()
        standing.update(from: MyStanding(rank: 12, points: 4_200))   // points/rank only
        render()
        render()
        #expect(computes == 1)
        standing.update(from: MyStanding(rank: 1, points: 4_300, weeklyWins: 1))
        render()
        #expect(computes == 2)
        // A new day changes the streak even with no new catch.
        _ = box.value(for: ProfileDerived.token(catches: rows, events: events, standing: standing,
                                                now: now.addingTimeInterval(86_400))) {
            computes += 1
            return ProfileDerived(catches: rows, events: events, standing: standing, now: now)
        }
        #expect(computes == 3)
    }

    // MARK: - 2. Wall-clock budgets (min of 3, ~5x headroom)

    /// Budgets and the measurements behind them live in `Budget` below.
    @Test func trophyInputsWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= Trophies.inputs(from: rows).totalCatches }
        print("[LargeHangarBudget] Trophies.inputs @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.inputs10k, "Trophies.inputs took \(t) s at 10k rows")
    }

    @Test func hangarGroupingWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= HangarGrouping.group(rows, by: .recent).count }
        print("[LargeHangarBudget] HangarGrouping.group @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.grouping10k, "HangarGrouping.group took \(t) s at 10k rows")
    }

    @Test func distinctMatchKeysWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= CardSets.distinctMatchKeys(for: rows).count }
        print("[LargeHangarBudget] CardSets.distinctMatchKeys @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.matchKeys10k, "distinctMatchKeys took \(t) s at 10k rows")
    }

    /// Not a budget: logs what a memo-hit re-diff costs (the hashing pass)
    /// next to a full pass, for the PR record. Asserts only the ordering.
    @Test func memoHitIsCheaperThanAFullPass() {
        let rows = Self.hangar10k
        let center = isolatedCenter()
        center.enqueueNewUnlocks(from: rows)
        let hit = fastest { center.enqueueNewUnlocks(from: rows) }
        let full = fastest { Self.sink &+= Trophies.inputs(from: rows).totalCatches }
        print("[LargeHangarBudget] re-diff @10k: memo hit \(Int(hit * 1000)) ms vs full inputs \(Int(full * 1000)) ms")
        #expect(hit < full)
    }

    /// Not a budget: logs what the token costs on the catch path, where both
    /// re-diffs (count task, post-geocode) miss and pay the hash ON TOP of a
    /// full pass. Asserts only the ordering: the token stays well under a
    /// full pass, or memoizing stops paying for itself.
    @Test func catchPathTokenOverheadIsLogged() {
        let rows = Self.hangar10k
        let token = fastest { Self.sink &+= TrophyInputsToken.of(rows) }
        let full = fastest { Self.sink &+= Trophies.inputs(from: rows).totalCatches }
        print("[LargeHangarBudget] catch path @10k: token \(Int(token * 1000)) ms per diff (x2 per catch) on top of full inputs \(Int(full * 1000)) ms per diff")
        #expect(token < full)
    }

    // MARK: - 3. Growth (10k → 20k under 3x)

    @Test func trophyInputsScalesLinearly() {
        let small = Self.hangar10k
        let large = Self.hangar20k
        let t10 = fastest { Self.sink &+= Trophies.inputs(from: small).totalCatches }
        let t20 = fastest { Self.sink &+= Trophies.inputs(from: large).totalCatches }
        print("[LargeHangarBudget] Trophies.inputs 10k \(Int(t10 * 1000)) ms → 20k \(Int(t20 * 1000)) ms (\(t20 / t10)x)")
        #expect(t20 < t10 * 3, "doubling the Hangar cost \(t20 / t10)x — something went quadratic")
    }

    // No growth check for HangarGrouping: at ~110-220 ms per 10k it sits at
    // the noise floor (one calibration run measured 20k FASTER than 10k), so
    // a ratio on it would flap. Its absolute budget above still guards it.

    /// Budgets in seconds, ~5x the Debug iPhone 17 simulator measurement at
    /// 10k rows (min of 3, 2026-10-22, with five other builders' test runs
    /// sharing the Mac): inputs 0.60-0.95 s, grouping 0.11-0.20 s, match
    /// keys 0.03-0.06 s (floored at 0.5 s — too short to budget tightly
    /// without flaps).
    private enum Budget {
        static let inputs10k = 5.0
        static let grouping10k = 1.0
        static let matchKeys10k = 0.5
    }
}
