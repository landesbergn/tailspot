//
//  LocalSkyGate.swift
//  Tailspot
//
//  L2 — the localized sky gate. `SkyCheck` asks "is the WHOLE frame open
//  sky?" (the indoor gate); this asks the same question of the PATCH UNDER
//  THE BRACKET: "is the piece of screen where this plane should appear
//  actually open sky, or is a building / tree in the way?"
//
//  This is the keystone occlusion fix: the SAME plane at 20 km is a real
//  catch over open sky and a cheat behind a Manhattan tower — distance can't
//  separate them, but the pixels under the bracket can.
//
//  Validated offline (tools/authenticity-gate/score_local_gate.py) against
//  real Bay frames + John's NYC catch screenshots: blocks tree/building
//  brackets (incl. the Citation/A220/E175 cheats), allows sky / cloud /
//  overcast / night, and fails OPEN on featureless frames and on a bracket
//  aimed at a genuine sky gap (the Hawker). Ships in SHADOW MODE — see
//  `VisualConfirmationPipeline.localGateEnforcing`.
//
//  Three signals, all reasoned over the patch around the bracket:
//    texture — fine pixel-gradient (sky ≈ 0; window grids / foliage ≫ 0)
//    warmth  — (R−B)/(R+B): lit windows / sodium-lit facades read warm
//    skyFraction — how much of the WHOLE frame reads as open sky, so we only
//                  trust "this patch is an occluder" when there's sky to
//                  contrast against (else fail open).
//
//  The texture threshold is RESOLUTION-dependent (it scales with the sample
//  lattice), so it is re-calibrated on-device from the shadow-mode telemetry
//  before enforcement is enabled. The starting values mirror the offline
//  corpus. The decision logic is pure + unit-tested with synthetic features.
//

import CoreVideo
import Foundation

/// Scalars the localized verdict reasons over — the patch under the bracket
/// plus the frame-wide sky fraction. Kept separate from extraction so the
/// decision is unit-testable with synthetic values (no image fixtures).
nonisolated struct LocalSkyFeatures: Sendable, Equatable {
    /// Mean fine pixel-gradient in the patch, ~0 (smooth sky) … high (clutter).
    var patchTexture: Double
    /// Patch colour warmth (R−B)/(R+B), −1 (cool/blue) … +1 (warm/orange).
    var patchWarmth: Double
    /// Patch mean luminance 0…1 — only used to decide whether the warmth
    /// signal is trustworthy (white balance is meaningless in near-darkness).
    var patchLum: Double
    /// Fraction of WHOLE-frame tiles that read as open sky (smooth + cool).
    var skyFraction: Double
}

nonisolated struct LocalSkyGate {

    /// Tuning constants. Texture/warmth mirror the offline corpus; `texSmooth`
    /// is the dial and is re-tuned on-device from shadow-mode telemetry (it
    /// scales with the sample lattice). Retune only against labeled frames.
    struct Thresholds: Sendable, Equatable {
        /// At/below this the patch is "smooth" (open sky — day/night/overcast).
        /// Confirmed on-device by the 2026-07 shadow telemetry: real sky
        /// verdicts max out at 0.0116, first occluders appear at 0.0153 —
        /// the dial sits in the gap, so the offline value transfers.
        var texSmooth: Double = 0.014
        /// Warm artificial light, trusted only with enough light to believe
        /// white balance. Sky is cool (warmth < this) so it never blocks.
        /// 0.04 → 0.07 (2026-07-04 shadow calibration): golden-hour skies
        /// read 0.045–0.06 warm — the same false-block `SkyCheck` hit in the
        /// field, fixed the same way (its warmThreshold moved 0.04 → 0.07).
        var warmThreshold: Double = 0.07
        /// Below this luminance neither colour NOR texture is trustworthy —
        /// see the night guard in `verdict`.
        var luminanceForColorTrust: Double = 0.12
        /// Need at least this much clearly-sky frame before trusting that a
        /// textured patch is an occluder; below it, fail open.
        var minSkyFraction: Double = 0.20

        static let `default` = Thresholds()
    }

    var thresholds: Thresholds = .default

    /// The gate decision. Pure — same inputs always yield the same verdict.
    /// Only `.notSky` blocks (when enforcing); `.sky` and `.uncertain` allow.
    func verdict(_ f: LocalSkyFeatures) -> SkyVerdict {
        // Warm artificial light is the decisive occluder signal — a lit
        // building reads warm even when smoothish. Trusted only with enough
        // light, which keeps a dark (smooth, neutral) night sky from reading
        // as warm.
        let colorTrustworthy = f.patchLum >= thresholds.luminanceForColorTrust
        if colorTrustworthy && f.patchWarmth >= thresholds.warmThreshold {
            return .notSky
        }
        // Smooth → open sky (day, night, overcast, cloud, contrail).
        if f.patchTexture <= thresholds.texSmooth {
            return .sky
        }
        // Near-dark patch: texture is as untrustworthy as colour — sensor
        // noise AND the plane's OWN lights (bright dots on black, centered in
        // the patch by construction) read as texture, so a night catch would
        // block itself. Fail open. (2026-07-04 shadow telemetry: night
        // catches at lum ≈ 0.05 with sky_fraction ≈ 0.8 were would-blocks.)
        guard colorTrustworthy else { return .uncertain }
        // Textured + cool → an occluder, but only confidently so when there's
        // clearly sky elsewhere to contrast against. A featureless frame (fog,
        // or a wall filling the view) has no sky reference → fail open.
        if f.skyFraction >= thresholds.minSkyFraction {
            return .notSky
        }
        return .uncertain
    }
}

// MARK: - Per-tile scene grid + extraction

/// Per-tile scene grid over the camera frame: luminance, colour warmth, and a
/// fine PIXEL-texture (mean local gradient) per tile. Computed on the camera
/// queue and snapshotted; the localized verdict reads the tiles around the
/// bracket at catch time. The fine texture is what separates a building facade
/// from sky — the coarse whole-frame `SkyFeatures` lattice misses it.
nonisolated struct LocalSkyGrid: Sendable, Equatable {
    let grid: Int
    let lum: [Double]       // grid*grid, row-major
    let warmth: [Double]
    let texture: [Double]
    /// Source buffer dimensions, so a screen point can be mapped back to a tile.
    let bufferSize: CGSize

    /// Sample a `grid*sub` × `grid*sub` luminance/colour lattice from a 32BGRA
    /// buffer, aggregate to `grid`×`grid` tiles (mean lum/warmth) plus a
    /// per-tile texture (mean adjacent |Δlum| among the tile's fine cells).
    /// Returns nil for an unsupported format or a buffer too small to sample.
    /// Runs synchronously on the caller's queue (the camera video queue).
    static func extract(from pixelBuffer: CVPixelBuffer, grid: Int = 16, sub: Int = 4) -> LocalSkyGrid? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let fine = grid * sub
        guard width > fine, height > fine, grid >= 2, sub >= 2 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let n = grid * grid
        var fineLum = [Double](repeating: 0, count: fine * fine)
        var sumR = [Double](repeating: 0, count: n)
        var sumB = [Double](repeating: 0, count: n)
        var sumL = [Double](repeating: 0, count: n)
        for fy in 0..<fine {
            let y = (fy * height) / fine + height / (2 * fine)
            for fx in 0..<fine {
                let x = (fx * width) / fine + width / (2 * fine)
                let off = y * rowBytes + x * 4   // BGRA
                let b = Double(ptr[off]) / 255
                let g = Double(ptr[off + 1]) / 255
                let r = Double(ptr[off + 2]) / 255
                let l = 0.299 * r + 0.587 * g + 0.114 * b
                fineLum[fy * fine + fx] = l
                let ti = (fy / sub) * grid + (fx / sub)
                sumR[ti] += r; sumB[ti] += b; sumL[ti] += l
            }
        }

        let perTile = Double(sub * sub)
        var lum = [Double](repeating: 0, count: n)
        var warmth = [Double](repeating: 0, count: n)
        for i in 0..<n {
            lum[i] = sumL[i] / perTile
            let s = sumR[i] + sumB[i]
            warmth[i] = s > 1e-6 ? (sumR[i] - sumB[i]) / s : 0
        }

        var texture = [Double](repeating: 0, count: n)
        for gy in 0..<grid {
            for gx in 0..<grid {
                var sum = 0.0, cnt = 0.0
                for sy in 0..<sub {
                    for sx in 0..<sub {
                        let i = (gy * sub + sy) * fine + (gx * sub + sx)
                        if sx + 1 < sub { sum += abs(fineLum[i] - fineLum[i + 1]); cnt += 1 }
                        if sy + 1 < sub { sum += abs(fineLum[i] - fineLum[i + fine]); cnt += 1 }
                    }
                }
                texture[gy * grid + gx] = cnt > 0 ? sum / cnt : 0
            }
        }

        return LocalSkyGrid(grid: grid, lum: lum, warmth: warmth, texture: texture,
                            bufferSize: CGSize(width: width, height: height))
    }

    /// Fraction of tiles that read as open sky (pixel-smooth + cool/dark).
    func skyFraction(thresholds t: LocalSkyGate.Thresholds = .default) -> Double {
        let n = grid * grid
        guard n > 0 else { return 0 }
        var sky = 0
        for i in 0..<n {
            let smooth = texture[i] <= t.texSmooth
            let cool = warmth[i] < t.warmThreshold || lum[i] < t.luminanceForColorTrust
            if smooth && cool { sky += 1 }
        }
        return Double(sky) / Double(n)
    }

    /// Localized features for a bracket at `screenPoint`: map screen → buffer →
    /// tile, aggregate a 3×3 patch (edge-clamped), and fold in the frame-wide
    /// sky fraction. Pure given the grid.
    func features(atScreenPoint screenPoint: CGPoint, screenSize: CGSize,
                  thresholds t: LocalSkyGate.Thresholds = .default) -> LocalSkyFeatures {
        let transform = AspectFillTransform(screenSize: screenSize, photoSize: bufferSize)
        let bp = transform.photoPoint(fromScreenPoint: screenPoint)
        let gx = min(grid - 1, max(0, Int(bp.x / bufferSize.width * CGFloat(grid))))
        let gy = min(grid - 1, max(0, Int(bp.y / bufferSize.height * CGFloat(grid))))

        var tex = 0.0, warm = 0.0, lm = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(grid - 1, max(0, gx + dx))
                let y = min(grid - 1, max(0, gy + dy))
                let i = y * grid + x
                tex += texture[i]; warm += warmth[i]; lm += lum[i]
            }
        }
        return LocalSkyFeatures(
            patchTexture: tex / 9, patchWarmth: warm / 9, patchLum: lm / 9,
            skyFraction: skyFraction(thresholds: t)
        )
    }
}
