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
    static let confirmedEvent = "catch_confirmed"
    static let deniedEvent = "catch_denied"

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

    /// Properties for a confirm/deny answer to the reveal "is this right?"
    /// prompt. The verdict rides in the event NAME (catch_confirmed vs
    /// catch_denied); the properties are identical for both.
    static func confirmationProperties(icao24: String, rarity: String) -> [String: AnalyticsValue] {
        [
            "icao24": .string(icao24),
            "rarity": .string(rarity),
        ]
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

    @MainActor static func fireConfirmation(_ row: Catch, isRight: Bool) {
        Analytics.capture(
            isRight ? confirmedEvent : deniedEvent,
            confirmationProperties(icao24: row.icao24, rarity: row.resolvedRarity.rawValue)
        )
    }
}
