//
//  HandleSuggestions.swift
//  Tailspot
//
//  Local fallback generator for onboarding handle suggestions.
//
//  The primary source of suggestions is the backend's
//  GET /v1/handles/suggestions, which returns handles verified FREE against the
//  devices table. This local generator is the OFFLINE / pre-fetch fallback: it
//  produces randomized handles like "contrail_4821" so onboarding never shows
//  the old deterministic set ("spotter_42", "blue_hour", …) that every user
//  collided on. Randomized 4-digit suffixes make collisions rare at current
//  scale; a rare one still surfaces the inline "taken" error on claim.
//
//  Pure value logic — `nonisolated` (Xcode 26 MainActor-default isolation) and
//  unit-testable without a host app. Mirrors the backend word bank in
//  backend/src/identity/handleSuggester.ts.
//

import Foundation

nonisolated enum HandleSuggestions {
    /// Clean, aviation-themed stems. Lowercase [a-z]; short enough that
    /// "<stem>_<4 digits>" stays within the backend's 3–20 char handle limit.
    static let stems: [String] = [
        "spotter", "contrail", "approach", "skyhawk", "vapor", "heading",
        "tailwind", "redeye", "jetwash", "flightpath", "mach", "cleared",
        "downwind", "skylane", "cruise", "beacon",
    ]

    /// `count` distinct randomized handles of the form "<stem>_<4-digit>", using
    /// the system RNG. Returns `[]` for a non-positive count.
    static func randomized(count: Int = 4) -> [String] {
        var rng = SystemRandomNumberGenerator()
        return randomized(count: count, using: &rng)
    }

    /// Deterministic variant: draws from the injected generator so tests can
    /// assert "same seed → same output".
    static func randomized(count: Int, using rng: inout some RandomNumberGenerator) -> [String] {
        guard count > 0 else { return [] }
        var out: [String] = []
        var seen = Set<String>()
        // Cap iterations so we can't spin if the space is somehow exhausted.
        let maxIters = count * 20
        var i = 0
        while out.count < count && i < maxIters {
            i += 1
            let stem = stems.randomElement(using: &rng) ?? stems[0]
            let suffix = Int.random(in: 1000...9999, using: &rng)
            let handle = "\(stem)_\(suffix)"
            if seen.insert(handle).inserted { out.append(handle) }
        }
        return out
    }
}
