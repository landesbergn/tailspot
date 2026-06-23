//
//  TailspotBackendClientTests.swift
//  TailspotTests
//
//  Decode + mapping tests for the api.tailspot.app wire format (WP 1.6).
//  Same philosophy as the OpenSky decode suite: the wire DTOs and their
//  mapping onto core types are the testable surface; transport stays thin.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("Backend wire decoding")
struct TailspotBackendClientTests {

    @Test func decodesAircraftResponseAndMapsToAircraft() throws {
        let json = """
        {
          "fetchedAt": 1781122007,
          "aircraft": [
            {
              "icao24": "a43adf",
              "callsign": "N3717R",
              "originCountry": "United States",
              "longitude": -122.706776,
              "latitude": 38.188011,
              "altitudeMeters": 1463.04,
              "velocityMps": 43.6248512,
              "trackDeg": 17.15,
              "onGround": false,
              "positionTimestamp": 1781122007,
              "typecode": "C172",
              "registration": "N3717R"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BackendAircraftResponse.self, from: json)
        #expect(decoded.fetchedAt == 1_781_122_007)
        #expect(decoded.aircraft.count == 1)

        let a = decoded.aircraft[0].asAircraft()
        #expect(a.icao24 == "a43adf")
        #expect(a.callsign == "N3717R")
        #expect(a.originCountry == "United States")
        #expect(a.altitudeMeters == 1463.04)
        #expect(a.velocityMps == 43.6248512)
        #expect(a.trackDeg == 17.15)
        #expect(a.onGround == false)
        #expect(a.positionTimestamp == Date(timeIntervalSince1970: 1_781_122_007))
        // Feed-supplied type/registration map straight through.
        #expect(a.typecode == "C172")
        #expect(a.registration == "N3717R")
        // The GA heuristic must keep working through the mapping — N-number
        // callsigns drive the small-airframe visibility half-cap.
        #expect(a.isLikelySmallAirframe)
    }

    @Test func decodesForeignTypecodeAndRegistration() throws {
        // The motivating case: a Singapore A350 the FAA-only metadata endpoint
        // can't resolve — but the feed carries `t`/`r` directly.
        let json = """
        {
          "fetchedAt": 1781122007,
          "aircraft": [
            {
              "icao24": "76cdb5",
              "callsign": "SIA248",
              "originCountry": "Singapore",
              "longitude": 115.0,
              "latitude": -8.5,
              "altitudeMeters": 13906.5,
              "velocityMps": 242.8,
              "trackDeg": 300.0,
              "onGround": false,
              "positionTimestamp": 1781122007,
              "typecode": "A359",
              "registration": "9V-SMH"
            }
          ]
        }
        """.data(using: .utf8)!

        let a = try JSONDecoder().decode(BackendAircraftResponse.self, from: json)
            .aircraft[0].asAircraft()
        #expect(a.typecode == "A359")
        #expect(a.registration == "9V-SMH")
        // And the typecode resolves to a real name via the bundled table —
        // no "Unknown aircraft" once this reaches a catch.
        let name = AircraftNaming.canonical(typecode: a.typecode, manufacturer: nil, model: nil)
        #expect(name.model?.isEmpty == false)
        #expect(name.type == .wide)
    }

    @Test func nullableFieldsDecodeAsNil() throws {
        // The backend contract allows null callsign / originCountry /
        // velocity / track / positionTimestamp.
        let json = """
        {
          "fetchedAt": 1781122007,
          "aircraft": [
            {
              "icao24": "abc123",
              "callsign": null,
              "originCountry": null,
              "longitude": -122.0,
              "latitude": 37.0,
              "altitudeMeters": 0,
              "velocityMps": null,
              "trackDeg": null,
              "onGround": true,
              "positionTimestamp": null
            }
          ]
        }
        """.data(using: .utf8)!

        let a = try JSONDecoder()
            .decode(BackendAircraftResponse.self, from: json)
            .aircraft[0].asAircraft()
        #expect(a.callsign == nil)
        // Null country maps to the display dash, not a dropped row —
        // Aircraft.originCountry is non-optional.
        #expect(a.originCountry == "—")
        #expect(a.velocityMps == nil)
        #expect(a.trackDeg == nil)
        #expect(a.positionTimestamp == nil)
        // typecode/registration keys are absent from this JSON entirely —
        // proves both null-tolerance and backward-compat with a pre-feature
        // backend build that doesn't emit them yet.
        #expect(a.typecode == nil)
        #expect(a.registration == nil)
        // No timestamp → extrapolation degrades gracefully to the raw fix.
        let pos = a.extrapolatedPosition(at: Date())
        #expect(pos.lat == 37.0)
        #expect(pos.lon == -122.0)
    }

    @Test func decodesMetadataAndMapsToAircraftMetadata() throws {
        let json = """
        {
          "icao24": "a8d71c",
          "registration": "N669QX",
          "manufacturer": "Embraer",
          "model": "E175",
          "typecode": "E75L",
          "operatorName": null,
          "source": "merged"
        }
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(BackendMetadata.self, from: json)
            .asAircraftMetadata()
        #expect(m.icao24 == "a8d71c")
        #expect(m.registration == "N669QX")
        #expect(m.manufacturerName == "Embraer")
        #expect(m.manufacturerIcao == nil)
        #expect(m.model == "E175")
        #expect(m.typecode == "E75L")
        #expect(m.operatorName == nil)
    }

    @Test func metadataWithAllNullsStillDecodes() throws {
        // A registration-only FAA orphan row (manufacturer/model unknown).
        let json = """
        {
          "icao24": "abcdef",
          "registration": "N1",
          "manufacturer": null,
          "model": null,
          "typecode": null,
          "operatorName": null,
          "source": "faa"
        }
        """.data(using: .utf8)!

        let m = try JSONDecoder().decode(BackendMetadata.self, from: json)
            .asAircraftMetadata()
        #expect(m.registration == "N1")
        #expect(m.manufacturerName == nil)
        #expect(m.typecode == nil)
    }

    @Test func clientBuildsWithDefaultProductionBaseURL() {
        let client = TailspotBackendClient()
        #expect(client.baseURL.absoluteString == "https://api.tailspot.app")
    }
}
