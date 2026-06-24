//
//  CatchTelemetryTests.swift
//  TailspotTests
//
//  Pins the catch-lifecycle event shapes (CatchTelemetry). The firing
//  itself is a thin pass-through to Analytics.capture (exercised by
//  AnalyticsTests); the *logic worth pinning* is which properties each
//  event carries — the contract the catch-confirmation-rate funnel
//  depends on.
//

import Foundation
import Testing
@testable import Tailspot

@Suite("CatchTelemetry properties")
struct CatchTelemetryTests {

    @Test func performedCarriesRarityTypeSlantAndNotDuplicate() {
        let p = CatchTelemetry.performedProperties(
            icao24: "ac5c1f", rarity: "rare", aircraftType: "wide", slantKm: 7.5
        )
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["rarity"]?.jsonValue as? String == "rare")
        #expect(p["aircraft_type"]?.jsonValue as? String == "wide")
        #expect((p["slant_km"]?.jsonValue as? Double) == 7.5)
        #expect(p["is_duplicate"]?.jsonValue as? Bool == false)
    }

    @Test func duplicateFlagsDuplicateAndOmitsAirframeProps() {
        let p = CatchTelemetry.duplicateProperties(icao24: "ac5c1f")
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["is_duplicate"]?.jsonValue as? Bool == true)
        // No Catch row exists for a duplicate — these must be absent.
        #expect(p["rarity"] == nil)
        #expect(p["aircraft_type"] == nil)
        #expect(p["slant_km"] == nil)
    }

    @Test func deletedCarriesCountAndRarity() {
        let p = CatchTelemetry.deletedProperties(icao24: "ac5c1f", count: 3, rarity: "epic")
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["count"]?.jsonValue as? Int == 3)
        #expect(p["rarity"]?.jsonValue as? String == "epic")
    }

    @Test func deletedOmitsRarityWhenUnknown() {
        let p = CatchTelemetry.deletedProperties(icao24: "ac5c1f", count: 1, rarity: nil)
        #expect(p["count"]?.jsonValue as? Int == 1)
        #expect(p["rarity"] == nil)
    }

    @Test func eventNamesAreStable() {
        #expect(CatchTelemetry.performedEvent == "catch_performed")
        #expect(CatchTelemetry.deletedEvent == "catch_deleted")
    }

    // MARK: - Authenticity gate telemetry (U5)

    @Test func outdoorGatePropertiesCarryVerdictAndSignals() {
        let f = SkyFeatures(edgeDensity: 0.2, tileVariance: 0.1, warmth: 0.3, meanLuminance: 0.5)
        let p = CatchTelemetry.outdoorGateProperties(verdict: .notSky, features: f, gpsAccuracyMeters: 12)
        #expect(p["verdict"]?.jsonValue as? String == "notSky")
        #expect((p["edge_density"]?.jsonValue as? Double) == 0.2)
        #expect((p["tile_variance"]?.jsonValue as? Double) == 0.1)
        #expect((p["gps_accuracy_m"]?.jsonValue as? Double) == 12)
    }

    @Test func outdoorGatePropertiesHandleMissingFeaturesAndGps() {
        let p = CatchTelemetry.outdoorGateProperties(verdict: .uncertain, features: nil, gpsAccuracyMeters: nil)
        #expect(p["verdict"]?.jsonValue as? String == "uncertain")
        #expect(p["features_available"]?.jsonValue as? Bool == false)
        #expect(p["gps_accuracy_m"] == nil)
    }

    @Test func gateEventNamesAreStable() {
        #expect(CatchTelemetry.outdoorGateShadowEvent == "outdoor_gate_shadow")
        #expect(CatchTelemetry.blockedOutdoorsEvent == "catch_blocked_outdoors")
    }
}
