//
//  SkyCheckTests.swift
//  TailspotTests
//
//  Pins the v1 authenticity gate's decision logic. The headline
//  guarantees: ceilings/walls read `.notSky`; a DARK night sky and a
//  far contrail read `.sky` (never `.notSky`); ambiguous frames fail
//  open to `.uncertain`. Decision logic is tested with synthetic
//  features; a couple of extractor smoke tests cover the pixel math.
//

import Foundation
import CoreVideo
import Testing
@testable import Tailspot

@Suite("SkyCheck verdict")
struct SkyCheckVerdictTests {

    private let gate = SkyCheck()

    // Representative scene features (smooth/busy, warm/cool, light/dark).
    private func sky(lum: Double, warmth: Double = -0.05) -> SkyFeatures {
        SkyFeatures(edgeDensity: 0.02, tileVariance: 0.01, warmth: warmth, meanLuminance: lum)
    }
    private func interior(warmth: Double, lum: Double = 0.45) -> SkyFeatures {
        SkyFeatures(edgeDensity: 0.20, tileVariance: 0.10, warmth: warmth, meanLuminance: lum)
    }

    @Test func daytimeSkyIsSky() {
        #expect(gate.verdict(features: sky(lum: 0.72), gpsAccuracyMeters: 8) == .sky)
    }

    /// The night guardrail: dark + smooth + neutral must NOT block, even
    /// with no GPS fix. Darkness is never an indoor signal.
    @Test func nightSkyIsSkyNotBlocked() {
        let night = sky(lum: 0.04, warmth: 0.0)
        #expect(gate.verdict(features: night, gpsAccuracyMeters: nil) != .notSky)
        #expect(gate.verdict(features: night, gpsAccuracyMeters: nil) == .sky)
    }

    @Test func farContrailIsNeverBlocked() {
        // Mostly-smooth sky with a faint speck — low structure overall.
        let far = SkyFeatures(edgeDensity: 0.04, tileVariance: 0.02, warmth: -0.03, meanLuminance: 0.6)
        #expect(gate.verdict(features: far, gpsAccuracyMeters: 6) != .notSky)
    }

    @Test func warmLitCeilingIsNotSky() {
        // Busy + warm artificial light → confident interior.
        #expect(gate.verdict(features: interior(warmth: 0.30), gpsAccuracyMeters: 8) == .notSky)
    }

    @Test func indoorWithPoorGpsIsNotSky() {
        // Busy + neutral light but a degraded fix → GPS corroborates.
        let room = SkyFeatures(edgeDensity: 0.16, tileVariance: 0.08, warmth: 0.05, meanLuminance: 0.4)
        #expect(gate.verdict(features: room, gpsAccuracyMeters: 120) == .notSky)
        // No fix at all is treated as poor.
        #expect(gate.verdict(features: room, gpsAccuracyMeters: nil) == .notSky)
    }

    @Test func busyButCoolOutdoorsWithSharpGpsFailsOpen() {
        // Textured outdoor scene (foliage / building edge), cool light,
        // sharp fix → must NOT block. Fail open.
        let outdoor = SkyFeatures(edgeDensity: 0.18, tileVariance: 0.09, warmth: -0.02, meanLuminance: 0.6)
        #expect(gate.verdict(features: outdoor, gpsAccuracyMeters: 6) != .notSky)
    }

    @Test func gpsOnlyCorroboratesNeverDecidesAlone() {
        // A smooth sky with a poor fix is still sky — GPS alone can't block.
        #expect(gate.verdict(features: sky(lum: 0.7), gpsAccuracyMeters: 200) == .sky)
    }

    @Test func verdictIsDeterministic() {
        let f = interior(warmth: 0.3)
        let a = gate.verdict(features: f, gpsAccuracyMeters: 50)
        let b = gate.verdict(features: f, gpsAccuracyMeters: 50)
        #expect(a == b)
    }
}

@Suite("SkyFeatures extraction")
struct SkyFeaturesExtractionTests {

    private func makeBGRA(_ width: Int, _ height: Int,
                          _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let off = y * rowBytes + x * 4
                base[off] = b; base[off + 1] = g; base[off + 2] = r; base[off + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    @Test func uniformFrameIsSmooth() throws {
        let buf = makeBGRA(64, 64) { _, _ in (128, 128, 128) }
        let f = try #require(SkyFeatures.extract(from: buf))
        #expect(f.edgeDensity < 0.01)
        #expect(f.tileVariance < 0.01)
        #expect(abs(f.meanLuminance - 0.5) < 0.02)
        #expect(abs(f.warmth) < 0.02)        // neutral gray
    }

    @Test func splitFrameHasStructure() throws {
        // Left half black, right half white → high edge + variance.
        let buf = makeBGRA(64, 64) { x, _ in x < 32 ? (0, 0, 0) : (255, 255, 255) }
        let f = try #require(SkyFeatures.extract(from: buf))
        // A single hard boundary across the sample grid lands ~0.045;
        // the high-contrast split shows up far more strongly in variance.
        // Both must clear the uniform-frame floor (edge/var < 0.01).
        #expect(f.edgeDensity > 0.03)
        #expect(f.tileVariance > 0.1)
    }

    @Test func warmFrameReadsWarm() throws {
        let buf = makeBGRA(64, 64) { _, _ in (220, 150, 60) }  // orange
        let f = try #require(SkyFeatures.extract(from: buf))
        #expect(f.warmth > 0.2)
    }

    @Test func nonBGRAReturnsNil() {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                            kCVPixelFormatType_32ARGB, nil, &pb)
        #expect(SkyFeatures.extract(from: pb!) == nil)
    }
}
