//
//  BundledDataPrewarm.swift
//  Tailspot
//
//  Decodes the bundled reference tables that are first needed LATER in a
//  session (airlines, airports, the FAA registry) off the main thread,
//  shortly after launch.
//
//  Each table is a lazy `static let` — decoded on first touch. Without
//  this, airports.json + the 1.75 MB faa-models.json were first touched on
//  main by the first Hangar open's backfill, landing during the sheet
//  animation. Swift initializes a `static let` exactly once and thread-
//  safely (like `dispatch_once`), so touching them from a background task
//  is safe.
//
//  AircraftTypes.json is deliberately NOT here: the launch trophy pass
//  touches it on main almost immediately, and a main-thread reader that
//  arrives mid-decode WAITS on the initializer — racing it from a lower-
//  priority task could only make that launch stall longer, never shorter.
//

import Foundation

nonisolated enum BundledDataPrewarm {
    static func start() {
        // Unit tests drive these tables directly; keep the test host quiet.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Task.detached(priority: .utility) {
            _ = Airlines.bundled.count
            _ = GuessOptions.airportsByIcao.count
            _ = FAARegistry.record(forIcao24: "000000")
        }
    }
}
