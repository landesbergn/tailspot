//
//  ReverseGeocodeTests.swift
//  TailspotTests
//
//  The formatting half is pure and pinned here for every placemark
//  shape; the network half (Apple geocoder) is a thin untested
//  wrapper by design.
//

import Testing
@testable import Tailspot

@Suite("Reverse geocode formatting")
struct ReverseGeocodeTests {

    @Test func usStyleCityState() {
        // US admin areas arrive abbreviated ("CA") from Apple geocoding.
        #expect(ReverseGeocode.format(locality: "Berkeley", adminArea: "CA", country: "United States") == "Berkeley, CA")
    }

    @Test func internationalCityRegion() {
        // Non-US placemarks carry full region names — used as-is, no
        // US-style abbreviation assumed.
        #expect(ReverseGeocode.format(locality: "Toulouse", adminArea: "Occitanie", country: "France") == "Toulouse, Occitanie")
    }

    @Test func cityCountryWhenNoRegion() {
        #expect(ReverseGeocode.format(locality: "Reykjavík", adminArea: nil, country: "Iceland") == "Reykjavík, Iceland")
    }

    @Test func regionCountryWhenNoCity() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: "Scotland", country: "United Kingdom") == "Scotland, United Kingdom")
    }

    @Test func countryAloneAsLastResort() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: nil, country: "Japan") == "Japan")
    }

    @Test func cityAloneWhenThatIsAllThereIs() {
        #expect(ReverseGeocode.format(locality: "Singapore", adminArea: nil, country: nil) == "Singapore")
    }

    @Test func nothingGivesNil() {
        #expect(ReverseGeocode.format(locality: nil, adminArea: nil, country: nil) == nil)
        #expect(ReverseGeocode.format(locality: "", adminArea: "  ", country: "") == nil)
    }

    // MARK: - Country key (ISO-preferred fallback)

    @Test func countryPrefersISOCode() {
        #expect(ReverseGeocode.countryKey(isoCountryCode: "US", country: "United States") == "US")
    }

    @Test func countryFallsBackToDisplayNameWhenNoISO() {
        #expect(ReverseGeocode.countryKey(isoCountryCode: nil, country: "France") == "France")
        // Empty/whitespace ISO collapses to nil → fall back to the name.
        #expect(ReverseGeocode.countryKey(isoCountryCode: "  ", country: "Germany") == "Germany")
    }

    @Test func countryNilWhenNeitherPresent() {
        #expect(ReverseGeocode.countryKey(isoCountryCode: nil, country: nil) == nil)
        #expect(ReverseGeocode.countryKey(isoCountryCode: "", country: "") == nil)
    }
}
