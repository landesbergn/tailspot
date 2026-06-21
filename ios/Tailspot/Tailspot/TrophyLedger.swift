//
//  TrophyLedger.swift
//  Tailspot
//
//  Device-local record of which trophy tiers the user has already been
//  *shown* — the "acknowledged" half of the unlock-moment machinery.
//
//  Trophy *truth* stays derived from the Hangar (see `Trophies.swift`);
//  this ledger only remembers what's been celebrated so a tier the user
//  just crossed can be detected as a transition (current > acknowledged)
//  and never re-fired. It is pure UI state — single-device, no sync, no
//  migration — so a small `UserDefaults` blob is the right home, not
//  SwiftData (CLAUDE.md: simplest viable iOS choice).
//
//  A concrete struct, deliberately NOT a protocol: a single-device app
//  with one write path doesn't earn the abstraction. Tests inject an
//  isolated `UserDefaults(suiteName:)` instead of a hand-rolled double.
//
//  `nonisolated` so the pure `TrophyUnlock` diff (also nonisolated) can
//  read it; `UserDefaults`'s own accessors are thread-safe regardless.
//

import Foundation

nonisolated struct UserDefaultsTrophyLedger {
    private let defaults: UserDefaults

    /// Namespaced + versioned. Bumped to v2 with the binary-roster redesign
    /// (new achievement ids) — a clean reset so the new roster re-seeds
    /// silently on next launch instead of flooding on the new ids.
    private let mapKey = "trophy.ledger.acknowledged.v2"
    private let seededKey = "trophy.ledger.seeded.v2"
    private let recapKey = "trophy.ledger.recapShown.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Acknowledged tiers

    /// Highest tier ordinal the user has been shown for `id`, or −1 if none.
    func acknowledgedOrdinal(for id: String) -> Int {
        loadMap()[id] ?? -1
    }

    /// Raise the acknowledged tier for `id`. Monotonic: never lowers an
    /// existing value (defensive against a transient lower current tier).
    func setAcknowledged(_ ordinal: Int, for id: String) {
        var map = loadMap()
        if ordinal > (map[id] ?? -1) {
            map[id] = ordinal
            saveMap(map)
        }
    }

    // MARK: - One-time flags

    /// True once the ledger has been seeded to the current earned-state.
    var isSeeded: Bool { defaults.bool(forKey: seededKey) }
    func markSeeded() { defaults.set(true, forKey: seededKey) }

    /// True once the one-time "trophy case" recap has been shown.
    var recapShown: Bool { defaults.bool(forKey: recapKey) }
    func markRecapShown() { defaults.set(true, forKey: recapKey) }

    // MARK: - Storage

    private func loadMap() -> [String: Int] {
        guard let data = defaults.data(forKey: mapKey),
              let map = try? JSONDecoder().decode([String: Int].self, from: data)
        else { return [:] }
        return map
    }

    private func saveMap(_ map: [String: Int]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: mapKey)
    }
}
