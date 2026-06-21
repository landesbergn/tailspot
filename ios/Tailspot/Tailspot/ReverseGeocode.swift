//
//  ReverseGeocode.swift
//  Tailspot
//
//  Observer coordinates → human place name ("Berkeley, CA"). One
//  thin async wrapper around Apple's geocoder + a pure formatting
//  function the tests pin. Callers treat nil as "try again later"
//  (offline, rate-limited, mid-ocean) — never as an error.
//
//  Implicitly MainActor (repo default isolation) — all callers are
//  views/managers on main. `format` is nonisolated so tests and any
//  future background caller can use it freely.
//
//  Geocoding API: MKReverseGeocodingRequest (MapKit, iOS 26+).
//  CLGeocoder.reverseGeocodeLocation is deprecated as of iOS 26.0
//  with the message "Use MKReverseGeocodingRequest" per the SDK
//  headers. The replacement is used here.
//
//  MKReverseGeocodingRequest returns MKMapItem values whose
//  MKAddressRepresentations provides:
//    • cityWithContext  — locale-aware "City, Region" (no country
//      for the device locale). This single Apple-formatted string is
//      used directly for the common has-city case so we don't need
//      to reassemble adminArea from a raw string that the new API
//      no longer exposes structurally. cityWithContext uses the
//      automatic context style — a US-locale device shows "Berkeley,
//      CA"; other locales may append the country.
//    • cityName        — locality only, for the no-context fallback.
//    • regionName      — localized country name, for the tail cases.
//    • region?.identifier — ISO region code ("US"); the structured
//      replacement for the deprecated placemark.isoCountryCode, used as
//      the stable, locale-independent country key.
//  The `format` function still handles every degradation path (no
//  city, no admin, country-only, nil) via the no-city tail.
//

import Foundation
import CoreLocation
import MapKit

nonisolated enum ReverseGeocode {

    /// Reverse-geocode to a display string. nil on any failure —
    /// callers persist nil and retry on a later view-open.
    @MainActor
    static func placeName(lat: Double, lon: Double) async -> String? {
        await placeAndCountry(lat: lat, lon: lon).place
    }

    /// Reverse-geocode to a stable COUNTRY key — ISO code preferred (e.g.
    /// "US"), else the country display name. nil on failure. Used by the
    /// detail-view backfill to fill `Catch.country` on its own.
    @MainActor
    static func country(lat: Double, lon: Double) async -> String? {
        await placeAndCountry(lat: lat, lon: lon).country
    }

    /// One reverse-geocode → both the display place and the country key,
    /// so the catch-time stamp fills `placeName` and `country` without a
    /// second request. Both nil on any failure.
    @MainActor
    static func placeAndCountry(lat: Double, lon: Double) async -> (place: String?, country: String?) {
        guard lat != 0 || lon != 0 else { return (nil, nil) }
        let location = CLLocation(latitude: lat, longitude: lon)
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first
        else { return (nil, nil) }
        let rep = item.addressRepresentations
        // Apple's locale-aware formatter gives "Berkeley, CA" (US) or
        // "Toulouse, Occitanie" (FR) without re-assembling adminArea.
        let place: String?
        if let cityContext = rep?.cityWithContext {
            place = cityContext
        } else {
            // Tail: no city — degrade through region/country/nil via format.
            place = format(locality: rep?.cityName, adminArea: nil, country: rep?.regionName)
        }
        return (place, countryKey(from: rep))
    }

    /// Stable country identifier off the address representation: the ISO
    /// region code when present (locale-independent — "US" everywhere),
    /// else the localized country display name. iOS 26's
    /// `MKAddressRepresentations.region?.identifier` is the structured ISO
    /// source that replaced the deprecated `MKMapItem.placemark.isoCountryCode`
    /// (the Swift overlay refines `regionCode` → `region: Locale.Region?`);
    /// `regionName` carries the localized country name.
    @MainActor
    private static func countryKey(from rep: MKAddressRepresentations?) -> String? {
        countryKey(isoCountryCode: rep?.region?.identifier, country: rep?.regionName)
    }

    /// Pure ISO-preferred fallback, extracted so the degradation path is
    /// unit-testable without a live geocode: ISO code wins; else the
    /// country display name; else nil. Empty/whitespace collapses to nil.
    nonisolated static func countryKey(isoCountryCode: String?, country: String?) -> String? {
        if let iso = isoCountryCode?.trimmedNonEmpty { return iso }
        return country?.trimmedNonEmpty
    }

    /// Locale-aware assembly, deliberately NOT US-hardcoded:
    /// US placemarks carry abbreviated admin areas ("CA") → "Berkeley, CA";
    /// elsewhere the region is a full name → "Toulouse, Occitanie";
    /// no region → "Reykjavík, Iceland"; degrade through region/
    /// country alone; nil when the placemark is empty.
    nonisolated static func format(
        locality: String?,
        adminArea: String?,
        country: String?
    ) -> String? {
        let city = locality?.trimmedNonEmpty
        let region = adminArea?.trimmedNonEmpty
        let nation = country?.trimmedNonEmpty
        switch (city, region, nation) {
        case let (c?, r?, _):     return "\(c), \(r)"
        case let (c?, nil, n?):   return "\(c), \(n)"
        case let (c?, nil, nil):  return c
        case let (nil, r?, n?):   return "\(r), \(n)"
        case let (nil, r?, nil):  return r
        case let (nil, nil, n?):  return n
        case (nil, nil, nil):     return nil
        }
    }
}

// `nonisolated` so the helper is usable from `format` (which is
// nonisolated) under Xcode 26 MainActor-default isolation — an
// unmarked extension would inherit MainActor and warn.
private nonisolated extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
