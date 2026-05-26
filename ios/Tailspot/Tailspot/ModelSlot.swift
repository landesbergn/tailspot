//
//  ModelSlot.swift
//  Tailspot
//
//  View-model wrapping a (PokeSetEntry, [HangarRow]) pair. Used by
//  SetDetailView's slot grid and ModelSlotDetailView's tail list to
//  answer "for this entry in the set, how many distinct tails of this
//  model have I caught and what are they?"
//
//  Spec § 9.2 — no new matcher is introduced here. The Catch →
//  PokeSetEntry pairing reuses the existing matcher in `Sets.swift`
//  (`PokeSets.matches(catch:entry:)`) so the resolver and the
//  set-status / set-progress helpers stay in lockstep.
//

import Foundation

/// One slot in a set's detail view — the entry it represents plus the
/// dedup'd HangarRows the user has caught that fill it. An empty
/// `tails` array means the slot is still locked.
struct ModelSlot: Identifiable, Hashable {
    let entry: PokeSetEntry
    let tails: [HangarRow]

    /// Stable identity comes from the underlying entry — `PokeSetEntry`
    /// already carries a unique `id` string per slot.
    var id: String { entry.id }

    /// True when the user has caught at least one tail matching this
    /// slot's entry. Equivalent to `!tails.isEmpty`.
    var isCaught: Bool { !tails.isEmpty }

    /// Number of distinct airframes (icao24s) the user has caught for
    /// this slot. HangarRow already dedupes by icao24, so this is the
    /// "unique tails" count consumers want for badging.
    var distinctTailCount: Int { tails.count }
}
