//
//  CatchBackfillTests.swift
//  TailspotTests
//
//  Unit tests for CatchBackfill.applyMetadata and needsMetadata.
//  Does NOT test backfillAll (network I/O).
//
//  Uses in-memory ModelContainer so tests don't touch disk.
//

import Testing
import Foundation
import SwiftData
@testable import Tailspot

@Suite("CatchBackfill")
@MainActor
struct CatchBackfillTests {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: Catch.self, configurations: config)
    }

    /// Build a minimal Catch with explicit airframe fields for testing.
    /// Parameter order mirrors the most common call pattern in these tests:
    /// typecode and registration are the key backfill targets.
    private func makeCatch(
        icao24: String = "abc123",
        model: String? = nil,
        manufacturer: String? = nil,
        operatorName: String? = nil,
        typecode: String? = nil,
        registration: String? = nil,
        altitudeMeters: Double? = nil,
        velocityMps: Double? = nil,
        slantDistanceMeters: Double = 5000,
        in context: ModelContext
    ) -> Catch {
        let c = Catch(
            icao24: icao24,
            callsign: nil,
            model: model,
            manufacturer: manufacturer,
            operatorName: operatorName,
            caughtAt: Date(timeIntervalSince1970: 1_700_000_000),
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: slantDistanceMeters,
            registration: registration,
            typecode: typecode,
            altitudeMeters: altitudeMeters,
            velocityMps: velocityMps
        )
        context.insert(c)
        return c
    }

    /// Construct a metadata value. All fields are optional; defaults to nil.
    private func makeMeta(
        icao24: String = "abc123",
        registration: String? = nil,
        manufacturerName: String? = nil,
        manufacturerIcao: String? = nil,
        model: String? = nil,
        typecode: String? = nil,
        operatorName: String? = nil
    ) -> AircraftMetadata {
        AircraftMetadata(
            icao24: icao24,
            registration: registration,
            manufacturerName: manufacturerName,
            manufacturerIcao: manufacturerIcao,
            model: model,
            typecode: typecode,
            operatorName: operatorName
        )
    }

    // MARK: - applyMetadata

    @Test func applyMetadataFillsOnlyNilFields() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // model already set; typecode + registration nil
        let c = makeCatch(model: "preset", in: context)
        let meta = makeMeta(
            registration: "N12345",
            manufacturerName: "Boeing",
            model: "737-800",
            typecode: "B738",
            operatorName: "United"
        )

        let changed = CatchBackfill.applyMetadata(meta, to: [c])

        #expect(changed == true)
        // Nil fields got filled
        #expect(c.typecode == "B738")
        #expect(c.registration == "N12345")
        #expect(c.manufacturer == "Boeing")
        #expect(c.operatorName == "United")
        // Pre-existing non-nil field must NOT be overwritten
        #expect(c.model == "preset")
    }

    @Test func applyMetadataReturnsFalseWhenNothingToFill() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = makeCatch(
            model: "737-800",
            manufacturer: "Boeing",
            operatorName: "United",
            typecode: "B738",
            registration: "N12345",
            in: context
        )
        let meta = makeMeta(
            registration: "N99999",
            manufacturerName: "Airbus",
            model: "A320",
            typecode: "A320",
            operatorName: "Delta"
        )

        let changed = CatchBackfill.applyMetadata(meta, to: [c])

        #expect(changed == false)
        // All values unchanged
        #expect(c.typecode == "B738")
        #expect(c.registration == "N12345")
        #expect(c.manufacturer == "Boeing")
        #expect(c.model == "737-800")
        #expect(c.operatorName == "United")
    }

    @Test func applyMetadataNeverTouchesMomentData() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let catchDate = Date(timeIntervalSince1970: 1_700_000_000)
        let c = Catch(
            icao24: "abc123",
            callsign: nil,
            model: nil,
            manufacturer: nil,
            caughtAt: catchDate,
            observerLat: 37.87,
            observerLon: -122.27,
            slantDistanceMeters: 9876.5,
            altitudeMeters: 10668,
            velocityMps: 245.0
        )
        context.insert(c)

        let meta = makeMeta(
            registration: "N12345",
            typecode: "B738"
        )
        _ = CatchBackfill.applyMetadata(meta, to: [c])

        // Moment-data must be untouched
        #expect(c.altitudeMeters == 10668)
        #expect(c.velocityMps == 245.0)
        #expect(c.slantDistanceMeters == 9876.5)
        #expect(c.caughtAt == catchDate)
    }

    @Test func applyMetadataFillsAllRowsSharingIcao() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c1 = makeCatch(icao24: "aabbcc", in: context)
        let c2 = makeCatch(icao24: "aabbcc", in: context)

        let meta = makeMeta(icao24: "aabbcc", registration: "G-FORM", typecode: "A388")
        let changed = CatchBackfill.applyMetadata(meta, to: [c1, c2])

        #expect(changed == true)
        #expect(c1.typecode == "A388")
        #expect(c1.registration == "G-FORM")
        #expect(c2.typecode == "A388")
        #expect(c2.registration == "G-FORM")
    }

    // MARK: - needsMetadata

    @Test func needsMetadataGate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let needsIt = makeCatch(typecode: nil, registration: nil, in: context)
        #expect(CatchBackfill.needsMetadata(needsIt) == true)

        let typecodeOnly = makeCatch(typecode: "B738", registration: nil, in: context)
        #expect(CatchBackfill.needsMetadata(typecodeOnly) == true)

        let registrationOnly = makeCatch(typecode: nil, registration: "N12345", in: context)
        #expect(CatchBackfill.needsMetadata(registrationOnly) == true)

        let hasAll = makeCatch(typecode: "B738", registration: "N12345", in: context)
        #expect(CatchBackfill.needsMetadata(hasAll) == false)
    }

    // MARK: - trimmedNonEmpty / empty-string edge case

    @Test func emptyStringMetadataLeavesFieldNil() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Catch with nil typecode
        let c = makeCatch(typecode: nil, in: context)
        // Metadata whose typecode is whitespace-only
        let meta = makeMeta(registration: "", typecode: "   ")

        let changed = CatchBackfill.applyMetadata(meta, to: [c])

        // Empty/whitespace strings must not be stored; field stays nil
        #expect(c.typecode == nil)
        #expect(c.registration == nil)
        // Nothing was actually set, so changed must be false
        #expect(changed == false)
    }
}
