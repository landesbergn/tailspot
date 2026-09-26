//
//  ChallengeReminders.swift
//  Tailspot
//
//  Local, time-based challenge reminders. Mirrors `StreakReminders`'
//  architecture: a pure, clock-injected planner that carries every
//  guardrail, exhaustively tested; a thin MainActor scheduler
//  (`ChallengeReminderScheduler`) applies the plan to
//  `UNUserNotificationCenter`, replacing a challenge's identifiers on every
//  recompute so stale state self-heals.
//
//  Moments (v2, 2026-09-26 — the mid-challenge nudges are new):
//    starts       every preset, at `startsAt`
//    midway       24h ONLY, roughly half way in, daylight-shifted
//    daily        3d / 7d ONLY, 17:00 local on each full interior day
//    ending_soon  every preset, 10 min (1h) or 1 h before the end
//    finished     every preset, at `endsAt`
//  plus `overtaken`, which is never planned here — it is a REMOTE push the
//  backend sends. It lives in the `Moment` vocabulary anyway so the tap
//  analytics (`challenge_reminder_opened`) has one list of moment names.
//
//  Why a mid-challenge nudge at all: a 3d or 7d challenge has exactly two
//  local reminders in the middle of it — none. The user hears "it started"
//  and then nothing until the last hour, by which time the race is decided.
//  One nudge a day at 17:00 (the streak reminder's hour — same reasoning,
//  and never a second evening slot of its own) with the standings in it is
//  the whole retention story for the long presets.
//
//  `nonisolated` — pure value types only, no UserNotifications calls here.
//

import Foundation

/// One planned local notification. The scheduler turns this into a
/// `UNNotificationRequest` with a `UNTimeIntervalNotificationTrigger`
/// matching `fireAt`.
nonisolated struct ChallengeReminderPlan: Equatable, Sendable {
    let identifier: String
    let fireAt: Date
    let title: String
    let body: String
}

nonisolated enum ChallengeReminders {
    /// Every challenge reminder identifier starts with this — never
    /// `StreakReminders.notificationId` ("tailspot.streak.reminder"), so a
    /// bulk cancel/lookup for one feature can never touch the other's slot.
    static let identifierPrefix = "tailspot.challenge."

    /// Minimum daylight a "starts" reminder needs to be worth scheduling.
    /// Below this the challenge is starting essentially now, and the user
    /// is looking at the screen that says so.
    static let startsLead: TimeInterval = 60

    /// The moment vocabulary. The raw value is both the identifier suffix
    /// and the `moment` property on `challenge_reminder_scheduled` /
    /// `challenge_reminder_opened`, so the two can never drift.
    ///
    /// `overtaken` is remote-only (the backend's push payload carries
    /// `"kind": "overtaken"`); nothing in this file ever plans one.
    enum Moment: String, CaseIterable, Sendable {
        case starts
        case midway
        case daily
        case endingSoon = "ending_soon"
        case finished
        case overtaken
    }

    // MARK: - Mid-challenge timing constants

    /// The hour a `daily` nudge fires, local. Deliberately
    /// `StreakReminders.reminderHour` (17) rather than a second constant:
    /// one app, one evening nudge hour, and the two features' banners land
    /// together instead of pestering twice.
    static var dailyHour: Int { StreakReminders.reminderHour }

    /// The daylight window a 24h challenge's `midway` nudge may land in.
    /// A 24h challenge started at 21:00 is half over at 09:00 — fine. One
    /// started at 14:00 is half over at 02:00, and nobody wants that.
    /// Inclusive at both ends (a midpoint at exactly 21:00 stays put).
    static let midwayWindow = (open: 8, close: 21)
    /// Where an out-of-window midpoint is pushed to: the next 09:00 local.
    static let midwayShiftedHour = 9
    /// A shifted `midway` this close to `ending_soon` is not a mid-challenge
    /// nudge any more, it is a second ending-soon banner. Skip it instead.
    static let midwayMinimumLeadBeforeEndingSoon: TimeInterval = 2 * 3600

    // MARK: - Identifiers

    static func isChallengeIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// `"tailspot.challenge.<id>.<moment>"`, or for a daily,
    /// `"tailspot.challenge.<id>.daily.<yyyy-MM-dd>"` — one slot per day, so
    /// a re-plan upserts the same day's nudge rather than stacking them.
    static func identifier(challengeId: String, moment: Moment, dayKey: String? = nil) -> String {
        if let dayKey, moment == .daily {
            return "\(identifierPrefix)\(challengeId).\(moment.rawValue).\(dayKey)"
        }
        return "\(identifierPrefix)\(challengeId).\(moment.rawValue)"
    }

    /// Recovers the challenge id from one of this file's own identifiers, or
    /// nil for anything else — including `StreakReminders.notificationId`
    /// and any identifier this build doesn't recognize.
    ///
    /// Parsed from the RIGHT, because the daily identifier has two trailing
    /// components (`…<id>.daily.2026-09-28`) while every other moment has
    /// one. The id itself is a UUID: it may contain dashes, never a dot, so
    /// whatever is left after peeling the moment off the end is the id.
    static func challengeId(fromNotificationIdentifier identifier: String) -> String? {
        parse(identifier)?.challengeId
    }

    /// The moment a challenge identifier names — the other half of
    /// `challengeId(fromNotificationIdentifier:)`, used by the tap analytics.
    static func moment(fromNotificationIdentifier identifier: String) -> Moment? {
        parse(identifier)?.moment
    }

    /// The one parser both accessors above use.
    static func parse(_ identifier: String) -> (challengeId: String, moment: Moment)? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        var parts = identifier.dropFirst(identifierPrefix.count).split(
            separator: ".", omittingEmptySubsequences: false
        ).map(String.init)
        guard parts.count >= 2 else { return nil }

        // Daily first: its LAST component is a day key, not a moment name.
        if parts.count >= 3, isDayKey(parts[parts.count - 1]),
           parts[parts.count - 2] == Moment.daily.rawValue {
            parts.removeLast(2)
            let id = parts.joined(separator: ".")
            return id.isEmpty ? nil : (id, .daily)
        }

        guard let moment = Moment(rawValue: parts.removeLast()), moment != .daily else { return nil }
        let id = parts.joined(separator: ".")
        return id.isEmpty ? nil : (id, moment)
    }

    /// Every identifier a single challenge can own — for cancellation on
    /// leave / cancel / delete, regardless of which moments are currently
    /// still in the future.
    ///
    /// The four fixed moments are always enumerated. The per-day `daily`
    /// slots can only be listed if the caller knows the window, so
    /// `startsAt` / `endsAt` are optional: pass them and the dailies come
    /// too. A caller with no summary in hand (a challenge cancelled from a
    /// link, with the list never loaded) gets the fixed four and relies on
    /// `ChallengeReminderScheduler`'s pending-sweep to catch the rest.
    static func identifiers(
        challengeId: String,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        timeZone: TimeZone = .current
    ) -> [String] {
        var ids = [Moment.starts, .midway, .endingSoon, .finished].map {
            identifier(challengeId: challengeId, moment: $0)
        }
        if let startsAt, let endsAt {
            ids += interiorDayKeys(startsAt: startsAt, endsAt: endsAt, timeZone: timeZone).map {
                identifier(challengeId: challengeId, moment: .daily, dayKey: $0.key)
            }
        }
        return ids
    }

    // MARK: - Plan

    /// Every moment for one challenge, pure and clock-injected like
    /// `StreakReminders.decision`. Guardrails:
    /// - Nothing at all when reminders are off or notifications aren't
    ///   authorized — a challenge reminder is never worth a permission nag
    ///   of its own; it rides the streak reminder's existing ask.
    /// - Each moment is included only if its instant is still in the
    ///   future relative to `now` — a reminder scheduled for the past would
    ///   never fire, and re-planning after the fact (e.g. app reopened
    ///   mid-challenge) must not resurrect a moment that already passed.
    /// - The "starts" moment needs `startsLead` (60 s) of daylight. A
    ///   Starts-Now create returns a `startsAt` a second or two in the past
    ///   or future depending on how far the device clock has drifted from
    ///   the server's, and a "Challenge started" banner buzzing one second
    ///   after the user pressed Create is noise, not a reminder.
    ///   Deliberate consequence: a sync that runs inside the last minute
    ///   before a start REMOVES an already-pending "starts" reminder (the
    ///   scheduler drops anything no longer planned) rather than only
    ///   declining to add one. That is the behaviour we want — a sync only
    ///   happens because the app is open, so the user is looking at
    ///   Tailspot when the thing starts and does not need to be told.
    /// - The "ending soon" lead is 10 minutes for the 1h preset (a 1-hour
    ///   warning on a 1-hour challenge would fire before or at the start)
    ///   and 1 hour for 24h/3d/7d.
    /// - Never two banners on one calendar day: a `daily` that lands on the
    ///   same local day as `ending_soon` or `finished` is dropped, and a
    ///   `midway` inside `midwayMinimumLeadBeforeEndingSoon` of
    ///   `ending_soon` is dropped.
    ///
    /// `placement` is the caller's last-known standing (see
    /// `ChallengesModel.reminderPlacements`). It is deliberately allowed to
    /// be stale: the plan is recomputed on every sync — foreground, refresh,
    /// create, join — so a placement that moves is corrected the next time
    /// the app is open, and a banner that says "You're 2nd" when you are now
    /// 3rd costs nothing next to having no standings line at all. Absent
    /// placement (or a solo field) falls back to the neutral copy.
    static func plan(
        challengeId: String,
        name: String,
        startsAt: Date,
        endsAt: Date,
        durationPreset: String,
        now: Date,
        enabled: Bool,
        authorized: Bool,
        placement: Int? = nil,
        participantCount: Int? = nil,
        timeZone: TimeZone = .current
    ) -> [ChallengeReminderPlan] {
        guard enabled, authorized else { return [] }
        var plans: [ChallengeReminderPlan] = []

        if startsAt.timeIntervalSince(now) >= startsLead {
            plans.append(ChallengeReminderPlan(
                identifier: identifier(challengeId: challengeId, moment: .starts),
                fireAt: startsAt,
                title: "Challenge started",
                body: "\(name) starts now."
            ))
        }

        let endingSoonLead: TimeInterval = durationPreset == "1h" ? 10 * 60 : 60 * 60
        let endingSoonAt = endsAt.addingTimeInterval(-endingSoonLead)

        let standingLine = standingCopy(name: name, placement: placement,
                                        participantCount: participantCount)

        // midway — 24h only.
        if durationPreset == "24h",
           let midwayAt = midwayInstant(startsAt: startsAt, timeZone: timeZone),
           midwayAt > now,
           midwayAt <= endingSoonAt.addingTimeInterval(-midwayMinimumLeadBeforeEndingSoon) {
            plans.append(ChallengeReminderPlan(
                identifier: identifier(challengeId: challengeId, moment: .midway),
                fireAt: midwayAt,
                title: "Halfway there",
                body: standingLine ?? "\(name) is half over. Check the standings."
            ))
        }

        // daily — multi-day presets only.
        if durationPreset == "3d" || durationPreset == "7d" {
            let calendar = calendar(timeZone)
            let total = totalDays(durationPreset: durationPreset)
            for day in interiorDayKeys(startsAt: startsAt, endsAt: endsAt, timeZone: timeZone) {
                guard let fireAt = calendar.date(bySettingHour: dailyHour, minute: 0, second: 0,
                                                 of: day.start) else { continue }
                guard fireAt > now else { continue }
                // One banner a day: the last day already gets ending_soon
                // and finished, and an ending_soon that fell back onto the
                // previous day (a challenge ending just after midnight)
                // would otherwise share a day with a daily.
                guard !calendar.isDate(fireAt, inSameDayAs: endingSoonAt),
                      !calendar.isDate(fireAt, inSameDayAs: endsAt) else { continue }
                plans.append(ChallengeReminderPlan(
                    identifier: identifier(challengeId: challengeId, moment: .daily, dayKey: day.key),
                    fireAt: fireAt,
                    title: "Day \(day.index) of \(total)",
                    body: standingLine ?? "\(name) is on. Check the standings."
                ))
            }
        }

        if endingSoonAt > now {
            let leadCopy = durationPreset == "1h" ? "Ten minutes" : "One hour"
            plans.append(ChallengeReminderPlan(
                identifier: identifier(challengeId: challengeId, moment: .endingSoon),
                fireAt: endingSoonAt,
                title: "Ending soon",
                body: "\(leadCopy) left in \(name)."
            ))
        }

        if endsAt > now {
            plans.append(ChallengeReminderPlan(
                identifier: identifier(challengeId: challengeId, moment: .finished),
                fireAt: endsAt,
                title: "Challenge finished",
                body: "\(name) just finished. See how you did."
            ))
        }

        return plans
    }

    // MARK: - Copy

    /// The standings line both mid-challenge moments share, or nil when
    /// there is nothing worth saying. A placement is only a fact worth
    /// stating in a field of two or more — "You're 1st" in a challenge you
    /// are alone in is a joke the app should not make — so a known
    /// `participantCount` below 2 falls back with the placement unused.
    static func standingCopy(name: String, placement: Int?, participantCount: Int?) -> String? {
        guard let placement, placement > 0 else { return nil }
        if let participantCount, participantCount < 2 { return nil }
        let ordinal = ChallengeTiming.placementLabel(placement: placement, isTie: false)
        return "You're \(ordinal) in \(name)."
    }

    // MARK: - Day math

    /// How many days the preset covers, for the "Day 3 of 7" title. Day 1 is
    /// the day the challenge started, so a 7d challenge's last interior day
    /// is day 7 and the (excluded) end day would be day 8.
    static func totalDays(durationPreset: String) -> Int {
        Int(ChallengeDurations.seconds(for: durationPreset) / 86_400).clampedToAtLeast(1)
    }

    /// Every full local day strictly after the start day and strictly before
    /// the end day — the days a `daily` nudge may land on. The start day is
    /// covered by `starts` (and by the user being in the app that created or
    /// joined it); the end day by `ending_soon` / `finished`.
    static func interiorDayKeys(
        startsAt: Date, endsAt: Date, timeZone: TimeZone = .current
    ) -> [(key: String, start: Date, index: Int)] {
        let calendar = calendar(timeZone)
        let startDay = calendar.startOfDay(for: startsAt)
        let endDay = calendar.startOfDay(for: endsAt)
        var result: [(key: String, start: Date, index: Int)] = []
        var day = calendar.date(byAdding: .day, value: 1, to: startDay) ?? startDay
        var index = 2 // the start day is day 1
        // 400 is a hard stop, not a rule: the longest preset is 7 days, and
        // an unbounded while over Calendar arithmetic is how you hang a run
        // loop on a corrupt date.
        while day < endDay, result.count < 400 {
            result.append((key: dayKey(day, calendar: calendar), start: day, index: index))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
            index += 1
        }
        return result
    }

    /// Where a 24h challenge's `midway` banner lands: the true midpoint when
    /// it falls inside the daylight window, otherwise the next 09:00 local.
    static func midwayInstant(startsAt: Date, timeZone: TimeZone = .current) -> Date? {
        let calendar = calendar(timeZone)
        let midpoint = startsAt.addingTimeInterval(12 * 3600)
        let dayStart = calendar.startOfDay(for: midpoint)
        guard let open = calendar.date(bySettingHour: midwayWindow.open, minute: 0, second: 0, of: dayStart),
              let close = calendar.date(bySettingHour: midwayWindow.close, minute: 0, second: 0, of: dayStart)
        else { return nil }
        if midpoint >= open && midpoint <= close { return midpoint }
        return calendar.nextDate(
            after: midpoint,
            matching: DateComponents(hour: midwayShiftedHour, minute: 0, second: 0),
            matchingPolicy: .nextTime
        )
    }

    /// `yyyy-MM-dd` in the given calendar. Built from components rather than
    /// a `DateFormatter` so there is no shared formatter whose time zone has
    /// to be mutated (and no locale that could hand back a non-Gregorian
    /// year).
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isDayKey(_ value: String) -> Bool {
        guard value.count == 10 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

private extension Int {
    func clampedToAtLeast(_ floor: Int) -> Int { Swift.max(self, floor) }
}
