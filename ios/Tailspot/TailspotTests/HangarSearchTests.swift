//
//  HangarSearchTests.swift
//  TailspotTests
//
//  HangarGrouping.search — the Catches list's search filter. It must
//  match exactly the text a card shows, so these build rows the same
//  way the list does (group by .recent) and query card-visible fields.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Hangar search")
@MainActor
struct HangarSearchTests {

    private func makeCatch(
        icao: String,
        callsign: String? = nil,
        operatorName: String? = nil,
        typecode: String? = nil,
        registration: String? = nil,
        placeName: String? = nil,
        originIata: String? = nil,
        destIata: String? = nil,
        caughtAt: Date = Date()
    ) -> Catch {
        let c = Catch(
            icao24: icao,
            callsign: callsign,
            model: nil,
            manufacturer: nil,
            operatorName: operatorName,
            caughtAt: caughtAt,
            observerLat: 0, observerLon: 0,
            slantDistanceMeters: 0,
            typecode: typecode
        )
        c.registration = registration
        c.placeName = placeName
        c.originIata = originIata
        c.destIata = destIata
        return c
    }

    private func rows(_ catches: [Catch]) -> [HangarRow] {
        HangarGrouping.group(catches, by: .recent).first?.rows ?? []
    }

    private var fixture: [HangarRow] {
        let now = Date()
        return rows([
            makeCatch(icao: "a1", callsign: "SWA4244", operatorName: "Southwest Airlines",
                      typecode: "B738", registration: "N8642E", placeName: "Oakland",
                      originIata: "OAK", destIata: "LAX", caughtAt: now),
            makeCatch(icao: "a2", callsign: "DAL972", operatorName: "Delta Air Lines",
                      typecode: "A321", placeName: "Berkeley",
                      caughtAt: now.addingTimeInterval(-60)),
            makeCatch(icao: "a3", callsign: "DAL15", operatorName: "Delta Air Lines",
                      typecode: "B739", placeName: "Denpasar",
                      caughtAt: now.addingTimeInterval(-120)),
        ])
    }

    private func callsigns(_ query: String) -> [String] {
        HangarGrouping.search(fixture, query: query).compactMap { $0.mostRecent.callsign }
    }

    @Test func blankQueryReturnsEverythingInOrder() {
        #expect(callsigns("") == ["SWA4244", "DAL972", "DAL15"])
        #expect(callsigns("   ") == ["SWA4244", "DAL972", "DAL15"])
    }

    @Test func matchesCallsignCaseInsensitively() {
        #expect(callsigns("swa") == ["SWA4244"])
    }

    @Test func matchesAirline() {
        #expect(callsigns("delta") == ["DAL972", "DAL15"])
    }

    @Test func matchesCanonicalModelName() {
        // The card shows "Boeing 737-800" for B738, not the raw typecode.
        #expect(callsigns("737") == ["SWA4244", "DAL15"])
        #expect(callsigns("airbus") == ["DAL972"])
    }

    @Test func matchesTypecodeRegistrationPlaceAndRoute() {
        #expect(callsigns("a321") == ["DAL972"])
        #expect(callsigns("n8642e") == ["SWA4244"])
        #expect(callsigns("berkeley") == ["DAL972"])
        #expect(callsigns("lax") == ["SWA4244"])
    }

    @Test func everyTermMustMatch() {
        #expect(callsigns("delta 737") == ["DAL15"])
        #expect(callsigns("delta oakland").isEmpty)
    }

    @Test func ignoresDiacritics() {
        let r = rows([makeCatch(icao: "b1", callsign: "AFR83", placeName: "Montréal")])
        #expect(HangarGrouping.search(r, query: "montreal").count == 1)
    }

    @Test func noMatchReturnsEmpty() {
        #expect(callsigns("zzz").isEmpty)
    }
}
