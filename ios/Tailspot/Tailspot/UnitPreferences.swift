//
//  UnitPreferences.swift
//  Tailspot
//
//  The user's display units — altitude (ft / m), speed (kt / mph / km/h) and
//  distance (km / mi) — chosen in Settings → UNITS. Storage stays SI
//  everywhere (`Aircraft.altitudeMeters`, `Catch.velocityMps`,
//  `Catch.slantDistanceMeters`, the wire DTO, replay snapshots, telemetry) —
//  the preference only changes how a value is FORMATTED, at the chokepoints
//  every card goes through (`CardPlane.altText` / `speedText` / `distText`),
//  plus the few loose strings that quote a distance (the AR overlay's
//  VoiceOver label, the beyond-eyeshot toast, the Debug aircraft list) and
//  the trophies whose copy quotes a value.
//
//  Explain-as-we-go: `UnitPreferences` is an `@Observable` class — the
//  Observation framework (iOS 17) that succeeds `ObservableObject` +
//  `@Published`. Any SwiftUI `body` that reads `UnitPreferences.shared.altitude`
//  — even indirectly, through a formatter's default argument — is tracked and
//  re-renders when the value changes. That's what lets a Hangar detail card
//  that's still alive in another tab re-format itself the moment the picker
//  flips in Settings, with no manual plumbing. The properties are written by
//  hand (`access` / `withMutation`) instead of as plain stored properties so
//  each write also lands in `UserDefaults`.
//
//  First-launch defaults are LOCALIZED (Noah's call, 2026-09-12): they follow
//  the phone's measurement system (iOS Settings → General → Language & Region
//  → Measurement System, surfaced as `Locale.measurementSystem`). Metric →
//  m / km/h / km; US and UK → ft / mph / mi. `DisplayUnits.localized(for:)`
//  is the one place that mapping lives. A stored choice always wins; the
//  locale is only consulted for a key that's missing or unreadable.
//

import Foundation
import Observation

/// Altitude display unit. Raw values are the persisted form — don't rename.
nonisolated enum AltitudeUnit: String, CaseIterable, Identifiable, Sendable {
    case feet, meters

    static let storageKey = "tailspot.units.altitude"

    var id: String { rawValue }

    /// Card suffix. `splitUnit` (CatchRevealView) splits on the LAST space,
    /// so a symbol must be a single space-free token.
    var symbol: String {
        switch self {
        case .feet: "ft"
        case .meters: "m"
        }
    }

    /// Spelled-out name for VoiceOver.
    var name: String {
        switch self {
        case .feet: "Feet"
        case .meters: "Meters"
        }
    }

    /// "35,433 ft" / "10,800 m" from meters MSL — whole units, grouped.
    func format(meters m: Double) -> String {
        let value: Double = switch self {
        case .feet: m * 3.28084
        case .meters: m
        }
        return "\(Int(value.rounded()).formatted(.number)) \(symbol)"
    }
}

/// Speed display unit. Raw values are the persisted form — don't rename.
nonisolated enum SpeedUnit: String, CaseIterable, Identifiable, Sendable {
    case knots, mph, kph

    static let storageKey = "tailspot.units.speed"

    var id: String { rawValue }

    /// Card suffix (single space-free token — see `AltitudeUnit.symbol`).
    var symbol: String {
        switch self {
        case .knots: "kt"
        case .mph: "mph"
        case .kph: "km/h"
        }
    }

    /// Spelled-out name for VoiceOver.
    var name: String {
        switch self {
        case .knots: "Knots"
        case .mph: "Miles per hour"
        case .kph: "Kilometers per hour"
        }
    }

    /// "451 kt" / "519 mph" / "835 km/h" from m/s ground speed.
    func format(mps v: Double) -> String {
        let value: Double = switch self {
        case .knots: v * 1.94384
        case .mph: v * 2.23694
        case .kph: v * 3.6
        }
        return "\(Int(value.rounded()).formatted(.number)) \(symbol)"
    }
}

/// Distance (slant range) display unit. Raw values are persisted — don't rename.
nonisolated enum DistanceUnit: String, CaseIterable, Identifiable, Sendable {
    case kilometers, miles

    static let storageKey = "tailspot.units.distance"

    var id: String { rawValue }

    /// Card suffix (single space-free token — see `AltitudeUnit.symbol`).
    var symbol: String {
        switch self {
        case .kilometers: "km"
        case .miles: "mi"
        }
    }

    /// Spelled-out name for VoiceOver and the Settings row.
    var name: String {
        switch self {
        case .kilometers: "Kilometers"
        case .miles: "Miles"
        }
    }

    /// Lower-case plural for spoken sentences ("12 kilometers away").
    var spokenName: String { name.lowercased() }

    /// The distance in this unit (statute miles for `.miles`).
    func value(meters m: Double) -> Double {
        switch self {
        case .kilometers: m / 1000
        case .miles: m / 1609.344
        }
    }

    /// "12.3 km" / "7.6 mi" from a slant distance in meters — one decimal,
    /// the card's historical form.
    func format(meters m: Double) -> String {
        String(format: "%.1f \(symbol)", value(meters: m))
    }
}

/// One snapshot of all three choices — what trophy copy is phrased in.
nonisolated struct DisplayUnits: Equatable, Sendable {
    var altitude: AltitudeUnit
    var speed: SpeedUnit
    var distance: DistanceUnit

    /// The first-launch choice for a locale. Metric regions get metric
    /// everywhere; the US and UK (miles on the road, mph on the signs) get
    /// feet / mph / miles. Knots — the cards' historical unit — is never a
    /// default: a casual spotter reads mph or km/h, and pilots can switch.
    static func localized(for locale: Locale) -> DisplayUnits {
        switch locale.measurementSystem {
        case .metric:
            DisplayUnits(altitude: .meters, speed: .kph, distance: .kilometers)
        default:   // .us, .uk, and anything Foundation adds later
            DisplayUnits(altitude: .feet, speed: .mph, distance: .miles)
        }
    }
}

/// The live preference. Views read `UnitPreferences.shared` (tracked by
/// Observation); Settings binds to it with `@Bindable`. Tests build their
/// own instance over a throwaway `UserDefaults` suite.
@Observable
final class UnitPreferences {
    static let shared = UnitPreferences()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var altitudeStorage: AltitudeUnit
    @ObservationIgnored private var speedStorage: SpeedUnit
    @ObservationIgnored private var distanceStorage: DistanceUnit

    /// `locale` only matters for keys that aren't stored yet (first launch,
    /// or a value a future build can't read); a saved choice always wins.
    init(defaults: UserDefaults = .standard, locale: Locale = .current) {
        self.defaults = defaults
        let fallback = DisplayUnits.localized(for: locale)
        altitudeStorage = defaults.string(forKey: AltitudeUnit.storageKey)
            .flatMap(AltitudeUnit.init(rawValue:)) ?? fallback.altitude
        speedStorage = defaults.string(forKey: SpeedUnit.storageKey)
            .flatMap(SpeedUnit.init(rawValue:)) ?? fallback.speed
        distanceStorage = defaults.string(forKey: DistanceUnit.storageKey)
            .flatMap(DistanceUnit.init(rawValue:)) ?? fallback.distance
    }

    var altitude: AltitudeUnit {
        get {
            access(keyPath: \.altitude)
            return altitudeStorage
        }
        set {
            withMutation(keyPath: \.altitude) {
                altitudeStorage = newValue
                defaults.set(newValue.rawValue, forKey: AltitudeUnit.storageKey)
            }
        }
    }

    var speed: SpeedUnit {
        get {
            access(keyPath: \.speed)
            return speedStorage
        }
        set {
            withMutation(keyPath: \.speed) {
                speedStorage = newValue
                defaults.set(newValue.rawValue, forKey: SpeedUnit.storageKey)
            }
        }
    }

    var distance: DistanceUnit {
        get {
            access(keyPath: \.distance)
            return distanceStorage
        }
        set {
            withMutation(keyPath: \.distance) {
                distanceStorage = newValue
                defaults.set(newValue.rawValue, forKey: DistanceUnit.storageKey)
            }
        }
    }

    /// All three choices at once (each read is tracked).
    var units: DisplayUnits {
        DisplayUnits(altitude: altitude, speed: speed, distance: distance)
    }
}

// MARK: - Achievement copy in the user's units

// Not `nonisolated`: this extension reads the MainActor-isolated
// `UnitPreferences.shared`, and its only callers are SwiftUI bodies.
extension Achievement {
    /// `summary` re-phrased in the chosen units for the trophies whose copy
    /// quotes an altitude, speed or distance (Sky High, Speed Demon, On the
    /// Deck, Long Lens); every other achievement returns its plain `summary`.
    var displaySummary: String {
        summary(units: UnitPreferences.shared.units)
    }
}
