//
//  UnitPreferences.swift
//  Tailspot
//
//  The user's display units for altitude (ft / m) and speed (kt / mph /
//  km/h), chosen in Settings → UNITS. Storage stays SI everywhere
//  (`Aircraft.altitudeMeters`, `Catch.velocityMps`, the wire DTO, replay
//  snapshots, telemetry) — the preference only changes how a value is
//  FORMATTED, at the one chokepoint every card goes through
//  (`CardPlane.altText` / `CardPlane.speedText`). Distance (km) is not
//  covered yet; it stays metric.
//
//  Explain-as-we-go: `UnitPreferences` is an `@Observable` class — the
//  Observation framework (iOS 17) that succeeds `ObservableObject` +
//  `@Published`. Any SwiftUI `body` that reads `UnitPreferences.shared.altitude`
//  — even indirectly, through a formatter's default argument — is tracked and
//  re-renders when the value changes. That's what lets a Hangar detail card
//  that's still alive in another tab re-format itself the moment the picker
//  flips in Settings, with no manual plumbing. The two properties are written
//  by hand (`access` / `withMutation`) instead of as plain stored properties so
//  each write also lands in `UserDefaults`.
//

import Foundation
import Observation

/// Altitude display unit. Raw values are the persisted form — don't rename.
nonisolated enum AltitudeUnit: String, CaseIterable, Identifiable, Sendable {
    case feet, meters

    static let storageKey = "tailspot.units.altitude"
    static let `default`: AltitudeUnit = .feet

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
    static let `default`: SpeedUnit = .knots

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

/// The live preference. Views read `UnitPreferences.shared` (tracked by
/// Observation); Settings binds to it with `@Bindable`. Tests build their
/// own instance over a throwaway `UserDefaults` suite.
@Observable
final class UnitPreferences {
    static let shared = UnitPreferences()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var altitudeStorage: AltitudeUnit
    @ObservationIgnored private var speedStorage: SpeedUnit

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        altitudeStorage = defaults.string(forKey: AltitudeUnit.storageKey)
            .flatMap(AltitudeUnit.init(rawValue:)) ?? .default
        speedStorage = defaults.string(forKey: SpeedUnit.storageKey)
            .flatMap(SpeedUnit.init(rawValue:)) ?? .default
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
}

// MARK: - Achievement copy in the user's units

// Not `nonisolated`: this extension reads the MainActor-isolated
// `UnitPreferences.shared`, and its only callers are SwiftUI bodies.
extension Achievement {
    /// `summary` re-phrased in the chosen units for the three trophies whose
    /// copy quotes an altitude or speed (Sky High, Speed Demon, On the Deck);
    /// every other achievement returns its plain `summary`.
    var displaySummary: String {
        summary(altitude: UnitPreferences.shared.altitude,
                speed: UnitPreferences.shared.speed)
    }
}
