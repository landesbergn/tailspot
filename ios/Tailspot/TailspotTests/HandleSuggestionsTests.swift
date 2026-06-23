//
//  HandleSuggestionsTests.swift
//  TailspotTests
//
//  Covers the local randomized fallback used by onboarding when the backend
//  suggestions endpoint is unreachable. Swift Testing (@Test / #expect).
//

import Foundation
import Testing
@testable import Tailspot

/// Mirror of the backend handle format: 3–20 of [A-Za-z0-9_].
private func isValidHandle(_ h: String) -> Bool {
    guard (3...20).contains(h.count) else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    return h.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Minimal deterministic RNG (SplitMix64) so "same seed → same output" is testable.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite("HandleSuggestions fallback generator")
struct HandleSuggestionsTests {
    @Test func producesRequestedCountDistinctValid() {
        let out = HandleSuggestions.randomized(count: 4)
        #expect(out.count == 4)
        #expect(Set(out).count == 4) // all distinct
        for h in out {
            #expect(isValidHandle(h), "invalid handle: \(h)")
        }
    }

    @Test func nonPositiveCountYieldsEmpty() {
        #expect(HandleSuggestions.randomized(count: 0).isEmpty)
        #expect(HandleSuggestions.randomized(count: -3).isEmpty)
    }

    @Test func neverEmitsTheOldDeterministicSet() {
        // Regression: the old hardcoded chips collided for every user. A
        // randomized draw should (essentially) never reproduce that exact set.
        let old: Set<String> = ["spotter_42", "blue_hour", "approach_287", "contrail_cam"]
        let out = Set(HandleSuggestions.randomized(count: 4))
        #expect(out.isDisjoint(with: old))
    }

    @Test func deterministicForSeededGenerator() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        let outA = HandleSuggestions.randomized(count: 6, using: &a)
        let outB = HandleSuggestions.randomized(count: 6, using: &b)
        #expect(outA == outB)
        #expect(outA.count == 6)
    }
}
