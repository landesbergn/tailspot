//
//  MetadataCache.swift
//  Tailspot
//
//  Bounded LRU cache for AircraftMetadata, keyed by icao24. Stores
//  Optional<AircraftMetadata>, so a "known miss" (OpenSky returned 404)
//  is distinguishable from "we haven't asked yet" — preventing repeated
//  lookups for icao24s that OpenSky doesn't know about.
//
//  Implemented as an `actor` so it's safe to share between the
//  @MainActor ADSBManager and any other context that ends up reading
//  it. The eviction order is "oldest insertion first" — we don't bump
//  on read, since this isn't a true working-set cache, just a
//  per-session memoization.
//

import Foundation

actor MetadataCache {

    enum Lookup: Equatable, Sendable {
        case notFetched
        case hit(AircraftMetadata?)
    }

    private let cap: Int
    private var storage: [String: AircraftMetadata?] = [:]
    private var order: [String] = []   // insertion order, oldest first

    init(cap: Int = 500) {
        precondition(cap > 0)
        self.cap = cap
    }

    func get(icao24: String) -> Lookup {
        if let inner = storage[icao24] {
            return .hit(inner)
        }
        return .notFetched
    }

    func set(icao24: String, value: AircraftMetadata?) {
        if storage[icao24] == nil && !storage.keys.contains(icao24) {
            order.append(icao24)
        }
        storage[icao24] = value

        while order.count > cap {
            let oldest = order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
