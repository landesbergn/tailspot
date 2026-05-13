//
//  AircraftMetadataDecodingTests.swift
//  TailspotTests
//
//  OpenSky's /metadata/aircraft/icao/{icao24} returns a flat JSON
//  object keyed by field name. Most fields are nullable in practice —
//  e.g. small GA aircraft often lack a model or registered owner.
//  AircraftMetadata's Decodable must tolerate that.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("AircraftMetadata Decoding")
struct AircraftMetadataDecodingTests {

    @Test func decodesFullPayload() throws {
        let json = """
        {
          "icao24": "a3b15e",
          "registration": "N12345",
          "manufacturerName": "BOEING",
          "manufacturerIcao": "BOEING",
          "model": "737-800",
          "typecode": "B738",
          "serialNumber": "12345",
          "operator": "American Airlines",
          "operatorIcao": "AAL",
          "owner": "American Airlines Inc"
        }
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
        #expect(m.icao24 == "a3b15e")
        #expect(m.registration == "N12345")
        #expect(m.manufacturerName == "BOEING")
        #expect(m.model == "737-800")
        #expect(m.typecode == "B738")
        #expect(m.operatorName == "American Airlines")
    }

    @Test func toleratesMissingOptionalFields() throws {
        let json = """
        {
          "icao24": "abc123"
        }
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
        #expect(m.icao24 == "abc123")
        #expect(m.registration == nil)
        #expect(m.manufacturerName == nil)
        #expect(m.model == nil)
        #expect(m.typecode == nil)
        #expect(m.operatorName == nil)
    }

    @Test func toleratesExplicitNulls() throws {
        let json = """
        {
          "icao24": "abc123",
          "registration": null,
          "manufacturerName": null,
          "model": null,
          "typecode": null,
          "operator": null
        }
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
        #expect(m.icao24 == "abc123")
        #expect(m.model == nil)
        #expect(m.operatorName == nil)
    }

    @Test func missingIcao24Throws() {
        let json = """
        { "model": "A320" }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(AircraftMetadata.self, from: json)
        }
    }
}
