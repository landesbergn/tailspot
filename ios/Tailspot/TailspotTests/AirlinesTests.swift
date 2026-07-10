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

    // The bundled snapshot (airlines.json, ~5,900 designators) is the
    // comprehensive layer beneath the curated table. If this fails the
    // resource fell out of the app bundle — resolution silently degrades
    // to the curated ~130.
    @Test func bundledDatasetLoadsAndCovers() {
        #expect(Airlines.bundled.count > 5000)
        // Resolves designators the curated table never carried.
        #expect(Airlines.name(forCallsign: "EWG905") == "Eurowings")
    }

    // Charter/bizav designators absent from the VRS dataset, identified from
    // real catches (the last 3 unresolved of the 234 in prod, 2026-07-08).
    @Test func curatedCoversDatasetGaps() {
        #expect(Airlines.bundled["ERY"] == nil)   // gap is real, not a stale note
        #expect(Airlines.name(forCallsign: "ERY94") == "Sky Quest")
        #expect(Airlines.name(forCallsign: "RLI904") == "Reliant Air")
        #expect(Airlines.name(forCallsign: "FTO382") == "Tropic Ocean Airways")
    }

    // The curated table is the display-name override layer: dataset names
    // are often legal names ("Federal Express", "Peach").
    @Test func curatedDisplayNameWinsOverBundledLegalName() {
        #expect(Airlines.bundled["FDX"] == "Federal Express")
        #expect(Airlines.name(forCallsign: "FDX350") == "FedEx Express")
        #expect(Airlines.bundled["APJ"] == "Peach")
        #expect(Airlines.name(forCallsign: "APJ545") == "Peach Aviation")
    }

    // Shape invariant: lookup is `[cs.prefix(3)]`, so any key that isn't
    // exactly 3 uppercase letters is dead weight that can never match (a
    // 4-char "FDX2" entry sat unreachable in the table until 2026-07-08).
    @Test func tableKeysAreMatchableDesignators() {
        for table in [Airlines.byICAO, Airlines.bundled] {
            for (key, value) in table {
                #expect(key.count == 3, "\(key) can never match a prefix(3) lookup")
                #expect(key.allSatisfy { $0.isLetter && $0.isUppercase },
                        "\(key) isn't an ICAO designator")
                #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty,
                        "\(key) maps to an empty name")
            }
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
