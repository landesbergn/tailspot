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

    /// Supported zoom range. Wide-camera digital zoom past ~5× shows
    /// mostly compression noise for the distances we care about.
    static let zoomRange: ClosedRange<CGFloat> = 1.0...5.0

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.startSession()
        if let bridge = captureBridge {
            view.bridgeCapture(to: bridge)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setZoom(zoomFactor)
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

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func startSession() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        // Configuration + start are slow; do them off the main thread.
        sessionQueue.async { [session, photoOutput] in
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
            }

            session.commitConfiguration()

            // Capture the device for later zoom updates. Read once on
            // the session queue; writes also go through that queue.
            DispatchQueue.main.async { self.device = device }
            session.startRunning()
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
        let settings = AVCapturePhotoSettings()
        let delegate = PhotoCaptureDelegate(completion: completion)
        pendingCaptureDelegates.append(delegate)
        sessionQueue.async { [photoOutput] in
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
