//
//  HangarGrouping.swift
//  Tailspot
//
//  Pure grouping helpers for the Hangar collection view. Kept out of
//  HangarView so the logic is unit-testable without spinning up SwiftUI.
//
//  v0 supports two grouping modes:
//   - .aircraftType — by canonical model name (e.g., "Boeing 737-800")
//   - .airline      — by operatorName (e.g., "United Airlines")
//
//  v1 (this file) adds dedupe: within a group, catches sharing an
//  icao24 collapse into a single HangarRow with a count + the full
//  list of catches (for delete-all and possible future per-tap drill).
//  Groups are ordered alphabetically by title; an "Unknown" bucket
//  for catches with no usable key falls at the end. Within each
//  group, rows are sorted most-recent-first.
//

import Foundation

/// One collapsed entry in a Hangar section. Represents every catch
/// of the same `icao24` (multiple events for the same plane) as a
/// single row.
///
/// `mostRecent` is the catch used for display (callsign, type,
/// timestamp). `allCatches` holds the full underlying set so the
/// swipe-to-delete action can drop every matching record.
struct HangarRow: Identifiable, Hashable {
    let icao24: String
    let mostRecent: Catch
    let count: Int
    let allCatches: [Catch]

    var id: String { icao24 }

    /// Earliest catch in the row's history. With Task 8's dedup-on-insert
    /// going forward there's only ever one Catch per icao24, so this
    /// equals `mostRecent`. Legacy multi-catch rows (pre-dedup) surface
    /// the original moment here — used by CatchDetailView's First-caught
    /// panel.
    var firstCatch: Catch { allCatches.last ?? mostRecent }

    /// Rarity tier from the most-recent catch. Derived live via
    /// `resolvedRarity` (typecode → activity table → classifier), so the
    /// Hangar re-tiers prior catches on read rather than showing a stored
    /// snapshot (spec 2026-06-08).
    var rarity: Rarity { mostRecent.resolvedRarity }

    /// Snapshotted aircraft type from the most-recent catch.
    var aircraftType: AircraftType { mostRecent.resolvedType }
}

/// A single bucket of dedup'd catch rows sharing a group key.
///
/// `id` is the group key (stable, used by SwiftUI's ForEach); `title`
/// is what we render. They're the same string in v0 but split so we
/// could localize titles later without breaking identity.
struct HangarGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let rows: [HangarRow]
}

enum HangarGrouping {
    case aircraftType
    case airline
    /// Single flat list of every dedup'd row, sorted by recency.
    /// Dedupe still applies (catches sharing an icao24 collapse into
    /// one ×N row); only the section grouping is suppressed. Matches
    /// the design canvas's "Recent" segmented option.
    case recent

    /// Title shown when a catch has no usable key for the selected
    /// grouping mode (e.g., no manufacturer + model, or no operator).
    static let unknownTitle = "Unknown"

    /// Section title used for the single bucket produced in `.recent`
    /// mode. Callers can choose to hide the header for this group
    /// (since there's no meaningful subgroup to label).
    static let recentTitle = "Recent"

    /// Returns ordered, deduped groups for the given catches.
    ///
    /// Within each group, catches sharing an `icao24` are collapsed
    /// into one `HangarRow` (count + list). Rows are sorted by the
    /// most-recent catch in each row, descending. Empty input returns
    /// an empty array — callers render their own empty-state.
    static func group(_ catches: [Catch], by mode: HangarGrouping) -> [HangarGroup] {
        // Recent mode skips bucketing entirely: every dedup'd row
        // lands in a single chronological group.
        if mode == .recent {
            guard !catches.isEmpty else { return [] }
            return [
                HangarGroup(
                    id: recentTitle,
                    title: recentTitle,
                    rows: dedupe(catches)
                )
            ]
        }

        let buckets = Dictionary(grouping: catches) { key(for: $0, mode: mode) }
        return buckets
            .map { key, items in
                HangarGroup(
                    id: key,
                    title: key,
                    rows: dedupe(items)
                )
            }
            .sorted { lhs, rhs in
                // Unknown bucket sorts to the end; otherwise alphabetical.
                switch (lhs.title == unknownTitle, rhs.title == unknownTitle) {
                case (true, false):  return false
                case (false, true):  return true
                default:             return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
    }

    /// Collapse catches sharing an icao24 into HangarRow entries.
    /// Within each row, `allCatches` is sorted most-recent-first so
    /// `allCatches.first == mostRecent`. The rows themselves are
    /// then sorted by `mostRecent.caughtAt` descending.
    private static func dedupe(_ catches: [Catch]) -> [HangarRow] {
        let byIcao = Dictionary(grouping: catches) { $0.icao24 }
        return byIcao
            .map { icao, items in
                let sorted = items.sorted { $0.caughtAt > $1.caughtAt }
                return HangarRow(
                    icao24: icao,
                    mostRecent: sorted[0],
                    count: sorted.count,
                    allCatches: sorted
                )
            }
            .sorted { $0.mostRecent.caughtAt > $1.mostRecent.caughtAt }
    }

    /// Derives the group key for a single catch under a given mode.
    /// Trims whitespace and collapses empties so blank-string fields
    /// don't create phantom groups.
    static func key(for c: Catch, mode: HangarGrouping) -> String {
        switch mode {
        case .aircraftType:
            // Canonical official name (DOC 8643 typecode first, string
            // cleanup fallback) so Boeing customer-code variants of
            // the same model land in one bucket regardless of airline.
            return AircraftNaming.canonical(
                typecode: c.typecode,
                manufacturer: c.manufacturer,
                model: c.model
            ).displayName ?? unknownTitle
        case .airline:
            return c.operatorName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? unknownTitle
        case .recent:
            // Recent mode doesn't bucket — every row goes into one
            // group. Returning `recentTitle` keeps the function total
            // for callers that introspect a single catch's key.
            return recentTitle
        }
    }

    /// Returns one `ModelSlot` per entry in the given set, with the
    /// dedup'd HangarRows that fall into each slot attached. Rows that
    /// don't match any entry in the set are dropped from the result —
    /// sets are a curated lens, not a universal bucket; those rows
    /// still surface in Recent. Empty `tails` means the slot is locked.
    ///
    /// The Catch → PokeSetEntry pairing reuses the existing matcher
    /// in `Sets.swift` (`PokeSets.matches(catch:entry:)`) so this
    /// resolver and `PokeSets.status` / `PokeSets.progress` stay in
    /// lockstep. Spec § 9.2 — no new matcher introduced here.
    ///
    /// **Deprecated for the Hangar Sets surface (2026-05-26).** The
    /// revamped Hangar Sets tab now uses `modelGroups(in:type:)` to
    /// derive the model layer dynamically. `resolveSlots` is kept for
    /// any future surface that wants the locked-slot Pokédex treatment.
    ///
    /// Implicitly MainActor (Xcode 26 default): `HangarRow.mostRecent`
    /// is a `Catch` which is @MainActor via SwiftData's `@Model`. The
    /// earlier `nonisolated` annotation triggered Swift 6 warnings;
    /// callers (UI + tests) are already on MainActor, so the constraint
    /// is free.
    static func resolveSlots(for set: PokeSet, in rows: [HangarRow]) -> [ModelSlot] {
        set.entries.map { entry in
            let matchingTails = rows.filter { row in
                PokeSets.matches(catch: row.mostRecent, entry: entry)
            }
            return ModelSlot(entry: entry, tails: matchingTails)
        }
    }

    /// Returns model groups for a single `AircraftType`, derived
    /// entirely from the dedup'd `HangarRow` list — no curated entry
    /// list, no enumeration of "possible" planes. Each group bundles
    /// a model display string (the manufacturer + model concatenation
    /// produced by `key(for:c:mode:.aircraftType)`) with the rows
    /// that share it. Sorted alphabetically (A–Z) by canonical model
    /// name; the Unknown bucket is always pinned last.
    ///
    /// Powers the Hangar Sets surface: tap a type tile → see the
    /// model groups you've actually caught, no locked silhouettes.
    /// The UI grows as the user catches new model strings; we don't
    /// have to pre-enumerate the OpenSky model space.
    /// Implicitly MainActor for the same reason as `resolveSlots`
    /// above — touches `HangarRow.mostRecent` which is @MainActor.
    static func modelGroups(
        in rows: [HangarRow],
        type: AircraftType
    ) -> [ModelGroup] {
        let filtered = rows.filter { $0.aircraftType == type }
        let buckets = Dictionary(grouping: filtered) { row in
            key(for: row.mostRecent, mode: .aircraftType)
        }
        return buckets
            .map { ModelGroup(model: $0.key, type: type, tails: $0.value) }
            .sorted { lhs, rhs in
                // Unknown pins to the END (junk drawer, not a headline);
                // everything else is A–Z by canonical model name, which
                // is exactly what the Set detail list displays.
                let lUnknown = lhs.model == unknownTitle
                let rUnknown = rhs.model == unknownTitle
                if lUnknown != rUnknown { return rUnknown }
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model)
                    == .orderedAscending
            }
    }
}

private extension String {
    /// Returns self if non-empty, otherwise nil. Used to fold empty
    /// strings into the "no data" branch alongside actual nils.
    var nonEmpty: String? { isEmpty ? nil : self }
}
