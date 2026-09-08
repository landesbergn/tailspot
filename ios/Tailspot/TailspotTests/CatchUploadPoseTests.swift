//
//  CatchUploadPoseTests.swift
//  TailspotTests
//
//  Pins the path that makes the backend's anti-cheat validator work at all:
//  Catch row → capture-diagnostics blob → POST /v1/catches body.
//
//  Before 2026-09-07 the app sent headingDeg/elevationDeg/headingAccuracyDeg
//  as null and `aircraft` as null on EVERY catch, so every stored verdict was
//  "unverifiable". These tests assert the pose now reaches the wire, and —
//  just as importantly — that a row with no diagnostics still sends the old
//  all-null shape rather than a malformed body the server would 422.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("Catch upload pose mapping")
struct CatchUploadPoseTests {

    /// A blob shaped like the one `ContentView.buildCaptureDiagnostics` writes.
    private func blob(
        headingDeg: Double? = 186.7,
        elevationDeg: Double? = 24.5,
        headingAccuracyDeg: Double? = 12.0,
        lat: Double? = 37.71234,
        lon: Double? = -122.21876,
        alt: Double? = 3048,
        ts: Date? = Date(timeIntervalSince1970: 1_757_200_000)
    ) -> String {
        CatchCaptureDiagnostics(
            headingDeg: headingDeg,
            cameraElevationDeg: elevationDeg,
            rollDeg: 1.2,
            zoom: 1.0,
            headingAccuracyDeg: headingAccuracyDeg,
            targetOffsetDeg: 3.1,
            targetArcmin: 9.4,
            wasTapped: true,
            candidateCount: 1,
            alternatives: nil,
            selector: "prominence-v1",
            aircraftLat: lat,
            aircraftLon: lon,
            aircraftAltitudeMeters: alt,
            aircraftPositionTimestamp: ts
        ).jsonString()!
    }

    // MARK: - from(diagnosticsJSON:)

    @Test func fullBlobMapsToPoseAndAircraft() {
        let pose = CatchUploadPose.from(diagnosticsJSON: blob())
        #expect(pose.headingDeg == 186.7)
        // The wire's `elevationDeg` is the diagnostics' `cameraElevationDeg`
        // (90 − pitch), NOT raw pitch — the same angle the server's validator
        // reconstructs geometrically.
        #expect(pose.elevationDeg == 24.5)
        #expect(pose.headingAccuracyDeg == 12.0)
        #expect(pose.aircraft?.lat == 37.71234)
        #expect(pose.aircraft?.lon == -122.21876)
        #expect(pose.aircraft?.altitudeMeters == 3048)
        // Unix seconds, not Foundation's seconds-since-2001.
        #expect(pose.aircraft?.positionTimestamp == 1_757_200_000)
    }

    @Test func nilDiagnosticsProducesTheOldAllNullShape() {
        let pose = CatchUploadPose.from(diagnosticsJSON: nil)
        #expect(pose == .empty)
        #expect(pose.aircraft == nil)
    }

    @Test func unparseableDiagnosticsProducesTheOldAllNullShape() {
        #expect(CatchUploadPose.from(diagnosticsJSON: "{not json") == .empty)
    }

    @Test func oldBlobWithoutAircraftKeysStillSendsThePose() {
        // A row captured before the aircraft position was recorded: the pose
        // survives (so the sanity checks still run) but there's nothing to
        // correlate against, so no aircraft block.
        let json = blob(lat: nil, lon: nil, alt: nil, ts: nil)
        let pose = CatchUploadPose.from(diagnosticsJSON: json)
        #expect(pose.headingDeg == 186.7)
        #expect(pose.aircraft == nil)
    }

    @Test func negativeHeadingAccuracyBecomesNil() {
        // CLLocation reports a NEGATIVE headingAccuracy to mean "invalid".
        // The server WIDENS its bearing tolerance by whatever we send, so a
        // negative would tighten it — send null instead.
        let pose = CatchUploadPose.from(diagnosticsJSON: blob(headingAccuracyDeg: -1))
        #expect(pose.headingAccuracyDeg == nil)
        #expect(pose.headingDeg == 186.7)   // the heading itself still goes
    }

    @Test func partialAircraftPositionSendsNoBlock() {
        // The backend requires lat + lon + altitudeMeters together; a partial
        // object is a 422 that would lose the catch. All-or-nothing.
        #expect(CatchUploadPose.from(diagnosticsJSON: blob(alt: nil)).aircraft == nil)
        #expect(CatchUploadPose.from(diagnosticsJSON: blob(lon: nil)).aircraft == nil)
    }

    @Test func missingPositionTimestampIsNullNotMissingAircraft() {
        let pose = CatchUploadPose.from(diagnosticsJSON: blob(ts: nil))
        #expect(pose.aircraft != nil)
        #expect(pose.aircraft?.positionTimestamp == nil)
    }

    // MARK: - Round-trip through the real Catch row + uploader seam

    @MainActor
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Catch.self, configurations: config)
        TestContainerRetention.retain(container)
        return ModelContext(container)
    }

    @MainActor
    private func insert(diagnostics: String?, into ctx: ModelContext) {
        let c = Catch(
            icao24: "ab1234",
            callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(),
            observerLat: 37.87, observerLon: -122.27,
            slantDistanceMeters: 25_000
        )
        c.captureDiagnosticsJSON = diagnostics
        ctx.insert(c)
        try? ctx.save()
    }

    @Test @MainActor func uploaderSendsThePoseFromTheRow() async throws {
        let ctx = try makeContext()
        insert(diagnostics: blob(), into: ctx)

        let fake = FakeUploadClient()
        fake.globalOutcome = .success(points: 100, duplicate: false)
        await uploadPendingWithClient(fake, context: ctx)

        let sent = try #require(fake.uploadedPoses["ab1234"])
        #expect(sent.headingDeg == 186.7)
        #expect(sent.elevationDeg == 24.5)
        #expect(sent.headingAccuracyDeg == 12.0)
        #expect(sent.aircraft?.altitudeMeters == 3048)
    }

    @Test @MainActor func uploaderSendsNilsForARowWithNoDiagnostics() async throws {
        let ctx = try makeContext()
        insert(diagnostics: nil, into: ctx)

        let fake = FakeUploadClient()
        fake.globalOutcome = .success(points: 100, duplicate: false)
        await uploadPendingWithClient(fake, context: ctx)

        // Exactly today's behaviour for the pre-existing Hangar: accepted,
        // scored, recorded "unverifiable".
        #expect(fake.uploadedPoses["ab1234"] == .empty)
    }
}
