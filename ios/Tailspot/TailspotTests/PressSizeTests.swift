//
//  PressSizeTests.swift
//  TailspotTests
//
//  `CatchBackfill.pressSizes`: which stored rows belong to one shutter press
//  (scoring v10's multi-catch bonus). Mirrors the server's rule in
//  `reconcilePress` and migration 0012: distinct airframes sharing an exact
//  `caughtAt`.
//

import Foundation
import Testing
@testable import Tailspot

@Suite struct PressSizeTests {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func rowsSharingAnInstantAreOnePress() {
        let sizes = CatchBackfill.pressSizes([
            (t0, "aaa111"), (t0, "bbb222"),
            (t0.addingTimeInterval(60), "ccc333"),
        ])
        #expect(sizes == [CatchBackfill.pressKey(t0): 2])
    }

    @Test func threePlanesAreATriple() {
        let sizes = CatchBackfill.pressSizes([(t0, "a"), (t0, "b"), (t0, "c")])
        #expect(sizes == [CatchBackfill.pressKey(t0): 3])
    }

    @Test func aRestoredDuplicateRowIsNotADouble() {
        // Same airframe, same instant (a restore can re-create a row), in
        // either case: still one plane.
        let sizes = CatchBackfill.pressSizes([(t0, "aaa111"), (t0, "AAA111")])
        #expect(sizes.isEmpty)
    }

    @Test func catchesASecondApartAreSeparatePresses() {
        let sizes = CatchBackfill.pressSizes([(t0, "a"), (t0.addingTimeInterval(1), "b")])
        #expect(sizes.isEmpty)
    }

    @Test func aRestoredRowJoinsItsLocalSibling() {
        // The phone's row keeps sub-millisecond precision; the server's copy
        // of its sibling comes back truncated to the millisecond.
        let local = Date(timeIntervalSince1970: 1_790_000_000.1234567)
        let restored = Date(timeIntervalSince1970: 1_790_000_000.123)
        let sizes = CatchBackfill.pressSizes([(local, "a"), (restored, "b")])
        #expect(sizes == [CatchBackfill.pressKey(local): 2])
    }
}
