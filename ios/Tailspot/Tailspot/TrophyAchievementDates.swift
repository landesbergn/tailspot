import Foundation
import SwiftData

/// Recovers the first qualifying catch under the current trophy rules. Dates
/// are stored independently of the celebration queue, including on upgrade and
/// restore. Server standings only contain counts/flags, not achievement dates;
/// those stay unknown instead of being stamped with the date of a later fetch.
///
/// Cost model (the 1.2.0 launch hang): every probe is a full
/// `Trophies.inputs` pass over a chronological prefix of the Hangar, and an
/// upgrade from a build without dates searches every earned trophy at once —
/// tens of full-Hangar passes. A 4,600-catch Hangar took ~36 s on the main
/// thread, so the launch watchdog killed the app before the first frame, and
/// because dates were only written at the end, every relaunch started over.
/// So: dates are persisted the moment each search finishes, synchronous
/// callers pass an evaluation budget, and the bulk of the work runs through
/// `backfill`, which yields to the UI between probes.
@MainActor
enum TrophyAchievementDates {
    /// Synchronous search. With the default budget it dates everything; pass
    /// `maxEvaluations` to bound the work (each evaluation is one prefix pass).
    /// Returns `true` when nothing is left to date.
    @discardableResult
    static func recordMissing(
        from catches: [Catch],
        inputs: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        events: TrophyEventStore = TrophyEventStore(),
        maxEvaluations: Int = .max
    ) -> Bool {
        guard var search = Search(catches: catches, inputs: inputs, roster: roster,
                                  ledger: ledger, events: events) else { return true }
        var evaluations = 0
        while let count = search.advance(ledger: ledger) {
            guard evaluations < maxEvaluations else { return false }
            search.evaluate(count)
            evaluations += 1
        }
        return true
    }

    /// The same search, run cooperatively: it suspends for `pause` before
    /// every prefix pass so touches and frames get through, and stops early
    /// if the task is cancelled or any of the rows it is reading leaves its
    /// context (a Hangar delete — its properties can no longer be read).
    /// Already-found dates are persisted, so a stopped run resumes cheaply.
    static func backfill(
        from catches: [Catch],
        inputs: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        events: TrophyEventStore = TrophyEventStore(),
        pause: Duration = .milliseconds(10)
    ) async {
        // Unattached rows (tests, previews) have no context to leave. On
        // entry, only a deleted-but-unsaved row is detectable (a saved delete
        // looks like an unattached row); callers start the backfill in the
        // same turn as their fetch, so later deletes hit the in-loop check.
        let attached = catches.filter { $0.modelContext != nil }
        guard !catches.contains(where: { $0.isDeleted }) else { return }
        guard var search = Search(catches: catches, inputs: inputs, roster: roster,
                                  ledger: ledger, events: events) else { return }
        while let count = search.advance(ledger: ledger) {
            try? await Task.sleep(for: pause)
            if Task.isCancelled || attached.contains(where: CatchUploader.isGone) { return }
            search.evaluate(count)
        }
    }

    /// Resumable binary-search state shared by both entry points. `advance`
    /// walks every trophy as far as the cached prefixes allow, persisting each
    /// date as soon as its search ends, and returns the next prefix length it
    /// needs evaluated (nil when every eligible trophy is dated).
    private struct Search {
        let sorted: [Catch]
        var prefixes: [Int: TrophyProgressInputs]
        var queue: [Achievement]
        var lower = 1
        var upper: Int
        var checkedNewest = false

        init?(catches: [Catch], inputs: TrophyProgressInputs, roster: [Achievement],
              ledger: UserDefaultsTrophyLedger, events: TrophyEventStore) {
            let known = ledger.achievedDates
            let missing = roster.filter { known[$0.id] == nil && $0.isEarned(inputs: inputs) }
            guard !missing.isEmpty else { return nil }
            if missing.contains(where: { $0.id == "groundstop" }),
               let date = events.firstOccurredAt(.groundedCatchAttempt) {
                ledger.recordAchievementDates(["groundstop": date])
            }
            let final = Search.catchOnly(inputs)
            let eligible = missing.filter {
                $0.isEarned(inputs: final) && !$0.isEarned(inputs: .zero)
            }
            guard !catches.isEmpty, !eligible.isEmpty else { return nil }
            sorted = catches.sorted { $0.caughtAt < $1.caughtAt }
            prefixes = [0: .zero, sorted.count: final]
            queue = eligible
            upper = sorted.count
        }

        // Exclude current non-catch facts from historical prefixes. Otherwise
        // an old catch could incorrectly inherit today's leaderboard crown.
        static func catchOnly(_ input: TrophyProgressInputs) -> TrophyProgressInputs {
            var result = input
            result.triedGroundedCatch = false
            result.weeklyWins = 0
            result.everToppedAllTime = false
            return result
        }

        mutating func evaluate(_ count: Int) {
            prefixes[count] = Search.catchOnly(Trophies.inputs(from: Array(sorted.prefix(count))))
        }

        mutating func advance(ledger: UserDefaultsTrophyLedger) -> Int? {
            // Newest-catch fast path, shared by every trophy: anything not yet
            // earned one catch ago was crossed by the latest catch. That is
            // the steady-state case (a live unlock), so it costs one prefix
            // pass no matter how many trophies the catch crossed.
            if !checkedNewest {
                let newest = sorted.count - 1
                if newest >= 1 {
                    guard let previous = prefixes[newest] else { return newest }
                    let crossed = queue.filter { !$0.isEarned(inputs: previous) }
                    var dates: [String: Date] = [:]
                    for achievement in crossed { dates[achievement.id] = sorted[newest].caughtAt }
                    ledger.recordAchievementDates(dates)
                    queue.removeAll { dates[$0.id] != nil }
                    upper = newest
                }
                checkedNewest = true
            }
            // All catch-based roster metrics are monotonic over chronological
            // prefixes, so each remaining trophy is a binary search; cached
            // prefixes are shared across trophies.
            while let achievement = queue.first {
                if lower >= upper {
                    ledger.recordAchievementDates([achievement.id: sorted[lower - 1].caughtAt])
                    queue.removeFirst()
                    lower = 1
                    upper = checkedNewest && sorted.count >= 2 ? sorted.count - 1 : sorted.count
                    continue
                }
                let middle = (lower + upper) / 2
                guard let probe = prefixes[middle] else { return middle }
                if achievement.isEarned(inputs: probe) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            return nil
        }
    }
}
