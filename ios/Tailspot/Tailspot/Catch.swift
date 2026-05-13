//
//  Catch.swift
//  Tailspot
//
//  The persisted record of "user tapped Catch on this aircraft."
//
//  Stored via SwiftData. SwiftData is Apple's modern persistence
//  framework (iOS 17+): you annotate a class with @Model and it
//  generates the database schema, change tracking, and query API
//  for you. Compared to Core Data it removes the boilerplate
//  (xcdatamodeld file, NSManagedObject subclasses) and integrates
//  natively with SwiftUI's @Query / .modelContainer modifiers.
//
//  v1 keeps the schema flat and stores everything we know at catch
//  time — including the metadata snapshot — so the Hangar list view
//  doesn't have to re-fetch anything. Future migrations can split
//  this into joined tables if it grows.
//
//  @Model classes are reference types (final class) and isolated to
//  the actor of the ModelContext that holds them. The repo's
//  MainActor-default isolation under Xcode 26 means Catch instances
//  are MainActor — which matches reality: the only places we
//  insert/query catches are SwiftUI views (always MainActor).
//

import Foundation
import SwiftData

@Model
final class Catch {
    var icao24: String
    var callsign: String?
    var model: String?
    var manufacturer: String?
    var caughtAt: Date
    var observerLat: Double
    var observerLon: Double
    var slantDistanceMeters: Double

    init(
        icao24: String,
        callsign: String?,
        model: String?,
        manufacturer: String?,
        caughtAt: Date,
        observerLat: Double,
        observerLon: Double,
        slantDistanceMeters: Double
    ) {
        self.icao24 = icao24
        self.callsign = callsign
        self.model = model
        self.manufacturer = manufacturer
        self.caughtAt = caughtAt
        self.observerLat = observerLat
        self.observerLon = observerLon
        self.slantDistanceMeters = slantDistanceMeters
    }
}
