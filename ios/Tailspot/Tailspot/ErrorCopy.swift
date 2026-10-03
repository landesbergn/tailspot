//
//  ErrorCopy.swift
//  Tailspot
//
//  The one place transport errors become human copy. Every surface that
//  used to echo `localizedDescription` routes through here instead — the
//  raw error keeps flowing to logs and the debug panel untouched.
//
//  Three buckets, because that's the distinction a spotter can act on:
//  *no connection* ("No internet"), *a connection too weak to finish
//  the request* ("Weak connection" — timeouts and DNS lookups that die
//  on one bar of cellular), and *Tailspot's side* ("Tailspot
//  unreachable" — HTTP status, decode failure, refused connection,
//  anything else). Cancellation is not a bucket at all: a request the
//  app cancelled itself (lock target switched, app backgrounded) says
//  nothing about the network, and callers drop it silently — it used to
//  read as "Tailspot unreachable" every time you panned off a plane
//  (2026-10-02). Two voices, because two kinds of surface render them:
//  `pill()` for the AR status pill (mono caps, no apostrophes — the B612
//  rule) and `prose()` for list-card detail lines. The prose server-side
//  line deliberately matches the Hangar restore card's phrasing — same
//  failure, same words everywhere.
//

import Foundation

nonisolated enum ErrorCopy {

    /// The URLError underneath, seeing through `AccountError.transport`.
    private static func urlError(_ error: Error) -> URLError? {
        var underlying = error
        if case AccountError.transport(let inner) = error { underlying = inner }
        return underlying as? URLError
    }

    /// True when the app cancelled the request itself — Swift task
    /// cancellation (a `.task(id:)` re-keyed, `stop()` on background), which
    /// URLSession surfaces as `URLError.cancelled`. Not a network failure:
    /// callers must not count it, show it, or cache it.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return urlError(error)?.code == .cancelled
    }

    /// True when the failure is on the user's side of the wire. The
    /// canonical URLError offline codes only.
    static func isOffline(_ error: Error) -> Bool {
        switch urlError(error)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// True when there IS a connection but it couldn't carry the request
    /// in time: a timeout, or a DNS lookup that failed on a dying link.
    /// Either can in principle be the server's fault, but the backend has
    /// uptime alerting and one bar of cellular is far more common, so
    /// "weak connection" is the honest first guess — and it still says
    /// "retrying", so a real outage reads as a connection that never
    /// gets better rather than as a lie.
    static func isWeakConnection(_ error: Error) -> Bool {
        switch urlError(error)?.code {
        case .timedOut, .cannotFindHost, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// Short machine-readable bucket name, for telemetry.
    static func bucket(for error: Error) -> String {
        if isOffline(error) { return "offline" }
        if isWeakConnection(error) { return "weak" }
        return "server"
    }

    /// AR status-pill copy. Rendered uppercased in the mono capsule;
    /// "retrying" is a promise the 10 s poll loop actually keeps.
    static func pill(for error: Error) -> String {
        if isOffline(error) { return "NO INTERNET — RETRYING" }
        if isWeakConnection(error) { return "WEAK CONNECTION — RETRYING" }
        return "TAILSPOT UNREACHABLE — RETRYING"
    }

    /// Detail-line copy for list-card error slots (leaderboard).
    static func prose(for error: Error) -> String {
        if isOffline(error) { return "You're offline — reconnect and try again." }
        if isWeakConnection(error) { return "Your connection is weak. Try again in a moment." }
        return "Couldn't reach Tailspot. Try again in a moment."
    }
}
