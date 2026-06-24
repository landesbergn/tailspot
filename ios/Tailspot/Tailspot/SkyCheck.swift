//
//  SkyCheck.swift
//  Tailspot
//
//  The v1 authenticity gate's brain: "is the phone pointed at open sky?"
//
//  Why this question (not "can the camera see THIS plane?"): a plane
//  detector fails at night, far away, and behind clouds — exactly the
//  legitimate hard-to-see catches we must NOT block. "Open sky" instead
//  cleanly separates the indoor cheat (ceiling/wall = not sky) from the
//  hard catches (night/contrail/cloud = still sky). See the Bet A plan.
//
//  Two design rules baked in:
//    1. Judge on STRUCTURE + COLOR, never brightness. A night sky is
//       dark-but-smooth; a dim room is dark-but-cluttered. Deciding on
//       darkness would re-break night spotting.
//    2. Fail OPEN. Only a confident interior returns `.notSky` (the
//       only verdict that blocks, and only when enforcing). Anything
//       ambiguous returns `.uncertain`, which allows the catch. Better
//       to miss a few cheats than strand a real outdoor catch.
//
//  The decision logic (`verdict(features:gpsAccuracyMeters:)`) is pure
//  and unit-tested with synthetic features; frame extraction
//  (`SkyFeatures.extract`) runs on the camera queue and is validated on
//  device via the offline gate-validation corpus (tools/authenticity-gate).
//

import Foundation
import CoreVideo

/// Verdict for "pointed at open sky?". Only `.notSky` blocks a catch
/// (when enforcing); `.sky` and `.uncertain` both allow.
nonisolated enum SkyVerdict: String, Sendable {
    case sky
    case notSky
    case uncertain
}

/// Scalar scene signals the gate reasons over. Kept separate from frame
/// extraction so the decision logic is unit-testable with synthetic
/// values (no image fixtures required).
nonisolated struct SkyFeatures: Sendable, Equatable {
    /// Mean adjacent-sample luminance difference, ~0 (smooth) … ~1 (busy).
    /// Open sky is smooth; interiors are full of edges/fixtures/objects.
    var edgeDensity: Double
    /// Variance of sample luminance, ~0 (uniform) … ~1.
    var tileVariance: Double
    /// Color warmth (R−B)/(R+B), −1 (cool/blue) … +1 (warm/orange).
    /// Indoor artificial light is warm; skylight is neutral/cool.
    var warmth: Double
    /// Mean luminance 0 (black) … 1 (white). Used ONLY to decide whether
    /// the color signal is trustworthy (white balance is meaningless in
    /// near-darkness) — never to decide sky-vs-not by brightness.
    var meanLuminance: Double
}

nonisolated struct SkyCheck {

    /// Tuning constants. **Retune against the offline corpus (U6,
    /// tools/authenticity-gate) — do not hand-tweak without new labeled
    /// indoor/outdoor/night sessions.** Conservative by design so only
    /// clear interiors reach `.notSky`.
    struct Thresholds: Sendable, Equatable {
        /// At/above either of these the frame is "busy" (structured).
        var edgeBusy: Double = 0.12
        var varianceBusy: Double = 0.06
        /// At/below BOTH of these the frame is "smooth" (sky-like).
        var edgeSmooth: Double = 0.06
        var varianceSmooth: Double = 0.03
        /// Warm artificial light, but only trusted when there's enough
        /// light to believe the white balance.
        var warmThreshold: Double = 0.18
        var luminanceForColorTrust: Double = 0.12

        static let `default` = Thresholds()
    }

    var thresholds: Thresholds = .default

    /// The gate decision. Pure — same inputs always yield the same
    /// verdict.
    ///
    /// - `gpsAccuracyMeters`: `CLLocation.horizontalAccuracy` (or nil).
    ///   Recorded for telemetry/tuning but deliberately NOT used to block
    ///   — see the body. Kept in the signature for that telemetry and for
    ///   future tuning.
    func verdict(features f: SkyFeatures, gpsAccuracyMeters: Double?) -> SkyVerdict {
        // Primary signal: structure.
        let busy = f.edgeDensity >= thresholds.edgeBusy
            || f.tileVariance >= thresholds.varianceBusy
        let smooth = f.edgeDensity <= thresholds.edgeSmooth
            && f.tileVariance <= thresholds.varianceSmooth

        // Warmth only counts when there's enough light to trust color —
        // this is what keeps a DARK (but smooth, neutral) night sky from
        // ever reading as warm/interior.
        let colorTrustworthy = f.meanLuminance >= thresholds.luminanceForColorTrust
        let warm = colorTrustworthy && f.warmth >= thresholds.warmThreshold

        // The CAMERA is decisive. Block only on a busy frame lit by warm
        // artificial light — the signature of an interior. GPS accuracy is
        // recorded in telemetry but is deliberately NOT a blocking signal:
        // a degraded fix is common outdoors (urban canyon, cold start,
        // tree cover) and must never, on its own, strand a real catch
        // (review 2026-06-24). Cost: a cool-lit or dark interior may not
        // block — acceptable, since missing a cheat beats false-blocking a
        // genuine catch (fail open).
        if busy && warm { return .notSky }

        // Confident sky: smooth and not warm (day OR night).
        if smooth && !warm { return .sky }

        return .uncertain
    }
}

// MARK: - Frame extraction

extension SkyFeatures {

    /// Sample a `grid`×`grid` lattice from a 32BGRA pixel buffer and
    /// compute the scene signals. Returns nil for an unsupported format
    /// or a buffer too small to sample. Runs synchronously on the
    /// caller's queue (the camera video queue).
    static func extract(from pixelBuffer: CVPixelBuffer, grid: Int = 12) -> SkyFeatures? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > grid, height > grid, grid >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var lum = [Double](repeating: 0, count: grid * grid)
        var sumR = 0.0, sumB = 0.0, sumL = 0.0
        for gy in 0..<grid {
            let y = (gy * height) / grid + height / (2 * grid)
            for gx in 0..<grid {
                let x = (gx * width) / grid + width / (2 * grid)
                let off = y * rowBytes + x * 4   // BGRA
                let b = Double(ptr[off]) / 255
                let g = Double(ptr[off + 1]) / 255
                let r = Double(ptr[off + 2]) / 255
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                lum[gy * grid + gx] = l
                sumR += r; sumB += b; sumL += l
            }
        }

        let n = Double(grid * grid)
        let meanL = sumL / n
        let variance = lum.reduce(0) { $0 + ($1 - meanL) * ($1 - meanL) } / n

        var edgeSum = 0.0, edgeCount = 0.0
        for gy in 0..<grid {
            for gx in 0..<grid {
                let i = gy * grid + gx
                if gx + 1 < grid { edgeSum += abs(lum[i] - lum[i + 1]); edgeCount += 1 }
                if gy + 1 < grid { edgeSum += abs(lum[i] - lum[i + grid]); edgeCount += 1 }
            }
        }
        let edgeDensity = edgeCount > 0 ? edgeSum / edgeCount : 0
        let warmth = (sumR + sumB) > 0 ? (sumR - sumB) / (sumR + sumB) : 0

        return SkyFeatures(
            edgeDensity: edgeDensity,
            tileVariance: variance,
            warmth: warmth,
            meanLuminance: meanL
        )
    }
}
