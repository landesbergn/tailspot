//
//  AirlinesTests.swift
//  TailspotTests
//
//  Callsign → operator resolution used to backfill catches that the feed left
//  with no operator ("Unknown operator").
//

import Testing
@testable import Tailspot

@Suite("Airlines callsign → operator")
struct AirlinesTests {

    @Test func resolvesAirlineCallsigns() {
        #expect(Airlines.name(forCallsign: "SWA4244") == "Southwest Airlines")
        #expect(Airlines.name(forCallsign: "UAL1") == "United Airlines")
        #expect(Airlines.name(forCallsign: "dal900") == "Delta Air Lines")   // case-insensitive
        #expect(Airlines.name(forCallsign: "FDX350") == "FedEx Express")
    }

    @Test func rejectsRegistrationsAndUnknowns() {
        #expect(Airlines.name(forCallsign: "N172SP") == nil)   // GA registration
        #expect(Airlines.name(forCallsign: "N21866") == nil)
        #expect(Airlines.name(forCallsign: "ZZZ9999") == nil)  // airline-format, not in table
        #expect(Airlines.name(forCallsign: nil) == nil)
        #expect(Airlines.name(forCallsign: "") == nil)
    }

    @Test func airlineFormatHeuristic() {
        #expect(Airlines.isAirlineFormat("SWA4244"))
        #expect(Airlines.isAirlineFormat("UAL1"))
        #expect(!Airlines.isAirlineFormat("N172SP"))   // digit in the first 3
        #expect(!Airlines.isAirlineFormat("ABCD"))     // no flight number
    }

    @Test func operatorLabelPrefersRecordedThenCallsignThenPrivate() {
        // Recorded operator always wins.
        #expect(Airlines.operatorLabel(operatorName: "Delta Air Lines", callsign: "N1") == "Delta Air Lines")
        // No operator → resolve from callsign.
        #expect(Airlines.operatorLabel(operatorName: nil, callsign: "SWA4244") == "Southwest Airlines")
        #expect(Airlines.operatorLabel(operatorName: "  ", callsign: "UAL1") == "United Airlines")
        // GA registration → Private.
        #expect(Airlines.operatorLabel(operatorName: nil, callsign: "N172SP") == "Private")
        // Airline-format but unmapped → Operator unknown.
        #expect(Airlines.operatorLabel(operatorName: nil, callsign: "ZZZ9999") == "Operator unknown")
    }
}
