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
    @State private var selectedAircraft: ObservedAircraft?

    var body: some View {
        ZStack {
            if cameraAuthorized {
                CameraPreview()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Per-aircraft AR reticles: one over each plane currently inside
            // the camera's view frustum. GeometryReader gives us the actual
            // on-screen size; .position(_:) places each at its projected
            // pixel. The reticle itself is tappable — opens the detail sheet.
            GeometryReader { geo in
                // Only show AR labels for aircraft that are plausibly
                // visible to the naked eye — above the horizon and
                // close enough to actually see. Full list (with
                // out-of-sight aircraft included) stays in the bottom
                // panel for reference. Doesn't model obstacles,
                // weather, etc. — see ObservedAircraft.isLikelyVisibleToObserver.
                ForEach(adsb.observed.filter(\.isLikelyVisibleToObserver)) { obs in
                    if let pos = obs.screenPosition(
                        phoneHeadingDeg: location.heading ?? 0,
                        cameraElevationDeg: motion.cameraElevationDeg,
                        in: geo.size
                    ) {
                        aircraftReticle(obs)
                            .position(pos)
                            .onTapGesture { selectedAircraft = obs }
                    }
                }
            }
            .ignoresSafeArea()

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
        .sheet(item: $selectedAircraft) { obs in
            AircraftDetailView(observed: obs)
        }
    }

    // MARK: - AR reticle

    /// Reticle box + compact label below. Box is hollow so the actual
    /// plane shows through the camera view inside it. Compound view is
    /// tappable; tapping opens AircraftDetailView for this aircraft.
    private func aircraftReticle(_ obs: ObservedAircraft) -> some View {
        let cs = obs.aircraft.callsign ?? obs.aircraft.icao24
        let fl = obs.aircraft.altitudeMeters / 30.48     // meters → flight level
        let dKm = obs.slantDistanceMeters / 1000

        return VStack(spacing: 4) {
            Rectangle()
                .stroke(Color.cyan, lineWidth: 1.5)
                .frame(width: 50, height: 50)

            VStack(spacing: 1) {
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
        .contentShape(.rect)   // make the gap between box and label hit-testable too
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
                        Text(emptyListMessage)
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
        let camElDeg = motion.cameraElevationDeg
        return String(format: "Tilt:    pitch %5.1f°  cam-el %+5.1f°  roll %5.1f°",
                      pitchDeg, camElDeg, rollDeg)
    }

    /// Empty-state message for the bottom list. Surfaces the actual
    /// reason — error, no fix yet, or just no traffic — instead of the
    /// blanket "Waiting for first fetch…" which used to stick around
    /// even after a failure.
    private var emptyListMessage: String {
        if let err = adsb.lastError { return err }
        if adsb.lastFetched == nil  { return "Waiting for first fetch…" }
        return "No aircraft in range."
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
