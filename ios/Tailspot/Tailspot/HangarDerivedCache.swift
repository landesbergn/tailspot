//
//  HangarDerivedCache.swift
//  Tailspot
//
//  Memoization for the Hangar pages' derived data (grouped rows, set
//  progress, trophy inputs).
//
//  Why this exists (2026-07-19 field report: segment switches lag): the
//  Sets / Recent / Trophies segment selection lives in HangarView, so
//  EVERY switch re-evaluates HangarView's body — and with it all three
//  kept-alive @Query pages. Each page's body used to re-run its full
//  derivation (HangarGrouping over all catches, set progress across all
//  families, Trophies.inputs) on the main thread mid-transition, every
//  switch, even though the catch data hadn't changed. The pages now
//  render from a cache keyed by a CONTENT fingerprint of the catches:
//  recompute happens only when the data actually changed, so a segment
//  switch is a cache hit and the transition stays smooth.
//
//  The token is derived from the content itself (not a mutation counter),
//  so there is no staleness risk: any path that edits a hashed field —
//  a new catch, a delete, a backfill fill — changes the fingerprint on
//  the next body eval and forces a recompute.
//

import Foundation

/// Order-sensitive content hash over every `Catch` field the Hangar's
/// derived views read (row grouping/dedupe, sets matching, rarity,
/// trophy inputs). Cheap — a few string hashes per row, microseconds at
/// collection scale — so it can run on every body eval; the expensive
/// derivations only re-run when it changes.
///
/// Over-inclusive on purpose: hashing a field no derivation reads costs
/// a spurious recompute (rare, harmless); missing one would serve stale
/// rows. Excluded only: photo focus/filename (render-path concerns with
/// their own caches) and the observer coordinates (no derivation reads
/// them).
enum CatchFingerprint {
    static func of(_ catches: [Catch]) -> Int {
        var hasher = Hasher()
        hasher.combine(catches.count)
        for c in catches {
            hasher.combine(c.icao24)
            hasher.combine(c.callsign)
            hasher.combine(c.model)
            hasher.combine(c.manufacturer)
            hasher.combine(c.operatorName)
            hasher.combine(c.caughtAt)
            hasher.combine(c.slantDistanceMeters)
            hasher.combine(c.rarity)
            hasher.combine(c.aircraftType)
            hasher.combine(c.registration)
            hasher.combine(c.typecode)
            hasher.combine(c.category)
            hasher.combine(c.altitudeMeters)
            hasher.combine(c.velocityMps)
            hasher.combine(c.originIcao)
            hasher.combine(c.destIcao)
            hasher.combine(c.placeName)
            hasher.combine(c.country)
            hasher.combine(c.suspectReason)
        }
        return hasher.finalize()
    }
}

/// Token-keyed memo cell for a view's derived data. Held in `@State` so
/// the SAME box survives body re-evaluations; mutating a reference type's
/// properties during a body eval is legal (it's not a state write, so it
/// can't invalidate or loop). On a token match `value(for:compute:)` is
/// a comparison + return; on a miss it runs `compute` once and stores.
final class DerivedCacheBox<Value> {
    private var token: Int?
    private var cached: Value?

    func value(for token: Int, compute: () -> Value) -> Value {
        if self.token == token, let cached { return cached }
        let fresh = compute()
        self.token = token
        self.cached = fresh
        return fresh
    }
}
