//
//  LeaderboardStandingCache.swift
//  Tailspot
//
//  Device-local cache of the SERVER-truth leaderboard facts that trophies
//  read: weekly-champion win count and the ever-held-#1-all-time flag.
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
//  and ProfileScreen's WEEKLY CHAMPION laurel (its @AppStorage observes the
//  same `weeklyWins` key, so a write here refreshes the laurel live).
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
    static let everToppedAllTimeKey = "tailspot.standing.everToppedAllTime"

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
        if me.everToppedAllTime == true {
            defaults.set(true, forKey: Self.everToppedAllTimeKey)
        }
    }

    /// Weekly-champion crowns the server has credited this device.
    /// 0 = none (or never fetched — indistinguishable, and correctly locked).
    var weeklyWins: Int {
        defaults.integer(forKey: Self.weeklyWinsKey)
    }

    /// Whether this device has ever held #1 on the all-time board.
    var everToppedAllTime: Bool {
        defaults.bool(forKey: Self.everToppedAllTimeKey)
    }
}
