//
//  AirlinesTests.swift
//  TailspotTests
//
//  Callsign → operator resolution used to backfill catches that the feed left
//  with no operator ("Unknown operator").
//

import Foundation
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

    // Field regression (caught 2026-07-03, reported 2026-07-08): both showed
    // "Operator unknown" — the table's original seed was US/Europe-heavy with
    // no Asia-Pacific LCC coverage.
    @Test func resolvesAsiaPacificCallsigns() {
        #expect(Airlines.name(forCallsign: "APJ545") == "Peach Aviation")
        #expect(Airlines.name(forCallsign: "BTK6143") == "Batik Air")
        #expect(Airlines.name(forCallsign: "SJV782") == "Super Air Jet")
        #expect(Airlines.name(forCallsign: "CTV660") == "Citilink")
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

    // Shape invariant: lookup is `byICAO[cs.prefix(3)]`, so any key that isn't
    // exactly 3 uppercase letters is dead weight that can never match (a
    // 4-char "FDX2" entry sat unreachable in the table until 2026-07-08).
    @Test func tableKeysAreMatchableDesignators() {
        for key in Airlines.byICAO.keys {
            #expect(key.count == 3, "\(key) can never match a prefix(3) lookup")
            #expect(key.allSatisfy { $0.isLetter && $0.isUppercase },
                    "\(key) isn't an ICAO designator")
        }
        for (key, value) in Airlines.byICAO {
            #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(key) maps to an empty name")
        }
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
