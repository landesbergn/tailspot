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
//  Coordinate space: the captured JPEG is stored sensor-landscape with an
//  EXIF orientation tag (verified against real device captures — raw
//  stills are landscape + orientation 6, not upright). `UIImage.cgImage`
//  ignores that tag, so all search math runs on an orientation-normalized
//  UPRIGHT image (`uprightCGImage`), matching the composer's
//  UIImage-oriented space. Skipping this rotates the search space 90°
//  and every coordinate mapping is garbage.
//
//  Design pinned by the 2026-07-05 offline eval over Noah's 79 real catch
//  photos (see PR #106 / the snap-eval review doc), which are 1080 px
//  wide. Stills are now captured at the sensor's full photo resolution
//  (~3024 px wide — PR for this change), so the search is
//  resolution-adaptive around that 1080-px reference space:
//    - FINE pass: native-resolution 640 px crops (center + 8-tile ring at
//      ±480 px) around the prediction. Distant planes sit near the
//      detector's ~15–20 px floor at 1080 px; at native 12 MP the same
//      planes are ~3× larger, i.e. squarely detectable. Distance gates
//      scale by photoWidth / 1080.
//    - COARSE pass (only when the photo is meaningfully wider than the
//      1080 reference AND the fine pass found nothing): downscale the
//      whole photo to 1080 wide and run the original eval-calibrated
//      9-tile policy there — literally the validated 1080 behavior, which
//      restores the wide angular coverage the fine ring loses at native
//      resolution (±800 native px is only ~26 % of a 3024 px frame). A
//      coarse hit is then REFINED with one native crop at the hit so the
//      returned center is native-precise; if the native crop can't
//      confirm (e.g. a big plane exceeding the per-crop size gate), the
//      coarse center itself is returned — it already passed the
//      calibrated gates.
//    - Gates per crop: confidence ≥ 0.25 (tuned on the labeled corpus —
//      see `confidenceFloor`), box side ≤ ⅓ crop (kills the giant-FP
//      class), snap radius ≤ 700 reference px.
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
    /// Calibrated in 1080-px reference space (largest verified real
    /// correction was 609 px); scale by `resolutionScale(photoWidth:)`
    /// before comparing native-px distances.
    static let maxSnapRadiusPixels: CGFloat = 700
    /// Early-exit: a gated hit this close (reference px) from the center
    /// crop is taken without running the ring (the common case — one
    /// model pass).
    static let centerAcceptRadiusPixels: CGFloat = 340
    /// The photo width every distance/radius constant was calibrated
    /// against (the 2026-07-05/07 eval corpus).
    static let referenceWidthPixels: CGFloat = 1080
    /// Photos at most this factor above the reference width skip the
    /// coarse pass — the fine ring already covers what the 1080 policy
    /// covered, and a downscale that small adds no context.
    static let coarsePassMinScale: CGFloat = 1.3
    /// A coarse hit is refined by one native crop; a native detection
    /// within this many native px of the (upscaled) coarse center is
    /// trusted as the same object. Coarse localization error is a few
    /// coarse px (tens of native px), while a *different* plane is
    /// hundreds away.
    static let refineAcceptRadiusPixels: CGFloat = 150

    /// Ring stride: 640 px tiles at ±480 px offsets overlap 160 px so a
    /// plane on a tile seam is fully inside at least one tile.
    static let ringOffset: CGFloat = 480

    /// One detector for all catches. `static let` is lazily initialized
    /// exactly once, thread-safe by language guarantee; nil when the model
    /// is missing from the bundle (feature silently off).
    private static let detector = AirplaneDetector()

    /// How many times larger than the calibration reference this photo
    /// is. Never below 1 — narrow/legacy photos keep reference behavior.
    static func resolutionScale(photoWidth: CGFloat) -> CGFloat {
        max(1, photoWidth / referenceWidthPixels)
    }

    /// Result of a catch-photo snap attempt, with enough context for the L4
    /// detector gate to reason about it: `screenPoint` is nil both when the
    /// detector saw nothing AND when the search couldn't run at all
    /// (undecodable photo, degenerate sizes) — `searched` separates the two,
    /// and `photoWidthPx` (upright-oriented) feeds the expected-footprint
    /// envelope math.
    struct Snap: Sendable {
        let screenPoint: CGPoint?
        let searched: Bool
        let photoWidthPx: Double?

        static let notSearched = Snap(screenPoint: nil, searched: false, photoWidthPx: nil)
    }

    /// Full pipeline for the catch path: decode the captured JPEG,
    /// normalize orientation, map the predicted SCREEN position into photo
    /// pixels, search, and map the snapped point back to screen space so
    /// the existing `CatchPhotoComposer.BracketOverlay` API is unchanged.
    static func snapOutcome(
        jpegData: Data,
        predictedScreen: CGPoint,
        screenSize: CGSize
    ) -> Snap {
        guard let image = UIImage(data: jpegData),
              let cgImage = uprightCGImage(from: image) else { return .notSearched }
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

    /// The captured JPEG in upright pixel order. AVFoundation stores
    /// stills sensor-landscape with an EXIF orientation tag that
    /// `UIImage.cgImage` ignores; the composer draws through
    /// orientation-aware `UIImage.draw`, so the snapper must search the
    /// same upright space or every coordinate mapping is rotated 90°.
    static func uprightCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up { return image.cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let upright = UIGraphicsImageRenderer(size: image.size, format: format)
            .image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return upright.cgImage
    }

    /// Detector search in (upright) photo-pixel space: fine native pass
    /// first, then — for photos meaningfully wider than the 1080
    /// reference — the coarse 1080-equivalent pass with native refine.
    static func snappedPhotoPoint(
        in cgImage: CGImage,
        predictedPhotoPoint predicted: CGPoint
    ) -> CGPoint? {
        guard let detector = Self.detector else { return nil }
        let photoSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = resolutionScale(photoWidth: photoSize.width)

        if let fine = ringSearch(
            detector: detector, cgImage: cgImage, photoSize: photoSize,
            predicted: predicted,
            centerAcceptRadius: centerAcceptRadiusPixels * scale,
            snapRadius: maxSnapRadiusPixels * scale
        ) {
            return fine
        }

        guard scale >= coarsePassMinScale,
              let coarse = downscaled(cgImage, toWidth: referenceWidthPixels)
        else { return nil }
        let coarseScale = CGFloat(coarse.width) / photoSize.width
        let coarseSize = CGSize(width: coarse.width, height: coarse.height)
        let predictedCoarse = CGPoint(x: predicted.x * coarseScale,
                                      y: predicted.y * coarseScale)
        guard let coarseHit = ringSearch(
            detector: detector, cgImage: coarse, photoSize: coarseSize,
            predicted: predictedCoarse,
            centerAcceptRadius: centerAcceptRadiusPixels,
            snapRadius: maxSnapRadiusPixels
        ) else { return nil }

        // Native refine: one crop at the coarse hit for a native-precise
        // center. An unconfirmable refine keeps the coarse center — that
        // detection already passed the calibrated gates.
        let coarseNative = CGPoint(x: coarseHit.x / coarseScale,
                                   y: coarseHit.y / coarseScale)
        let side = CGFloat(AirplaneDetector.inputSide)
        let rect = AirplaneDetector.cropRect(center: coarseNative, side: side, in: photoSize)
        let refined = choose(
            from: detector.detect(in: cgImage, cropRect: rect).filter(passesGates),
            predicted: coarseNative,
            snapRadius: refineAcceptRadiusPixels
        )
        return refined.map { midpoint(of: $0.rect) } ?? coarseNative
    }

    /// Center + 8-ring crop search; nearest gated detection within
    /// `snapRadius` wins, with an early exit when the center crop already
    /// holds a hit within `centerAcceptRadius`.
    private static func ringSearch(
        detector: AirplaneDetector,
        cgImage: CGImage,
        photoSize: CGSize,
        predicted: CGPoint,
        centerAcceptRadius: CGFloat,
        snapRadius: CGFloat
    ) -> CGPoint? {
        let side = CGFloat(AirplaneDetector.inputSide)
        var hits: [Detection] = []
        for (index, center) in searchCenters(around: predicted).enumerated() {
            // Skip ring tiles that fall entirely outside the photo.
            guard center.x > -side / 2, center.x < photoSize.width + side / 2,
                  center.y > -side / 2, center.y < photoSize.height + side / 2 else { continue }
            let rect = AirplaneDetector.cropRect(center: center, side: side, in: photoSize)
            hits += detector.detect(in: cgImage, cropRect: rect).filter(passesGates)

            if index == 0,
               let best = choose(from: hits, predicted: predicted, snapRadius: snapRadius),
               distance(best, to: predicted) <= centerAcceptRadius {
                return midpoint(of: best.rect)
            }
        }
        return choose(from: hits, predicted: predicted, snapRadius: snapRadius)
            .map { midpoint(of: $0.rect) }
    }

    /// Downscale to `width` preserving aspect (no-op for narrower images).
    /// Used for the coarse pass; `.high` interpolation so near-floor
    /// planes survive the resample.
    static func downscaled(_ cgImage: CGImage, toWidth width: CGFloat) -> CGImage? {
        let ratio = width / CGFloat(cgImage.width)
        guard ratio < 1 else { return cgImage }
        let size = CGSize(width: width.rounded(),
                          height: (CGFloat(cgImage.height) * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
        }
        return small.cgImage
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
    /// Both are PER-CROP quantities, so they apply unscaled in whichever
    /// space (native or coarse) the crop was made.
    static func passesGates(_ d: Detection) -> Bool {
        d.confidence >= confidenceFloor
            && max(d.rect.width, d.rect.height) <= maxDetectionSide
    }

    /// Nearest-to-prediction detection within the reference snap radius
    /// (kept for tests and reference-space callers).
    static func choose(from detections: [Detection], predicted: CGPoint) -> Detection? {
        choose(from: detections, predicted: predicted, snapRadius: maxSnapRadiusPixels)
    }

    /// Nearest-to-prediction detection within an explicit radius.
    static func choose(
        from detections: [Detection],
        predicted: CGPoint,
        snapRadius: CGFloat
    ) -> Detection? {
        detections
            .filter { distance($0, to: predicted) <= snapRadius }
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
