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

    @Test func timeoutsAndDNSReadWeakConnection() {
        // One bar of cellular times out or loses the DNS lookup; the user
        // has *a* connection, it just can't carry the request (2026-10-02).
        for code in [URLError.Code.timedOut, .cannotFindHost, .dnsLookupFailed] {
            let error = URLError(code)
            #expect(!ErrorCopy.isOffline(error))
            #expect(ErrorCopy.isWeakConnection(error))
            #expect(ErrorCopy.pill(for: error) == "WEAK CONNECTION — RETRYING")
            #expect(ErrorCopy.prose(for: error) == "Your connection is weak. Try again in a moment.")
            #expect(ErrorCopy.bucket(for: error) == "weak")
        }
        // Wrapped account transport errors see through too.
        #expect(ErrorCopy.isWeakConnection(AccountError.transport(URLError(.timedOut))))
    }

    @Test func refusedConnectionStaysServerSide() {
        let refused = URLError(.cannotConnectToHost)
        #expect(!ErrorCopy.isWeakConnection(refused))
        #expect(ErrorCopy.pill(for: refused) == "TAILSPOT UNREACHABLE — RETRYING")
        #expect(ErrorCopy.bucket(for: refused) == "server")
    }

    @Test func cancellationIsRecognizedInEveryShape() {
        // The bug behind most "Tailspot unreachable" pills: a lookup the
        // app cancelled itself read as a server failure.
        #expect(ErrorCopy.isCancellation(URLError(.cancelled)))
        #expect(ErrorCopy.isCancellation(CancellationError()))
        #expect(ErrorCopy.isCancellation(AccountError.transport(URLError(.cancelled))))
        #expect(!ErrorCopy.isCancellation(URLError(.timedOut)))
        #expect(!ErrorCopy.isCancellation(ADSBSourceError.http(status: 503)))
    }
}
