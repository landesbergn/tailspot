//
//  RevealSettleDeadlineTests.swift
//  TailspotTests
//
//  `revealSettleDeadline` decides WHEN the catch reveal's TimelineView may
//  pause: the last of its three animation clocks (`start`/`chipsStart`/
//  `bonusStart`) to finish, padded a hair past every clamp. Getting this
//  wrong would either freeze a clock mid-animation (deadline too early) or
//  waste frames (too late), so the pure math is worth pinning.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Reveal settle deadline")
struct RevealSettleDeadlineTests {

    private let duration = 1.7
    private let chipPop = 0.6
    private let bonus = 0.6

    /// No clock started yet → nothing to pause on.
    @Test func nilWhenNoAnchorSet() {
        #expect(revealSettleDeadline(
            start: nil, chipsStart: nil, bonusStart: nil,
            duration: duration, chipPopDuration: chipPop, bonusCountUpDuration: bonus
        ) == nil)
    }

    /// A lone reveal clock settles at start + duration + pad — past the `t`
    /// clamp at start + duration, so the pausing tick lands on the final frame.
    @Test func revealOnlyIsDurationPlusPad() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let d = revealSettleDeadline(
            start: start, chipsStart: nil, bonusStart: nil,
            duration: duration, chipPopDuration: chipPop, bonusCountUpDuration: bonus,
            pad: 0.1
        )
        #expect(d == start.addingTimeInterval(duration + 0.1))
    }

    /// The deadline is the LATEST clock's end: once the player answers, the
    /// long-past reveal/chip clocks don't pull the pause in early — the bonus
    /// count-up gets its full window.
    @Test func takesLatestAcrossClocks() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)        // long done
        let chipsStart = start.addingTimeInterval(2.0)                // long done
        let bonusStart = start.addingTimeInterval(10.0)              // just tapped
        let d = revealSettleDeadline(
            start: start, chipsStart: chipsStart, bonusStart: bonusStart,
            duration: duration, chipPopDuration: chipPop, bonusCountUpDuration: bonus,
            pad: 0.1
        )
        #expect(d == bonusStart.addingTimeInterval(bonus + 0.1))
    }

    /// Concurrent clocks (a chip tap during the pop-in) settle on whichever
    /// finishes last — here the bonus count-up outlasts the remaining pop.
    @Test func concurrentClocksTakeTheLaterEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let chipsStart = start.addingTimeInterval(5.0)
        let bonusStart = chipsStart.addingTimeInterval(0.3)          // tapped mid pop-in
        let d = revealSettleDeadline(
            start: start, chipsStart: chipsStart, bonusStart: bonusStart,
            duration: duration, chipPopDuration: chipPop, bonusCountUpDuration: bonus,
            pad: 0.1
        )
        // chip pop ends at chipsStart+0.7; bonus ends at chipsStart+0.3+0.7 = +1.0.
        #expect(d == bonusStart.addingTimeInterval(bonus + 0.1))
    }
}
