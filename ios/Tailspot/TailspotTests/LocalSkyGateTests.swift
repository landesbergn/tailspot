//
//  LocalSkyGateTests.swift
//  TailspotTests
//
//  L2 — the localized sky gate. Pins the pure verdict logic (synthetic
//  features, no image fixtures) against the cases the offline corpus
//  validated, plus the screen→tile patch sampling.
//

import Testing
import Foundation
import CoreGraphics
@testable import Tailspot

@Suite("Localized sky gate (L2)")
struct LocalSkyGateTests {

    let gate = LocalSkyGate()

    private func feat(tex: Double, warm: Double = -0.30, lum: Double = 0.60,
                      sky: Double = 0.80) -> LocalSkyFeatures {
        LocalSkyFeatures(patchTexture: tex, patchWarmth: warm, patchLum: lum, skyFraction: sky)
    }

    // MARK: - Verdict logic

    @Test func smoothCoolPatchIsSky() {
        #expect(gate.verdict(feat(tex: 0.002)) == .sky)          // clear blue sky
    }

    @Test func nightSkyIsSky() {
        // Dark, smooth, neutral → sky. Must not re-break night spotting.
        #expect(gate.verdict(feat(tex: 0.005, warm: -0.30, lum: 0.08)) == .sky)
    }

    @Test func texturedPatchWithSkyAvailableIsOccluded() {
        // Tree / building + clear sky elsewhere in frame → block.
        #expect(gate.verdict(feat(tex: 0.05, warm: -0.05, sky: 0.40)) == .notSky)
    }

    @Test func warmLitPatchIsOccluded() {
        // Warm-lit windows / sodium-lit facade → block via warmth even when
        // only moderately textured (John's E175: warm brick).
        #expect(gate.verdict(feat(tex: 0.02, warm: 0.12, lum: 0.40)) == .notSky)
    }

    @Test func darkNeutralIsNeverReadWarm() {
        // Below the colour-trust luminance, warmth is ignored → a dark smooth
        // patch stays sky even with a noisy warm reading.
        #expect(gate.verdict(feat(tex: 0.005, warm: 0.20, lum: 0.05)) == .sky)
    }

    @Test func texturedButNoSkyAvailableFailsOpen() {
        // Featureless / wall-filling frame: textured patch but no sky reference
        // to contrast against → uncertain (allow). Doctrine: fail open.
        #expect(gate.verdict(feat(tex: 0.05, warm: -0.05, sky: 0.10)) == .uncertain)
    }

    // MARK: - Patch sampling (screen → tile)

    @Test func patchSamplesTheTileUnderTheBracket() {
        // 4×4 grid: left half textured (building), right half smooth (sky).
        // screenSize == bufferSize so the AspectFill mapping is identity.
        let g = 4
        var tex = [Double](repeating: 0, count: g * g)
        let warm = [Double](repeating: -0.30, count: g * g)
        let lum = [Double](repeating: 0.60, count: g * g)
        for y in 0..<g { for x in 0..<g { tex[y * g + x] = x < 2 ? 0.10 : 0.001 } }
        let grid = LocalSkyGrid(grid: g, lum: lum, warmth: warm, texture: tex,
                                bufferSize: CGSize(width: 400, height: 400))
        let size = CGSize(width: 400, height: 400)

        // Bracket on the left (textured) half → block.
        let left = grid.features(atScreenPoint: CGPoint(x: 50, y: 200), screenSize: size)
        #expect(gate.verdict(left) == .notSky)

        // Bracket on the right (smooth) half → sky.
        let right = grid.features(atScreenPoint: CGPoint(x: 350, y: 200), screenSize: size)
        #expect(gate.verdict(right) == .sky)

        // Half the tiles are smooth sky → sky-fraction guard is satisfied.
        #expect(grid.skyFraction() == 0.5)
    }

    @Test func bracketOffScreenEdgeClampsIntoTheGrid() {
        // A bracket mapped outside the buffer clamps to the nearest tile
        // rather than crashing.
        let g = 4
        let tex = [Double](repeating: 0.001, count: g * g)
        let grid = LocalSkyGrid(grid: g, lum: [Double](repeating: 0.6, count: g * g),
                                warmth: [Double](repeating: -0.3, count: g * g),
                                texture: tex, bufferSize: CGSize(width: 400, height: 400))
        let f = grid.features(atScreenPoint: CGPoint(x: -200, y: -200),
                              screenSize: CGSize(width: 400, height: 400))
        #expect(gate.verdict(f) == .sky)
    }
}
