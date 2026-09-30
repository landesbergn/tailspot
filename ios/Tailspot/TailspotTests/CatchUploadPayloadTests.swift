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
//  The same rule governs `aircraft` (and `aircraft.positionTimestamp`): absent
//  is 422, null means "no position recorded", an object is what the validator
//  correlates the pose against.
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
            aircraft: nil,
            guess: nil)
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
            aircraft: nil,
            guess: nil)
        let json = String(data: try JSONEncoder().encode(req), encoding: .utf8)!
        #expect(json.contains("\"headingDeg\":186.7"))
        #expect(json.contains("\"elevationDeg\":12"))
        #expect(json.contains("\"aircraft\":null"))   // no recorded position -> explicit null
    }

    // ── Aircraft block (anti-cheat, 2026-09-07) ──────────────────────────
    // Same explicit-null rule as the pose: absent = 422, null = "no position
    // recorded, verdict unverifiable", object = validate it.

    @Test func absentAircraftEncodesAsExplicitNull() throws {
        let json = try encodedNilPosePayload()
        #expect(json.contains("\"aircraft\":null"))
    }

    @Test func presentAircraftEncodesAsAnObject() throws {
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111",
            icao24: "abc123", callsign: "UAL1",
            caughtAt: 1_715_000_000,
            observer: .init(lat: 37.8, lon: -122.27,
                            headingDeg: 186.7, elevationDeg: 24.5, headingAccuracyDeg: 12.0),
            aircraft: .init(lat: 37.71234, lon: -122.21876,
                            altitudeMeters: 3048, positionTimestamp: 1_757_200_000),
            guess: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ac = obj["aircraft"] as? [String: Any]
        #expect(ac?["lat"] as? Double == 37.71234)
        #expect(ac?["lon"] as? Double == -122.21876)
        #expect(ac?["altitudeMeters"] as? Double == 3048)
        #expect(ac?["positionTimestamp"] as? Double == 1_757_200_000)
        // And the pose that pairs with it.
        let o = obj["observer"] as? [String: Any]
        #expect(o?["headingDeg"] as? Double == 186.7)
        #expect(o?["elevationDeg"] as? Double == 24.5)
        #expect(o?["headingAccuracyDeg"] as? Double == 12.0)
    }

    @Test func aircraftWithoutAFixTimeEncodesTimestampAsNull() throws {
        // The backend takes `positionTimestamp` as number|null; the
        // synthesized Encodable would OMIT a nil, which is malformed.
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111",
            icao24: "abc123", callsign: nil,
            caughtAt: 1_715_000_000,
            observer: .init(lat: 37.8, lon: -122.27,
                            headingDeg: nil, elevationDeg: nil, headingAccuracyDeg: nil),
            aircraft: .init(lat: 37.7, lon: -122.2,
                            altitudeMeters: 3048, positionTimestamp: nil),
            guess: nil)
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let ac = try #require(obj["aircraft"] as? [String: Any])
        #expect(ac.keys.contains("positionTimestamp"))
        #expect(ac["positionTimestamp"] is NSNull)
    }

    // ── Guess block (game-layer PR2) ─────────────────────────────────────
    // The backend's contract for `guess` is the OPPOSITE of the pose angles:
    // an ABSENT key means "no guess" (the common case), while a present
    // block must be well-formed {kind, value} or the whole catch 422s. So
    // nil must be OMITTED — not encoded as null — and a present guess must
    // carry both keys.

    @Test func noGuessOmitsTheKeyEntirely() throws {
        let json = try encodedNilPosePayload()
        #expect(!json.contains("\"guess\""))
    }

    @Test func presentGuessEncodesKindAndValue() throws {
        let req = UploadCatchRequest(
            catchUuid: "11111111-1111-4111-8111-111111111111",
            icao24: "abc123", callsign: "CPA873",
            caughtAt: 1_715_000_000,
            observer: .init(lat: 37.8, lon: -122.27,
                            headingDeg: nil, elevationDeg: nil, headingAccuracyDeg: nil),
            aircraft: nil,
            guess: .init(kind: "route", value: "VHHH"))
        let data = try JSONEncoder().encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let guess = obj["guess"] as? [String: Any]
        #expect(guess?["kind"] as? String == "route")
        #expect(guess?["value"] as? String == "VHHH")
        // The verdict NEVER goes on the wire — the server verifies the value
        // against its own truth (there is no "guessedRight" to spoof).
        #expect(guess?.keys.contains("correct") == false)
    }
}
