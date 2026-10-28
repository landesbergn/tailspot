//
//  TypeHistory.swift
//  Tailspot
//
//  "You and this type" — the Hangar-derived block on the back of the catch
//  card: when you first caught this type, and a log of who was flying the
//  ones you've caught ("Southwest 2×, Delta 1×").
//
//  Pure and computed on read from the catch list — nothing new is stored on
//  `Catch`. No new matching rules either: "same type" means "resolves to the
//  same CardSetEntry" via `TypeInfoStore.entry(for:)` (the existing
//  `CardSets.matches(key:entry:)`, exact typecode first), and the airline
//  label is `Airlines.operatorLabel` — the same one the catch
//  detail card shows. So this block can never disagree with the Hangar.
//

import Foundation

nonisolated struct TypeHistory: Equatable, Sendable {
    nonisolated struct AirlineCount: Equatable, Sendable {
        let name: String
        let count: Int
    }

    /// Earliest `caughtAt` among the user's catches of this type — the same
    /// entry when one matches, otherwise the same typecode. Includes the
    /// catch being shown.
    let firstCaughtAt: Date?
    /// The catch log: operator label → how many of those catches it flew,
    /// sorted by count desc, then name. Counts catches, not airframes (the
    /// same Southwest jet caught twice is "Southwest 2×"). "Operator unknown" (an
    /// airline callsign we can't name) is left out — it isn't an airline seen.
    let airlines: [AirlineCount]

    /// Builds the history for `c` against the whole Hangar `all`. `c` is
    /// counted even if `all` doesn't contain it (the reveal may pass a list
    /// fetched before the new catch was saved).
    static func compute(for c: Catch, in all: [Catch]) -> TypeHistory {
        var hangar = all
        if !hangar.contains(where: { $0 === c }) { hangar.append(c) }

        let match = TypeInfoStore.entry(for: c)
        let sameType: [Catch]
        if let match {
            let keys = CardSets.matchKeys(for: hangar)
            // Candidates via the Sets matcher, then kept only when they
            // resolve to THIS entry the way the back itself does: a MAX 8
            // whose raw model reads "737-8" token-matches the 737-800 slot
            // too, but its own back is the MAX 8's, so it isn't a 737-800.
            sameType = keys.filter { CardSets.matches(key: $0, entry: match.entry) }
                .map(\.source)
                .filter { TypeInfoStore.entry(for: $0)?.entry.id == match.entry.id }
        } else if let tc = normalizedTypecode(c.typecode) {
            sameType = hangar.filter { normalizedTypecode($0.typecode) == tc }
        } else {
            // No entry and no typecode: nothing to compare on, so it's just
            // this airframe.
            sameType = hangar.filter { airframeKey($0) == airframeKey(c) }
        }

        let firstCaughtAt = sameType.map(\.caughtAt).min()

        var catchesByLabel: [String: Int] = [:]
        for row in sameType {
            // A row with neither an operator nor a callsign says nothing
            // about who flies it; operatorLabel would call it "Private",
            // which is a guess, so it's left out rather than counted.
            let hasOperator = row.operatorName.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            let hasCallsign = row.callsign.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
            guard hasOperator || hasCallsign else { continue }
            let label = Airlines.operatorLabel(operatorName: row.operatorName, callsign: row.callsign)
            guard label != "Operator unknown" else { continue }
            catchesByLabel[label, default: 0] += 1
        }
        let airlines = catchesByLabel
            .map { AirlineCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }

        return TypeHistory(firstCaughtAt: firstCaughtAt, airlines: airlines)
    }

    /// Hangar dedupe key: icao24, trimmed + lowercased (rows are stored
    /// lowercased, but be tolerant).
    private static func airframeKey(_ c: Catch) -> String {
        c.icao24.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalizedTypecode(_ tc: String?) -> String? {
        guard let t = tc?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !t.isEmpty else { return nil }
        return t
    }
}
