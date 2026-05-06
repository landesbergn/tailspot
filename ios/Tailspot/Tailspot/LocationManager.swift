//
//  LocationManager.swift
//  Tailspot
//
//  Wraps Apple's CLLocationManager and exposes GPS + true-north heading
//  as @Published properties so SwiftUI views auto-refresh when they change.
//

import Foundation
import CoreLocation

final class LocationManager: NSObject, ObservableObject {
    private let manager = CLLocationManager()

    // GPS
    @Published var latitude: Double?     // degrees
    @Published var longitude: Double?    // degrees
    @Published var altitude: Double?     // meters above sea level
    @Published var horizontalAccuracy: Double?  // meters; lower is better

    // Compass
    @Published var heading: Double?              // 0-360, degrees from true north
    @Published var headingAccuracy: Double?      // degrees; -1 means invalid

    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorizationStatus = manager.authorizationStatus
    }

    /// Trigger the iOS permission prompt (no-op if already granted).
    /// Updates begin automatically once the user grants permission.
    func requestPermissionAndStart() {
        manager.requestWhenInUseAuthorization()
    }
}

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        latitude = last.coordinate.latitude
        longitude = last.coordinate.longitude
        altitude = last.altitude
        horizontalAccuracy = last.horizontalAccuracy
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // trueHeading is -1 until we get a GPS fix; fall back to magnetic until then.
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingAccuracy = newHeading.headingAccuracy
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationManager error: \(error.localizedDescription)")
    }
}
