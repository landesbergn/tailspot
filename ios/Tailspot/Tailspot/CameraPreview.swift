//
//  CameraPreview.swift
//  Tailspot
//
//  SwiftUI bridge for AVCaptureSession. SwiftUI doesn't yet ship a built-in
//  camera-preview view, so we wrap a UIView (PreviewView) that hosts an
//  AVCaptureVideoPreviewLayer, and expose it to SwiftUI via UIViewRepresentable.
//
//  Camera permission must be granted before this view appears, otherwise
//  AVCaptureDeviceInput init will fail. ContentView handles the permission
//  request before mounting this view.
//
//  Zoom is digital, applied via AVCaptureDevice.videoZoomFactor on the
//  built-in wide camera. Range clamped to 1.0–5.0 by `Self.zoomRange`
//  (past ~5× a 30 km plane is pixelated noise anyway). The pinch
//  gesture itself lives in ContentView so it composes with the
//  tap-to-ID handler on the same layer.
//

import SwiftUI
import AVFoundation
import os

/// Bridge that lets ContentView ask the active `PreviewView` to capture
/// a still photo without restructuring camera ownership. `PreviewView`
/// installs its capture closure on this bridge during setup; ContentView
/// holds the bridge as a `@State` and calls `captureJPEG()` from the
/// auto-catch path. nil result = capture failed (device gone, session
/// not running, encoding error).
///
/// Not an ObservableObject — we don't observe any property, we just use
/// the class as a mailbox for one function. @MainActor isolation is
/// explicit so the setter (called from PreviewView.bridgeCapture during
/// makeUIView) and the caller (ContentView's auto-catch) never race.
@MainActor
final class CameraCaptureBridge {
    var captureFunction: ((@escaping (Data?) -> Void) -> Void)?

    /// Awaits the next captured JPEG. Returns nil if no PreviewView has
    /// installed a capture function (i.e., camera wasn't authorized or
    /// session never started) or if the capture itself failed.
    func captureJPEG() async -> Data? {
        guard let fn = captureFunction else { return nil }
        return await withCheckedContinuation { continuation in
            fn { data in continuation.resume(returning: data) }
        }
    }
}

/// Mailbox for the visual-confirmation frame tap (same one-function-class
/// pattern as CameraCaptureBridge). The handler is invoked on the camera's
/// VIDEO queue at the tap's throttled rate — never on main. `nonisolated(unsafe)`
/// because the property is written once during view wiring (main) before
/// frames flow and only read afterwards (camera queue); the temporal
/// ordering makes the unguarded access safe, documented here rather than
/// paying for a lock on the per-frame hot path.
@MainActor
final class CameraFrameBridge {
    nonisolated(unsafe) var frameHandler: (@Sendable (CVPixelBuffer) -> Void)?
}

struct CameraPreview: UIViewRepresentable {
    /// Current zoom factor. ContentView owns the state; PreviewView
    /// no-ops if the value hasn't changed since the last apply (see
    /// `lastAppliedZoom`) — important because `updateUIView` fires on
    /// every body re-eval, which at 30 Hz would otherwise thrash
    /// `device.lockForConfiguration`.
    var zoomFactor: CGFloat = 1.0

    /// Optional bridge that PreviewView wires up so callers can grab
    /// a still photo. nil = ContentView doesn't need captures.
    var captureBridge: CameraCaptureBridge?

    /// Optional bridge for the visual-confirmation frame tap. nil = no
    /// video-frame delivery (the output isn't even added to the session).
    var frameBridge: CameraFrameBridge?

    /// Whether the capture session should be running. ContentView drives
    /// this from occlusion + scene state (2026-07-19 field report: the
    /// camera kept the ISP hot at 1080p/30 fps — plus a per-frame BGRA
    /// conversion — the whole time a Hangar/Profile sheet covered the AR
    /// view; the audit rated it the biggest controllable battery drain).
    /// While false the preview freezes on its last frame (invisible behind
    /// an opaque sheet); restarting takes ~0.3–0.5 s, mostly masked by the
    /// sheet's dismiss animation because SwiftUI flips this the moment the
    /// sheet state changes, before the animation finishes.
    var isActive: Bool = true

    /// Supported zoom range. Wide-camera digital zoom past ~5× shows
    /// mostly compression noise for the distances we care about.
    static let zoomRange: ClosedRange<CGFloat> = 1.0...5.0

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        if let bridge = frameBridge {
            view.bridgeFrames(to: bridge)   // before startSession so the
                                            // output joins the one config pass
        }
        view.startSession()
        if let bridge = captureBridge {
            view.bridgeCapture(to: bridge)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setZoom(zoomFactor)
        uiView.setSessionActive(isActive)
    }
}

/// A UIView whose backing layer is AVCaptureVideoPreviewLayer.
/// Trick: override layerClass so the view's `layer` property already is
/// the preview layer — no manual sublayer management.
final class PreviewView: UIView {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tailspot.camera.session")
    private let photoOutput = AVCapturePhotoOutput()
    /// Held so we can adjust `videoZoomFactor` after the session is up.
    private var device: AVCaptureDevice?
    /// Last zoom factor we actually pushed to the device. updateUIView
    /// runs on every SwiftUI body eval (~30 Hz here because of the
    /// TimelineView); without this guard we'd re-lock the device every
    /// frame for no change.
    private var lastAppliedZoom: CGFloat = 1.0
    /// Hold capture delegates alive until each AVCapture invocation
    /// finishes. AVCapturePhotoOutput uses a weak delegate reference.
    private var pendingCaptureDelegates: [PhotoCaptureDelegate] = []
    /// Visual-confirmation frame tap. Created in bridgeFrames(to:) BEFORE
    /// startSession so the video output is added during the single
    /// beginConfiguration pass; nil when no frameBridge was supplied.
    private var frameTap: FrameTapDelegate?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "tailspot.camera.video")

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func startSession() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        // Configuration + start are slow; do them off the main thread.
        sessionQueue.async { [session, photoOutput, frameTap, videoOutput, videoQueue] in
            session.beginConfiguration()
            session.sessionPreset = .high

            guard
                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                Log.ui.error("CameraPreview: failed to set up back camera")
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
                // Full-sensor stills. The `.high` preset picks a ~1080p
                // video format, and by default the photo output inherits
                // that as its still size — which put distant planes at
                // ~8–14 px in the saved photo, below the airplane
                // detector's ~15–20 px floor (CatchPhotoSnapper). Most
                // formats support 12 MP stills alongside 1080p video;
                // opt in to the largest the active format offers.
                // Must happen AFTER addOutput (the output needs a device
                // connection to know its supported dimensions).
                if let maxDims = device.activeFormat.supportedMaxPhotoDimensions
                    .max(by: { $0.width * $0.height < $1.width * $1.height }) {
                    photoOutput.maxPhotoDimensions = maxDims
                }
            }

            // Visual-confirmation frame tap: only when a bridge was wired.
            if let frameTap, session.canAddOutput(videoOutput) {
                videoOutput.videoSettings =
                    [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.setSampleBufferDelegate(frameTap, queue: videoQueue)
                session.addOutput(videoOutput)
                // Buffers arrive sensor-landscape by default; rotate to
                // portrait so frame pixels line up with the aspect-fill
                // preview (and therefore with AspectFillTransform's math).
                if let conn = videoOutput.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }
            }

            session.commitConfiguration()

            // Capture the device for later zoom updates. Read once on
            // the session queue; writes also go through that queue.
            DispatchQueue.main.async { self.device = device }
            session.startRunning()
        }
    }

    /// Desired running state, tracked on MAIN so `updateUIView`'s ~30 Hz
    /// calls no-op on the cheap path without a queue hop; actual
    /// start/stop transitions dispatch to the session queue (never main —
    /// startRunning/stopRunning block). The serial queue also orders a
    /// stop queued during initial configuration correctly AFTER the
    /// config block's startRunning.
    private var wantsRunning = true

    /// Start or stop the capture session. Stopping powers down the ISP +
    /// the 30 fps frame delivery while an opaque sheet covers the AR view
    /// (see `CameraPreview.isActive`); the preview layer keeps its last
    /// frame, so there's nothing to see even if a sliver were visible.
    func setSessionActive(_ wanted: Bool) {
        guard wanted != wantsRunning else { return }
        wantsRunning = wanted
        sessionQueue.async { [session] in
            if wanted {
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Wire this view's capture method into a `CameraCaptureBridge`
    /// so the SwiftUI side can request a still photo. Called once at
    /// `makeUIView` time by `CameraPreview`.
    func bridgeCapture(to bridge: CameraCaptureBridge) {
        bridge.captureFunction = { [weak self] completion in
            self?.capturePhoto(completion: completion)
        }
    }

    /// Wire the visual-confirmation frame tap. MUST be called before
    /// `startSession()` (CameraPreview.makeUIView does) so the video
    /// output is added during the single configuration pass.
    func bridgeFrames(to bridge: CameraFrameBridge) {
        frameTap = FrameTapDelegate(bridge: bridge)
    }

    /// Forwards throttled video frames to the CameraFrameBridge handler.
    /// `nonisolated` for the same Xcode-26 default-isolation reason as
    /// PhotoCaptureDelegate — AVFoundation calls this on `videoQueue`.
    private final nonisolated class FrameTapDelegate: NSObject,
        AVCaptureVideoDataOutputSampleBufferDelegate {

        /// Minimum spacing between delivered frames. The detector budget
        /// is ~8 fps (SWIFT-DESIGN.md); the camera produces 30–60.
        private static let minInterval: CFTimeInterval = 1.0 / 8.0

        private let bridge: CameraFrameBridge
        // Only ever touched on videoQueue (serial), so plain var is safe.
        nonisolated(unsafe) private var lastDelivery: CFTimeInterval = 0

        init(bridge: CameraFrameBridge) {
            self.bridge = bridge
        }

        func captureOutput(_ output: AVCaptureOutput,
                           didOutput sampleBuffer: CMSampleBuffer,
                           from connection: AVCaptureConnection) {
            let now = CACurrentMediaTime()
            guard now - lastDelivery >= Self.minInterval,
                  let handler = bridge.frameHandler,
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return }
            lastDelivery = now
            handler(pixelBuffer)
        }
    }

    /// Issue a still-photo capture with the default settings (JPEG).
    /// Calls `completion` once on whatever queue AVFoundation hands
    /// the callback on — typically a background queue, so callers
    /// should hop to MainActor before touching UI state.
    ///
    /// Delegates accumulate in `pendingCaptureDelegates` for the
    /// lifetime of this PreviewView. Capture rate is ~tens per session
    /// at most (you have to tap-pin + hold 3s for each), and each
    /// delegate is bytes — not worth the closure-capture ceremony of
    /// scrubbing them on completion.
    private func capturePhoto(completion: @escaping (Data?) -> Void) {
        let delegate = PhotoCaptureDelegate(completion: completion)
        pendingCaptureDelegates.append(delegate)
        sessionQueue.async { [photoOutput] in
            let settings = AVCapturePhotoSettings()
            // Ask for the full-sensor still the output was configured for
            // (per-capture settings default back to the video size
            // otherwise). Read on the session queue, where the output was
            // configured.
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            // The subject is a moving plane behind a hand-held phone:
            // shutter latency costs bracket accuracy (the tap→shutter
            // drift CatchPhotoSnapper corrects for), so skip the
            // multi-frame fusion pipelines.
            settings.photoQualityPrioritization = .speed
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }

    /// One-shot delegate that forwards the captured JPEG (or nil on
    /// error) to a closure. PreviewView keeps a reference in
    /// `pendingCaptureDelegates` until the callback fires because
    /// AVCapturePhotoOutput's delegate property is weak.
    ///
    /// `nonisolated` so the AVCapturePhotoCaptureDelegate conformance
    /// is also nonisolated — AVFoundation invokes the protocol method
    /// on a background queue, not MainActor. Under Xcode 26's
    /// default-MainActor isolation the conformance would otherwise be
    /// main-actor-bound and emit a Swift 6 warning. The completion
    /// closure runs on that background queue; existing callers hop to
    /// MainActor before touching UI state.
    private final nonisolated class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
        let completion: (Data?) -> Void
        init(completion: @escaping (Data?) -> Void) { self.completion = completion }

        func photoOutput(_ output: AVCapturePhotoOutput,
                         didFinishProcessingPhoto photo: AVCapturePhoto,
                         error: Error?) {
            if let error {
                Log.ui.error("Photo capture error: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            completion(photo.fileDataRepresentation())
        }
    }

    /// Set the camera zoom factor. Clamps to `CameraPreview.zoomRange`
    /// and skips the AVFoundation round-trip when the value matches
    /// the last applied one (updateUIView is called continuously).
    func setZoom(_ factor: CGFloat) {
        let clamped = min(max(CameraPreview.zoomRange.lowerBound, factor),
                          CameraPreview.zoomRange.upperBound)
        guard clamped != lastAppliedZoom else { return }
        lastAppliedZoom = clamped
        sessionQueue.async { [weak self] in
            guard let device = self?.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                Log.ui.error("CameraPreview: zoom set failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
