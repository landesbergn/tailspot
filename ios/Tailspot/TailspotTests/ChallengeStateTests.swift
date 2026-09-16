//
//  ChallengeStateTests.swift
//  TailspotTests
//
//  ChallengeTiming: the status state machine at its exact boundaries, every
//  timeRemainingCopy bucket, and placement label formatting (spec section
//  13: "countdown copy at 59 s / 61 min / 25 h / 3 d... the challenge state
//  machine from timestamps... placement formatting").
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Challenge timing")
struct ChallengeStateTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let end = Date(timeIntervalSince1970: 1_800_086_400) // start + 24h

    // MARK: - status boundaries

    @Test func statusBeforeStartIsUpcoming() {
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end, cancelledAt: nil,
            now: start.addingTimeInterval(-1))
        #expect(s == .upcoming)
    }

    @Test func statusExactlyAtStartIsLive() {
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end, cancelledAt: nil, now: start)
        #expect(s == .live)
    }

    @Test func statusOneSecondBeforeEndIsLive() {
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end, cancelledAt: nil,
            now: end.addingTimeInterval(-1))
        #expect(s == .live)
    }

    @Test func statusExactlyAtEndIsFinished() {
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end, cancelledAt: nil, now: end)
        #expect(s == .finished)
    }

    @Test func statusAfterEndIsFinished() {
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end, cancelledAt: nil,
            now: end.addingTimeInterval(3600))
        #expect(s == .finished)
    }

    @Test func cancelledWinsRegardlessOfWindow() {
        // Cancelled while the window would otherwise say "live".
        let s = ChallengeTiming.status(
            startsAt: start, endsAt: end,
            cancelledAt: start.addingTimeInterval(10),
            now: start.addingTimeInterval(100))
        #expect(s == .cancelled)
        // Cancelled while the window would otherwise say "upcoming".
        let s2 = ChallengeTiming.status(
            startsAt: start, endsAt: end,
            cancelledAt: start.addingTimeInterval(-10),
            now: start.addingTimeInterval(-100))
        #expect(s2 == .cancelled)
    }

    // MARK: - timeRemainingCopy buckets

    @Test func under1MinuteRoundsDownToZeroMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(59) // 59 seconds
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "0M LEFT")
    }

    @Test func fortyEightMinutesShowsMinutesOnly() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(48 * 60)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "48M LEFT")
    }

    @Test func sixtyOneMinutesShowsHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(61 * 60)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "1H 1M LEFT")
    }

    @Test func oneHourTwelveMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(72 * 60)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "1H 12M LEFT")
    }

    @Test func twentyFiveHoursShowsDaysAndHours() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(25 * 3600)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "1D 1H LEFT")
    }

    @Test func threeDaysExactDropsZeroHours() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(3 * 24 * 3600)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "3D LEFT")
    }

    @Test func twoDaysFiveHours() {
        let now = Date(timeIntervalSince1970: 0)
        let until = now.addingTimeInterval(2 * 24 * 3600 + 5 * 3600)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "2D 5H LEFT")
    }

    @Test func negativeRemainingIsEnded() {
        let now = Date(timeIntervalSince1970: 1000)
        let until = Date(timeIntervalSince1970: 500)
        #expect(ChallengeTiming.timeRemainingCopy(until: until, now: now) == "ENDED")
    }

    @Test func exactlyZeroRemainingIsEnded() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(ChallengeTiming.timeRemainingCopy(until: now, now: now) == "ENDED")
    }

    // MARK: - startsInCopy

    @Test func startsInThreeHours() {
        let now = Date(timeIntervalSince1970: 0)
        let starts = now.addingTimeInterval(3 * 3600)
        #expect(ChallengeTiming.startsInCopy(startsAt: starts, now: now) == "STARTS IN 3H")
    }

    @Test func startsInFortyEightMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let starts = now.addingTimeInterval(48 * 60)
        #expect(ChallengeTiming.startsInCopy(startsAt: starts, now: now) == "STARTS IN 48M")
    }

    // MARK: - placementLabel

    @Test func placementLabelOrdinals() {
        #expect(ChallengeTiming.placementLabel(placement: 1, isTie: false) == "1st")
        #expect(ChallengeTiming.placementLabel(placement: 2, isTie: false) == "2nd")
        #expect(ChallengeTiming.placementLabel(placement: 3, isTie: false) == "3rd")
        #expect(ChallengeTiming.placementLabel(placement: 4, isTie: false) == "4th")
        #expect(ChallengeTiming.placementLabel(placement: 11, isTie: false) == "11th")
        #expect(ChallengeTiming.placementLabel(placement: 21, isTie: false) == "21st")
    }

    @Test func placementLabelTiePrefix() {
        #expect(ChallengeTiming.placementLabel(placement: 1, isTie: true) == "T-1st")
        #expect(ChallengeTiming.placementLabel(placement: 3, isTie: true) == "T-3rd")
    }

    // MARK: - placementOf

    @Test func placementOfFormatsOrdinalAndFieldSize() {
        #expect(ChallengeTiming.placementOf(placement: 3, participants: 6) == "3rd of 6")
        #expect(ChallengeTiming.placementOf(placement: 1, participants: 1) == "1st of 1")
    }
}
