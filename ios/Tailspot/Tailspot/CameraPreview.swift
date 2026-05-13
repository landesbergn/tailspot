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

import SwiftUI
import AVFoundation
import os

struct CameraPreview: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.startSession()
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Nothing dynamic to push down for now.
    }
}

/// A UIView whose backing layer is AVCaptureVideoPreviewLayer.
/// Trick: override layerClass so the view's `layer` property already is
/// the preview layer — no manual sublayer management.
final class PreviewView: UIView {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "tailspot.camera.session")

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

            session.startRunning()
        }
    }
}
