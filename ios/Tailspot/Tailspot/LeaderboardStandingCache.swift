//
//  LeaderboardStandingCache.swift
//  Tailspot
//
//  Device-local cache of the SERVER-truth leaderboard facts that trophies
//  read: weekly/monthly champion win counts and the ever-held-#1-all-time flag.
//  Both are computed exclusively by the backend (Monday crowning /
//  `alltime_toppers` ledger) and reach the device only inside a
//  GET /v1/leaderboard `me` payload — the app must NEVER infer a win
//  locally (a device can't know it held #1 at the closing bell).
//
//  Writes happen in the SCREENS' fetch completions (ProfileScreen's
//  `loadStanding`, LeaderboardScreen's `load`) via `update(from:)` — a
//  deliberate choice over hooking the client's decode path, so the network
//  layer stays side-effect free and every cache write is visible at the
//  call site.
//
//  Reads feed `TrophyProgressInputs` (Top Flight / Dynasty / Chart Topper)
//  and ProfileScreen's WEEKLY/MONTHLY CHAMPION laurels (their @AppStorage
//  values observe the same win-count keys, so a write refreshes them live).
//  Offline degradation falls out of the storage: the last-fetched values
//  persist across launches, and a fresh install that has never reached the
//  backend reads 0 / false — all three trophies locked.
//
//  Same shape as `TrophyEventStore`: a concrete `nonisolated` struct over
//  UserDefaults (thread-safe accessors); tests inject an isolated
//  `UserDefaults(suiteName:)`.
//

import Foundation

nonisolated struct LeaderboardStandingCache {

    /// Shared with ProfileScreen's `@AppStorage` laurel — introduced in the
    /// dynamic-leaderboards PR2 round; stable once shipped.
    static let weeklyWinsKey = "tailspot.standing.weeklyWins"
    static let monthlyWinsKey = "tailspot.standing.monthlyWins"
    static let everToppedAllTimeKey = "tailspot.standing.everToppedAllTime"
    /// Latched the first time a WEEK-window response ranks this device
    /// (in-window points > 0). Earns a notification decliner the one
    /// re-offer (StreakReminders.reoffer).
    static let everPlacedWeeklyKey = "tailspot.standing.everPlacedWeekly"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Absorb the server facts carried by a leaderboard response's `me`.
    /// Nil fields (the pre-windows backend) leave the cache untouched.
    ///
    /// `weeklyWins` mirrors the server count as-is (the server may re-crown /
    /// correct, and shared crowns count each sharer — all server business).
    /// `everToppedAllTime` only LATCHES true: the fact is monotonic by
    /// definition ("ever"), so a transient false — say, a response from a
    /// backend mid-migration — must not un-earn a trophy the user saw.
    func update(from me: MyStanding) {
        if let wins = me.weeklyWins {
            defaults.set(wins, forKey: Self.weeklyWinsKey)
        }
        if let wins = me.monthlyWins {
            defaults.set(wins, forKey: Self.monthlyWinsKey)
        }
        if me.everToppedAllTime == true {
            defaults.set(true, forKey: Self.everToppedAllTimeKey)
        }
    }

    /// A response counts as a weekly-board placement when the server echoed
    /// the week window (the pre-windows backend ignores the param and
    /// answers all-time) and ranked me. Rank 0 is the server's "unranked"
    /// sentinel for zero in-window points.
    static func isWeeklyPlacement(window: String?, rank: Int) -> Bool {
        window == LeaderboardWindow.week.rawValue && rank >= 1
    }

    /// Latch the placement fact from a leaderboard response. Monotonic like
    /// `everToppedAllTime`: a later unranked week doesn't un-place.
    func notePlacement(window: String?, me: MyStanding) {
        if Self.isWeeklyPlacement(window: window, rank: me.rank) {
            defaults.set(true, forKey: Self.everPlacedWeeklyKey)
        }
    }

    var everPlacedWeekly: Bool {
        defaults.bool(forKey: Self.everPlacedWeeklyKey)
    }

    /// Weekly-champion crowns the server has credited this device.
    /// 0 = none (or never fetched — indistinguishable, and correctly locked).
    var weeklyWins: Int {
        defaults.integer(forKey: Self.weeklyWinsKey)
    }

    /// Monthly-champion crowns the server has credited this device.
    var monthlyWins: Int {
        defaults.integer(forKey: Self.monthlyWinsKey)
    }

    /// Whether this device has ever held #1 on the all-time board.
    var everToppedAllTime: Bool {
        defaults.bool(forKey: Self.everToppedAllTimeKey)
    }
}
