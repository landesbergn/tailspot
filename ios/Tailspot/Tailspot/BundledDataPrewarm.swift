//
//  BundledDataPrewarm.swift
//  Tailspot
//
//  Decodes the bundled reference tables (aircraft types, airlines,
//  airports, the FAA registry) once, OFF the main thread, right after
//  launch.
//
//  Each table is a lazy `static let` — decoded on first touch. Without
//  this, the first touch happened on the main thread mid-interaction:
//  AircraftTypes.json in the launch trophy pass, airports.json + the
//  1.75 MB faa-models.json in the first Hangar open's backfill, landing
//  during the sheet animation. Swift initializes a `static let` exactly
//  once and thread-safely (like `dispatch_once`), so touching them from a
//  background task is safe; a main-thread reader that arrives mid-decode
//  simply waits for it to finish instead of starting a second one.
//

import Foundation

nonisolated enum BundledDataPrewarm {
    static func start() {
        Task.detached(priority: .utility) {
            _ = AircraftNaming.table.count
            _ = Airlines.bundled.count
            _ = GuessOptions.airportsByIcao.count
            _ = FAARegistry.record(forIcao24: "000000")
        }
    }
}
