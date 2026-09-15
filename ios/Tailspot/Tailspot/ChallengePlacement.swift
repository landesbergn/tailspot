//
//  ChallengePlacement.swift
//  Tailspot
//
//  Client-side mirror of the server's competition-ranking query (section
//  10.2's `ORDER BY points DESC, d.handle ASC` + "placement computed in
//  code: 1 + count(rows with strictly more points)"). Exists so an
//  optimistic client-side re-render (a catch just landed, before the next
//  standings fetch) agrees with the server's eventual answer rather than
//  drifting during the gap. `nonisolated` — pure, no networking.
//

import Foundation

nonisolated enum ChallengePlacement {
    /// Competition ranking: equal points share a placement and the next
    /// placement is skipped (100/100/60 → 1, 1, 3). Section 5 "Ties".
    /// Order matches the server: points descending, handle ascending as the
    /// tiebreaker for stable iteration order (the server's `ORDER BY`).
    static func rank(points: [String: Int]) -> [(handle: String, placement: Int)] {
        let sorted = points.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        var result: [(handle: String, placement: Int)] = []
        var lastPoints: Int?
        var lastPlacement = 0
        for (index, entry) in sorted.enumerated() {
            if entry.value != lastPoints {
                lastPlacement = index + 1
                lastPoints = entry.value
            }
            result.append((handle: entry.key, placement: lastPlacement))
        }
        return result
    }

    /// Every handle sharing placement 1. "Everyone tied at the top wins"
    /// (section 5) — an empty `points` map has no winners.
    static func winners(_ points: [String: Int]) -> [String] {
        rank(points: points).filter { $0.placement == 1 }.map(\.handle)
    }

    /// Section 5 "No Contest": at finalization, fewer than two accepted
    /// participants, or no participant with any points, ends as No Contest.
    static func isNoContest(activeParticipants: Int, totalPoints: Int) -> Bool {
        activeParticipants < 2 || totalPoints == 0
    }
}
