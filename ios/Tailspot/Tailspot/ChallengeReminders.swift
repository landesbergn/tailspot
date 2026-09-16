//
//  ChallengeReminders.swift
//  Tailspot
//
//  Local, time-based challenge reminders (spec D17: "Local time-based
//  reminders only (starts, ending soon, finished) in phase 2"). Mirrors
//  `StreakReminders`' architecture: a pure, clock-injected planner that
//  carries every guardrail, exhaustively tested; a thin MainActor scheduler
//  (not part of this pass — see the spec's phase-2 file list) applies the
//  plan to `UNUserNotificationCenter`, replacing the three identifiers for
//  a given challenge on every recompute so stale state self-heals.
//
//  `nonisolated` — pure value types only, no UserNotifications calls here.
//

import Foundation

/// One planned local notification. The scheduler (not built in this pass)
/// turns this into a `UNNotificationRequest` with a
/// `UNCalendarNotificationTrigger` or `UNTimeIntervalNotificationTrigger`
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

    static func isChallengeIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(identifierPrefix)
    }

    /// The three moment suffixes an identifier ever ends in — used by
    /// `challengeId(fromNotificationIdentifier:)` to find the right split
    /// point when the challenge id itself contains dashes (every real id is
    /// a UUID).
    private static let moments: Set<Substring> = ["starts", "ending_soon", "finished"]

    /// Recovers the challenge id from one of this file's own identifiers
    /// (`"tailspot.challenge.<id>.<moment>"`), or nil for anything else —
    /// including `StreakReminders.notificationId` and any identifier this
    /// build doesn't recognize. Splits on the LAST "." rather than the
    /// first: the id may itself contain dashes (UUIDs do), but never a ".",
    /// so everything before the final "." is the id and everything after is
    /// the moment.
    static func challengeId(fromNotificationIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let remainder = identifier.dropFirst(identifierPrefix.count)
        guard let lastDot = remainder.lastIndex(of: ".") else { return nil }
        let id = remainder[remainder.startIndex..<lastDot]
        let moment = remainder[remainder.index(after: lastDot)...]
        guard !id.isEmpty, moments.contains(moment) else { return nil }
        return String(id)
    }

    /// The (at most three) identifiers a single challenge ever owns —
    /// for cancellation on leave/cancel/delete, regardless of which moments
    /// are currently still in the future.
    static func identifiers(challengeId: String) -> [String] {
        ["starts", "ending_soon", "finished"].map {
            "\(identifierPrefix)\(challengeId).\($0)"
        }
    }

    /// The three possible moments, pure and clock-injected like
    /// `StreakReminders.decision`. Guardrails:
    /// - Nothing at all when reminders are off or notifications aren't
    ///   authorized — a challenge reminder is never worth a permission nag
    ///   of its own; it rides the streak reminder's existing ask.
    /// - Each moment is included only if its instant is still in the
    ///   future relative to `now` — a reminder scheduled for the past would
    ///   never fire, and re-planning after the fact (e.g. app reopened
    ///   mid-challenge) must not resurrect a moment that already passed.
    /// - The "ending soon" lead is 10 minutes for the 1h preset (a 1-hour
    ///   warning on a 1-hour challenge would fire before or at the start)
    ///   and 1 hour for 24h/3d/7d, per the spec's phase-2 test list.
    static func plan(
        challengeId: String,
        name: String,
        startsAt: Date,
        endsAt: Date,
        durationPreset: String,
        now: Date,
        enabled: Bool,
        authorized: Bool
    ) -> [ChallengeReminderPlan] {
        guard enabled, authorized else { return [] }
        var plans: [ChallengeReminderPlan] = []

        if startsAt > now {
            plans.append(ChallengeReminderPlan(
                identifier: "\(identifierPrefix)\(challengeId).starts",
                fireAt: startsAt,
                title: "Challenge started",
                body: "\(name) starts now."
            ))
        }

        let endingSoonLead: TimeInterval = durationPreset == "1h" ? 10 * 60 : 60 * 60
        let endingSoonAt = endsAt.addingTimeInterval(-endingSoonLead)
        if endingSoonAt > now {
            let leadCopy = durationPreset == "1h" ? "Ten minutes" : "One hour"
            plans.append(ChallengeReminderPlan(
                identifier: "\(identifierPrefix)\(challengeId).ending_soon",
                fireAt: endingSoonAt,
                title: "Ending soon",
                body: "\(leadCopy) left in \(name)."
            ))
        }

        if endsAt > now {
            plans.append(ChallengeReminderPlan(
                identifier: "\(identifierPrefix)\(challengeId).finished",
                fireAt: endsAt,
                title: "Challenge finished",
                body: "\(name) just finished. See how you did."
            ))
        }

        return plans
    }
}
