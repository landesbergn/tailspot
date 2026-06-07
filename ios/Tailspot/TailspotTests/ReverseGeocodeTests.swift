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
        // CLPlacemark gives "CA" as administrativeArea in the US.
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
}
