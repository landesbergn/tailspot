//
//  CallsignTests.swift
//  TailspotTests
//
//  Placeholder flight IDs ("00000000") are treated as no callsign, so a
//  catch card names the plane by its tail number instead (N549FX,
//  2026-11-08).
//

import Foundation
import Testing
@testable import Tailspot

@Suite("Callsign placeholders") @MainActor
struct CallsignTests {

    @Test func keepsRealCallsigns() {
        #expect(Callsign.clean("SWA4244") == "SWA4244")
        #expect(Callsign.clean("  N453FD \n") == "N453FD")
        #expect(Callsign.clean("AF1") == "AF1")
        #expect(Callsign.clean("1200") == "1200")    // non-zero digit = real
        #expect(Callsign.clean("N10") == "N10")
    }

    @Test func dropsBlankAndPlaceholderCallsigns() {
        #expect(Callsign.clean(nil) == nil)
        #expect(Callsign.clean("") == nil)
        #expect(Callsign.clean("   ") == nil)
        #expect(Callsign.clean("00000000") == nil)
        #expect(Callsign.clean("0000 ") == nil)
        #expect(Callsign.clean("--------") == nil)
        #expect(Callsign.clean("0-0") == nil)
    }

    @Test func cardIdentifierFallsBackToRegistration() {
        #expect(Callsign.cardIdentifier(callsign: "00000000", registration: "N549FX") == "N549FX")
        #expect(Callsign.cardIdentifier(callsign: nil, registration: " N549FX ") == "N549FX")
        #expect(Callsign.cardIdentifier(callsign: "UAL248", registration: "N12345") == "UAL248")
        #expect(Callsign.cardIdentifier(callsign: "00000000", registration: nil) == nil)
        #expect(Callsign.cardIdentifier(callsign: nil, registration: "  ") == nil)
    }

    @Test func storedPlaceholderCatchRendersByTailNumber() {
        let c = Catch(
            icao24: "a6f9ee", callsign: "00000000",
            model: "CL-600-2B16", manufacturer: "Bombardier",
            caughtAt: Date(), observerLat: 37.8, observerLon: -122.3,
            slantDistanceMeters: 8_000, registration: "N549FX", typecode: "CL30"
        )
        let plane = CardPlane(catchRecord: c)
        #expect(plane.callsign == "N549FX")
        #expect(CatchShare.identifier(for: plane) == "N549FX")
    }

    @Test func placeholderCallsignIsNotAFlightKey() {
        #expect(Catch.flightKey("00000000") == nil)
        #expect(Catch.flightKey(" ual248 ") == "UAL248")
    }

    @Test func placeholderCallsignSkipsRouteBackfill() {
        let c = Catch(
            icao24: "a6f9ee", callsign: "00000000", model: nil, manufacturer: nil,
            caughtAt: Date(), observerLat: 37.8, observerLon: -122.3,
            slantDistanceMeters: 8_000
        )
        #expect(CatchBackfill.needsRoute(c) == false)
    }

    @Test func feedDecodeDropsPlaceholder() throws {
        let json = #"""
        {"icao24":"a6f9ee","callsign":"00000000","longitude":-122.3,"latitude":37.8,
         "altitudeMeters":3100,"onGround":false}
        """#
        let row = try JSONDecoder().decode(BackendAircraft.self, from: Data(json.utf8))
        #expect(row.asAircraft().callsign == nil)
    }
}
