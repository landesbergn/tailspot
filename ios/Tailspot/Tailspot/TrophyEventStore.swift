//
//  TrophyEventStore.swift
//  Tailspot
//
//  Device-local record of one-off *events* that trophies can derive from
//  when there is no `Catch` row to read. Trophy truth stays derived
//  (Trophies.swift) — but some moments deliberately create no Hangar row
//  (e.g. tapping a parked plane: the grounded easter egg correctly refuses
//  to catch it), so the derivation needs a second, tiny input source.
//
//  Deliberately GENERIC: one store, an `Event` enum, a per-event counter.
//  Future event-based badges add a case here and a `TrophyProgressInputs`
//  field — no new storage machinery. Counts (not booleans) so a future
//  "did it N times" badge is already representable; `hasOccurred` is the
//  boolean view today's 1-of-1 badges want.
//
//  Same shape as `UserDefaultsTrophyLedger`: a concrete `nonisolated`
//  struct over UserDefaults (thread-safe accessors), tests inject an
//  isolated `UserDefaults(suiteName:)`. Single-device, no sync, no
//  migration — UserDefaults is the right home (CLAUDE.md: simplest viable).
//

import Foundation

nonisolated struct TrophyEventStore {

    /// The recordable events. Raw value is the storage key suffix —
    /// stable once shipped (renaming a case would orphan recorded events).
    enum Event: String, CaseIterable, Sendable {
        /// The user tapped a parked (on-ground) plane in the AR view —
        /// the grounded easter egg. Feeds the "Ground Stop" secret badge.
        case groundedCatchAttempt = "groundedCatchAttempt"
    }

    private let defaults: UserDefaults
    private static let keyPrefix = "trophy.events.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Record one occurrence of `event` (increments its counter).
    func record(_ event: Event) {
        let key = Self.keyPrefix + event.rawValue
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
    }

    /// How many times `event` has been recorded on this device.
    func count(of event: Event) -> Int {
        defaults.integer(forKey: Self.keyPrefix + event.rawValue)
    }

    /// True once `event` has been recorded at least once — the input the
    /// current 1-of-1 badges consume. Stays true no matter how often the
    /// event repeats (recording is idempotent with respect to this view).
    func hasOccurred(_ event: Event) -> Bool {
        count(of: event) > 0
    }
}
