import Foundation

/// Recovers the first qualifying catch under the current trophy rules. Dates
/// are stored independently of the celebration queue, including on upgrade and
/// restore. Server standings only contain counts/flags, not achievement dates;
/// those stay unknown instead of being stamped with the date of a later fetch.
@MainActor
enum TrophyAchievementDates {
    static func recordMissing(
        from catches: [Catch],
        inputs: TrophyProgressInputs,
        roster: [Achievement] = Trophies.roster,
        ledger: UserDefaultsTrophyLedger = UserDefaultsTrophyLedger(),
        events: TrophyEventStore = TrophyEventStore()
    ) {
        let known = ledger.achievedDates
        let missing = roster.filter { known[$0.id] == nil && $0.isEarned(inputs: inputs) }
        guard !missing.isEmpty else { return }
        var dates: [String: Date] = [:]
        if missing.contains(where: { $0.id == "groundstop" }),
           let date = events.firstOccurredAt(.groundedCatchAttempt) {
            dates["groundstop"] = date
        }

        // Exclude current non-catch facts from historical prefixes. Otherwise
        // an old catch could incorrectly inherit today's leaderboard crown.
        func catchOnly(_ input: TrophyProgressInputs) -> TrophyProgressInputs {
            var result = input
            result.triedGroundedCatch = false
            result.weeklyWins = 0
            result.everToppedAllTime = false
            return result
        }
        let eligible = missing.filter { $0.isEarned(inputs: catchOnly(inputs)) }
        guard !catches.isEmpty, !eligible.isEmpty else {
            ledger.recordAchievementDates(dates)
            return
        }
        let sorted = catches.sorted { $0.caughtAt < $1.caughtAt }
        var prefixes = [0: TrophyProgressInputs.zero, sorted.count: catchOnly(inputs)]
        func prefix(_ count: Int) -> TrophyProgressInputs {
            if let cached = prefixes[count] { return cached }
            let value = catchOnly(Trophies.inputs(from: Array(sorted.prefix(count))))
            prefixes[count] = value
            return value
        }
        // All catch-based roster metrics are monotonic over chronological
        // prefixes. Share cached evaluations across trophies rather than
        // replaying the entire Hangar once per trophy or per rendered row.
        for achievement in eligible where !achievement.isEarned(inputs: .zero) {
            var lower = 1
            var upper = sorted.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if achievement.isEarned(inputs: prefix(middle)) {
                    upper = middle
                } else {
                    lower = middle + 1
                }
            }
            dates[achievement.id] = sorted[lower - 1].caughtAt
        }
        ledger.recordAchievementDates(dates)
    }
}
