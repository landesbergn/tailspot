//
//  DetectorGate.swift
//  Tailspot
//
//  Anti-cheat Lever 4 — the detector soft-gate (docs/anti-cheat-plan.md §5),
//  adapted to the post-catch confirm model (2026-07-04): it raises SUSPICION
//  on a catch the camera should have corroborated but didn't; it never blocks.
//
//  The gate only judges INSIDE the detector's competence envelope:
//    - enough light (the detector was never validated at night — a dark-sky
//      catch is legitimate and undetectable, so it must never be doubted), and
//    - an expected on-screen footprint comfortably above the model's ~15–20 px
//      detection floor (tools/visual-confirmation/REPORT.md) — a distant speck
//      the model physically can't resolve is L3's business, not L4's.
//  Outside the envelope the verdict is `outOfEnvelope`, which callers treat
//  exactly like a pass — fail open, same doctrine as SkyCheck/LocalSkyGate.
//
//  "Saw the plane" comes from the catch path's strongest detector evidence:
//  the CatchPhotoSnapper pass over the captured full-res still (9-tile ring
//  search, zero hallucinated snaps in the 2026-07-07 labeled eval), OR a live
//  preview-stream VisualFix (fresh by construction — it expires after ~1 s of
//  misses). Either one corroborates; corroboration always wins, even when the
//  envelope math says we shouldn't have seen it.
//
//  Pure and nonisolated like SkyCheck: same inputs, same verdict, no camera,
//  no CoreML — every rule unit-testable with synthetic values.
//

import Foundation

/// Verdict for "did the camera corroborate this catch?". Only `noDetection`
/// raises suspicion (and only when enforcement is on); `corroborated` and
/// `outOfEnvelope` both pass.
nonisolated enum DetectorGateVerdict: String, Sendable {
    // Raw values are the PostHog `detector_verdict` / `verdict` strings —
    // snake_case to match the rest of the catch telemetry vocabulary.
    case corroborated                        // detector saw a plane (snap or live fix)
    case noDetection = "no_detection"        // in-envelope, and it saw nothing
    case outOfEnvelope = "out_of_envelope"   // night / speck / missing signals — not judged
}

nonisolated struct DetectorGate {

    /// Tuning constants. Deliberately conservative — the envelope must only
    /// cover scenes where a miss is genuinely suspicious.
    struct Thresholds: Sendable, Equatable {
        /// Minimum expected plane footprint (px, in the captured still) to
        /// demand a detection. The model's measured floor is ~15–20 px
        /// (REPORT.md: 0.48 conf at ~19 px, missed at ~12 px); 24 px keeps a
        /// margin so "should have seen it" is comfortably true.
        var minFootprintPx: Double = 24
        /// Minimum mean scene luminance to judge at all — the same "enough
        /// light to trust the signal" dial as SkyCheck's color trust. Below
        /// it (night, dusk) the detector is out of its depth by design.
        var minLuminance: Double = 0.12

        static let `default` = Thresholds()
    }

    var thresholds: Thresholds = .default

    /// The gate decision. Pure — same inputs always yield the same verdict.
    ///
    /// - `sawPlane`: the photo-snap found a plane, or a live preview fix
    ///   existed at catch time.
    /// - `expectedFootprintPx`: `expectedFootprintPx(...)`, or nil when any
    ///   input was unavailable (no observation, no photo) → fail open.
    /// - `meanLuminance`: whole-frame `SkyFeatures.meanLuminance`, or nil
    ///   before the first camera frame → fail open.
    func verdict(
        sawPlane: Bool,
        expectedFootprintPx: Double?,
        meanLuminance: Double?
    ) -> DetectorGateVerdict {
        // Corroboration always wins — a real detection outranks any envelope
        // reasoning about whether one was likely.
        if sawPlane { return .corroborated }
        guard let footprint = expectedFootprintPx, let lum = meanLuminance else {
            return .outOfEnvelope
        }
        guard lum >= thresholds.minLuminance else { return .outOfEnvelope }
        guard footprint >= thresholds.minFootprintPx else { return .outOfEnvelope }
        return .noDetection
    }

    /// Expected plane footprint in captured-still pixels: the small-angle
    /// apparent size (wingspan / slant, radians) as a fraction of the photo's
    /// horizontal field of view. The still reflects the digital zoom (the
    /// same assumption CatchPhotoSnapper's aspect-fill mapping is built on),
    /// so the effective FOV is the base FOV divided by zoom.
    /// nil when any input can't produce a meaningful size — callers fail open.
    static func expectedFootprintPx(
        wingspanMeters: Double,
        slantMeters: Double,
        effectiveHfovDeg: Double,
        photoWidthPx: Double
    ) -> Double? {
        guard wingspanMeters > 0, slantMeters > 0,
              effectiveHfovDeg > 0, photoWidthPx > 0 else { return nil }
        let apparentSizeRad = wingspanMeters / slantMeters
        let hfovRad = effectiveHfovDeg * .pi / 180
        return apparentSizeRad / hfovRad * photoWidthPx
    }
}
