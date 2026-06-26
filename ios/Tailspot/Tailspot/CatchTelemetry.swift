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
//    - catch_uploaded   — fires once per catch the backend accepts. Carries
//                         the aircraft IDENTITY snapshotted on the Catch
//                         (tail number, typecode, manufacturer, model,
//                         operator, type, ADS-B category, callsign) plus the
//                         authoritative rarity/points/duplicate from the
//                         server response — so PostHog can show *which* plane
//                         was caught. Airframe attributes, not user PII; the
//                         only location is the coarse reverse-geocoded
//                         place_name (no precise coordinates).
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
    static let uploadedEvent = "catch_uploaded"
    static let deletedEvent = "catch_deleted"
    static let blockedOutdoorsEvent = "catch_blocked_outdoors"
    static let gateOverrideEvent = "catch_gate_override"

    // MARK: - Pure property builders (unit-tested)

    /// Properties for a successful catch of a single airframe.
    static func performedProperties(
        icao24: String,
        rarity: String,
        aircraftType: String,
        slantKm: Double,
        visualConfirmEnabled: Bool,
        visualFixConfidence: Float?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "aircraft_type": .string(aircraftType),
            "slant_km": .double(slantKm),
            "is_duplicate": .bool(false),
            // Visual-confirmation context (2026-06-26 go-live): is the feature
            // on, and did the caught plane have a live detector fix at catch
            // time + how confident. The wild "is it actually helping?" signal.
            "visual_confirm_enabled": .bool(visualConfirmEnabled),
            "visual_fix_active": .bool(visualFixConfidence != nil),
        ]
        if let c = visualFixConfidence { props["visual_fix_confidence"] = .double(Double(c)) }
        return props
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

    /// Properties for a server-confirmed catch upload (`catch_uploaded`).
    ///
    /// Carries the aircraft IDENTITY captured on the `Catch` so PostHog can
    /// answer "which specific plane was caught" — tail number, typecode,
    /// manufacturer, model, operator, derived type, ADS-B emitter category,
    /// and callsign. `rarity`/`points`/`duplicate` come from the authoritative
    /// server response (rarity falls back to the local resolved value when the
    /// server omits it). These are airframe attributes, NOT user PII — the only
    /// location is the coarse reverse-geocoded `place_name` (no coordinates).
    ///
    /// Nil/blank string fields are OMITTED (matching `deletedProperties` and
    /// `Catch.preferredAirframeField`'s blank-is-absent rule) — never sent as
    /// null or a placeholder, so PostHog only sees keys we actually know.
    static func uploadedProperties(
        icao24: String,
        rarity: String,
        points: Int,
        duplicate: Bool,
        registration: String?,
        typecode: String?,
        manufacturer: String?,
        model: String?,
        operatorName: String?,
        aircraftType: String?,
        category: String?,
        callsign: String?,
        placeName: String?
    ) -> [String: AnalyticsValue] {
        var props: [String: AnalyticsValue] = [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
            "points": .int(points),
            "duplicate": .bool(duplicate),
        ]
        // Insert only when the value is non-nil and non-blank — a missing
        // airframe field should be an absent key, not "" or null.
        func add(_ key: String, _ value: String?) {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return }
            props[key] = .string(trimmed)
        }
        add("registration", registration)
        add("typecode", typecode)
        add("manufacturer", manufacturer)
        add("model", model)
        add("operator_name", operatorName)
        add("aircraft_type", aircraftType)
        add("category", category)
        add("callsign", callsign)
        add("place_name", placeName)
        return props
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

    @MainActor static func firePerformed(
        _ row: Catch,
        visualConfirmEnabled: Bool,
        visualFixConfidence: Float?
    ) {
        Analytics.capture(performedEvent, performedProperties(
            icao24: row.icao24,
            rarity: row.resolvedRarity.rawValue,
            aircraftType: row.resolvedType.rawValue,
            slantKm: row.slantDistanceMeters / 1000,
            visualConfirmEnabled: visualConfirmEnabled,
            visualFixConfidence: visualFixConfidence
        ))
    }

    @MainActor static func fireDuplicate(icao24: String) {
        Analytics.capture(performedEvent, duplicateProperties(icao24: icao24))
    }

    /// Fire `catch_uploaded` after the backend accepts a catch. Reads the
    /// aircraft identity off the `Catch` (MainActor-isolated SwiftData row)
    /// and the rarity/points/duplicate off the server response. Rarity prefers
    /// the server value (authoritative re-tiering) and falls back to the
    /// locally resolved tier when the response omits it.
    @MainActor static func fireUploaded(_ row: Catch, response: UploadCatchResponse) {
        Analytics.capture(uploadedEvent, uploadedProperties(
            icao24: row.icao24,
            rarity: response.rarity ?? row.resolvedRarity.rawValue,
            points: response.points,
            duplicate: response.duplicate,
            registration: row.registration,
            typecode: row.typecode,
            manufacturer: row.manufacturer,
            model: row.model,
            operatorName: row.operatorName,
            aircraftType: row.resolvedType.rawValue,
            category: row.category,
            callsign: row.callsign,
            placeName: row.placeName
        ))
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
