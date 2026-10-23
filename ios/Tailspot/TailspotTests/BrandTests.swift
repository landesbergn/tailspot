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

/// WCAG 2.x contrast pins for the small-text inks (a11y pass, 2026-10-22).
/// AA asks for 4.5:1 for text under 18 pt (14 pt bold). These guard the
/// two places that used to fall short: the reveal's faint ink (labels,
/// "tap to continue", SKIP) on its own ground and on the share artboard,
/// and the tier text shade on the Hangar card's elevated ground.
@MainActor
@Suite("Small-text contrast (WCAG AA)")
struct SmallTextContrastTests {

    /// WCAG relative luminance of an opaque color, from its resolved sRGB
    /// (gamma-encoded) channels.
    private func luminance(_ color: Color) -> Double {
        let r = color.resolve(in: EnvironmentValues())
        func lin(_ c: Float) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r.red) + 0.7152 * lin(r.green) + 0.0722 * lin(r.blue)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func helperMatchesKnownRatios() {
        // Black on white is the 21:1 ceiling; the old faint ink measured
        // 4.01:1 on the reveal ground in the audit.
        #expect(abs(contrast(Color(hex: 0x000000), Color(hex: 0xFFFFFF)) - 21) < 0.01)
        #expect(abs(contrast(Color(hex: 0x5F7284), RP.bg) - 4.01) < 0.01)
    }

    @Test func revealFaintInkClearsAAOnRevealAndShareGrounds() {
        #expect(contrast(RP.faint, RP.bg) >= 4.5)
        #expect(contrast(RP.faint, Brand.Color.bgPrimary) >= 4.5)
        // Still a quieter step than muted, so the ink hierarchy survives.
        #expect(contrast(RP.faint, RP.bg) < contrast(RP.muted, RP.bg))
    }

    @Test(arguments: Rarity.allCases)
    func tierTextTintClearsAAOnElevatedCard(_ rarity: Rarity) {
        #expect(contrast(rarity.textTint, Brand.Color.bgElevated) >= 4.5,
                "\(rarity.label) text tint is under 4.5:1 on bgElevated")
    }

    @Test func onlyEpicNeedsItsOwnTextShade() {
        for rarity in Rarity.allCases where rarity != .epic {
            #expect(rarity.textTint == rarity.tint)
        }
        #expect(Rarity.epic.textTint != Rarity.epic.tint)
    }
}
