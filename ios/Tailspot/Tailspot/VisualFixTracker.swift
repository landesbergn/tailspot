//
//  VisualFixTracker.swift
//  Tailspot
//
//  The association half of visual confirmation (see
//  tools/visual-confirmation/SWIFT-DESIGN.md): given the detector's output
//  for a crop around an aircraft's PREDICTED screen position, decide whether
//  a detection is "our" plane, smooth the correction over time, and expire
//  it when the plane stops being seen.
//
//  Pure math + state — no CoreML, no camera, no SwiftUI — so every rule
//  here is unit-testable. The caller (the detector pipeline) maps detection
//  rects into screen space before handing them in.
//
//  Why an EMA on the OFFSET rather than the position: the predicted position
//  moves every frame as the plane flies and the phone pans; the *error*
//  between predicted and visual (mostly compass bias) is the slowly-varying
//  quantity worth smoothing. Smoothing the position directly would lag the
//  plane's real motion; smoothing the offset keeps brackets glued to the
//  plane while still suppressing per-frame detector jitter.
//

import CoreGraphics
import Foundation

// Pure value/state types that flow between the (background) detection
// pipeline and (main-actor) UI — explicitly nonisolated like Geo/Aircraft.
nonisolated struct VisualFix: Equatable {
    /// Corrected screen position: prediction + smoothed visual offset.
    let screenPoint: CGPoint
    /// Confidence of the most recent accepted detection (0–1).
    let confidence: Float
}

nonisolated struct VisualFixTracker {
    /// Detections farther than this from the predicted position are rejected
    /// as "not our plane" (clutter, a second aircraft, a streetlamp the
    /// model calls an airplane). In screen points; callers pass the crop's
    /// half-width so the gate and the searched area agree.
    var gateRadius: CGFloat

    /// EMA weight for a new offset sample (0–1; higher = snappier).
    var smoothing: CGFloat = 0.4

    /// Consecutive detector frames with no accepted detection before the
    /// fix expires and the bracket falls back to the predicted position.
    /// At ~8 fps, 8 misses ≈ one second of "lost it."
    var maxMisses: Int = 8

    private struct State {
        var emaOffset: CGVector
        var confidence: Float
        var misses: Int
    }

    private var states: [String: State] = [:]

    init(gateRadius: CGFloat) {
        self.gateRadius = gateRadius
    }

    /// Whether an aircraft currently has a live (non-expired) visual fix.
    func hasFix(for icao24: String) -> Bool {
        states[icao24] != nil
    }

    /// Feed one detector frame for one aircraft. `detections` are the
    /// post-NMS results mapped to SCREEN space; `predicted` is the
    /// geometry-predicted screen position the crop was centered on.
    ///
    /// Returns the corrected fix, or nil when there is no live fix (either
    /// nothing acceptable was ever seen, or the fix just expired).
    @discardableResult
    mutating func ingest(
        icao24: String,
        detections: [Detection],
        predicted: CGPoint
    ) -> VisualFix? {
        // Best = highest confidence inside the gate. Confidence (not
        // proximity) ranks candidates: with compass bias the true plane is
        // often NOT the nearest point to the prediction, but it is usually
        // the strongest airplane-shaped thing in the crop.
        let accepted = detections
            .filter { distance(center(of: $0.rect), predicted) <= gateRadius }
            .max { $0.confidence < $1.confidence }

        guard let hit = accepted else {
            return registerMiss(icao24: icao24, predicted: predicted)
        }

        let sample = CGVector(
            dx: center(of: hit.rect).x - predicted.x,
            dy: center(of: hit.rect).y - predicted.y
        )

        if var s = states[icao24] {
            s.emaOffset.dx += smoothing * (sample.dx - s.emaOffset.dx)
            s.emaOffset.dy += smoothing * (sample.dy - s.emaOffset.dy)
            s.confidence = hit.confidence
            s.misses = 0
            states[icao24] = s
        } else {
            // First acquisition: take the sample as-is rather than easing in
            // from zero — easing would draw the bracket sliding from the
            // (wrong) predicted position toward the plane.
            states[icao24] = State(emaOffset: sample, confidence: hit.confidence, misses: 0)
        }

        return fix(for: icao24, predicted: predicted)
    }

    /// The current corrected position for an aircraft given the latest
    /// prediction, without ingesting a new frame (used by render ticks that
    /// run faster than the detector).
    func fix(for icao24: String, predicted: CGPoint) -> VisualFix? {
        guard let s = states[icao24] else { return nil }
        return VisualFix(
            screenPoint: CGPoint(x: predicted.x + s.emaOffset.dx, y: predicted.y + s.emaOffset.dy),
            confidence: s.confidence
        )
    }

    /// Drop state for aircraft no longer being tracked (left visibility,
    /// lock moved on) so the dictionary can't grow unboundedly.
    mutating func retain(only icaos: some Sequence<String>) {
        let keep = Set(icaos)
        states = states.filter { keep.contains($0.key) }
    }

    private mutating func registerMiss(icao24: String, predicted: CGPoint) -> VisualFix? {
        guard var s = states[icao24] else { return nil }
        s.misses += 1
        if s.misses >= maxMisses {
            states[icao24] = nil
            return nil
        }
        states[icao24] = s
        // Keep serving the last-good offset while inside the miss budget:
        // a 100 ms detector hiccup shouldn't visibly snap the bracket back.
        return fix(for: icao24, predicted: predicted)
    }

    private func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }
}
