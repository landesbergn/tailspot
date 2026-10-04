//
//  DistinctMatchKeysTests.swift
//  TailspotTests
//
//  `CardSets.distinctMatchKeys` drops keys whose match strings repeat an
//  earlier key's — the fix that took `Trophies.inputs` from ~2.7 s to
//  ~0.4 s on a 4,600-catch Hangar. It is only safe if set status is
//  bit-for-bit the same as with every key, including WHICH catch fills
//  each slot (first match wins).
//

import Testing
import Foundation
@testable import Tailspot

@Suite("Distinct match keys")
struct DistinctMatchKeysTests {

    /// Repeats of the same types/models, mixed casing, nils and empties, in
    /// an order where the first example of each type is not the first row.
    private func hangar() -> [Catch] {
        let shapes: [(String?, String?)] = [
            ("B738", "737-800"), ("A20N", nil), ("b738", "737-800"), (nil, "Cessna 172"),
            ("B77W", "777-300ER"), (nil, nil), ("A320", "A320-214"), ("", ""),
            ("C172", nil), ("B744", "747-400"), ("A388", nil), ("E75L", "ERJ-175"),
        ]
        return (0..<300).map { index in
            let shape = shapes[(index * 7) % shapes.count]
            return Catch(icao24: String(format: "b%05x", index), callsign: nil,
                         model: shape.1, manufacturer: nil,
                         caughtAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 60),
                         observerLat: 0, observerLon: 0, slantDistanceMeters: 0,
                         typecode: shape.0)
        }
    }

    private func fills(_ status: [(CardSetEntry, CardSets.SlotStatus)]) -> [String: ObjectIdentifier?] {
        Dictionary(uniqueKeysWithValues: status.map { entry, slot in
            switch slot {
            case .caught(let example): return (entry.id, ObjectIdentifier(example))
            default: return (entry.id, nil)
            }
        })
    }

    @Test func setStatusIsIdenticalToTheFullKeyList() {
        let rows = hangar()
        let all = CardSets.matchKeys(for: rows)
        let distinct = CardSets.distinctMatchKeys(for: rows)
        #expect(distinct.count < all.count / 10, "fixture should be dominated by repeats")
        var caughtSlots = 0
        for set in CardSets.families {
            let full = fills(CardSets.status(of: set, againstKeys: all))
            #expect(fills(CardSets.status(of: set, againstKeys: distinct)) == full, "\(set.id)")
            caughtSlots += full.values.filter { $0 != nil }.count
        }
        #expect(caughtSlots > 5, "fixture should fill real slots")
    }

    @Test func keepsTheFirstCatchOfEachType() {
        let rows = hangar()
        let distinct = CardSets.distinctMatchKeys(for: rows)
        let firstIndex = Dictionary(rows.enumerated().map { (ObjectIdentifier($1), $0) },
                                    uniquingKeysWith: { first, _ in first })
        let positions = distinct.map { firstIndex[ObjectIdentifier($0.source)]! }
        #expect(positions == positions.sorted(), "order must follow the Hangar")
        #expect(positions.first == 0)
    }
}
