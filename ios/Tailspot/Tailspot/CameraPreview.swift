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

struct CameraPreview: UIViewRepresentable {
    /// Current zoom factor. ContentView owns the state; PreviewView
    /// no-ops if the value hasn't changed since the last apply (see
    /// `lastAppliedZoom`) — important because `updateUIView` fires on
    /// every body re-eval, which at 30 Hz would otherwise thrash
    /// `device.lockForConfiguration`.
    var zoomFactor: CGFloat = 1.0

    /// Supported zoom range. Wide-camera digital zoom past ~5× shows
    /// mostly compression noise for the distances we care about.
    static let zoomRange: ClosedRange<CGFloat> = 1.0...5.0

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.startSession()
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
    /// Held so we can adjust `videoZoomFactor` after the session is up.
    private var device: AVCaptureDevice?
    /// Last zoom factor we actually pushed to the device. updateUIView
    /// runs on every SwiftUI body eval (~30 Hz here because of the
    /// TimelineView); without this guard we'd re-lock the device every
    /// frame for no change.
    private var lastAppliedZoom: CGFloat = 1.0

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    private var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    func startSession() {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill

        // Configuration + start are slow; do them off the main thread.
        sessionQueue.async { [session] in
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
            session.commitConfiguration()

            // Capture the device for later zoom updates. Read once on
            // the session queue; writes also go through that queue.
            DispatchQueue.main.async { self.device = device }
            session.startRunning()
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
