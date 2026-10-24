//
//  SetDetailStatsTests.swift
//  TailspotTests
//
//  `SetDetailScreen.computeEntryStats` replaced a per-row, per-body-eval
//  `catches.filter { CardSets.matches(catch:entry:) }` with one keyed pass
//  memoized per data change. The rows (tail count, most recent catch) and
//  the header's "N of M" must be exactly what the old per-catch path gave.
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Set detail stats")
struct SetDetailStatsTests {

    /// Repeated tails and types, mixed casing, nils, out-of-order dates.
    private func hangar() -> [Catch] {
        let shapes: [(String?, String?)] = [
            ("B738", "737-800"), ("A20N", nil), ("b738", "737-800"), (nil, "Cessna 172"),
            ("B77W", "777-300ER"), (nil, nil), ("A320", "A320-214"), ("B739", nil),
            ("C172", nil), ("B744", "747-400"), ("B38M", nil), ("E75L", "ERJ-175"),
        ]
        return (0..<240).map { index in
            let shape = shapes[(index * 7) % shapes.count]
            return Catch(icao24: String(format: "a%05x", index % 37), callsign: nil,
                         model: shape.1, manufacturer: nil,
                         caughtAt: Date(timeIntervalSince1970: 1_780_000_000 + Double((index * 13) % 240) * 60),
                         observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
                         typecode: shape.0)
        }
    }

    @Test func matchesThePerCatchPathForEveryFamily() {
        let rows = hangar()
        var caughtEntries = 0
        for set in CardSets.families {
            let stats = SetDetailScreen.computeEntryStats(set: set, catches: rows)
            for entry in set.entries {
                let matching = rows.filter { CardSets.matches(catch: $0, entry: entry) }
                let stat = stats[entry.id]
                #expect(stat?.tailCount == Set(matching.map(\.icao24)).count, "\(set.id)/\(entry.id)")
                #expect(stat?.mostRecent == matching.map(\.caughtAt).max(), "\(set.id)/\(entry.id)")
                if !matching.isEmpty { caughtEntries += 1 }
            }
            // Header: caught = entries with any match == CardSets.progress.
            let caught = set.entries.filter { (stats[$0.id]?.tailCount ?? 0) > 0 }.count
            #expect(caught == CardSets.progress(of: set, against: rows).caught, "\(set.id)")
        }
        #expect(caughtEntries > 5, "fixture should fill real entries")
    }
}
