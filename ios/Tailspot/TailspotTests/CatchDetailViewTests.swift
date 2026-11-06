//
//  CatchDetailViewTests.swift
//  TailspotTests
//
//  The detail card must show the catch the tapped Hangar cell shows.
//  Regression for 2026-11-05: the SWA503 cell (today) opened SWA4842
//  (Jul 23), an earlier catch of the same Southwest airframe, because
//  the detail rendered `row.firstCatch` while the cell renders
//  `row.mostRecent`.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch detail")
@MainActor
struct CatchDetailViewTests {

    private func makeCatch(callsign: String, caughtAt: Date) -> Catch {
        Catch(
            icao24: "a1b2c3",
            callsign: callsign,
            model: "737-7H4",
            manufacturer: "BOEING",
            operatorName: "Southwest Airlines",
            caughtAt: caughtAt,
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: "B737"
        )
    }

    @Test func reCaughtAirframeShowsTheCatchTheCellShows() {
        let july = makeCatch(callsign: "SWA4842", caughtAt: Date(timeIntervalSince1970: 1_784_840_000))
        let november = makeCatch(callsign: "SWA503", caughtAt: Date(timeIntervalSince1970: 1_793_900_000))

        let rows = HangarGrouping.group([july, november], by: .recent).flatMap(\.rows)
        #expect(rows.count == 1)
        let row = rows[0]

        // The cell renders mostRecent; the detail must render the same catch.
        #expect(row.mostRecent === november)
        #expect(CatchDetailView(row: row).shown === november)
    }
}
