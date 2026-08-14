//
//  ErrorCopy.swift
//  Tailspot
//
//  The one place transport errors become human copy. Every surface that
//  used to echo `localizedDescription` routes through here instead — the
//  raw error keeps flowing to logs and the debug panel untouched.
//
//  Two buckets, because that's the only distinction a spotter can act
//  on: *your connection* ("No internet") vs *Tailspot's side* ("Tailspot
//  unreachable" — HTTP status, decode failure, DNS, timeout, anything
//  else). Two voices, because two kinds of surface render them: `pill()`
//  for the AR status pill (mono caps, no apostrophes — the B612 rule)
//  and `prose()` for list-card detail lines. The prose server-side line
//  deliberately matches the Hangar restore card's phrasing — same
//  failure, same words everywhere.
//

import Foundation

nonisolated enum ErrorCopy {

    /// True when the failure is on the user's side of the wire. The
    /// canonical URLError offline codes only — a timeout or DNS failure
    /// can be either side, and "Tailspot unreachable" is honest for both.
    static func isOffline(_ error: Error) -> Bool {
        var underlying = error
        if case AccountError.transport(let inner) = error { underlying = inner }
        guard let urlError = underlying as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// AR status-pill copy. Rendered uppercased in the mono capsule;
    /// "retrying" is a promise the 10 s poll loop actually keeps.
    static func pill(for error: Error) -> String {
        isOffline(error) ? "NO INTERNET — RETRYING"
                         : "TAILSPOT UNREACHABLE — RETRYING"
    }

    /// Detail-line copy for list-card error slots (leaderboard).
    static func prose(for error: Error) -> String {
        isOffline(error) ? "You're offline — reconnect and try again."
                         : "Couldn't reach Tailspot. Try again in a moment."
    }
}
