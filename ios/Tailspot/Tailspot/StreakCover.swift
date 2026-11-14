//
//  StreakCover.swift
//  Tailspot
//
//  Covered days: days with no catch that still don't break a streak. Three
//  things can cover a day, and they all end up in the one set that
//  `Streaks.coveredDays()` hands every streak reader:
//
//  1. A FREEZE, earned and spent automatically. Every `daysPerFreeze`
//     streak days earns one (at most `maxFreezes` held). A missed day spends
//     one the next time the app runs, with no action from the user.
//  2. A REPAIR, offered by hand. When a miss wasn't covered by a freeze, the
//     user can repair it from the Profile for `repairWindowDays` days, once
//     every `repairCooldownDays` days.
//  3. A FORGIVEN day, declared by the operator for everyone (an FAA ground
//     stop, say). The app reads the list from `GET /v1/streak-forgiveness`;
//     the push that announces it is only the announcement.
//
//  A covered day bridges a streak and never counts toward it
//  (`Streaks.currentStreak`), so every counted day is still a real catch.
//
//  Shape follows the repo's planner convention: pure, clock-free rules
//  (`StreakCover`) that carry every guardrail and are unit-tested; a thin
//  UserDefaults store; and a small coordinator the app calls on foreground
//  and at catch time. Local-only like the Hangar: deleting the app loses
//  held freezes and past freeze/repair days.
//

import Foundation
import os

/// One operator-forgiven day, as served by the backend.
nonisolated struct ForgivenDay: Codable, Equatable, Sendable {
    let day: String
    let reason: String
}

/// Everything this install remembers about freezes and repairs.
nonisolated struct StreakLedger: Codable, Equatable, Sendable {
    var freezesHeld = 0
    /// Days a freeze covered.
    var freezeDays: [String] = []
    /// Days the user repaired by hand.
    var repairedDays: [String] = []
    /// The day the last repair was MADE (not the day it covered); the
    /// cooldown runs from here.
    var lastRepairDay: String?
    /// The catch-day that last earned (or would have earned) a freeze, so
    /// one day can never award twice.
    var lastAwardDay: String?
    /// Forgiven days already announced in a toast.
    var announcedForgiven: [String] = []
    /// The missed day the repair toast last pointed at.
    var repairAnnouncedFor: String?

    var coveredDays: Set<String> { Set(freezeDays).union(repairedDays) }
}

nonisolated enum StreakCover {
    static let maxFreezes = 2
    static let daysPerFreeze = 7
    /// Freezes and repairs only protect a streak of at least this many
    /// days. Spending the monthly repair, or a freeze that took a week to
    /// earn, on a one-day streak protects nothing worth the cost.
    static let protectedMinimum = 2
    /// A miss can be repaired while it is yesterday or the day before.
    static let repairWindowDays = 2
    static let repairCooldownDays = 30

    // MARK: Earning

    /// A new install of this feature starts with what its live streak has
    /// already earned, so a 20-day streak isn't told to start from zero.
    static func seededLedger(currentStreak: Int) -> StreakLedger {
        StreakLedger(freezesHeld: min(maxFreezes, max(0, currentStreak) / daysPerFreeze))
    }

    /// Called on the first catch of a day with the streak it produced.
    /// Returns whether a freeze was actually added (false at the cap).
    static func award(
        _ ledger: StreakLedger, streakAfterCatch: Int, todayKey: String
    ) -> (ledger: StreakLedger, earned: Bool) {
        guard streakAfterCatch > 0,
              streakAfterCatch % daysPerFreeze == 0,
              ledger.lastAwardDay != todayKey else { return (ledger, false) }
        var next = ledger
        next.lastAwardDay = todayKey
        guard next.freezesHeld < maxFreezes else { return (next, false) }
        next.freezesHeld += 1
        return (next, true)
    }

    // MARK: Spending

    struct FreezeUse: Equatable, Sendable {
        /// The missed days now covered, oldest last.
        let days: [String]
        /// The streak those freezes kept alive.
        let streakKept: Int
    }

    /// Spend freezes on the uncovered missed days between the last catch
    /// and today, if the freezes held cover ALL of them. A gap the freezes
    /// can't fully bridge spends nothing: half a bridge saves no streak.
    /// Today itself is never settled; it is still open.
    static func settle(
        _ ledger: StreakLedger,
        catchDays: Set<String>,
        forgiven: Set<String>,
        todayKey: String
    ) -> (ledger: StreakLedger, used: FreezeUse?) {
        guard ledger.freezesHeld > 0, let earliest = catchDays.min() else { return (ledger, nil) }
        let covered = forgiven.union(ledger.coveredDays)
        var missed: [String] = []
        var cursor = todayKey
        var anchor: String?
        while let prev = Streaks.key(byAdding: -1, to: cursor), prev >= earliest {
            if catchDays.contains(prev) { anchor = prev; break }
            if !covered.contains(prev) {
                missed.append(prev)
                if missed.count > ledger.freezesHeld { return (ledger, nil) }
            }
            cursor = prev
        }
        guard let anchor, !missed.isEmpty else { return (ledger, nil) }
        let stake = Streaks.currentStreak(days: catchDays, todayKey: anchor, covered: covered)
        guard stake >= protectedMinimum else { return (ledger, nil) }
        var next = ledger
        next.freezesHeld -= missed.count
        next.freezeDays.append(contentsOf: missed)
        // The kept streak counts a catch already made today.
        let kept = Streaks.currentStreak(
            days: catchDays, todayKey: todayKey, covered: covered.union(missed))
        return (next, FreezeUse(days: missed, streakKept: kept))
    }

    // MARK: Repair

    struct RepairOffer: Equatable, Sendable {
        let missedDay: String
        /// The streak the user gets back by repairing.
        let streakRestored: Int
    }

    /// The one repair on offer, if any: a single uncovered missed day,
    /// yesterday or the day before, whose bridging rejoins a streak of at
    /// least `protectedMinimum` to the present, outside the cooldown. Two
    /// missed days in a row are not repairable.
    static func repairOffer(
        _ ledger: StreakLedger,
        catchDays: Set<String>,
        forgiven: Set<String>,
        todayKey: String
    ) -> RepairOffer? {
        if let last = ledger.lastRepairDay,
           let ready = Streaks.key(byAdding: repairCooldownDays, to: last),
           todayKey < ready {
            return nil
        }
        let covered = forgiven.union(ledger.coveredDays)
        var between: [String] = []   // days after the candidate, before today
        var candidate = todayKey
        for _ in 0..<repairWindowDays {
            guard let day = Streaks.key(byAdding: -1, to: candidate) else { return nil }
            candidate = day
            if catchDays.contains(day) || covered.contains(day) {
                between.append(day)
                continue
            }
            // `day` is an uncovered miss. Everything after it is caught or
            // covered (or the loop would have stopped at a later miss).
            // With `day` as "today", currentStreak reads the run that ended
            // the day before it.
            let before = Streaks.currentStreak(days: catchDays, todayKey: day, covered: covered)
            guard before >= protectedMinimum else { return nil }
            let restored = Streaks.currentStreak(
                days: catchDays, todayKey: todayKey, covered: covered.union([day]))
            return RepairOffer(missedDay: day, streakRestored: restored)
        }
        return nil
    }

    static func repair(
        _ ledger: StreakLedger, offer: RepairOffer, todayKey: String
    ) -> StreakLedger {
        var next = ledger
        next.repairedDays.append(offer.missedDay)
        next.lastRepairDay = todayKey
        return next
    }

    // MARK: Foreground pass

    /// What one foreground changed, for telemetry and the toast.
    struct Pass: Equatable, Sendable {
        var ledger: StreakLedger
        var freezeUse: FreezeUse?
        /// Set only the first time this missed day is pointed at.
        var repairToAnnounce: RepairOffer?
        /// Set only the first time this forgiven day is announced.
        var forgivenToAnnounce: ForgivenDay?
        /// The single line to show, most important first.
        var toastLine: String?
    }

    /// Everything a foreground does, pure: spend freezes, then decide the
    /// one thing worth saying. A freeze that saved the streak outranks a
    /// repair offer, which outranks a forgiveness note.
    static func foregroundPass(
        _ ledger: StreakLedger,
        catchDays: Set<String>,
        forgiven: [ForgivenDay],
        todayKey: String
    ) -> Pass {
        let forgivenKeys = Set(forgiven.map(\.day))
        let settled = settle(ledger, catchDays: catchDays, forgiven: forgivenKeys, todayKey: todayKey)
        var pass = Pass(ledger: settled.ledger, freezeUse: settled.used)
        let covered = forgivenKeys.union(pass.ledger.coveredDays)
        let current = Streaks.currentStreak(days: catchDays, todayKey: todayKey, covered: covered)

        if let offer = repairOffer(pass.ledger, catchDays: catchDays,
                                   forgiven: forgivenKeys, todayKey: todayKey),
           pass.ledger.repairAnnouncedFor != offer.missedDay {
            pass.ledger.repairAnnouncedFor = offer.missedDay
            pass.repairToAnnounce = offer
        }

        // A forgiven day is worth a line only while it is today or
        // yesterday, only if it actually spared this user a catch, and only
        // while there is a streak for it to have spared.
        let yesterday = Streaks.key(byAdding: -1, to: todayKey)
        if current > 0,
           let day = forgiven.last(where: {
               ($0.day == todayKey || $0.day == yesterday)
                   && !catchDays.contains($0.day)
                   && !pass.ledger.announcedForgiven.contains($0.day)
           }) {
            pass.ledger.announcedForgiven.append(day.day)
            pass.forgivenToAnnounce = day
        }

        if let use = pass.freezeUse {
            pass.toastLine = freezeUsedLine(use, todayKey: todayKey)
        } else if let offer = pass.repairToAnnounce {
            pass.toastLine = repairAvailableLine(offer, todayKey: todayKey)
        } else if let day = pass.forgivenToAnnounce {
            pass.toastLine = forgivenLine(day, todayKey: todayKey)
        }
        return pass
    }

    // MARK: Copy (dry voice)

    static func freezeUsedLine(_ use: FreezeUse, todayKey: String) -> String {
        if use.days.count == 1, let day = use.days.first {
            return "Freeze used for \(Streaks.dayPhrase(forKey: day, todayKey: todayKey)). "
                + "\(use.streakKept)-day streak intact."
        }
        return "\(use.days.count) freezes used. \(use.streakKept)-day streak intact."
    }

    static func repairAvailableLine(_ offer: RepairOffer, todayKey: String) -> String {
        "Missed \(Streaks.dayPhrase(forKey: offer.missedDay, todayKey: todayKey)). "
            + "Repair your \(offer.streakRestored)-day streak in Profile."
    }

    static func forgivenLine(_ day: ForgivenDay, todayKey: String) -> String {
        if day.day == todayKey { return "No catch needed today: \(day.reason)." }
        let phrase = Streaks.dayPhrase(forKey: day.day, todayKey: todayKey)
        return "\(phrase.prefix(1).uppercased())\(phrase.dropFirst()) didn't count against your streak: \(day.reason)."
    }

    /// Profile line under the streak when a repair is on offer.
    static func repairPrompt(_ offer: RepairOffer, todayKey: String) -> String {
        "Missed \(Streaks.dayPhrase(forKey: offer.missedDay, todayKey: todayKey)). "
            + "\(offer.streakRestored) days at stake."
    }

    static let repairButtonTitle = "Repair streak"

    // MARK: Wire validation

    /// Keep only well-formed rows from the server: a real "yyyy-MM-dd" key
    /// and a non-empty reason, trimmed to something a toast can hold.
    static func sanitized(_ days: [ForgivenDay]) -> [ForgivenDay] {
        var seen = Set<String>()
        return days.compactMap { row in
            let reason = row.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard row.day.count == 10,
                  let next = Streaks.key(byAdding: 1, to: row.day),
                  Streaks.key(byAdding: -1, to: next) == row.day,
                  !reason.isEmpty,
                  seen.insert(row.day).inserted else { return nil }
            return ForgivenDay(day: row.day, reason: String(reason.prefix(80)))
        }
        .sorted { $0.day < $1.day }
    }
}

// MARK: - Store

/// UserDefaults persistence for the ledger and the cached forgiveness list.
/// Reads are cheap (two small JSON blobs) and happen on every streak read,
/// which is what keeps every reader on the same covered set.
nonisolated enum StreakCoverStore {
    static let ledgerKey = "tailspot.streak.ledger.v1"
    static let forgivenKey = "tailspot.streak.forgiven.v1"

    /// nil until the feature has run once on this install (see
    /// `StreakCover.seededLedger`).
    static func ledger(defaults: UserDefaults = .standard) -> StreakLedger? {
        guard let data = defaults.data(forKey: ledgerKey) else { return nil }
        return try? JSONDecoder().decode(StreakLedger.self, from: data)
    }

    static func save(_ ledger: StreakLedger, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: ledgerKey)
    }

    static func forgiven(defaults: UserDefaults = .standard) -> [ForgivenDay] {
        guard let data = defaults.data(forKey: forgivenKey) else { return [] }
        return (try? JSONDecoder().decode([ForgivenDay].self, from: data)) ?? []
    }

    /// Replace the cache with the server's list. Wholesale, not a union: the
    /// server returns every day it has ever forgiven, and replacing is what
    /// lets the operator take back a day declared by mistake.
    static func saveForgiven(_ days: [ForgivenDay], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(days) else { return }
        defaults.set(data, forKey: forgivenKey)
    }

    /// A hash of everything stored here, for memo keys that must recompute
    /// when the covered set or the freeze count changes.
    static func stateToken(defaults: UserDefaults = .standard) -> Int {
        var hasher = Hasher()
        hasher.combine(defaults.data(forKey: ledgerKey))
        hasher.combine(defaults.data(forKey: forgivenKey))
        return hasher.finalize()
    }

    static func coveredDays(defaults: UserDefaults = .standard) -> Set<String> {
        Set(forgiven(defaults: defaults).map(\.day))
            .union(ledger(defaults: defaults)?.coveredDays ?? [])
    }
}

// MARK: - Client

/// `GET /v1/streak-forgiveness` → `{ "days": [ { "day", "reason" } ] }`.
/// Public and cached server-side; no bearer token.
nonisolated struct StreakForgivenessClient {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL = TailspotAccountClient.defaultBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct Envelope: Decodable {
        let days: [ForgivenDay]
    }

    static func decode(_ data: Data) throws -> [ForgivenDay] {
        StreakCover.sanitized(try JSONDecoder().decode(Envelope.self, from: data).days)
    }

    func fetch() async throws -> [ForgivenDay] {
        guard let url = URL(string: "v1/streak-forgiveness", relativeTo: baseURL)?.absoluteURL else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }
}

// MARK: - Telemetry

nonisolated enum StreakCoverTelemetry {
    static let freezeEarnedEvent = "streak_freeze_earned"
    static let freezeUsedEvent = "streak_freeze_used"
    static let repairOfferedEvent = "streak_repair_offered"
    static let repairedEvent = "streak_repaired"
    static let forgivenessAppliedEvent = "streak_forgiveness_applied"

    static func freezeEarnedProperties(streakDays: Int, held: Int) -> [String: AnalyticsValue] {
        ["streak_days": .int(streakDays), "freezes_held": .int(held)]
    }

    static func freezeUsedProperties(_ use: StreakCover.FreezeUse, held: Int) -> [String: AnalyticsValue] {
        ["days_covered": .int(use.days.count), "streak_days": .int(use.streakKept),
         "freezes_held": .int(held)]
    }

    static func repairProperties(_ offer: StreakCover.RepairOffer) -> [String: AnalyticsValue] {
        ["missed_day": .string(offer.missedDay), "streak_days": .int(offer.streakRestored)]
    }

    static func forgivenessProperties(_ day: ForgivenDay) -> [String: AnalyticsValue] {
        ["day_key": .string(day.day), "reason": .string(day.reason)]
    }
}

// MARK: - Coordinator

/// The three moments the ledger changes: a foreground, a catch, and a tap
/// on Repair. Each loads, applies a pure rule, saves and reports.
nonisolated enum StreakCoverCenter {

    /// The ledger, created on first use from the streak the Hangar already
    /// holds.
    static func loadOrSeed(
        catchDays: Set<String>, todayKey: String, defaults: UserDefaults = .standard
    ) -> StreakLedger {
        if let ledger = StreakCoverStore.ledger(defaults: defaults) { return ledger }
        let forgiven = Set(StreakCoverStore.forgiven(defaults: defaults).map(\.day))
        let seeded = StreakCover.seededLedger(
            currentStreak: Streaks.currentStreak(days: catchDays, todayKey: todayKey, covered: forgiven))
        StreakCoverStore.save(seeded, defaults: defaults)
        return seeded
    }

    /// On every foreground, before the reminder re-plan (which must see the
    /// covered days this produces): refresh the forgiven list, spend
    /// freezes on any missed days, and return the toast line to show, if
    /// any. A failed fetch keeps the cached list.
    ///
    /// Takes the day set, not the rows: this runs off the main actor (it
    /// awaits the network), and SwiftData models must not follow it there.
    static func foreground(
        catchDays: Set<String>,
        now: Date = Date(),
        client: StreakForgivenessClient = StreakForgivenessClient(),
        defaults: UserDefaults = .standard
    ) async -> String? {
        do {
            StreakCoverStore.saveForgiven(try await client.fetch(), defaults: defaults)
        } catch {
            Log.ui.debug("Streak forgiveness fetch failed: \(String(describing: error), privacy: .public)")
        }
        let todayKey = Streaks.dayKey(for: now)
        let ledger = loadOrSeed(catchDays: catchDays, todayKey: todayKey, defaults: defaults)
        let pass = StreakCover.foregroundPass(
            ledger, catchDays: catchDays,
            forgiven: StreakCoverStore.forgiven(defaults: defaults), todayKey: todayKey)
        if pass.ledger != ledger { StreakCoverStore.save(pass.ledger, defaults: defaults) }
        if let use = pass.freezeUse {
            Log.ui.notice("Streak freeze used for \(use.days.count, privacy: .public) day(s)")
            Analytics.capture(StreakCoverTelemetry.freezeUsedEvent,
                              StreakCoverTelemetry.freezeUsedProperties(use, held: pass.ledger.freezesHeld))
        }
        if let offer = pass.repairToAnnounce {
            Analytics.capture(StreakCoverTelemetry.repairOfferedEvent,
                              StreakCoverTelemetry.repairProperties(offer))
        }
        if let day = pass.forgivenToAnnounce {
            Analytics.capture(StreakCoverTelemetry.forgivenessAppliedEvent,
                              StreakCoverTelemetry.forgivenessProperties(day))
        }
        return pass.toastLine
    }

    /// At catch time, BEFORE the streak for the reveal is read: a catch can
    /// beat the foreground pass (a notification tap straight into a catch),
    /// and the reveal must not show a streak the freeze was about to save
    /// as broken. `priorDays` is the real day set without this catch.
    static func settleBeforeCatch(
        priorDays: Set<String>, todayKey: String, defaults: UserDefaults = .standard
    ) {
        let ledger = loadOrSeed(catchDays: priorDays, todayKey: todayKey, defaults: defaults)
        let forgiven = Set(StreakCoverStore.forgiven(defaults: defaults).map(\.day))
        let settled = StreakCover.settle(
            ledger, catchDays: priorDays, forgiven: forgiven, todayKey: todayKey)
        guard let use = settled.used else { return }
        StreakCoverStore.save(settled.ledger, defaults: defaults)
        Analytics.capture(StreakCoverTelemetry.freezeUsedEvent,
                          StreakCoverTelemetry.freezeUsedProperties(use, held: settled.ledger.freezesHeld))
    }

    /// On the first catch of a day, with the real streak it produced.
    static func awardIfEarned(
        streakAfterCatch: Int, todayKey: String, defaults: UserDefaults = .standard
    ) {
        guard let ledger = StreakCoverStore.ledger(defaults: defaults) else { return }
        let result = StreakCover.award(ledger, streakAfterCatch: streakAfterCatch, todayKey: todayKey)
        guard result.ledger != ledger else { return }
        StreakCoverStore.save(result.ledger, defaults: defaults)
        if result.earned {
            Analytics.capture(
                StreakCoverTelemetry.freezeEarnedEvent,
                StreakCoverTelemetry.freezeEarnedProperties(
                    streakDays: streakAfterCatch, held: result.ledger.freezesHeld))
        }
    }

    /// What the Profile streak row needs beyond the summary.
    struct Status: Equatable, Sendable {
        var freezesHeld = 0
        var repair: StreakCover.RepairOffer?
        /// Why today needs no catch, when it is a forgiven day.
        var todayReason: String?
    }

    static func status(
        catches: [Catch], now: Date = Date(), defaults: UserDefaults = .standard
    ) -> Status {
        #if DEBUG
        // A forced streak is synthetic; real freezes and repairs next to it
        // would be the two-streaks bug in a new place.
        if StreakDebug.override != nil { return Status() }
        #endif
        let todayKey = Streaks.dayKey(for: now)
        let forgiven = StreakCoverStore.forgiven(defaults: defaults)
        guard let ledger = StreakCoverStore.ledger(defaults: defaults) else {
            return Status(todayReason: forgiven.first { $0.day == todayKey }?.reason)
        }
        return Status(
            freezesHeld: ledger.freezesHeld,
            repair: StreakCover.repairOffer(
                ledger, catchDays: Streaks.realDaySet(catches: catches),
                forgiven: Set(forgiven.map(\.day)), todayKey: todayKey),
            todayReason: forgiven.first { $0.day == todayKey }?.reason
        )
    }

    /// The user tapped Repair. Re-derives the offer rather than trusting
    /// the one on screen, so a stale card can't repair twice.
    @discardableResult
    static func repair(
        catches: [Catch], now: Date = Date(), defaults: UserDefaults = .standard
    ) -> Bool {
        let todayKey = Streaks.dayKey(for: now)
        guard let ledger = StreakCoverStore.ledger(defaults: defaults),
              let offer = StreakCover.repairOffer(
                  ledger, catchDays: Streaks.realDaySet(catches: catches),
                  forgiven: Set(StreakCoverStore.forgiven(defaults: defaults).map(\.day)),
                  todayKey: todayKey) else { return false }
        StreakCoverStore.save(StreakCover.repair(ledger, offer: offer, todayKey: todayKey),
                              defaults: defaults)
        Analytics.capture(StreakCoverTelemetry.repairedEvent,
                          StreakCoverTelemetry.repairProperties(offer))
        return true
    }
}
