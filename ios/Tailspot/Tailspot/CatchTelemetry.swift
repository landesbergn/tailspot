//
//  CatchTelemetry.swift
//  Tailspot
//
//  Catch-lifecycle analytics for the catch-confirmation-rate north-star
//  (STRATEGY.md). The catch path lives deep inside ContentView and the
//  delete path inside CatchDetailView — both untestable in isolation — so
//  the *logic* (which event, which properties) is factored out here as
//  pure builders that unit tests can pin, with thin `@MainActor` wrappers
//  that read a `Catch` and hand off to `Analytics.capture`.
//
//  Events (REST path, per Analytics.swift — NOT the PostHog SDK):
//    - catch_performed  — fires once per processed target on a catch tap.
//                         Successful catches carry rarity/type/slant;
//                         duplicates (already in the Hangar, no new row)
//                         carry only icao24 + is_duplicate=true.
//    - catch_deleted    — fires once per delete action (a HangarRow may
//                         group N icao rows; `count` records how many).
//
//  Together with the confirm/deny affordance (catch_confirmed /
//  catch_denied) these are the numerator + negative signals the
//  catch-confirmation-rate funnel needs.
//

import Foundation

nonisolated enum CatchTelemetry {

    static let performedEvent = "catch_performed"
    static let deletedEvent = "catch_deleted"
    static let blockedOutdoorsEvent = "catch_blocked_outdoors"
    static let gateOverrideEvent = "catch_gate_override"

    // MARK: - Pure property builders (unit-tested)

    /// Properties for a successful catch of a single airframe.
    static func performedProperties(
        icao24: String,
        rarity: String,
        aircraftType: String,
        slantKm: Double
    ) -> [String: AnalyticsValue] {
        [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "aircraft_type": .string(aircraftType),
            "slant_km": .double(slantKm),
            "is_duplicate": .bool(false),
        ]
    }

    /// Properties for a duplicate-catch tap — the target is already in the
    /// Hangar, so no `Catch` row exists to read rarity/type from. We still
    /// record the attempt (it IS a capture attempt — part of the funnel
    /// denominator) flagged as a duplicate.
    static func duplicateProperties(icao24: String) -> [String: AnalyticsValue] {
        [
            "icao24": .string(icao24),
            "is_duplicate": .bool(true),
        ]
    }

    /// Properties for a delete. `count` is the number of underlying `Catch`
    /// rows the deleted Hangar row grouped (≥1). `rarity` is omitted when
    /// unknown rather than sent as a placeholder.
    static func deletedProperties(
        icao24: String,
        count: Int,
        rarity: String?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "count": .int(count),
        ]
        if let rarity { props["rarity"] = .string(rarity) }
        return props
    }

    /// Properties for the v1 authenticity gate events (block + override):
    /// the verdict + raw scene signals, so the false-block rate can be
    /// watched and the corpus re-scored.
    static func outdoorGateProperties(
        verdict: SkyVerdict,
        features: SkyFeatures?,
        gpsAccuracyMeters: Double?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = ["verdict": .string(verdict.rawValue)]
        if let f = features {
            props["edge_density"] = .double(f.edgeDensity)
            props["tile_variance"] = .double(f.tileVariance)
            props["warmth"] = .double(f.warmth)
            props["mean_luminance"] = .double(f.meanLuminance)
        } else {
            props["features_available"] = .bool(false)
        }
        if let g = gpsAccuracyMeters { props["gps_accuracy_m"] = .double(g) }
        return props
    }

    // MARK: - Fire wrappers (read MainActor-isolated `Catch`, then capture)

    @MainActor static func firePerformed(_ row: Catch) {
        Analytics.capture(performedEvent, performedProperties(
            icao24: row.icao24,
            rarity: row.resolvedRarity.rawValue,
            aircraftType: row.resolvedType.rawValue,
            slantKm: row.slantDistanceMeters / 1000
        ))
    }

    @MainActor static func fireDuplicate(icao24: String) {
        Analytics.capture(performedEvent, duplicateProperties(icao24: icao24))
    }

    @MainActor static func fireDeleted(icao24: String, count: Int, rarity: String?) {
        Analytics.capture(deletedEvent, deletedProperties(
            icao24: icao24, count: count, rarity: rarity
        ))
    }

    /// Fired when the gate blocks an indoor catch (verdict `.notSky`).
    static func fireBlockedOutdoors(
        verdict: SkyVerdict, features: SkyFeatures?, gpsAccuracyMeters: Double?
    ) {
        Analytics.capture(blockedOutdoorsEvent, outdoorGateProperties(
            verdict: verdict, features: features, gpsAccuracyMeters: gpsAccuracyMeters
        ))
    }

    /// Fired when the user taps "Catch anyway" through a block — the
    /// calibration signal for how often the gate is wrong.
    static func fireGateOverride(
        verdict: SkyVerdict, features: SkyFeatures?, gpsAccuracyMeters: Double?
    ) {
        Analytics.capture(gateOverrideEvent, outdoorGateProperties(
            verdict: verdict, features: features, gpsAccuracyMeters: gpsAccuracyMeters
        ))
    }
}
