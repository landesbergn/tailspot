//
//  PlanespottersClient.swift
//  Tailspot
//
//  Per-icao24 photo lookup against Planespotters.net's public API.
//  The API is unauthenticated; misses return an empty `photos` array
//  rather than a 404.
//
//  TOS constraints baked into the design:
//  - **No on-device image-byte caching.** This file fetches only the
//    photo metadata (URLs + photographer + link). The image bytes
//    are loaded by `AsyncImage` at display time, which lets iOS's
//    URLCache + HTTP cache-control handle the (allowed) per-response
//    cache without us writing pixels to disk.
//  - **Mandatory attribution.** The `PlanePhoto` value carries the
//    `photographer` name and the Planespotters page `link`; UI code
//    is responsible for displaying both and making the link tappable.
//
//  The client itself memoizes API responses in an in-process actor
//  (`PlanespottersCache`) keyed on lowercase icao24 — per session
//  only, never persisted, capped to keep memory bounded.
//

import Foundation
import os

// Private logger — nonisolated so it's callable from the nonisolated client.
// Mirrors the subsystem/category convention in Log.swift.
private nonisolated let planespottersLog = Logger(
    subsystem: "com.landesberg.tailspot",
    category: "planespotters"
)

// MARK: - Domain value type

/// A single aircraft photo + its attribution.
nonisolated struct PlanePhoto: Equatable, Sendable {
    /// Larger thumbnail (~420px wide), suitable for a hero card.
    let thumbnailLargeURL: URL
    /// Smaller thumbnail (~200px wide), suitable for inline cells.
    /// Held so a future Hangar row design can use it without a re-fetch.
    let thumbnailURL: URL
    /// Planespotters page for this photo. Open in Safari from any
    /// UI that displays the photo (TOS attribution requirement).
    let link: URL
    /// Photographer credit. Display verbatim, prefixed with "© ", on
    /// any UI that displays the photo (TOS attribution requirement).
    let photographer: String
}

// MARK: - Client

nonisolated struct PlanespottersClient: Sendable {
    private let session: URLSession
    private let baseURL: URL
    private let cache: PlanespottersCache

    init(session: URLSession = .shared,
         baseURL: URL = URL(string: "https://api.planespotters.net/pub/photos/hex/")!,
         cache: PlanespottersCache = PlanespottersCache()) {
        self.session = session
        self.baseURL = baseURL
        self.cache = cache
    }

    /// Fetches the first available photo for the given icao24, or nil if
    /// Planespotters has no record. Caches the API response for the
    /// rest of the session.
    func photo(for icao24: String) async -> PlanePhoto? {
        let key = icao24.lowercased()
        if case .hit(let cached) = await cache.get(key: key) {
            return cached
        }
        guard let url = URL(string: key, relativeTo: baseURL) else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Non-2xx — surface to log but don't poison the cache;
                // a later display can retry.
                planespottersLog.notice("Planespotters HTTP \(((response as? HTTPURLResponse)?.statusCode ?? -1)) for \(key, privacy: .public)")
                return nil
            }
            let decoded = try JSONDecoder().decode(PlanespottersResponse.self, from: data)
            let photo = decoded.photos.first.flatMap(PlanePhoto.init(_:))
            await cache.set(key: key, value: photo)
            return photo
        } catch {
            // Transport error — don't cache the miss, the next display retries.
            planespottersLog.error("Planespotters fetch failed for \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

nonisolated extension PlanespottersClient {
    /// Shared singleton so multiple views share the same in-session cache.
    static let shared = PlanespottersClient()
}

// MARK: - Wire format

/// Top-level response. `photos` is empty on miss (not 404).
nonisolated struct PlanespottersResponse: Decodable, Sendable {
    let photos: [PlanespottersPhoto]
}

nonisolated struct PlanespottersPhoto: Decodable, Sendable {
    let id: String
    let thumbnail: PhotoVariant
    // swiftlint:disable:next identifier_name
    let thumbnail_large: PhotoVariant
    let link: String
    let photographer: String
}

nonisolated struct PhotoVariant: Decodable, Sendable {
    let src: String
}

nonisolated extension PlanePhoto {
    /// Convert a wire-format photo into the app-facing value type. Returns
    /// nil if any required URL doesn't parse.
    init?(_ wire: PlanespottersPhoto) {
        guard
            let thumbLargeURL = URL(string: wire.thumbnail_large.src),
            let thumbURL = URL(string: wire.thumbnail.src),
            let linkURL = URL(string: wire.link)
        else { return nil }
        self.thumbnailLargeURL = thumbLargeURL
        self.thumbnailURL = thumbURL
        self.link = linkURL
        self.photographer = wire.photographer
    }
}

// MARK: - In-session cache

/// Per-session memoization. Bounded to keep memory in check. Entries
/// never persist past app termination — matches TOS "no caching of
/// response data beyond ~24 hours" with a much tighter bound.
actor PlanespottersCache {
    /// Distinguishes "we haven't asked Planespotters about this icao24
    /// yet" (.notFetched) from "we asked and they have no photo"
    /// (.hit(nil)) so the UI can avoid re-asking for known-misses.
    enum Lookup: Sendable {
        case notFetched
        case hit(value: PlanePhoto?)

        var value: PlanePhoto? {
            switch self {
            case .notFetched: return nil
            case .hit(let v): return v
            }
        }
    }

    private var store: [String: PlanePhoto?] = [:]
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func get(key: String) -> Lookup {
        guard store.keys.contains(key) else { return .notFetched }
        return .hit(value: store[key] ?? nil)
    }

    func set(key: String, value: PlanePhoto?) {
        if store.count >= capacity {
            // Cheap eviction — drop the first key. The cache exists so
            // a re-display in the same session doesn't hammer the API;
            // a perfect LRU isn't worth the complexity here.
            if let drop = store.keys.first { store.removeValue(forKey: drop) }
        }
        store[key] = value
    }
}
