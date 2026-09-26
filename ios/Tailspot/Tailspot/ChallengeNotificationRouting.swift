//
//  ChallengeNotificationRouting.swift
//  Tailspot
//
//  What the app does with a challenge notification once iOS hands it over —
//  the two decisions, both pure, both tested without a notification center:
//
//  1. FOREGROUND PRESENTATION. A challenge banner obeys exactly the rule
//     the streak reminder obeys: silent while the viewfinder is frontmost,
//     banner + sound anywhere else. If you are pointing the camera at the
//     sky, a notification telling you to go catch a plane is the app
//     arguing with itself — and that is just as true of "You're 2nd in
//     Weekend Flyoff" as it is of the streak nudge. The rule itself stays
//     in `StreakReminders.foregroundPresentation(cameraFrontmost:)`; this
//     only decides that a given notification is ours.
//
//  2. TAP ROUTING. A tap opens that challenge's detail. Local reminders and
//     the backend's remote pushes are deliberately identical here: both
//     carry `userInfo["challengeId"]` and `userInfo["kind"]`, so the tap
//     path does not care which one it is looking at. The local ones can
//     also be read straight out of the identifier, which is the fallback
//     when a userInfo dictionary goes missing.
//
//  The remote payload the backend sends (contract, do not change here):
//
//      { "aps": { "alert": { "title": …, "body": … },
//                 "sound": "default",
//                 "thread-id": "<challengeId>" },
//        "challengeId": "<id>",
//        "kind": "overtaken" }
//
//  Nothing is rendered client-side — iOS draws the banner from `aps`, and
//  the tap comes back through the same delegate as a local reminder.
//
//  `nonisolated` — pure functions, no UI, no notification-center calls.
//

import Foundation
import UserNotifications

nonisolated enum ChallengeNotificationRouting {
    /// The `userInfo` keys both the local scheduler and the backend set.
    static let challengeIdKey = "challengeId"
    static let kindKey = "kind"

    /// Where a tapped challenge notification should take the user.
    struct Route: Equatable {
        let challengeId: String
        /// `starts` / `midway` / `daily` / `ending_soon` / `finished` for a
        /// local reminder, `overtaken` for the backend's push. Unknown
        /// values from a future server survive as-is — the analytics
        /// property is a string, and dropping the tap because this build
        /// doesn't recognize the word would be the worse failure.
        let moment: String
    }

    /// Is this ours? True for anything carrying a `challengeId`, and for
    /// any identifier with the challenge prefix — a remote push has no
    /// identifier we control, and a local reminder whose content was
    /// somehow stripped still has its identifier.
    static func isChallengeNotification(identifier: String, userInfo: [AnyHashable: Any]) -> Bool {
        challengeId(identifier: identifier, userInfo: userInfo) != nil
    }

    /// The challenge id, from `userInfo` first (the one field remote and
    /// local pushes share) and the identifier second.
    static func challengeId(identifier: String, userInfo: [AnyHashable: Any]) -> String? {
        if let id = userInfo[challengeIdKey] as? String, !id.isEmpty { return id }
        return ChallengeReminders.challengeId(fromNotificationIdentifier: identifier)
    }

    /// The full tap route, or nil when the notification is not ours.
    static func route(identifier: String, userInfo: [AnyHashable: Any]) -> Route? {
        guard let id = challengeId(identifier: identifier, userInfo: userInfo) else { return nil }
        let kind = (userInfo[kindKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ChallengeReminders.moment(fromNotificationIdentifier: identifier)?.rawValue
        return Route(challengeId: id, moment: kind ?? "unknown")
    }

    /// Foreground presentation for a challenge notification, or nil when the
    /// notification is not ours (the caller then keeps its own default —
    /// see `StreakReminderCenter.userNotificationCenter(_:willPresent:)`).
    static func foregroundPresentation(
        identifier: String,
        userInfo: [AnyHashable: Any],
        cameraFrontmost: Bool
    ) -> UNNotificationPresentationOptions? {
        guard isChallengeNotification(identifier: identifier, userInfo: userInfo) else { return nil }
        // Deliberately the streak rule itself, not a copy of it: if the
        // "never cover the viewfinder" policy ever changes, it changes once.
        return StreakReminders.foregroundPresentation(cameraFrontmost: cameraFrontmost)
    }

    /// The tap event's name. One constant so the scheduler's
    /// `challenge_reminder_scheduled` and this can be read as a pair.
    static let openedEvent = "challenge_reminder_opened"
}
