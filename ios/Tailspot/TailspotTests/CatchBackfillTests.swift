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

    // MARK: - applyFAAFallback

    @Test func applyFAAFallbackFillsNilIdentity() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Catch with all identity nil. Catch.init classifies even with nil
        // inputs, so aircraftType is populated by the classifier on init.
        // Explicitly nil it to simulate a legacy row that migrated without
        // a value — the real target of FAA fallback for aircraftType.
        let c = makeCatch(icao24: "a9eefa", in: context)
        c.aircraftType = nil   // simulate pre-field legacy row

        let changed = CatchBackfill.applyFAAFallback(to: [c], icao24: "a9eefa")

        #expect(changed == true)
        #expect(c.manufacturer == "Cirrus")
        #expect(c.model == "SR20")
        #expect(c.aircraftType == "ga")
        #expect(c.registration == "N7391E")
    }

    @Test func applyFAAFallbackRespectsExistingValues() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Catch with model already set — FAA fallback must not overwrite it.
        let c = makeCatch(icao24: "a9eefa", model: "SR22T", in: context)

        let changed = CatchBackfill.applyFAAFallback(to: [c], icao24: "a9eefa")

        // model was already set, so FAA SR20 must not overwrite it.
        // manufacturer, registration, (possibly aircraftType) may still fill.
        #expect(c.model == "SR22T")
        // changed may be true (manufacturer/registration filled) or false
        // depending on what the classifier set at init — just verify model.
        _ = changed
    }

    @Test func applyFAAFallbackForeignReturnsFalse() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let c = makeCatch(icao24: "71c575", in: context)
        let manufacturerBefore = c.manufacturer
        let modelBefore = c.model

        let changed = CatchBackfill.applyFAAFallback(to: [c], icao24: "71c575")

        #expect(changed == false)
        #expect(c.manufacturer == manufacturerBefore)
        #expect(c.model == modelBefore)
    }

    // MARK: - Route backfill (2026-07-04)

    private func makeRoutedCatch(
        callsign: String?, origin: String? = nil, dest: String? = nil,
        in context: ModelContext
    ) -> Catch {
        let c = Catch(
            icao24: "86e123", callsign: callsign, model: nil, manufacturer: nil,
            caughtAt: Date(timeIntervalSince1970: 1_700_000_000),
            observerLat: 35.55, observerLon: 139.78, slantDistanceMeters: 9000,
            originIcao: origin, destIcao: dest
        )
        context.insert(c)
        return c
    }

    private var tokyoRoute: BackendAircraft.Route {
        makeRoute(origin: "RJTT", dest: "KSFO", originName: "Tokyo", destName: "San Francisco")
    }

    /// Decode a Route through JSON — its memberwise init is synthesized
    /// internal-to-Decodable shape; building via decoder mirrors production.
    private func makeRoute(
        origin: String?, dest: String?,
        originIata: String? = nil, destIata: String? = nil,
        originName: String? = nil, destName: String? = nil
    ) -> BackendAircraft.Route {
        var dict: [String: String] = [:]
        if let origin { dict["originIcao"] = origin }
        if let dest { dict["destIcao"] = dest }
        if let originIata { dict["originIata"] = originIata }
        if let destIata { dict["destIata"] = destIata }
        if let originName { dict["originName"] = originName }
        if let destName { dict["destName"] = destName }
        let data = try! JSONEncoder().encode(dict)
        return try! JSONDecoder().decode(BackendAircraft.Route.self, from: data)
    }

    @Test func needsRouteGate() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Route-less catch with a callsign -> needs.
        #expect(CatchBackfill.needsRoute(makeRoutedCatch(callsign: "ANA858", in: context)))
        // No callsign -> nothing to look up.
        #expect(!CatchBackfill.needsRoute(makeRoutedCatch(callsign: nil, in: context)))
        #expect(!CatchBackfill.needsRoute(makeRoutedCatch(callsign: "  ", in: context)))
        // A one-sided recorded route is moment-data -> left alone.
        #expect(!CatchBackfill.needsRoute(makeRoutedCatch(callsign: "ANA858", origin: "RJTT", in: context)))
        // A full ICAO route without IATA display codes DOES re-qualify
        // (2026-07-05 translation pass) — see needsRouteIncludesIataUpgradeRows.
        #expect(CatchBackfill.needsRoute(makeRoutedCatch(callsign: "ANA858", origin: "RJTT", dest: "KSFO", in: context)))
    }

    @Test func applyRouteFillsNilOnlyWithNames() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", in: context)

        #expect(CatchBackfill.applyRoute(tokyoRoute, to: [c]))
        #expect(c.originIcao == "RJTT")
        #expect(c.destIcao == "KSFO")
        #expect(c.originName == "Tokyo")
        #expect(c.destName == "San Francisco")
    }

    @Test func applyRouteNeverOverwritesRecordedRoute() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // As-flown one-sided route stays exactly as recorded.
        let c = makeRoutedCatch(callsign: "ANA858", origin: "RJAA", in: context)

        #expect(!CatchBackfill.applyRoute(tokyoRoute, to: [c]))
        #expect(c.originIcao == "RJAA")
        #expect(c.destIcao == nil)
    }

    @Test func applyRouteRejectsHalfAnswers() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", in: context)

        // A lookup that resolves only one end fills nothing — a half route
        // is worse than none on the card.
        #expect(!CatchBackfill.applyRoute(makeRoute(origin: "RJTT", dest: nil), to: [c]))
        #expect(c.originIcao == nil)
        #expect(c.destIcao == nil)
    }

    // MARK: - IATA + degenerate routes (2026-07-05)

    @Test func applyRouteFillsIataAlongsideCodes() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", in: context)

        let route = makeRoute(origin: "RJTT", dest: "KSFO",
                              originIata: "HND", destIata: "SFO")
        #expect(CatchBackfill.applyRoute(route, to: [c]))
        #expect(c.originIata == "HND")
        #expect(c.destIata == "SFO")
        #expect(c.displayOrigin == "HND")   // IATA wins the display
        #expect(c.displayDest == "SFO")
    }

    @Test func applyRouteTranslatesIataOntoMatchingStoredRoute() throws {
        // Pre-IATA row: full ICAO route recorded, no display codes. The
        // lookup translates ONLY when its ICAO pair matches what we stored.
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", origin: "RJTT", dest: "KSFO", in: context)

        let match = makeRoute(origin: "RJTT", dest: "KSFO",
                              originIata: "HND", destIata: "SFO")
        #expect(CatchBackfill.applyRoute(match, to: [c]))
        #expect(c.originIata == "HND")
        #expect(c.originIcao == "RJTT")     // codes untouched
    }

    @Test func applyRouteNeverRelabelsAMismatchedRoute() throws {
        // Current filing differs from the as-flown stored route → the IATA
        // of TODAY'S airports must not be stamped onto yesterday's journey.
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", origin: "RJAA", dest: "KSFO", in: context)

        let different = makeRoute(origin: "VVNB", dest: "RJTT",
                                  originIata: "HAN", destIata: "HND")
        #expect(!CatchBackfill.applyRoute(different, to: [c]))
        #expect(c.originIata == nil)
        #expect(c.originIcao == "RJAA")
    }

    @Test func needsRouteIncludesIataUpgradeRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // Full ICAO route, no IATA → needs (translation pass).
        #expect(CatchBackfill.needsRoute(
            makeRoutedCatch(callsign: "ANA858", origin: "RJTT", dest: "KSFO", in: context)))
        // One-sided route → still left alone.
        #expect(!CatchBackfill.needsRoute(
            makeRoutedCatch(callsign: "ANA858", origin: "RJTT", in: context)))
    }

    @Test func clearDegenerateRoutesRepairsRoundTrips() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let bad = makeRoutedCatch(callsign: "JBU1", origin: "KLGA", dest: "KLGA", in: context)
        bad.originName = "New York"
        bad.destName = "New York"
        let good = makeRoutedCatch(callsign: "ANA858", origin: "RJTT", dest: "KSFO", in: context)

        #expect(CatchBackfill.clearDegenerateRoutes([bad, good]))
        #expect(bad.originIcao == nil)
        #expect(bad.destIcao == nil)
        #expect(bad.originName == nil)
        #expect(bad.destName == nil)
        // A real route is untouched.
        #expect(good.originIcao == "RJTT")
        #expect(good.destIcao == "KSFO")
        // Nothing degenerate → no change reported.
        #expect(!CatchBackfill.clearDegenerateRoutes([good]))
    }

    @Test func displayCodesFallBackToIcao() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let c = makeRoutedCatch(callsign: "ANA858", origin: "RJTT", dest: "KSFO", in: context)
        #expect(c.displayOrigin == "RJTT")
        #expect(c.displayDest == "KSFO")
    }
}

// MARK: - Per-launch negative cache
//
// backfillAll's metadata path re-fired network lookups on every Hangar open
// for airframes that can never resolve. The per-launch negative cache stops
// that. Serialized because the cache is process-static; each test resets it.
// Catches carry no callsign, so the route path (concrete routeClient) never
// touches the network — only the injected metadata source is exercised.

@Suite("CatchBackfill per-launch negative cache", .serialized)
@MainActor
struct CatchBackfillNegativeCacheTests {

    /// Counts metadata calls and returns a configurable result, so a test can
    /// assert the second same-launch pass skips the re-fetch.
    private final class CountingSource: ADSBSource, @unchecked Sendable {
        private(set) var metadataCallCount = 0
        var result: AircraftMetadata?

        func aircraftInBbox(
            lamin: Double, lomin: Double, lamax: Double, lomax: Double
        ) async throws -> [Aircraft] { [] }

        func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
            metadataCallCount += 1
            return result
        }
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Catch.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// A route-less, airframe-fact-less catch (no callsign → route path is a
    /// no-op; nil typecode+registration → needsMetadata true).
    private func makeCatch(icao24: String, in context: ModelContext) -> Catch {
        let c = Catch(
            icao24: icao24, callsign: nil, model: nil, manufacturer: nil,
            caughtAt: Date(timeIntervalSince1970: 1_700_000_000),
            observerLat: 37.87, observerLon: -122.27, slantDistanceMeters: 5000
        )
        context.insert(c)
        return c
    }

    private func makeMeta(icao24: String, registration: String, typecode: String) -> AircraftMetadata {
        AircraftMetadata(
            icao24: icao24, registration: registration,
            manufacturerName: nil, manufacturerIcao: nil,
            model: nil, typecode: typecode, operatorName: nil
        )
    }

    /// An unresolvable airframe (foreign icao with no FAA record, source
    /// returns nil) is fetched once, then SKIPPED on the next same-launch
    /// pass — the fix for re-fetching e.g. Noah's Bali catches on every open.
    @Test func skipsUnresolvedIcaoOnSecondPass() async throws {
        CatchBackfill._resetNegativeCacheForTesting()
        defer { CatchBackfill._resetNegativeCacheForTesting() }
        // Retain the container for the test's lifetime — SwiftData traps on a
        // change-notification timer if it deallocates under a live context.
        let container = try makeContainer()
        let context = ModelContext(container)
        defer { _ = container }
        let c = makeCatch(icao24: "71c575", in: context)   // no FAA record
        let src = CountingSource()                          // returns nil

        await CatchBackfill.backfillAll([c], in: context, source: src)
        #expect(src.metadataCallCount == 1)                 // first pass fetches
        #expect(CatchBackfill.needsMetadata(c))             // still unresolved

        await CatchBackfill.backfillAll([c], in: context, source: src)
        #expect(src.metadataCallCount == 1)                 // skipped, no re-fetch
        #expect(CatchBackfill.needsMetadata(c))
    }

    /// A row that fully resolves is never added to the cache; it simply drops
    /// out of needsMetadata, so the next pass has nothing left to fetch.
    @Test func resolvedIcaoIsNotReattempted() async throws {
        CatchBackfill._resetNegativeCacheForTesting()
        defer { CatchBackfill._resetNegativeCacheForTesting() }
        // Retain the container for the test's lifetime — SwiftData traps on a
        // change-notification timer if it deallocates under a live context.
        let container = try makeContainer()
        let context = ModelContext(container)
        defer { _ = container }
        let c = makeCatch(icao24: "abcabc", in: context)
        let src = CountingSource()
        src.result = makeMeta(icao24: "abcabc", registration: "N123", typecode: "B738")

        await CatchBackfill.backfillAll([c], in: context, source: src)
        #expect(src.metadataCallCount == 1)
        #expect(!CatchBackfill.needsMetadata(c))            // resolved

        await CatchBackfill.backfillAll([c], in: context, source: src)
        #expect(src.metadataCallCount == 1)                 // nothing needs it now
    }
}
