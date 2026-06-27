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
            icao24: "ac5c1f", rarity: "rare", aircraftType: "wide", slantKm: 7.5,
            visualConfirmEnabled: false, visualFixConfidence: nil
        )
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["rarity"]?.jsonValue as? String == "rare")
        #expect(p["aircraft_type"]?.jsonValue as? String == "wide")
        #expect((p["slant_km"]?.jsonValue as? Double) == 7.5)
        #expect(p["is_duplicate"]?.jsonValue as? Bool == false)
        // Visual confirmation off + no fix → flags present, confidence absent.
        #expect(p["visual_confirm_enabled"]?.jsonValue as? Bool == false)
        #expect(p["visual_fix_active"]?.jsonValue as? Bool == false)
        #expect(p["visual_fix_confidence"] == nil)
    }

    @Test func performedCarriesVisualFixWhenLockedOn() {
        let p = CatchTelemetry.performedProperties(
            icao24: "ac5c1f", rarity: "rare", aircraftType: "wide", slantKm: 7.5,
            visualConfirmEnabled: true, visualFixConfidence: 0.5
        )
        #expect(p["visual_confirm_enabled"]?.jsonValue as? Bool == true)
        #expect(p["visual_fix_active"]?.jsonValue as? Bool == true)
        #expect((p["visual_fix_confidence"]?.jsonValue as? Double) == 0.5)
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

    // MARK: - catch_uploaded (aircraft identity)

    @Test func uploadedCarriesFullAircraftIdentity() {
        let p = CatchTelemetry.uploadedProperties(
            icao24: "ac5c1f",
            rarity: "epic",
            points: 250,
            duplicate: false,
            registration: "N628TS",
            typecode: "B77W",
            manufacturer: "Boeing",
            model: "777-300ER",
            operatorName: "United Airlines",
            aircraftType: "wide",
            category: "A5",
            callsign: "UAL1",
            placeName: "Berkeley, CA"
        )
        // Server-authoritative fields.
        #expect(p["icao24"]?.jsonValue as? String == "ac5c1f")
        #expect(p["rarity"]?.jsonValue as? String == "epic")
        #expect(p["points"]?.jsonValue as? Int == 250)
        #expect(p["duplicate"]?.jsonValue as? Bool == false)
        // Aircraft identity off the Catch.
        #expect(p["registration"]?.jsonValue as? String == "N628TS")
        #expect(p["typecode"]?.jsonValue as? String == "B77W")
        #expect(p["manufacturer"]?.jsonValue as? String == "Boeing")
        #expect(p["model"]?.jsonValue as? String == "777-300ER")
        #expect(p["operator_name"]?.jsonValue as? String == "United Airlines")
        #expect(p["aircraft_type"]?.jsonValue as? String == "wide")
        #expect(p["category"]?.jsonValue as? String == "A5")
        #expect(p["callsign"]?.jsonValue as? String == "UAL1")
        #expect(p["place_name"]?.jsonValue as? String == "Berkeley, CA")
    }

    @Test func uploadedOmitsNilAndBlankAirframeFields() {
        let p = CatchTelemetry.uploadedProperties(
            icao24: "abc123",
            rarity: "common",
            points: 10,
            duplicate: true,
            registration: nil,
            typecode: nil,
            manufacturer: nil,
            model: nil,
            operatorName: "",          // blank → treated as absent
            aircraftType: "narrow",
            category: nil,
            callsign: "   ",           // whitespace-only → treated as absent
            placeName: nil
        )
        // Required keys always present.
        #expect(p["icao24"]?.jsonValue as? String == "abc123")
        #expect(p["rarity"]?.jsonValue as? String == "common")
        #expect(p["points"]?.jsonValue as? Int == 10)
        #expect(p["duplicate"]?.jsonValue as? Bool == true)
        #expect(p["aircraft_type"]?.jsonValue as? String == "narrow")
        // Nil/blank fields are OMITTED, never sent as "" or null.
        #expect(p["registration"] == nil)
        #expect(p["typecode"] == nil)
        #expect(p["manufacturer"] == nil)
        #expect(p["model"] == nil)
        #expect(p["operator_name"] == nil)
        #expect(p["category"] == nil)
        #expect(p["callsign"] == nil)
        #expect(p["place_name"] == nil)
    }

    @Test func uploadedTrimsWhitespaceFromValues() {
        let p = CatchTelemetry.uploadedProperties(
            icao24: "abc123", rarity: "rare", points: 50, duplicate: false,
            registration: "  N123AB  ", typecode: nil, manufacturer: nil,
            model: nil, operatorName: nil, aircraftType: "wide",
            category: nil, callsign: " SWA42 ", placeName: nil
        )
        #expect(p["registration"]?.jsonValue as? String == "N123AB")
        #expect(p["callsign"]?.jsonValue as? String == "SWA42")
    }

    @Test func uploadedEventNameIsStable() {
        #expect(CatchTelemetry.uploadedEvent == "catch_uploaded")
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
        let p = CatchTelemetry.outdoorGateProperties(
            verdict: .notSky, features: f, gpsAccuracyMeters: 12)
        #expect(p["verdict"]?.jsonValue as? String == "notSky")
        #expect((p["edge_density"]?.jsonValue as? Double) == 0.2)
        #expect((p["tile_variance"]?.jsonValue as? Double) == 0.1)
        #expect((p["gps_accuracy_m"]?.jsonValue as? Double) == 12)
    }

    @Test func outdoorGatePropertiesHandleMissingFeaturesAndGps() {
        let p = CatchTelemetry.outdoorGateProperties(
            verdict: .uncertain, features: nil, gpsAccuracyMeters: nil)
        #expect(p["verdict"]?.jsonValue as? String == "uncertain")
        #expect(p["features_available"]?.jsonValue as? Bool == false)
        #expect(p["gps_accuracy_m"] == nil)
    }

    @Test func gateEventNamesAreStable() {
        #expect(CatchTelemetry.blockedOutdoorsEvent == "catch_blocked_outdoors")
        #expect(CatchTelemetry.gateOverrideEvent == "catch_gate_override")
    }

    // MARK: - Anti-cheat telemetry (PR1: aim + size floor)

    @Test func performedDefaultsToMultiNOneAndOmitsAngularSize() {
        // Existing callers (and duplicates) get multi_n=1 and no size key.
        let p = CatchTelemetry.performedProperties(
            icao24: "ac5c1f", rarity: "rare", aircraftType: "wide", slantKm: 7.5,
            visualConfirmEnabled: false, visualFixConfidence: nil
        )
        #expect(p["multi_n"]?.jsonValue as? Int == 1)
        #expect(p["angular_size_arcmin"] == nil)
    }

    @Test func performedCarriesMultiNAndAngularSizeWhenProvided() {
        let p = CatchTelemetry.performedProperties(
            icao24: "ac5c1f", rarity: "rare", aircraftType: "wide", slantKm: 7.5,
            visualConfirmEnabled: false, visualFixConfidence: nil,
            multiN: 3, angularSizeArcmin: 8.4
        )
        #expect(p["multi_n"]?.jsonValue as? Int == 3)
        #expect((p["angular_size_arcmin"]?.jsonValue as? Double) == 8.4)
    }

    @Test func sizeGatePropertiesCarrySizeSlantAndFloor() {
        let p = CatchTelemetry.sizeGateProperties(arcmin: 1.9, slantKm: 28.7, blockedCount: 2)
        #expect((p["angular_size_arcmin"]?.jsonValue as? Double) == 1.9)
        #expect((p["slant_km"]?.jsonValue as? Double) == 28.7)
        #expect(p["blocked_count"]?.jsonValue as? Int == 2)
        #expect((p["floor_arcmin"]?.jsonValue as? Double) == ObservedAircraft.catchSizeFloorArcminutes)
    }

    @Test func sizeEventNamesAreStable() {
        #expect(CatchTelemetry.blockedSizeEvent == "catch_blocked_size")
        #expect(CatchTelemetry.sizeOverrideEvent == "catch_size_override")
    }

    // MARK: - Localized sky gate (L2)

    @Test func localGatePropertiesCarryVerdictFeaturesAndMode() {
        let f = LocalSkyFeatures(patchTexture: 0.05, patchWarmth: 0.12,
                                 patchLum: 0.4, skyFraction: 0.3)
        let p = CatchTelemetry.localGateProperties(
            verdict: .notSky, features: f, wouldBlock: true, enforcing: false)
        #expect(p["verdict"]?.jsonValue as? String == "notSky")
        #expect((p["patch_texture"]?.jsonValue as? Double) == 0.05)
        #expect((p["patch_warmth"]?.jsonValue as? Double) == 0.12)
        #expect((p["sky_fraction"]?.jsonValue as? Double) == 0.3)
        #expect(p["would_block"]?.jsonValue as? Bool == true)
        #expect(p["enforcing"]?.jsonValue as? Bool == false)
    }

    @Test func localGateEventNamesAreStable() {
        #expect(CatchTelemetry.localGateEvent == "catch_local_gate")
        #expect(CatchTelemetry.occludedOverrideEvent == "catch_occluded_override")
    }
}
