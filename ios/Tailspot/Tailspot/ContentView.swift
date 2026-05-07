//
//  ContentView.swift
//  Tailspot
//
//  Day 2 POC: camera background + sensor readout (top) + scrollable list
//  of nearby aircraft with their bearing/elevation/distance from us
//  (bottom). No projected labels yet — that's Day 3.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var location = LocationManager()
    @StateObject private var motion = MotionManager()
    @StateObject private var adsb = ADSBManager()
    @State private var cameraAuthorized = false

    var body: some View {
        ZStack {
            if cameraAuthorized {
                CameraPreview()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Per-aircraft AR labels: one over each plane that's currently
            // inside the camera's view frustum. GeometryReader gives us the
            // actual on-screen size; .position(_:) places each label at its
            // projected pixel coordinate.
            GeometryReader { geo in
                ForEach(adsb.observed) { obs in
                    if let pos = obs.screenPosition(
                        phoneHeadingDeg: location.heading ?? 0,
                        phonePitchDeg: motion.pitch * 180 / .pi,
                        in: geo.size
                    ) {
                        aircraftLabel(obs).position(pos)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)   // labels shouldn't eat taps from the readout / list

            VStack(spacing: 0) {
                sensorReadout
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                aircraftList
            }
        }
        .task {
            await requestCameraPermission()
            location.requestPermissionAndStart()
            motion.start()
            adsb.start { location.cllocation }
        }
    }

    // MARK: - AR label

    private func aircraftLabel(_ obs: ObservedAircraft) -> some View {
        let cs = obs.aircraft.callsign ?? obs.aircraft.icao24
        let fl = obs.aircraft.altitudeMeters / 30.48     // meters → flight level
        let dKm = obs.slantDistanceMeters / 1000

        return VStack(spacing: 1) {
            Image(systemName: "airplane")
                .font(.title3)
                .rotationEffect(.degrees((obs.aircraft.trackDeg ?? 0) - 90))
            Text(cs)
                .font(.caption2.monospaced().bold())
            Text(String(format: "FL%03.0f  %.0fkm", fl, dKm))
                .font(.system(size: 9, design: .monospaced))
        }
        .foregroundStyle(.white)
        .shadow(color: .black, radius: 2)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 4))
    }

    // MARK: - Top: sensor readout

    private var sensorReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tailspot — POC Day 2")
                .font(.headline)

            Group {
                Text(formatLocation())
                Text(formatHeading())
                Text(formatAttitude())
                adsbStatusRow
                if !cameraAuthorized {
                    Text("camera: not authorized")
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: .rect(cornerRadius: 12))
    }

    // MARK: - Bottom: nearby-aircraft list

    private var aircraftList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nearby aircraft (\(adsb.observed.count))")
                    .font(.caption.bold())
                Spacer()
                if let err = adsb.lastError {
                    Text(err).font(.caption2)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(adsb.observed) { obs in
                        aircraftRow(obs)
                    }
                    if adsb.observed.isEmpty {
                        Text(adsb.lastFetched == nil
                             ? "Waiting for first fetch…"
                             : "No aircraft in range.")
                            .font(.caption.monospaced())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 320)
        }
        .background(.black.opacity(0.7))
    }

    private func aircraftRow(_ obs: ObservedAircraft) -> some View {
        let cs = obs.aircraft.callsign ?? obs.aircraft.icao24
        let altKm = obs.aircraft.altitudeMeters / 1000
        let dKm = obs.slantDistanceMeters / 1000

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(cs)
                .frame(width: 70, alignment: .leading)
                .bold()
            Text(String(format: "brg %5.1f°", obs.bearingDeg))
                .frame(width: 86, alignment: .leading)
            Text(String(format: "el %+5.1f°", obs.elevationDeg))
                .frame(width: 76, alignment: .leading)
            Text(String(format: "%4.1fkm", dKm))
                .frame(width: 60, alignment: .leading)
            Text(String(format: "FL%03.0f", altKm * 32.8))
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
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

    private func formatADSBStatus() -> String {
        if let t = adsb.lastFetched {
            let secs = Int(Date().timeIntervalSince(t))
            return String(format: "ADSB:    %d aircraft, %ds ago", adsb.observed.count, secs)
        }
        return "ADSB:    fetching…"
    }

    /// Tap-to-toggle row: shows the ADS-B status text plus a [LIVE] /
    /// [MOCK] tag. Tapping anywhere on the row flips the source.
    private var adsbStatusRow: some View {
        HStack(spacing: 8) {
            Text(formatADSBStatus())
            Text(adsb.useMock ? "[MOCK]" : "[LIVE]")
                .foregroundStyle(adsb.useMock ? .yellow : .green)
                .bold()
            Spacer()
        }
        .contentShape(.rect)        // make the whole row hit-testable
        .onTapGesture {
            adsb.useMock.toggle()
        }
    }
}

#Preview {
    ContentView()
}
