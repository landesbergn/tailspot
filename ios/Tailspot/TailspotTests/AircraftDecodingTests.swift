//
//  AircraftDecodingTests.swift
//  TailspotTests
//
//  OpenSky returns each aircraft as a positional JSON array — values
//  keyed by index, not by name. The custom Decodable on Aircraft is
//  brittle by design (any reorder by OpenSky breaks us). Test it
//  thoroughly so we notice fast.
//
//  The FailableDecodable test is the most important one: in production,
//  OpenSky responses include radar contacts with no lat/lon. A bug in
//  the wrapper would cause ONE bad aircraft to nuke the entire batch,
//  producing an empty list — silent failure, no crash.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Aircraft Decoding")
struct AircraftDecodingTests {

    /// 18-element OpenSky state vector — note the trailing whitespace
    /// in the callsign, which is how OpenSky actually pads them.
    private static let validJSON = """
    [
      "a3b15e","UAL248  ","United States",1715000000,1715000000,
      -122.27,37.87,9000.0,false,230.0,270.5,0.5,null,9144.0,
      "1234",false,0,1
    ]
    """.data(using: .utf8)!

    @Test func decodesValidAircraftWithAllFields() throws {
        let a = try JSONDecoder().decode(Aircraft.self, from: Self.validJSON)
        #expect(a.icao24 == "a3b15e")
        #expect(a.callsign == "UAL248")
        #expect(a.originCountry == "United States")
        #expect(a.longitude == -122.27)
        #expect(a.latitude == 37.87)
        #expect(a.altitudeMeters == 9144.0)   // geo (index 13) preferred over baro (7)
        #expect(a.onGround == false)
        #expect(a.velocityMps == 230.0)
        #expect(a.trackDeg == 270.5)
    }

    @Test func nullPositionThrows() {
        // Lat/lon at indices 5/6 are null — these are radar-only contacts.
        let json = """
        ["abc","CALL","C",null,100,null,null,null,false,null,null,null,null,null,null,false,0,null]
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Aircraft.self, from: json)
        }
    }

    @Test func failableDecodableDropsBadEntries() throws {
        // Mixed array: good, bad (null position), good. Exactly the
        // shape OpenSky returns on a typical real-world fetch.
        let json = """
        [
          ["a3b15e","UAL248  ","United States",1715000000,1715000000,-122.27,37.87,9000.0,false,230.0,270.5,0.5,null,9144.0,"1234",false,0,1],
          ["abc","NULLPOS","C",null,100,null,null,null,false,null,null,null,null,null,null,false,0,null],
          ["b3c4d5","DAL567","United States",1715000000,1715000000,-122.0,37.5,8000.0,false,200.0,180.0,0.0,null,null,null,false,0,null]
        ]
        """.data(using: .utf8)!
        let wrapped = try JSONDecoder().decode([FailableDecodable<Aircraft>].self, from: json)
        let valid = wrapped.compactMap(\.value)
        #expect(valid.count == 2)
        #expect(valid.map(\.icao24) == ["a3b15e", "b3c4d5"])
    }

    @Test func emptyOrWhitespaceCallsignBecomesNil() throws {
        let json = """
        ["abc","   ","Country",null,100,-122.0,37.0,9000.0,false,230.0,90.0,0.0,null,null,null,false,0,null]
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Aircraft.self, from: json)
        #expect(a.callsign == nil)
    }

    @Test func callsignWhitespaceTrimmed() throws {
        let json = """
        ["abc","  UAL123  ","Country",null,100,-122.0,37.0,9000.0,false,230.0,90.0,0.0,null,null,null,false,0,null]
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Aircraft.self, from: json)
        #expect(a.callsign == "UAL123")
    }

    @Test func geoAltitudePreferredOverBaro() throws {
        let json = """
        ["abc","CALL","C",null,100,-122.0,37.0,8000.0,false,200,90,0,null,9000.0,null,false,0,null]
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Aircraft.self, from: json)
        #expect(a.altitudeMeters == 9000.0)
    }

    @Test func baroAltitudeFallbackWhenGeoMissing() throws {
        let json = """
        ["abc","CALL","C",null,100,-122.0,37.0,8000.0,false,200,90,0,null,null,null,false,0,null]
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Aircraft.self, from: json)
        #expect(a.altitudeMeters == 8000.0)
    }

    @Test func bothAltitudesNullDefaultsToZero() throws {
        let json = """
        ["abc","CALL","C",null,100,-122.0,37.0,null,false,200,90,0,null,null,null,false,0,null]
        """.data(using: .utf8)!
        let a = try JSONDecoder().decode(Aircraft.self, from: json)
        #expect(a.altitudeMeters == 0)
    }
}
