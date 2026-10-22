//
//  CatchUploadHoldTests.swift
//  TailspotTests
//
//  Pins the route-guess upload hold. A catch row is POSTed exactly once, and
//  the server only awards the +25% route-guess bonus for a guess it sees in
//  that POST. From 1.1.0 the per-catch immediate upload always beat the
//  answer, so the server saw ~10 of ~2,490 guesses. The fix holds a catch
//  hosting a bonus round out of every upload sweep until the guess resolves,
//  with a 120 s safety expiry so a forgotten hold can't strand the catch.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch upload guess hold")
struct CatchUploadHoldTests {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("a held row is skipped by the uploader")
    func heldRowSkipped() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(holds.isHeld("uuid-a", now: t0))
        #expect(holds.isHeld("uuid-a", now: t0.addingTimeInterval(119)))
    }

    @Test("a hold expires after the timeout, so the catch still uploads")
    func expiredHoldReleased() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(CatchUploadHolds.timeout == 120)
        #expect(!holds.isHeld("uuid-a", now: t0.addingTimeInterval(120)))
        #expect(!holds.isHeld("uuid-a", now: t0.addingTimeInterval(600)))
    }

    @Test("rows without a hold, or without a serverUuid, upload as before")
    func unheldRowPasses() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        #expect(!holds.isHeld("uuid-b", now: t0))
        #expect(!holds.isHeld(nil, now: t0))
        #expect(!CatchUploadHolds.isHeld(key: "uuid-a", holds: [:], now: t0))
    }

    @Test("release removes the hold and reports whether there was one")
    func releaseRemovesHold() {
        var holds = CatchUploadHolds()
        holds.hold("uuid-a", now: t0)
        holds.hold("uuid-b", now: t0)
        let first = holds.release("uuid-a")
        #expect(first)
        #expect(!holds.isHeld("uuid-a", now: t0))
        #expect(holds.isHeld("uuid-b", now: t0))
        // A second release (e.g. answer, then the reveal's close button) is a
        // no-op that tells the caller not to kick another upload.
        let again = holds.release("uuid-a")
        let never = holds.release("never-held")
        #expect(!again)
        #expect(!never)
    }

    @Test("the live registry gates a real Catch row by its serverUuid")
    @MainActor
    func liveRegistryGatesRow() {
        let row = Catch(
            icao24: "abc123", callsign: "UAL1", model: "Boeing 737-800",
            manufacturer: "Boeing", operatorName: "United", caughtAt: t0,
            observerLat: 37.8, observerLon: -122.27, slantDistanceMeters: 9000
        )
        let key = UUID().uuidString
        // Before the row has a serverUuid it can't be held.
        #expect(!CatchUploader.isHeldForGuess(row))
        row.serverUuid = key
        #expect(!CatchUploader.isHeldForGuess(row))
        CatchUploader.guessHolds.hold(key)
        #expect(CatchUploader.isHeldForGuess(row))
        let released = CatchUploader.guessHolds.release(key)
        #expect(released)
        #expect(!CatchUploader.isHeldForGuess(row))
    }
}
