//
//  RevealDismissAnalytics.swift
//  Tailspot
//
//  `reveal_dismissed` — how a player leaves the single-catch reveal, and
//  how long they stayed (back-controls pass, 2026-10-30). The reveal's exit
//  used to be an 11 pt faint "tap to continue"; it's now a readable
//  "Continue" link rather than a full-width button, which would have cost
//  the card ~30 pt on an iPhone SE. This event is how we find out whether
//  that's enough: if people sit on the reveal unsure what to do (long
//  dwell, few `continue` taps), that's the case for a bigger control.
//

import Foundation

enum RevealDismissAnalytics {
    enum Method: String {
        /// The "Continue" link.
        case `continue`
        /// A tap anywhere on the settled reveal outside the controls.
        case tapAnywhere = "tap_anywhere"
        /// The "View in Hangar ›" link.
        case viewInHangar = "view_in_hangar"
    }

    /// The event's properties. Pure, so tests pin the shape. A negative
    /// dwell (clock skew) clamps to 0.
    nonisolated static func properties(method: Method, dwell: TimeInterval) -> [String: AnalyticsValue] {
        [
            "method": .string(method.rawValue),
            "dwell_ms": .int(max(0, Int((dwell * 1000).rounded()))),
        ]
    }

    /// Sends the event unless `muted` (the DEBUG simulated reveal).
    static func capture(method: Method, appearedAt: Date?, now: Date = Date(), muted: Bool) {
        guard !muted else { return }
        let dwell = appearedAt.map { now.timeIntervalSince($0) } ?? 0
        Analytics.capture("reveal_dismissed", properties(method: method, dwell: dwell))
    }
}
