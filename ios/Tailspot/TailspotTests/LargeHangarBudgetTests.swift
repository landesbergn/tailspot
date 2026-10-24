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
//   1. Pass counts and memo hits. `TrophyUnlockCenter` counts its
//      full-Hangar `Trophies.inputs` passes (DEBUG only). An unchanged
//      re-diff (every sheet close) must do 0, one new catch exactly 1.
//      Exact, never flaky. THIS is the regression guard.
//   2. Wall-clock ceilings on the three heavy derivations, as the MINIMUM
//      of 3 runs (the least-disturbed run) against ~10x headroom over what
//      the Debug simulator measured. They run in the required Unit-tests
//      check on a shared macos-26 runner, so they only catch an
//      order-of-magnitude slip (a new per-row lookup gone quadratic), never
//      a 2x drift. A flapping required check blocks every merge under the
//      strict ruleset, so the ceilings stay this loose.
//   3. Growth: quadrupling the rows (2.5k → 10k) must cost under 10x.
//      Linear is ~4x and quadratic ~16x, so the gap is wide enough for a
//      shared runner's noise without depending on its absolute speed.
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

    /// 10,000 managed rows, built once for the whole suite (insert + fetch is
    /// a few seconds in Debug). The growth check's 2.5k Hangar takes every
    /// fourth row, NOT a prefix: the rows are newest-first, so a prefix would
    /// cover only the newest quarter of the 300 days and be a differently
    /// shaped Hangar.
    private static let hangar10k: [Catch] = makeHangar(count: 10_000)
    private static let hangar2500: [Catch] = stride(from: 0, to: hangar10k.count, by: 4).map { hangar10k[$0] }

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

    /// A throwaway UserDefaults suite. Callers `defer { drop(name) }` so the
    /// UUID-named plist doesn't pile up in the simulator across runs.
    private func makeSuite(_ prefix: String = "test.budget") -> (name: String, defaults: UserDefaults) {
        let name = "\(prefix).\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    private func drop(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func makeCenter(in suite: UserDefaults) -> TrophyUnlockCenter {
        TrophyUnlockCenter(
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
        let (suiteName, suite) = makeSuite()
        defer { drop(suiteName) }
        let center = makeCenter(in: suite)
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
        let (suiteName, suite) = makeSuite()
        defer { drop(suiteName) }
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
        let (suiteName, suite) = makeSuite()
        defer { drop(suiteName) }
        let center = makeCenter(in: suite)
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

    /// The first launch after an App Store update that bumps
    /// `Trophies.rosterVersion` (1.2.2 → 1.2.3 went 3 → 4): the ledger is
    /// already seeded, so the launch diff takes the reseed branch and grants
    /// the trophies the bump made earnable. That synchronous half is what a
    /// watchdog kill measures, so it must stay one inputs pass plus the one
    /// bounded date probe, with the rest parked for `finishAchievementDates`.
    /// Worst case on purpose: the previous build's ledger has no dates at
    /// all. The counts are the guard; the clock only catches one pass getting
    /// an order of magnitude more expensive.
    @Test func rosterBumpUpgradeLaunchIsOnePassAndBounded() {
        let (suiteName, suite) = makeSuite("test.budget.upgrade")
        defer { drop(suiteName) }
        let rows = Self.hangar10k
        let ledger = UserDefaultsTrophyLedger(defaults: suite)
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        // The previous build's roster lacked four trophies this Hangar earns;
        // seed its ledger directly, so no date pass has run.
        let inputs = Trophies.inputs(from: rows, events: events, standing: standing)
        let granted = Set(Trophies.roster.filter { $0.isEarned(inputs: inputs) }.prefix(4).map(\.id))
        #expect(granted.count == 4, "precondition: the fixture earns trophies to grant")
        let previous = Trophies.rosterVersion - 1
        TrophyUnlock.seed(inputs: inputs, roster: Trophies.roster.filter { !granted.contains($0.id) }, into: ledger)
        ledger.markRosterVersion(previous)
        #expect(ledger.achievedDates.isEmpty)

        let center = TrophyUnlockCenter(ledger: ledger, events: events, standing: standing)
        // Read before and after in one synchronous stretch on the main actor,
        // so no other suite's search can land in between.
        let evaluationsBefore = TrophyAchievementDates.prefixEvaluations
        let seconds = fastest(runs: 1) { center.enqueueNewUnlocks(from: rows) }
        let evaluations = TrophyAchievementDates.prefixEvaluations - evaluationsBefore
        print("[LargeHangarBudget] roster-bump upgrade launch @10k: \(Int(seconds * 1000)) ms")
        #expect(ledger.rosterVersion == Trophies.rosterVersion)
        #expect(Set(center.pendingEvents.map(\.achievementID)) == granted, "the reseed queues one card per granted trophy")
        #expect(center.fullInputsPasses == 1)
        #expect(evaluations <= 1, "the upgrade launch ran \(evaluations) date passes synchronously; the rest belong in finishAchievementDates")
        #expect(seconds < Budget.upgradeLaunch10k,
                "the upgrade launch diff took \(seconds) s at 10k rows, over a ~10x-headroom ceiling of \(Budget.upgradeLaunch10k) s: one launch pass got an order of magnitude more expensive")
    }

    @Test func lateStampOnTheNewCatchDoesOneMorePass() {
        let (suiteName, suite) = makeSuite()
        defer { drop(suiteName) }
        let center = makeCenter(in: suite)
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
        let (suiteName, suite) = makeSuite("test.budget.profile")
        defer { drop(suiteName) }
        let events = TrophyEventStore(defaults: suite)
        let standing = LeaderboardStandingCache(defaults: suite)
        let rows = Self.hangar10k
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let box = DerivedCacheBox<ProfileDerived>()
        var computes = 0
        // `streakOverride: nil` pins the key against the wrench panel's
        // UserDefaults.standard override, which a Debug test run could see.
        @discardableResult
        func render(at date: Date) -> ProfileDerived {
            box.value(for: ProfileDerived.token(catches: rows, events: events, standing: standing,
                                                now: date, streakOverride: nil)) {
                computes += 1
                return ProfileDerived(catches: rows, events: events, standing: standing, now: date)
            }
        }
        let first = render(at: now)
        standing.update(from: MyStanding(rank: 12, points: 4_200))   // points/rank only
        render(at: now)
        render(at: now)
        #expect(computes == 1)
        standing.update(from: MyStanding(rank: 1, points: 4_300, weeklyWins: 1))
        render(at: now)
        #expect(computes == 2)
        // Two days on with no new catch: the key rolls over, the recompute
        // runs at the NEW date, and the streak it serves has lapsed. (The
        // fixture's newest catch is at `now` and ~33 rows land per day, so
        // the streak is live at `now`.)
        #expect(first.streak.current > 0, "precondition: a live streak at the newest catch")
        let later = render(at: now.addingTimeInterval(2 * 86_400))
        #expect(computes == 3)
        #expect(later.streak.current == 0)
    }

    // MARK: - 2. Wall-clock ceilings (min of 3, ~10x headroom)

    /// Budgets and the measurements behind them live in `Budget` below.
    @Test func trophyInputsWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= Trophies.inputs(from: rows).totalCatches }
        print("[LargeHangarBudget] Trophies.inputs @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.inputs10k,
                "Trophies.inputs took \(t) s at 10k rows, over a ~10x-headroom ceiling of \(Budget.inputs10k) s: an order-of-magnitude slip, not runner noise")
    }

    @Test func hangarGroupingWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= HangarGrouping.group(rows, by: .recent).count }
        print("[LargeHangarBudget] HangarGrouping.group @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.grouping10k,
                "HangarGrouping.group took \(t) s at 10k rows, over a ~10x-headroom ceiling of \(Budget.grouping10k) s: an order-of-magnitude slip, not runner noise")
    }

    @Test func distinctMatchKeysWithinBudgetAt10k() {
        let rows = Self.hangar10k
        let t = fastest { Self.sink &+= CardSets.distinctMatchKeys(for: rows).count }
        print("[LargeHangarBudget] CardSets.distinctMatchKeys @10k: \(Int(t * 1000)) ms")
        #expect(t < Budget.matchKeys10k,
                "distinctMatchKeys took \(t) s at 10k rows, over a ~10x-headroom ceiling of \(Budget.matchKeys10k) s: an order-of-magnitude slip, not runner noise")
    }

    /// Not a budget: logs what a memo-hit re-diff costs (the hashing pass)
    /// next to a full pass, for the PR record. Asserts only the ordering.
    @Test func memoHitIsCheaperThanAFullPass() {
        let rows = Self.hangar10k
        let (suiteName, suite) = makeSuite()
        defer { drop(suiteName) }
        let center = makeCenter(in: suite)
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

    // MARK: - 3. Growth (2.5k → 10k under 10x)

    @Test func trophyInputsScalesLinearly() {
        let small = Self.hangar2500
        let large = Self.hangar10k
        let tSmall = fastest { Self.sink &+= Trophies.inputs(from: small).totalCatches }
        let tLarge = fastest { Self.sink &+= Trophies.inputs(from: large).totalCatches }
        let ratio = tLarge / tSmall
        print("[LargeHangarBudget] Trophies.inputs 2.5k \(Int(tSmall * 1000)) ms → 10k \(Int(tLarge * 1000)) ms (\(ratio)x)")
        #expect(ratio < 10, "4x the rows cost \(ratio)x (linear ≈ 4x, quadratic ≈ 16x) — something went quadratic")
    }

    // No growth check for HangarGrouping: at ~110-220 ms per 10k it sits at
    // the noise floor (one calibration run measured 20k FASTER than 10k), so
    // a ratio on it would flap. Its absolute budget above still guards it.

    /// Ceilings in seconds, ~10x the Debug iPhone 17 simulator measurement
    /// at 10k rows (min of 3, 2026-10-22, with five other builders' test runs
    /// sharing the Mac): inputs 0.60-0.95 s, grouping 0.11-0.20 s, match
    /// keys 0.03-0.06 s (floored at 1 s — too short to bound tightly without
    /// flaps). The roster-bump upgrade launch (an inputs pass plus a ~10k-row
    /// prefix pass; a single run, not min of 3, because a second run would
    /// find the ledger already stamped) measured 1.84 s on 2026-10-24 with a
    /// simulator build running alongside, so its ceiling is ~10x that. The
    /// clock is not what catches a launch running the full date search: 20
    /// passes measured ~9 s, under it. The pass counts catch that.
    /// Deliberately generous: these gate the required CI check on a
    /// shared runner. If one ever trips on noise, raise it; the pass-count
    /// tests above are the precise guard.
    private enum Budget {
        static let inputs10k = 10.0
        static let grouping10k = 2.0
        static let matchKeys10k = 1.0
        static let upgradeLaunch10k = 20.0
    }
}
