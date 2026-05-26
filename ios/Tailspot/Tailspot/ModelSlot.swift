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
/// dedup'd HangarRows the user has caught that fill it.
///
/// **Deprecated for the Hangar Sets surface (2026-05-26).** The
/// Hangar's revamped Sets tab no longer enumerates curated entries;
/// it shows counts per category and derives the model layer
/// dynamically via `ModelGroup` instead. `ModelSlot` is kept for any
/// future surface that still wants the locked-slot Pokédex treatment.
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

// MARK: - ModelGroup

/// Dynamic grouping used by the Hangar Sets surface — bundles a
/// derived model name (from caught planes, NOT from a curated entry)
/// with the HangarRows that match. The Hangar's Sets tab is now a
/// count-per-category view that drills into whatever the user has
/// actually caught, so additions to the OpenSky model space land in
/// the UI without a curation pass.
struct ModelGroup: Identifiable, Hashable {
    /// The display string used to bucket catches together — typically
    /// the manufacturer + model concatenation produced by
    /// `HangarGrouping.key(for:c:mode:.aircraftType)` (e.g.,
    /// "BOEING 737-800"). Whitespace-trimmed; an empty input falls
    /// into `HangarGrouping.unknownTitle`.
    let model: String
    let type: AircraftType
    let tails: [HangarRow]

    var id: String { "\(type.rawValue)::\(model)" }
    var distinctTailCount: Int { tails.count }
}
