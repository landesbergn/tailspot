//
//  VisualConfirmationPipeline.swift
//  Tailspot
//
//  Glue between the camera frame tap, the CoreML detector, and the AR
//  overlay (SWIFT-DESIGN.md). Per detector frame:
//
//    camera queue ──ingestFrame──▶ busy-skip ──▶ detection queue:
//        read the current target (icao + predicted SCREEN point),
//        map screen → buffer pixels (AspectFillTransform),
//        crop 640px native around the prediction, run the detector,
//        map hits back to screen space,
//    ──▶ MainActor: VisualFixTracker.ingest → published `fixes`.
//
//  The render loop (30 Hz TimelineView) reads `fixes` and draws the
//  bracket at the corrected position when a live fix exists. Scope for
//  the spike: ONE tracked aircraft per frame — the lock-engine target or
//  the tap-pinned plane (SWIFT-DESIGN.md defers multi-crop scheduling).
//
//  While a replay recording is active, the pipeline also saves the crop
//  JPEG + a JSONL sidecar (timestamp, icao, predicted point, crop rect,
//  detections) at ~1 Hz to Documents/replays/frames/ — the offline
//  ground-truth for the go/no-go gate, deliberately OUTSIDE the stable
//  ReplayEvent format (frames can be re-scored by future detectors).
//

import Combine     // @Published/ObservableObject without import SwiftUI
import CoreImage
import CoreVideo
import Foundation
import QuartzCore
import os

@MainActor
final class VisualConfirmationPipeline: ObservableObject {

    /// Live corrected positions keyed by icao24. Published on main so the
    /// TimelineView body can read it like any other observable state.
    @Published private(set) var fixes: [String: VisualFix] = [:]

    /// Kill switch (debug-overlay toggle). Default ON in Debug builds,
    /// OFF in Release until the field gate passes.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? Self.defaultEnabled }
        set {
            objectWillChange.send()   // not @Published (UserDefaults-backed)
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            enabledSnapshot.withLock { $0 = newValue }
            if !newValue { fixes = [:] }
        }
    }
    static let enabledKey = "tailspot.debug.visualConfirm"
    #if DEBUG
    private static let defaultEnabled = true
    #else
    private static let defaultEnabled = false
    #endif

    /// What the detector should look for, refreshed every render frame.
    nonisolated struct Target: Sendable {
        let icao24: String
        let predictedScreen: CGPoint
        let screenSize: CGSize
    }

    /// Crop side in native buffer pixels (SWIFT-DESIGN.md: covers ±15° of
    /// compass error at 1× on the 4032-px-wide sensor's preview stream).
    nonisolated static let cropSidePixels: CGFloat = 640

    private let detector: AirplaneDetector?
    private let detectionQueue = DispatchQueue(label: "tailspot.visualconfirm",
                                               qos: .userInitiated)
    /// Camera-queue-readable snapshot of the main-actor state the frame
    /// path needs. Tiny critical sections; written at 30 Hz, read at 8 Hz.
    private let targetSnapshot = OSAllocatedUnfairLock<Target?>(initialState: nil)
    private let enabledSnapshot: OSAllocatedUnfairLock<Bool>
    private let recordingSnapshot = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Drops frames while a detection is in flight rather than queueing
    /// them — stale frames are worse than skipped ones.
    private let busy = OSAllocatedUnfairLock<Bool>(initialState: false)
    /// Latest sky-scene features for the v1 authenticity gate. Written on
    /// the camera queue every frame (independent of the detector toggle),
    /// read at catch time. nil until the first frame arrives.
    private let skyFeaturesSnapshot = OSAllocatedUnfairLock<SkyFeatures?>(initialState: nil)

    private var tracker = VisualFixTracker(gateRadius: 150)
    // `nonisolated`: CropFrameSaver is itself a nonisolated class (it uses
    // nonisolated(unsafe) state by design) and is called synchronously from the
    // background detection queue. Without this the property inherits the class's
    // @MainActor isolation and can't be touched from that Sendable closure.
    nonisolated private let frameSaver = CropFrameSaver()

    init(detector: AirplaneDetector? = AirplaneDetector()) {
        self.detector = detector
        let initial = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool
            ?? Self.defaultEnabled
        self.enabledSnapshot = OSAllocatedUnfairLock(initialState: initial)
    }

    /// Whether the feature can run at all (model present in the bundle).
    var isAvailable: Bool { detector != nil }

    /// Snapshot of the most recent frame's sky features (v1 authenticity
    /// gate). nil before the first frame arrives.
    nonisolated var latestSkyFeatures: SkyFeatures? { skyFeaturesSnapshot.withLock { $0 } }

    /// Called from the render loop every frame with the single plane worth
    /// confirming (lock target or pin), or nil when there isn't one.
    ///
    /// `nonisolated` + lock-only on purpose: this runs INSIDE the SwiftUI
    /// body evaluation (the TimelineView frame), where mutating @Published
    /// state would be a publish-during-view-update violation. Stale-state
    /// pruning happens on the next detector ingest instead (a main-actor
    /// hop that is always outside body evaluation).
    nonisolated func updateTarget(_ target: Target?) {
        targetSnapshot.withLock { $0 = target }
    }

    /// Mirror of ReplayRecorder.isRecording, pushed in by ContentView so
    /// the frame path can check it without touching main-actor state.
    func setRecording(_ recording: Bool) {
        recordingSnapshot.withLock { $0 = recording }
    }

    /// Frame entry point — runs on the camera's video queue (~8 fps).
    nonisolated func ingestFrame(_ pixelBuffer: CVPixelBuffer) {
        // v1 authenticity gate: compute sky features on EVERY frame,
        // independent of the visual-confirm detector toggle and of having
        // a lock target. Cheap (12×12 sample lattice); stored for a read
        // at catch time.
        if let sky = SkyFeatures.extract(from: pixelBuffer) {
            skyFeaturesSnapshot.withLock { $0 = sky }
        }
        guard enabledSnapshot.withLock({ $0 }),
              let target = targetSnapshot.withLock({ $0 }),
              let detector
        else { return }
        // Busy-skip: at most one detection in flight.
        let wasBusy = busy.withLock { b -> Bool in
            if b { return true }
            b = true
            return false
        }
        guard !wasBusy else { return }

        let recording = recordingSnapshot.withLock { $0 }
        // CVPixelBuffer isn't Sendable, but a CoreVideo buffer is safe to hand
        // to a single serial queue. `nonisolated(unsafe)` opts this one capture
        // out of the Swift 6 data-race check for the @Sendable closure below.
        nonisolated(unsafe) let frame = pixelBuffer
        detectionQueue.async { [weak self] in
            defer { self?.busy.withLock { $0 = false } }
            guard let self else { return }

            let bufferSize = CGSize(width: CVPixelBufferGetWidth(frame),
                                    height: CVPixelBufferGetHeight(frame))
            let transform = AspectFillTransform(screenSize: target.screenSize,
                                                photoSize: bufferSize)
            let predictedBuffer = transform.photoPoint(fromScreenPoint: target.predictedScreen)
            let crop = AirplaneDetector.cropRect(center: predictedBuffer,
                                                 side: Self.cropSidePixels,
                                                 in: bufferSize)

            let detections = detector.detect(in: frame, cropRect: crop)

            // Buffer-space → screen-space for the tracker/overlay.
            let screenDetections = detections.map {
                Detection(
                    rect: CGRect(
                        origin: transform.screenPoint(fromPhotoPoint: $0.rect.origin),
                        size: CGSize(width: $0.rect.width * transform.scale,
                                     height: $0.rect.height * transform.scale)
                    ),
                    confidence: $0.confidence
                )
            }
            // Gate = the crop's half-side in screen points, so "inside the
            // searched area" and "acceptable" are the same circle.
            let gate = Self.cropSidePixels / 2 * transform.scale

            if recording {
                self.frameSaver.saveIfDue(pixelBuffer: frame, crop: crop,
                                          target: target, detections: detections)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                // Prune state for planes that are no longer the target
                // (deferred from updateTarget — see its doc comment).
                self.tracker.retain(only: [target.icao24])
                self.tracker.gateRadius = gate
                let fix = self.tracker.ingest(icao24: target.icao24,
                                              detections: screenDetections,
                                              predicted: target.predictedScreen)
                var next: [String: VisualFix] = [:]
                if let fix { next[target.icao24] = fix }
                if next != self.fixes { self.fixes = next }
            }
        }
    }
}

// MARK: - Ground-truth frame saver

/// Writes the detector's crop (as JPEG) + a JSONL sidecar line at ~1 Hz
/// while a replay recording is active. Lives entirely on the detection
/// queue. Files land in Documents/replays/frames/ next to the replay
/// JSONLs; retrieve with the same devicectl copy incantation.
private final nonisolated class CropFrameSaver {
    private static let interval: CFTimeInterval = 1.0

    nonisolated(unsafe) private var lastSave: CFTimeInterval = 0
    nonisolated(unsafe) private var sidecarHandle: FileHandle?
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let iso = ISO8601DateFormatter()

    func saveIfDue(pixelBuffer: CVPixelBuffer, crop: CGRect,
                   target: VisualConfirmationPipeline.Target,
                   detections: [Detection]) {
        let now = CACurrentMediaTime()
        guard now - lastSave >= Self.interval else { return }
        lastSave = now

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("replays/frames", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = iso.string(from: Date()).replacingOccurrences(of: ":", with: "")
        let bufferH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let ciRect = CGRect(x: crop.minX, y: bufferH - crop.maxY,
                            width: crop.width, height: crop.height)
        let image = CIImage(cvPixelBuffer: pixelBuffer).cropped(to: ciRect)

        let jpegURL = dir.appendingPathComponent("crop-\(stamp)-\(target.icao24).jpg")
        if let data = ciContext.jpegRepresentation(
            of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8]
        ) {
            try? data.write(to: jpegURL)
        }

        let line: [String: Any] = [
            "ts": iso.string(from: Date()),
            "icao24": target.icao24,
            "predictedScreenX": target.predictedScreen.x,
            "predictedScreenY": target.predictedScreen.y,
            "screenW": target.screenSize.width,
            "screenH": target.screenSize.height,
            "cropX": crop.minX, "cropY": crop.minY, "cropSide": crop.width,
            "detections": detections.map {
                ["x": $0.rect.minX, "y": $0.rect.minY,
                 "w": $0.rect.width, "h": $0.rect.height,
                 "conf": Double($0.confidence)]
            },
            "file": jpegURL.lastPathComponent,
        ]
        if let json = try? JSONSerialization.data(withJSONObject: line),
           var text = String(data: json, encoding: .utf8) {
            text += "\n"
            let sidecar = dir.appendingPathComponent("frames.jsonl")
            if sidecarHandle == nil {
                if !FileManager.default.fileExists(atPath: sidecar.path) {
                    FileManager.default.createFile(atPath: sidecar.path, contents: nil)
                }
                sidecarHandle = try? FileHandle(forWritingTo: sidecar)
                _ = try? sidecarHandle?.seekToEnd()
            }
            sidecarHandle?.write(text.data(using: .utf8)!)
        }
    }
}
