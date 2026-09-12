//
//  UnitPreferencesTests.swift
//  TailspotTests
//
//  The Settings → UNITS preference: formatting per unit, persistence through
//  UserDefaults, the CardPlane formatters honouring an explicit unit, and the
//  three trophies whose copy quotes an altitude/speed.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Unit preferences")
@MainActor
struct UnitPreferencesTests {

    // MARK: Formatting

    @Test func altitudeFormatsWholeUnitsWithGrouping() {
        #expect(AltitudeUnit.feet.format(meters: 152.4) == "500 ft")
        #expect(AltitudeUnit.meters.format(meters: 152.4) == "152 m")
        #expect(AltitudeUnit.feet.format(meters: 10_668) == "35,000 ft")
        #expect(AltitudeUnit.meters.format(meters: 10_668) == "10,668 m")
    }

    @Test func speedFormatsPerUnit() {
        // 102.889 m/s is exactly 200 kt.
        #expect(SpeedUnit.knots.format(mps: 102.889) == "200 kt")
        #expect(SpeedUnit.mph.format(mps: 102.889) == "230 mph")
        #expect(SpeedUnit.kph.format(mps: 102.889) == "370 km/h")
        // A fast cruise crosses four digits only in km/h — grouped like altitude.
        #expect(SpeedUnit.kph.format(mps: 280) == "1,008 km/h")
    }

    /// The reveal card splits "value unit" on the last space to tint the
    /// unit, so every symbol must be one space-free token.
    @Test func symbolsAreSingleTokens() {
        for u in AltitudeUnit.allCases { #expect(!u.symbol.contains(" ")) }
        for u in SpeedUnit.allCases { #expect(!u.symbol.contains(" ")) }
        let parts = splitUnit(SpeedUnit.kph.format(mps: 280))
        #expect(parts.value == "1,008")
        #expect(parts.unit == "km/h")
    }

    // MARK: CardPlane honours an explicit unit

    @Test func cardPlaneFormattersTakeAUnit() {
        #expect(CardPlane.altText(fromMeters: 152.4, unit: .feet) == "500 ft")
        #expect(CardPlane.altText(fromMeters: 152.4, unit: .meters) == "152 m")
        #expect(CardPlane.altText(fromMeters: nil, unit: .meters) == nil)
        #expect(CardPlane.speedText(fromMps: 102.889, unit: .mph) == "230 mph")
        #expect(CardPlane.speedText(fromMps: 102.889, unit: .kph) == "370 km/h")
        #expect(CardPlane.speedText(fromMps: nil, unit: .kph) == nil)
    }

    // MARK: Persistence

    private func freshDefaults() -> UserDefaults {
        let name = "tailspot.tests.units.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaultsToFeetAndKnots() {
        let prefs = UnitPreferences(defaults: freshDefaults())
        #expect(prefs.altitude == .feet)
        #expect(prefs.speed == .knots)
    }

    @Test func roundTripsThroughUserDefaults() {
        let d = freshDefaults()
        let prefs = UnitPreferences(defaults: d)
        prefs.altitude = .meters
        prefs.speed = .kph
        #expect(d.string(forKey: AltitudeUnit.storageKey) == "meters")
        #expect(d.string(forKey: SpeedUnit.storageKey) == "kph")
        // A second instance over the same store reads the choice back.
        let reread = UnitPreferences(defaults: d)
        #expect(reread.altitude == .meters)
        #expect(reread.speed == .kph)
    }

    @Test func unknownStoredValueFallsBackToDefault() {
        let d = freshDefaults()
        d.set("furlongs", forKey: AltitudeUnit.storageKey)
        d.set("warp", forKey: SpeedUnit.storageKey)
        let prefs = UnitPreferences(defaults: d)
        #expect(prefs.altitude == .feet)
        #expect(prefs.speed == .knots)
    }

    // MARK: Trophy copy

    private func trophy(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    @Test func altitudeTrophiesFollowTheAltitudeUnit() {
        let high = trophy("milehigh")
        #expect(high.summary(altitude: .feet, speed: .knots) == "Catch one above 40,000 ft")
        #expect(high.summary(altitude: .meters, speed: .knots) == "Catch one above 12,192 m")
        let low = trophy("ondeck")
        #expect(low.summary(altitude: .feet, speed: .kph) == "Catch one below 3,000 ft")
        #expect(low.summary(altitude: .meters, speed: .kph) == "Catch one below 914 m")
    }

    @Test func speedTrophyFollowsTheSpeedUnit() {
        let fast = trophy("speeddemon")
        #expect(fast.summary(altitude: .feet, speed: .knots) == "Catch one doing 520+ kt")
        #expect(fast.summary(altitude: .feet, speed: .mph) == "Catch one doing 600+ mph")
        #expect(fast.summary(altitude: .feet, speed: .kph) == "Catch one doing 965+ km/h")
    }

    @Test func unitFreeTrophiesKeepTheirSummary() {
        let first = trophy("firstcatch")
        #expect(first.unitSummary == nil)
        #expect(first.summary(altitude: .meters, speed: .kph) == first.summary)
    }
}
