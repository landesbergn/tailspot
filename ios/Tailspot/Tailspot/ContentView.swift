//
//  ContentView.swift
//  Tailspot
//
//  Day 1 POC: camera background + live sensor readout overlay.
//  No planes yet — that's tomorrow.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var motion = MotionManager()
    @State private var cameraAuthorized = false

    var body: some View {
        ZStack {
            if cameraAuthorized {
                CameraPreview()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Tailspot — POC Day 1")
                    .font(.headline)

                Group {
                    Text(formatLocation())
                    Text(formatHeading())
                    Text(formatAttitude())
                    if !cameraAuthorized {
                        Text("camera: not authorized")
                    }
                }
                .font(.system(.caption, design: .monospaced))
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task {
            await requestCameraPermission()
            location.requestPermissionAndStart()
            motion.start()
        }
    }

    // MARK: - Permission

    private func requestCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            cameraAuthorized = false
        @unknown default:
            cameraAuthorized = false
        }
    }

    // MARK: - Formatting

    private func formatLocation() -> String {
        guard let lat = location.latitude, let lon = location.longitude else {
            return "GPS:     waiting…"
        }
        let alt = location.altitude ?? 0
        let acc = location.horizontalAccuracy ?? -1
        return String(format: "GPS:     %.5f°, %.5f°  alt %.0fm  ±%.0fm", lat, lon, alt, acc)
    }

    private func formatHeading() -> String {
        guard let h = location.heading else { return "Heading: waiting…" }
        let acc = location.headingAccuracy ?? -1
        return String(format: "Heading: %6.1f°  ±%.1f°", h, acc)
    }

    private func formatAttitude() -> String {
        let pitchDeg = motion.pitch * 180 / .pi
        let rollDeg = motion.roll * 180 / .pi
        return String(format: "Tilt:    pitch %5.1f°  roll %5.1f°", pitchDeg, rollDeg)
    }
}

#Preview {
    ContentView()
}
