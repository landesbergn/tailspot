//
//  CatchUploadPayloadTests.swift
//  TailspotTests
//
//  Pins the POST /v1/catches body shape. The backend accepts observer pose
//  angles only as a number or an EXPLICIT null — an absent key is 422. Swift's
//  synthesized Encodable omits nil optionals, which silently broke every
//  catch upload (nil pose → absent keys → 422 storm). These tests assert the
//  pose keys are present as null.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Catch upload payload")
struct CatchUploadPayloadTests {

    private func encodedNilPosePayload() throws -> String {
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111",
            icao24: "abc123",
            callsign: nil,
            caughtAt: 1_715_000_000,
            observer: .init(lat: 37.8, lon: -122.27,
                            headingDeg: nil, elevationDeg: nil, headingAccuracyDeg: nil),
            aircraft: nil)
        return String(data: try JSONEncoder().encode(req), encoding: .utf8)!
    }

    @Test func nilPoseAnglesEncodeAsExplicitNullNotAbsent() throws {
        let json = try encodedNilPosePayload()
        #expect(json.contains("\"headingDeg\":null"))
        #expect(json.contains("\"elevationDeg\":null"))
        #expect(json.contains("\"headingAccuracyDeg\":null"))
    }

    @Test func presentPoseAnglesEncodeAsNumbers() throws {
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111",
            icao24: "abc123", callsign: "UAL1",
            caughtAt: 1_715_000_000,
            observer: .init(lat: 37.8, lon: -122.27,
                            headingDeg: 186.7, elevationDeg: 12.0, headingAccuracyDeg: 16.4),
            aircraft: nil)
        let json = String(data: try JSONEncoder().encode(req), encoding: .utf8)!
        #expect(json.contains("\"headingDeg\":186.7"))
        #expect(json.contains("\"elevationDeg\":12"))
        #expect(json.contains("\"aircraft\":null"))   // always explicit null (backfill path)
    }
}
