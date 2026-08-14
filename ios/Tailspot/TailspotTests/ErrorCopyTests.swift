//
//  ErrorCopyTests.swift
//  TailspotTests
//
//  Pins the transport-error → human-copy mapping (error-copy pass,
//  2026-08-14). The strings themselves are the contract: the AR pill and
//  the leaderboard error card render these verbatim, and the whole point
//  of ErrorCopy is that no surface ever falls back to a raw
//  localizedDescription (the old pill shouted "THE INTERNET CONNECTION
//  APPEARS TO BE OFFLINE." and the leaderboard could leak the
//  developer-facing AccountError.notRegistered description).
//

import Foundation
import Testing
@testable import Tailspot

@Suite("ErrorCopy buckets")
struct ErrorCopyTests {

    @Test func offlineErrorsReadNoInternet() {
        let offline = URLError(.notConnectedToInternet)
        #expect(ErrorCopy.isOffline(offline))
        #expect(ErrorCopy.pill(for: offline) == "NO INTERNET — RETRYING")
        #expect(ErrorCopy.prose(for: offline) == "You're offline — reconnect and try again.")
    }

    @Test func serverSideErrorsReadUnreachable() {
        let http = ADSBSourceError.http(status: 500)
        #expect(!ErrorCopy.isOffline(http))
        #expect(ErrorCopy.pill(for: http) == "TAILSPOT UNREACHABLE — RETRYING")
        // The prose line deliberately matches the Hangar restore card's
        // phrasing — same failure, same words.
        #expect(ErrorCopy.prose(for: http) == "Couldn't reach Tailspot. Try again in a moment.")
    }

    @Test func developerCopyCanNeverLeak() {
        // The exact case the audit flagged: a pre-registration leaderboard
        // call must read as a normal reachability problem, not
        // "call ensureRegistered() first".
        let prose = ErrorCopy.prose(for: AccountError.notRegistered)
        #expect(!prose.contains("ensureRegistered"))
        #expect(prose == "Couldn't reach Tailspot. Try again in a moment.")
    }

    @Test func accountTransportUnwrapsToOffline() {
        // AccountError wraps the underlying URLError; the bucket check
        // must see through the wrapper.
        let wrapped = AccountError.transport(URLError(.networkConnectionLost))
        #expect(ErrorCopy.isOffline(wrapped))
        #expect(ErrorCopy.pill(for: wrapped) == "NO INTERNET — RETRYING")
    }

    @Test func ambiguousTimeoutStaysServerSide() {
        // A timeout can be either side of the wire; "unreachable" is
        // honest for both, "no internet" only for one.
        #expect(!ErrorCopy.isOffline(URLError(.timedOut)))
    }

    @Test func multiCatchQuestionReadsPlural() {
        let q = CatchSuspicion.multiQuestion(count: 3)
        #expect(q == "3 of those were hidden or very far — did you really see them?")
        // Same shape contract the per-reason questions are pinned to.
        #expect(q.hasSuffix("?"))
    }
}
