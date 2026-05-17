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
//  Groups are ordered alphabetically by title; an "Unknown" bucket for
//  catches with no usable key falls at the end. Within each group,
//  catches are sorted most-recent-first.
//

import Foundation

/// A single bucket of catches sharing a group key.
///
/// `id` is the group key (stable, used by SwiftUI's ForEach); `title`
/// is what we render. They're the same string in v0 but split so we
/// could localize titles later without breaking identity.
struct HangarGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let catches: [Catch]
}

enum HangarGrouping {
    case aircraftType
    case airline

    /// Title shown when a catch has no usable key for the selected
    /// grouping mode (e.g., no manufacturer + model, or no operator).
    static let unknownTitle = "Unknown"

    /// Returns ordered groups for the given catches. Empty input
    /// returns an empty array — callers render their own empty-state.
    static func group(_ catches: [Catch], by mode: HangarGrouping) -> [HangarGroup] {
        let buckets = Dictionary(grouping: catches) { key(for: $0, mode: mode) }
        return buckets
            .map { key, items in
                HangarGroup(
                    id: key,
                    title: key,
                    catches: items.sorted { $0.caughtAt > $1.caughtAt }
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
