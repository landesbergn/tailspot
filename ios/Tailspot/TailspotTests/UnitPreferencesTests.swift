//
//  UnitPreferencesTests.swift
//  TailspotTests
//
//  The Settings → UNITS preference: formatting per unit, persistence through
//  UserDefaults, the CardPlane formatters honouring an explicit unit, and the
//  trophies whose copy quotes an altitude, speed or distance.
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
        for u in DistanceUnit.allCases { #expect(!u.symbol.contains(" ")) }
        let parts = splitUnit(SpeedUnit.kph.format(mps: 280))
        #expect(parts.value == "1,008")
        #expect(parts.unit == "km/h")
    }

    // MARK: CardPlane honours an explicit unit

    @Test func distanceFormatsPerUnit() {
        #expect(DistanceUnit.kilometers.format(meters: 12_000) == "12.0 km")
        #expect(DistanceUnit.miles.format(meters: 12_000) == "7.5 mi")
        #expect(DistanceUnit.miles.format(meters: 1609.344) == "1.0 mi")
        #expect(DistanceUnit.kilometers.spokenName == "kilometers")
        #expect(DistanceUnit.miles.spokenName == "miles")
    }

    @Test func farTapToastFollowsTheDistanceUnit() {
        let toast = TopToast.farTap(slantMeters: 52_000)
        #expect(toast.message(distanceUnit: .kilometers) == "Nearest plane is 52 km out — beyond eyeshot")
        #expect(toast.message(distanceUnit: .miles) == "Nearest plane is 32 mi out — beyond eyeshot")
    }

    @Test func cardPlaneFormattersTakeAUnit() {
        #expect(CardPlane.altText(fromMeters: 152.4, unit: .feet) == "500 ft")
        #expect(CardPlane.altText(fromMeters: 152.4, unit: .meters) == "152 m")
        #expect(CardPlane.altText(fromMeters: nil, unit: .meters) == nil)
        #expect(CardPlane.speedText(fromMps: 102.889, unit: .mph) == "230 mph")
        #expect(CardPlane.speedText(fromMps: 102.889, unit: .kph) == "370 km/h")
        #expect(CardPlane.speedText(fromMps: nil, unit: .kph) == nil)
        #expect(CardPlane.distText(fromMeters: 12_000, unit: .miles) == "7.5 mi")
        #expect(CardPlane.distText(fromMeters: 0, unit: .miles) == nil)   // unknown sentinel
    }

    // MARK: Persistence

    private func freshDefaults() -> UserDefaults {
        let name = "tailspot.tests.units.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: Localized first-launch defaults

    @Test func localizedDefaultsFollowTheMeasurementSystem() {
        let us = DisplayUnits(altitude: .feet, speed: .mph, distance: .miles)
        let metric = DisplayUnits(altitude: .meters, speed: .kph, distance: .kilometers)
        #expect(DisplayUnits.localized(for: Locale(identifier: "en_US")) == us)
        // The UK is its own measurement system (miles + mph on the road).
        #expect(DisplayUnits.localized(for: Locale(identifier: "en_GB")) == us)
        #expect(DisplayUnits.localized(for: Locale(identifier: "fr_FR")) == metric)
        #expect(DisplayUnits.localized(for: Locale(identifier: "id_ID")) == metric)   // Bali field tests
        #expect(DisplayUnits.localized(for: Locale(identifier: "en_AU")) == metric)
    }

    @Test func firstLaunchUsesTheLocaleDefault() {
        let us = UnitPreferences(defaults: freshDefaults(), locale: Locale(identifier: "en_US"))
        #expect(us.units == DisplayUnits(altitude: .feet, speed: .mph, distance: .miles))
        let de = UnitPreferences(defaults: freshDefaults(), locale: Locale(identifier: "de_DE"))
        #expect(de.units == DisplayUnits(altitude: .meters, speed: .kph, distance: .kilometers))
    }

    @Test func aStoredChoiceBeatsTheLocale() {
        let d = freshDefaults()
        d.set("feet", forKey: AltitudeUnit.storageKey)
        d.set("knots", forKey: SpeedUnit.storageKey)
        // Distance deliberately unset → falls to the locale (metric here).
        let prefs = UnitPreferences(defaults: d, locale: Locale(identifier: "de_DE"))
        #expect(prefs.altitude == .feet)
        #expect(prefs.speed == .knots)
        #expect(prefs.distance == .kilometers)
    }

    @Test func roundTripsThroughUserDefaults() {
        let d = freshDefaults()
        let prefs = UnitPreferences(defaults: d)
        prefs.altitude = .meters
        prefs.speed = .kph
        prefs.distance = .miles
        #expect(d.string(forKey: AltitudeUnit.storageKey) == "meters")
        #expect(d.string(forKey: SpeedUnit.storageKey) == "kph")
        #expect(d.string(forKey: DistanceUnit.storageKey) == "miles")
        // A second instance over the same store reads the choice back.
        let reread = UnitPreferences(defaults: d)
        #expect(reread.altitude == .meters)
        #expect(reread.speed == .kph)
        #expect(reread.distance == .miles)
    }

    @Test func unknownStoredValueFallsBackToDefault() {
        let d = freshDefaults()
        d.set("furlongs", forKey: AltitudeUnit.storageKey)
        d.set("warp", forKey: SpeedUnit.storageKey)
        d.set("leagues", forKey: DistanceUnit.storageKey)
        let prefs = UnitPreferences(defaults: d, locale: Locale(identifier: "en_US"))
        #expect(prefs.altitude == .feet)
        #expect(prefs.speed == .mph)
        #expect(prefs.distance == .miles)
    }

    // MARK: Trophy copy

    private func trophy(_ id: String) -> Achievement {
        Trophies.roster.first { $0.id == id }!
    }

    private func units(_ alt: AltitudeUnit = .feet, _ spd: SpeedUnit = .knots,
                       _ dist: DistanceUnit = .kilometers) -> DisplayUnits {
        DisplayUnits(altitude: alt, speed: spd, distance: dist)
    }

    @Test func altitudeTrophiesFollowTheAltitudeUnit() {
        let high = trophy("milehigh")
        #expect(high.summary(units: units(.feet)) == "Catch one above 40,000 ft")
        #expect(high.summary(units: units(.meters)) == "Catch one above 12,192 m")
        let low = trophy("ondeck")
        #expect(low.summary(units: units(.feet, .kph)) == "Catch one below 3,000 ft")
        #expect(low.summary(units: units(.meters, .kph)) == "Catch one below 914 m")
    }

    @Test func speedTrophyFollowsTheSpeedUnit() {
        let fast = trophy("speeddemon")
        #expect(fast.summary(units: units(.feet, .knots)) == "Catch one doing 520+ kt")
        #expect(fast.summary(units: units(.feet, .mph)) == "Catch one doing 600+ mph")
        #expect(fast.summary(units: units(.feet, .kph)) == "Catch one doing 965+ km/h")
    }

    @Test func distanceTrophyFollowsTheDistanceUnit() {
        let far = trophy("longshot")
        #expect(far.summary(units: units(.feet, .knots, .kilometers)) == "Five catches past 25 km")
        #expect(far.summary(units: units(.feet, .knots, .miles)) == "Five catches past 15.5 mi")
    }

    @Test func unitFreeTrophiesKeepTheirSummary() {
        let first = trophy("firstcatch")
        #expect(first.unitSummary == nil)
        #expect(first.summary(units: units(.meters, .kph, .miles)) == first.summary)
    }
}
