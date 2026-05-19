//
//  HangarRarity.swift
//  Tailspot
//
//  Curated rarity classification for aircraft. Pure function —
//  given a Catch, returns whether the airframe sits on the "rare"
//  list. Used by HangarRow to surface a "RARE" pill in the
//  collection view.
//
//  v1 uses a hand-curated list of model substrings that match
//  commercially uncommon types (passenger 747s, A380s, A340s) or
//  rare-spotted-from-the-ground military types (C-130, C-17,
//  tanker variants, etc.). Future: data-driven from per-icao24
//  catch-volume once the backend exists (PLAN §1.2).
//
//  Classification is per-model string only — manufacturer is
//  ignored because every rare model in the v1 list is canonical
//  enough that the model substring alone is unambiguous.
//

import Foundation

enum HangarRarity: String, Equatable, Sendable {
    case common
    case rare

    /// Case-insensitive substrings matched against `Catch.model`.
    /// First hit wins. Keep the list short; every entry diminishes
    /// the rarity signal a little, so reserve it for genuinely
    /// uncommon-in-the-wild types.
    static let rareModelTokens: [String] = [
        "747",        // Boeing 747 — passenger fleet has dwindled to a handful
        "a380",       // Airbus A380 — small global fleet, never US-domestic
        "a340",       // Airbus A340 — discontinued, mostly retired
        "concorde",   // For the wishful thinker
        "c-130",      // Lockheed C-130 Hercules — military
        "c-17",       // Boeing C-17 Globemaster — military
        "c-5",        // Lockheed C-5 Galaxy — military, huge
        "kc-",        // KC-135, KC-46, KC-10 tankers — military
        "b-52",       // Boeing B-52 — military strategic bomber
        "b-1",        // Rockwell B-1 — military
        "b-2",        // Northrop B-2 — military, basically never seen
        "u-2",        // Lockheed U-2 — high-altitude recon, extremely rare
        "sr-71",      // For the wishful thinker (retired but iconic)
        "ah-",        // AH-64 Apache, AH-1 Cobra — attack helicopters
    ]

    /// Classify a Catch by its model string.
    static func tier(for c: Catch) -> HangarRarity {
        guard let model = c.model?.lowercased() else { return .common }
        for token in rareModelTokens where model.contains(token) {
            return .rare
        }
        return .common
    }
}
