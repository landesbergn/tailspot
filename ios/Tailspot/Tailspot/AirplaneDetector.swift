//
//  AirplaneDetector.swift
//  Tailspot
//
//  CoreML inference for visual confirmation (SWIFT-DESIGN.md): run the
//  bundled YOLOX-Small airplane detector on a NATIVE-RESOLUTION crop of
//  the camera buffer centered on a plane's predicted position. Cropping
//  (rather than downscaling the whole frame to 640px) is the load-bearing
//  trick: it preserves ~6× of apparent aircraft size, which is the
//  difference between detecting a distant plane and not (REPORT.md's
//  size sweep dies under a ~15–20 px footprint).
//
//  Deliberately NOT Vision/VNCoreMLRequest: Vision hides its letterbox
//  and resampling choices, and the decode math (AirplaneDetectionDecoder)
//  assumes exact control of both. Direct MLModel + CoreImage keeps every
//  pixel transform explicit and mirrored against validate.py.
//
//  Threading: the class is `nonisolated` and does its work synchronously —
//  the caller (VisualConfirmationPipeline) owns the serial detection queue.
//  MLModel prediction is itself thread-safe.
//

import CoreImage
// `@preconcurrency`: CoreML's `MLModel` predates Sendable annotations, so a
// stored `let model: MLModel` trips a Swift 6 Sendable warning. Prediction is
// thread-safe (see the threading note above), so we suppress it at the import.
@preconcurrency import CoreML
import CoreVideo
import Foundation
import os     // os.Logger interpolation in the Log helpers

nonisolated final class AirplaneDetector: Sendable {

    /// Model input side (the YOLOX 640×640 input; see REPORT.md).
    static let inputSide = 640

    private let model: MLModel
    // CIContext is expensive to create and thread-safe to use — one per
    // detector. Software renderer disabled; let it pick GPU/ANE-friendly
    // paths.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Loads the bundled compiled model. Returns nil (with a log) when the
    /// model resource is missing — callers treat a nil detector as
    /// "feature unavailable," never a crash.
    init?() {
        guard let url = Bundle.main.url(forResource: "YoloxAirplane_int8",
                                        withExtension: "mlmodelc") else {
            Log.ui.error("AirplaneDetector: YoloxAirplane_int8.mlmodelc missing from bundle")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all   // ANE/GPU as CoreML sees fit
            self.model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            Log.ui.error("AirplaneDetector: model load failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Compute the square crop for a predicted position, clamped fully
    /// inside the buffer: shifted (not shrunk) when the center is near an
    /// edge, shrunk only when the buffer itself is smaller than `side`.
    /// Pure + static so the clamping rules are unit-testable.
    static func cropRect(center: CGPoint, side: CGFloat, in bufferSize: CGSize) -> CGRect {
        let s = min(side, min(bufferSize.width, bufferSize.height))
        var x = center.x - s / 2
        var y = center.y - s / 2
        x = max(0, min(x, bufferSize.width - s))
        y = max(0, min(y, bufferSize.height - s))
        return CGRect(x: x, y: y, width: s, height: s)
    }

    /// Run detection on `cropRect` (top-left-origin buffer pixels) of the
    /// frame. Returns detections in BUFFER pixel coordinates (same
    /// top-left-origin space as `cropRect`), post-NMS.
    func detect(in pixelBuffer: CVPixelBuffer, cropRect: CGRect) -> [Detection] {
        let bufferH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // CoreImage uses a BOTTOM-left origin; our rects are top-left.
        let ciRect = CGRect(
            x: cropRect.minX,
            y: bufferH - cropRect.maxY,
            width: cropRect.width,
            height: cropRect.height
        )
        let scale = CGFloat(Self.inputSide) / cropRect.width

        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: ciRect)
        // Move the crop to the origin, then scale to 640×640.
        image = image
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let input = renderToMultiArray(image) else { return [] }

        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: ["image": input])
        } catch {
            Log.ui.error("AirplaneDetector: feature provider failed: \(String(describing: error), privacy: .public)")
            return []
        }

        guard
            let output = try? model.prediction(from: provider),
            let tensorArray = output.featureValue(for: "detections")?.multiArrayValue
        else {
            return []
        }

        // Reconstruct the logical (8400, 85) row-major tensor the decoder
        // expects, HONORING the array's strides + dtype. The previous code
        // blind-copied the backing buffer as contiguous Float32 — but the
        // FP16-compute output (Neural Engine / GPU) can come back padded or
        // non-contiguous, which scrambled every anchor and produced impossible
        // scores (>1) + zero-size boxes, so the bracket snapped off the plane.
        guard let tensor = Self.logicalTensor(from: tensorArray) else {
            Log.ui.error("AirplaneDetector: unexpected detections tensor shape/dtype \(tensorArray.shape, privacy: .public)")
            return []
        }

        let decoded = AirplaneDetectionDecoder.decode(
            tensor: tensor,
            letterboxScale: Float(scale)
        )
        let kept = AirplaneDetectionDecoder.nonMaxSuppression(decoded)

        // Crop-space → buffer-space (both top-left origin; pure offset).
        return kept.map {
            Detection(
                rect: $0.rect.offsetBy(dx: cropRect.minX, dy: cropRect.minY),
                confidence: $0.confidence
            )
        }
    }

    /// Copy the model's `(1, 8400, 85)` output into the logical row-major
    /// `[Float]` the decoder expects, HONORING the MLMultiArray's strides and
    /// dtype.
    ///
    /// This is the fix for the field bug where the AR bracket snapped off the
    /// plane: CoreML's output (FP16 compute on the Neural Engine / GPU) can be
    /// returned padded or non-contiguous, and the old blind contiguous copy
    /// then read the wrong memory — yielding impossible scores (objectness ×
    /// class > 1, seen at ~150 in recordings) and zero-size boxes. Indexing
    /// every element through its stride reconstructs the correct tensor
    /// regardless of backing layout. Returns nil on an unexpected shape or an
    /// unsupported dtype (caller treats nil as "no detections" this frame).
    nonisolated static func logicalTensor(from array: MLMultiArray) -> [Float]? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count == 3,
              shape[0] == 1,
              shape[1] == AirplaneDetectionDecoder.anchorCount,
              shape[2] == AirplaneDetectionDecoder.anchorStride,
              strides.count == 3
        else { return nil }

        let anchors = shape[1]
        let chans = shape[2]
        let sA = strides[1]
        let sC = strides[2]
        var out = [Float](repeating: 0, count: anchors * chans)

        switch array.dataType {
        case .float32:
            array.withUnsafeBufferPointer(ofType: Float32.self) { src in
                for a in 0 ..< anchors {
                    let rb = a * sA
                    let db = a * chans
                    for c in 0 ..< chans { out[db + c] = src[rb + c * sC] }
                }
            }
        case .float16:
            array.withUnsafeBufferPointer(ofType: Float16.self) { src in
                for a in 0 ..< anchors {
                    let rb = a * sA
                    let db = a * chans
                    for c in 0 ..< chans { out[db + c] = Float(src[rb + c * sC]) }
                }
            }
        default:
            return nil
        }
        return out
    }

    /// Render a 640×640 CIImage into the model's (1, 3, 640, 640) float32
    /// NCHW MLMultiArray, RGB, raw 0–255 (REPORT.md input spec — the model
    /// takes a plain MultiArray, not an ImageType, so the pixel unpacking
    /// is ours).
    private func renderToMultiArray(_ image: CIImage) -> MLMultiArray? {
        let side = Self.inputSide

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let rendered = pb else { return nil }

        ciContext.render(image, to: rendered,
                         bounds: CGRect(x: 0, y: 0, width: side, height: side),
                         colorSpace: CGColorSpaceCreateDeviceRGB())

        guard let array = try? MLMultiArray(
            shape: [1, 3, NSNumber(value: side), NSNumber(value: side)],
            dataType: .float32
        ) else { return nil }

        CVPixelBufferLockBaseAddress(rendered, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(rendered, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(rendered) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(rendered)
        let src = base.assumingMemoryBound(to: UInt8.self)

        let plane = side * side
        let dst = array.dataPointer.assumingMemoryBound(to: Float32.self)
        // BGRA interleaved → RGB planar, raw 0–255 floats.
        for y in 0..<side {
            let row = src + y * bytesPerRow
            let rowOut = y * side
            for x in 0..<side {
                let p = row + x * 4
                let out = rowOut + x
                dst[out]             = Float32(p[2])   // R
                dst[plane + out]     = Float32(p[1])   // G
                dst[2 * plane + out] = Float32(p[0])   // B
            }
        }
        return array
    }
}
