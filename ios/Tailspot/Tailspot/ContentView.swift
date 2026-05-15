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
    @StateObject private var lockOn = LockOnEngine()
    @State private var cameraAuthorized = false
    @State private var selectedAircraft: ObservedAircraft?
    /// Hidden by default. Tap the small wrench glyph in the top-right
    /// to reveal the sensor readout (top) + nearby-aircraft list
    /// (bottom). Field-testing UI is intentionally clean; raw sensor
    /// dumps are for inspection, not normal use.
    @State private var showDebug = false
    /// Metadata for whatever plane the lock engine is currently
    /// tracking. Fetched lazily through ADSBManager.metadata(for:),
    /// which consults its in-memory cache first; only first time we
    /// see an icao24 actually hits OpenSky. Kicked off the moment
    /// acquisition starts (driven by .task(id:) on targetIcao24) so
    /// by the time the lock snaps green, the label content is usually
    /// already populated.
    @State private var lockedMetadata: AircraftMetadata?

    var body: some View {
        ZStack {
            if cameraAuthorized {
                CameraPreview()
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Lock-on AR overlay. The view is clean by default — no
            // crosshair, no per-aircraft labels. As the user aims at
            // a plane (within lockZoneRadius of screen center), yellow
            // brackets close in for ~0.6 s, then snap green and a
            // compact label identifies the plane. Tap the locked
            // label to open the detail sheet (with the Catch button).
            //
            // The 30 Hz TimelineView drives both the engine state
            // transitions and the bracket animation. The engine is a
            // pure state machine — repeated update() calls with the
            // same target are idempotent — so calling it from inside
            // the TimelineView body is safe.
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
                    let now = context.date
                    let visible = adsb.observed.filter(\.isLikelyVisibleToObserver)
                    let heading = location.heading ?? 0
                    let camEl = motion.cameraElevationDeg

                    let closest = closestTargetIcao24(
                        in: visible,
                        phoneHeadingDeg: heading,
                        cameraElevationDeg: camEl,
                        screenSize: geo.size
                    )
                    // `let _` so the void-returning call is legal
                    // inside @ViewBuilder (statements aren't otherwise).
                    let _ = lockOn.update(closestTargetIcao24: closest, now: now)

                    ZStack {
                        if let icao = lockOn.state.targetIcao24,
                           let target = visible.first(where: { $0.aircraft.icao24 == icao }),
                           let pos = target.screenPosition(
                               phoneHeadingDeg: heading,
                               cameraElevationDeg: camEl,
                               in: geo.size
                           )
                        {
                            lockOverlay(
                                state: lockOn.state,
                                target: target,
                                metadata: lockedMetadata,
                                now: now
                            )
                                .position(pos)
                                .onTapGesture { selectedAircraft = target }
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .ignoresSafeArea()

            // Debug overlays — hidden by default; revealed by the
            // wrench toggle below.
            if showDebug {
                VStack(spacing: 0) {
                    sensorReadout
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)

                    aircraftList
                }
                .transition(.opacity)
            }

            // Small discrete toggle in the top-trailing corner.
            VStack {
                HStack {
                    Spacer()
                    debugToggleButton
                        .padding(.top, 8)
                        .padding(.trailing, 12)
                }
                Spacer()
            }
        }
        .task {
            await requestCameraPermission()
            location.requestPermissionAndStart()
            motion.start()
            adsb.start { location.cllocation }
        }
        // Re-runs whenever the lock engine switches to (or away from)
        // a target icao. Hits ADSBManager.metadata(for:) — instant on
        // a cache hit, single OpenSky call on miss.
        .task(id: lockOn.state.targetIcao24) {
            if let icao = lockOn.state.targetIcao24 {
                lockedMetadata = await adsb.metadata(for: icao)
            } else {
                lockedMetadata = nil
            }
        }
        .sheet(item: $selectedAircraft) { obs in
            AircraftDetailView(observed: obs, manager: adsb, observerLocation: location.cllocation)
        }
    }

    // MARK: - Debug toggle

    /// Small wrench glyph in the top-trailing corner; tap to toggle
    /// the sensor readout + aircraft-list overlays. Low-contrast on
    /// purpose so it doesn't compete with the AR view.
    private var debugToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                showDebug.toggle()
            }
        } label: {
            Image(systemName: showDebug ? "wrench.fill" : "wrench")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(showDebug ? 0.9 : 0.45))
                .padding(8)
                .background(.black.opacity(showDebug ? 0.45 : 0.20), in: .circle)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .accessibilityLabel(showDebug ? "Hide debug overlays" : "Show debug overlays")
    }

    // MARK: - Lock-on visuals

    /// Brackets + label rendered at a target's projected screen
    /// position. Style + size depend on the lock-on state:
    /// `acquiring` → yellow brackets easing inward from a larger box;
    /// `locked` / `sticky` → solid green brackets at the steady size,
    /// with the identification label.
    @ViewBuilder
    private func lockOverlay(
        state: LockOnEngine.State,
        target: ObservedAircraft,
        metadata: AircraftMetadata?,
        now: Date
    ) -> some View {
        let style = lockOverlayStyle(for: state, now: now)
        VStack(spacing: 4) {
            LockBrackets(boxSize: style.boxSize, color: style.color, opacity: style.opacity)
            if style.showLabel {
                lockLabel(target, metadata: metadata)
                    .opacity(style.opacity)
            }
        }
        .contentShape(.rect)
    }

    /// Visual parameters derived from engine state + current time.
    private struct LockOverlayStyle {
        var boxSize: CGFloat
        var color: Color
        var opacity: Double
        var showLabel: Bool
    }

    private func lockOverlayStyle(for state: LockOnEngine.State, now: Date) -> LockOverlayStyle {
        let lockedSize: CGFloat = 64
        let acquiringSizeMax: CGFloat = 150
        switch state {
        case .idle:
            return .init(boxSize: 0, color: .clear, opacity: 0, showLabel: false)
        case .acquiring:
            let p = lockOn.acquisitionProgress(now: now)
            let size = acquiringSizeMax - (acquiringSizeMax - lockedSize) * CGFloat(p)
            // Fade in as we acquire.
            let opacity = 0.35 + 0.55 * p
            return .init(boxSize: size, color: .yellow, opacity: opacity, showLabel: false)
        case .locked:
            return .init(boxSize: lockedSize, color: .green, opacity: 1.0, showLabel: true)
        case .sticky(_, let lostAt):
            // Fade the brackets but keep them visible for the
            // stickyHoldDuration window so the user can read the label.
            let elapsed = now.timeIntervalSince(lostAt)
            let fade = max(0, 1 - elapsed / lockOn.stickyHoldDuration)
            return .init(boxSize: lockedSize, color: .green, opacity: fade, showLabel: true)
        }
    }

    /// Identification card shown below a locked target. Four lines
    /// in decreasing emphasis: callsign, airline (operator), make +
    /// model, altitude + speed. Lines for which we don't yet have
    /// data are simply omitted — keeps the card from filling with
    /// dashes while the metadata fetch is in flight.
    private func lockLabel(_ obs: ObservedAircraft, metadata: AircraftMetadata?) -> some View {
        let cs = obs.aircraft.callsign ?? obs.aircraft.icao24
        let airline = metadata?.operatorName
        let makeModel: String? = {
            switch (metadata?.manufacturerName, metadata?.model) {
            case let (mfg?, model?): return "\(mfg) \(model)"
            case let (mfg?, nil):    return mfg
            case let (nil, model?):  return model
            default:                 return nil
            }
        }()
        let altFt = Int((obs.aircraft.altitudeMeters * 3.28084).rounded())
        let altText = "\(altFt.formatted(.number)) ft"
        let speedText: String? = obs.aircraft.velocityMps.map {
            "\(Int(($0 * 2.23694).rounded())) mph"
        }
        let stats = [altText, speedText].compactMap(\.self).joined(separator: "  ·  ")

        return VStack(alignment: .leading, spacing: 1) {
            Text(cs)
                .font(.caption.monospaced().bold())
                .foregroundStyle(.white)

            if let airline {
                Text(airline)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.95))
            }
            if let makeModel {
                Text(makeModel)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text(stats)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
        .shadow(color: .black, radius: 2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: .rect(cornerRadius: 4))
    }

    // MARK: - Top: sensor readout

    private var sensorReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tailspot — POC Day 2")
                .font(.headline)

            Group {
                Text(formatLocation())
                Text(formatHeading())
                    .foregroundStyle(isHeadingAccuracyBad ? .red : .white)
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
        // Same predicate as the AR layer: above horizon + within
        // maxVisibleDistanceMeters. Keeps the bottom panel honest with
        // what's on-screen instead of dumping the full 50 km bbox.
        let visible = adsb.observed.filter(\.isLikelyVisibleToObserver)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Nearby aircraft (\(visible.count))")
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
                    ForEach(visible) { obs in
                        aircraftRow(obs)
                    }
                    if visible.isEmpty {
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

    /// True when CL reports a poor heading fix (>15°). Drives the
    /// red-text cue on the heading readout so the user notices the
    /// compass needs calibration (figure-8 the phone). Negative
    /// values mean "unknown" — treat as neutral, not bad.
    private var isHeadingAccuracyBad: Bool {
        guard let acc = location.headingAccuracy else { return false }
        return acc > 15
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

// MARK: - Lock-on bracket shapes

/// Four L-shaped corner brackets around a center point, sized to
/// boxSize. Drawn as four separate strokes so the arms have round
/// caps and don't render a closed-rectangle look.
private struct LockBrackets: View {
    let boxSize: CGFloat
    let color: Color
    let opacity: Double
    var armLength: CGFloat { max(8, boxSize * 0.22) }
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            CornerBracket(armLength: armLength, corner: .topLeft)
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
            CornerBracket(armLength: armLength, corner: .topRight)
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
            CornerBracket(armLength: armLength, corner: .bottomLeft)
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
            CornerBracket(armLength: armLength, corner: .bottomRight)
                .stroke(color, style: .init(lineWidth: lineWidth, lineCap: .round))
        }
        .frame(width: boxSize, height: boxSize)
        .opacity(opacity)
    }
}

private enum BracketCorner { case topLeft, topRight, bottomLeft, bottomRight }

private struct CornerBracket: Shape {
    let armLength: CGFloat
    let corner: BracketCorner

    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch corner {
        case .topLeft:
            p.move(to: CGPoint(x: 0, y: armLength))
            p.addLine(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: armLength, y: 0))
        case .topRight:
            p.move(to: CGPoint(x: rect.width - armLength, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: armLength))
        case .bottomLeft:
            p.move(to: CGPoint(x: 0, y: rect.height - armLength))
            p.addLine(to: CGPoint(x: 0, y: rect.height))
            p.addLine(to: CGPoint(x: armLength, y: rect.height))
        case .bottomRight:
            p.move(to: CGPoint(x: rect.width - armLength, y: rect.height))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height - armLength))
        }
        return p
    }
}

#Preview {
    ContentView()
}
