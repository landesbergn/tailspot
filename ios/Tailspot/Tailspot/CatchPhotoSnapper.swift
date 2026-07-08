//
//  CatchPhotoSnapper.swift
//  Tailspot
//
//  Snaps the catch-photo bracket onto the plane the camera actually
//  captured. The geometric prediction (GPS + compass + pitch) that places
//  the bracket can be hundreds of pixels off — compass wobble, plus the
//  hand moving during the ~0.2–0.6 s between the catch tap and the
//  shutter. This runs the bundled YOLOX airplane detector over the
//  captured STILL, centered where geometry predicted, and returns the
//  corrected point; no detection → nil and the caller keeps the
//  geometric position (never worse than before).
//
//  Design pinned by the 2026-07-05 offline eval over Noah's 79 real catch
//  photos (see PR / the snap-eval review doc):
//    - Search by tiling NATIVE-resolution 640 px crops around the
//      prediction — never by downscaling a wider crop. Distant planes sit
//      near the detector's ~15–20 px floor; a 2× downscale erases them
//      and instead surfaces giant low-confidence hallucination boxes.
//    - Gates: confidence ≥ 0.25 (tuned on the labeled corpus — see the
//      note on `confidenceFloor`), box side ≤ ⅓ crop (kills the giant-FP
//      class), snap radius ≤ 700 px (largest verified real correction
//      was 609 px).
//    - Choose the detection NEAREST the prediction, not the most
//      confident — at airports several real planes can be in frame.
//
//  Known limitation (verified in the eval, accepted): at an airport with
//  background aircraft in view, the nearest detection can be a parked
//  plane rather than the caught one.
//
//  Threading: everything here is pure CPU/ANE work on immutable inputs —
//  `nonisolated`, called from a detached task off the MainActor catch
//  path. Inputs (Data / CGPoint / CGSize) are Sendable so the detached
//  closure captures cleanly under Swift 6 isolation checking.
//

import CoreGraphics
import Foundation
import UIKit

nonisolated enum CatchPhotoSnapper {

    /// Gates — see the eval rationale in the header. The floor was tuned
    /// against Noah's hand-labeled corpus (2026-07-07, 65 photos): every
    /// reachable labeled plane down to 0.25 is real, the none/unsure
    /// photos produce zero candidates even at 0.20, and all 14 verified
    /// snaps choose the same detection at 0.25 as at 0.45. 0.25 gains 5
    /// correct snaps over 0.45 on that corpus at zero measured cost;
    /// margin above 0.20 kept because the negative set is small — revisit
    /// with catch_photo_snap field data.
    static let confidenceFloor: Float = 0.25
    static let maxDetectionSide: CGFloat = CGFloat(AirplaneDetector.inputSide) / 3
    static let maxSnapRadiusPixels: CGFloat = 700
    /// Early-exit: a gated hit this close from the center crop is taken
    /// without running the ring (the common case — one model pass).
    static let centerAcceptRadiusPixels: CGFloat = 340

    /// Ring stride: 640 px tiles at ±480 px offsets overlap 160 px so a
    /// plane on a tile seam is fully inside at least one tile.
    static let ringOffset: CGFloat = 480

    /// One detector for all catches. `static let` is lazily initialized
    /// exactly once, thread-safe by language guarantee; nil when the model
    /// is missing from the bundle (feature silently off).
    private static let detector = AirplaneDetector()

    /// Result of a catch-photo snap attempt, with enough context for the L4
    /// detector gate to reason about it: `screenPoint` is nil both when the
    /// detector saw nothing AND when the search couldn't run at all
    /// (undecodable photo, degenerate sizes) — `searched` separates the two,
    /// and `photoWidthPx` feeds the expected-footprint envelope math.
    struct Snap: Sendable {
        let screenPoint: CGPoint?
        let searched: Bool
        let photoWidthPx: Double?

        static let notSearched = Snap(screenPoint: nil, searched: false, photoWidthPx: nil)
    }

    /// Full pipeline for the catch path: decode the captured JPEG, map the
    /// predicted SCREEN position into photo pixels, search, and map the
    /// snapped point back to screen space so the existing
    /// `CatchPhotoComposer.BracketOverlay` API is unchanged.
    static func snapOutcome(
        jpegData: Data,
        predictedScreen: CGPoint,
        screenSize: CGSize
    ) -> Snap {
        guard let cgImage = UIImage(data: jpegData)?.cgImage else { return .notSearched }
        let photoSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard photoSize.width > 0, photoSize.height > 0,
              screenSize.width > 0, screenSize.height > 0 else { return .notSearched }
        let transform = AspectFillTransform(screenSize: screenSize, photoSize: photoSize)
        let predictedPhoto = transform.photoPoint(fromScreenPoint: predictedScreen)
        let snappedPhoto = snappedPhotoPoint(in: cgImage, predictedPhotoPoint: predictedPhoto)
        return Snap(
            screenPoint: snappedPhoto.map(transform.screenPoint(fromPhotoPoint:)),
            searched: true,
            photoWidthPx: Double(photoSize.width)
        )
    }

    /// Snap-only convenience (the pre-L4 shape; kept for tests and callers
    /// that don't need the search context). Returns nil when there is
    /// nothing to snap to.
    static func snapScreenPosition(
        jpegData: Data,
        predictedScreen: CGPoint,
        screenSize: CGSize
    ) -> CGPoint? {
        snapOutcome(jpegData: jpegData, predictedScreen: predictedScreen,
                    screenSize: screenSize).screenPoint
    }

    /// Detector search in photo-pixel space. Center crop first (early exit
    /// on a near hit), then the 8-tile ring; nearest gated detection wins.
    static func snappedPhotoPoint(
        in cgImage: CGImage,
        predictedPhotoPoint predicted: CGPoint
    ) -> CGPoint? {
        guard let detector = Self.detector else { return nil }
        let photoSize = CGSize(width: cgImage.width, height: cgImage.height)
        let side = CGFloat(AirplaneDetector.inputSide)

        var hits: [Detection] = []
        for (index, center) in searchCenters(around: predicted).enumerated() {
            // Skip ring tiles that fall entirely outside the photo.
            guard center.x > -side / 2, center.x < photoSize.width + side / 2,
                  center.y > -side / 2, center.y < photoSize.height + side / 2 else { continue }
            let rect = AirplaneDetector.cropRect(center: center, side: side, in: photoSize)
            hits += detector.detect(in: cgImage, cropRect: rect).filter(passesGates)

            if index == 0, let best = choose(from: hits, predicted: predicted),
               distance(best, to: predicted) <= centerAcceptRadiusPixels {
                return midpoint(of: best.rect)
            }
        }
        return choose(from: hits, predicted: predicted).map { midpoint(of: $0.rect) }
    }

    /// Center + 8 surrounding tile centers, nearest-first so an early
    /// return favors the least-correction candidates.
    static func searchCenters(around p: CGPoint) -> [CGPoint] {
        let o = ringOffset
        return [
            p,
            CGPoint(x: p.x - o, y: p.y), CGPoint(x: p.x + o, y: p.y),
            CGPoint(x: p.x, y: p.y - o), CGPoint(x: p.x, y: p.y + o),
            CGPoint(x: p.x - o, y: p.y - o), CGPoint(x: p.x + o, y: p.y - o),
            CGPoint(x: p.x - o, y: p.y + o), CGPoint(x: p.x + o, y: p.y + o),
        ]
    }

    /// Confidence + size gates. The size cap rejects the "giant blurry
    /// box over half the crop" false-positive class the eval surfaced.
    static func passesGates(_ d: Detection) -> Bool {
        d.confidence >= confidenceFloor
            && max(d.rect.width, d.rect.height) <= maxDetectionSide
    }

    /// Nearest-to-prediction detection within the snap radius.
    static func choose(from detections: [Detection], predicted: CGPoint) -> Detection? {
        detections
            .filter { distance($0, to: predicted) <= maxSnapRadiusPixels }
            .min { distance($0, to: predicted) < distance($1, to: predicted) }
    }

    private static func distance(_ d: Detection, to p: CGPoint) -> CGFloat {
        let c = midpoint(of: d.rect)
        return hypot(c.x - p.x, c.y - p.y)
    }

    private static func midpoint(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }
}
