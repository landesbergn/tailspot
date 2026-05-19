//
//  BrandTests.swift
//  TailspotTests
//
//  Round-trip tests for the Color(hex:) helper used throughout
//  Brand.swift to define color tokens. The hex literal is the
//  source of truth — these tests pin the channel-extraction so a
//  future Swift bump can't silently change the math.
//

import Testing
import SwiftUI
@testable import Tailspot

@Suite("Brand color hex helper")
struct BrandColorHexTests {

    @Test func extractsRedGreenBlueChannels() {
        // 0x336699 — red 51, green 102, blue 153 (all distinct).
        let c = Color(hex: 0x336699)
        let resolved = c.resolve(in: EnvironmentValues())
        #expect(abs(Double(resolved.red)   - 51.0/255) < 0.001)
        #expect(abs(Double(resolved.green) - 102.0/255) < 0.001)
        #expect(abs(Double(resolved.blue)  - 153.0/255) < 0.001)
        #expect(abs(Double(resolved.opacity) - 1.0) < 0.001)
    }

    @Test func extractsZeroAndFull() {
        let black = Color(hex: 0x000000).resolve(in: EnvironmentValues())
        #expect(black.red == 0 && black.green == 0 && black.blue == 0)

        let white = Color(hex: 0xFFFFFF).resolve(in: EnvironmentValues())
        #expect(abs(Double(white.red)   - 1.0) < 0.001)
        #expect(abs(Double(white.green) - 1.0) < 0.001)
        #expect(abs(Double(white.blue)  - 1.0) < 0.001)
    }

    @Test func acceptsAlphaOverride() {
        let half = Color(hex: 0x808080, alpha: 0.5).resolve(in: EnvironmentValues())
        #expect(abs(Double(half.opacity) - 0.5) < 0.001)
    }
}
