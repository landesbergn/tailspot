//
//  HangarGrouping.swift
//  Tailspot
//
//  Pure grouping helpers for the Hangar collection view. Kept out of
//  HangarView so the logic is unit-testable without spinning up SwiftUI.
//
//  v0 supports two grouping modes:
//   - .aircraftType — by manufacturer + model (e.g., "BOEING 737-800")
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

    /// Curated rarity classification of the underlying aircraft.
    /// Derived from `mostRecent.model` so a stale row is fine — the
    /// model string doesn't change between catches of the same icao24.
    var rarity: HangarRarity { HangarRarity.tier(for: mostRecent) }
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

    /// Title shown when a catch has no usable key for the selected
    /// grouping mode (e.g., no manufacturer + model, or no operator).
    static let unknownTitle = "Unknown"

    /// Returns ordered, deduped groups for the given catches.
    ///
    /// Within each group, catches sharing an `icao24` are collapsed
    /// into one `HangarRow` (count + list). Rows are sorted by the
    /// most-recent catch in each row, descending. Empty input returns
    /// an empty array — callers render their own empty-state.
    static func group(_ catches: [Catch], by mode: HangarGrouping) -> [HangarGroup] {
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
            let mfg = c.manufacturer?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            let mdl = c.model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            switch (mfg, mdl) {
            case let (m?, d?): return "\(m) \(d)"
            case let (m?, nil): return m
            case let (nil, d?): return d
            default: return unknownTitle
            }
        case .airline:
            return c.operatorName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonEmpty ?? unknownTitle
        }
    }
}

private extension String {
    /// Returns self if non-empty, otherwise nil. Used to fold empty
    /// strings into the "no data" branch alongside actual nils.
    var nonEmpty: String? { isEmpty ? nil : self }
}
