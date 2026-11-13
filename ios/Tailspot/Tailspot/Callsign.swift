//
//  Callsign.swift
//  Tailspot
//
//  One rule for "does this plane have a real flight callsign?".
//
//  The callsign is the flight ID the crew types into the transponder, and
//  ADS-B relays whatever is there. Some aircraft (mostly business jets whose
//  crews never set it) broadcast a placeholder instead: all zeros, or just
//  dashes. adsb.lol passes those through untouched, so a Challenger 300
//  (N549FX, 2026-11-08) showed up on its card as "00000000 · PRIVATE".
//
//  `Callsign.clean` treats those placeholders exactly like a blank callsign:
//  nil. It runs where the feed is decoded (so new catches never store one)
//  and at the display/lookup sites that read stored catches (so rows caught
//  before this fix render correctly without a data migration).
//

import Foundation

nonisolated enum Callsign {
    /// The trimmed callsign, or nil when it is blank or a placeholder.
    /// A placeholder is a string with no letters and no non-zero digits,
    /// e.g. "00000000", "0000", "--------", "0-0". A real callsign always
    /// has a letter or a non-zero digit, so nothing real is dropped.
    static func clean(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        let meaningful = t.contains { $0.isLetter || ($0.isNumber && $0 != "0") }
        return meaningful ? t : nil
    }

    /// What a catch card names the plane by: the callsign, else the tail
    /// number. Same order as the Hangar row (which then falls back to the
    /// hex id itself), so a callsign-less business jet reads "N549FX" on
    /// every card rather than only the carrier.
    static func cardIdentifier(callsign: String?, registration: String?) -> String? {
        if let cs = clean(callsign) { return cs }
        // Inline trim: the String.trimmedNonEmpty helpers are file-private.
        guard let reg = registration?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reg.isEmpty else { return nil }
        return reg
    }
}
