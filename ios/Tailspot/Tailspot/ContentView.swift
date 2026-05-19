//
//  ContentView.swift
//  Tailspot
//
//  Day 2 POC: camera background + sensor readout (top) + scrollable list
//  of nearby aircraft with their bearing/elevation/distance from us
//  (bottom). No projected labels yet — that's Day 3.
//

import SwiftUI
import SwiftData
import AVFoundation
import os

struct ContentView: View {
    /// Camera FOV at 1× zoom (approximate for iPhone 16 main wide camera
    /// in portrait). The effective FOV passed to projection math is
    /// these divided by the current `zoom` factor — at 2× the visible
    /// world halves horizontally and vertically. Refine when we query
    /// `AVCaptureDevice.activeFormat.videoFieldOfView` (which gives
    /// only horizontal); for v0 the approximation is good enough.
    private static let baseHfovDeg: Double = 56
    private static let baseVfovDeg: Double = 72

    @StateObject private var location = LocationManager()
    @StateObject private var motion = MotionManager()
    @StateObject private var adsb = ADSBManager()
    @StateObject private var lockOn = LockOnEngine()
    /// Field-session recorder for replay/regression. Off by default;
    /// the debug overlay carries a tap-to-start row. When active a 1 Hz
    /// task captures the current sensor state + visible aircraft and
    /// appends a tick line to `Documents/replays/replay-<utc>.jsonl`.
    @StateObject private var recorder = ReplayRecorder()
    @State private var cameraAuthorized = false
    @State private var selectedAircraft: ObservedAircraft?
    /// Hidden by default. Tap the small wrench glyph in the top-right
    /// to reveal the sensor readout (top) + nearby-aircraft list
    /// (bottom). Field-testing UI is intentionally clean; raw sensor
    /// dumps are for inspection, not normal use.
    @State private var showDebug = false
    /// Drives the Hangar sheet (collection of past catches). Opened
    /// via the tray glyph in the top-trailing corner.
    @State private var showHangar = false
    /// Lightweight @Query used only to render the catch-count badge
    /// on the Hangar button. HangarView runs its own @Query for the
    /// actual list — keeping these separate means ContentView's body
    /// doesn't re-evaluate the full sorted list on every catch.
    @Query private var catches: [Catch]
    /// Metadata for whatever plane the lock engine is currently
    /// tracking. Fetched lazily through ADSBManager.metadata(for:),
    /// which consults its in-memory cache first; only first time we
    /// see an icao24 actually hits OpenSky. Kicked off the moment
    /// acquisition starts (driven by .task(id:) on targetIcao24) so
    /// by the time the lock snaps green, the label content is usually
    /// already populated.
    @State private var lockedMetadata: AircraftMetadata?
    /// Camera zoom factor. 1.0 = default wide. Pinch gesture below
    /// drives the binding; CameraPreview applies it via
    /// AVCaptureDevice.videoZoomFactor. The projection math also reads
    /// this to shrink the effective FOV so lock brackets stay glued
    /// to planes as the user zooms in.
    @State private var zoom: CGFloat = 1.0
    /// Zoom at the moment the current pinch started — the gesture's
    /// `magnification` value is a *relative* scale (1.0 at gesture
    /// start), so we multiply against this to get the new absolute zoom.
    @State private var zoomGestureBase: CGFloat = 1.0
    /// When the user taps a plane directly, we pin the lock to that
    /// icao24 — overriding the center-driven closest-target heuristic.
    /// Tap-elsewhere clears; tap-same-plane toggles off; the plane
    /// leaving visibility also clears. The pin is what makes the
    /// engine `forceLock()` snap-green-instantly instead of running a
    /// 0.6 s acquisition.
    @State private var pinnedIcao: String?
    /// URL of the recording the user wants to analyze. Non-nil →
    /// `ReplayReportView` sheet is presented for that file.
    @State private var replayURL: URL?
    /// Opacity of the launch splash screen. Starts at 1.0 (opaque),
    /// animates to 0 after ~600ms, then the AR view underneath becomes
    /// interactive. The splash absorbs taps for the first half of the
    /// fade so no gestures fire while it's mostly visible.
    @State private var splashOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Main AR view and overlays (camera, lock brackets, debug panels, etc.)
            ZStack {
                if cameraAuthorized {
                    CameraPreview(zoomFactor: zoom)
                        .ignoresSafeArea()
                } else {
                    Brand.Color.bgPrimary.ignoresSafeArea()
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
                    let effectiveHfov = Self.baseHfovDeg / zoom
                    let effectiveVfov = Self.baseVfovDeg / zoom

                    TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
                        let now = context.date
                        let visible = adsb.observed.filter(\.isLikelyVisibleToObserver)
                        let heading = location.heading ?? 0
                        let camEl = motion.cameraElevationDeg

                        // Target choice: the explicit tap-pinned plane (if
                        // still visible) wins; otherwise fall back to
                        // whichever visible plane is nearest to screen
                        // center. A pin pointing at a no-longer-visible
                        // plane is ignored here; the .onChange on lockOn
                        // state clears it for next frame.
                        let centerClosest = closestTargetIcao24(
                            in: visible,
                            phoneHeadingDeg: heading,
                            cameraElevationDeg: camEl,
                            screenSize: geo.size,
                            hfovDeg: effectiveHfov,
                            vfovDeg: effectiveVfov
                        )
                        let pinStillVisible = pinnedIcao.map { id in
                            visible.contains { $0.aircraft.icao24 == id }
                        } ?? false
                        let engineTarget = pinStillVisible ? pinnedIcao : centerClosest
                        // `let _` so the void-returning call is legal
                        // inside @ViewBuilder (statements aren't otherwise).
                        let _ = lockOn.update(closestTargetIcao24: engineTarget, now: now)

                        ZStack {
                            // Background tap-and-pinch layer. Color.clear +
                            // contentShape makes the whole AR area receive
                            // gestures; the lock-label's own tap (further
                            // up the Z-stack) still wins for taps that
                            // land on it because innermost-first wins.
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let next = zoomGestureBase * CGFloat(value)
                                            zoom = min(max(CameraPreview.zoomRange.lowerBound, next),
                                                       CameraPreview.zoomRange.upperBound)
                                        }
                                        .onEnded { _ in zoomGestureBase = zoom }
                                )
                                .simultaneousGesture(
                                    SpatialTapGesture()
                                        .onEnded { event in
                                            handleTap(
                                                at: event.location,
                                                in: geo.size,
                                                visible: visible,
                                                phoneHeadingDeg: heading,
                                                cameraElevationDeg: camEl,
                                                hfovDeg: effectiveHfov,
                                                vfovDeg: effectiveVfov,
                                                now: now
                                            )
                                        }
                                )

                            if let icao = lockOn.state.targetIcao24,
                               let target = visible.first(where: { $0.aircraft.icao24 == icao }),
                               let pos = target.screenPosition(
                                   phoneHeadingDeg: heading,
                                   cameraElevationDeg: camEl,
                                   in: geo.size,
                                   hfovDeg: effectiveHfov,
                                   vfovDeg: effectiveVfov
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

                // Zoom indicator. Faint pill in the top-center; hidden at 1.0×.
                if zoom > 1.01 {
                    VStack {
                        Text(String(format: "%.1f×", zoom))
                            .font(.system(.caption, design: .monospaced).bold())
                            .foregroundStyle(Brand.Color.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
                            .padding(.top, 12)
                            .transition(.opacity)
                        Spacer()
                    }
                }

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

                // Top-trailing controls: hangar (collection) then debug
                // wrench. Both are discrete so they don't compete with
                // the AR overlay; hangar gets a small green count badge
                // when there's something to see.
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        hangarButton
                        debugToggleButton
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    Spacer()
                }
            }

            // Launch splash screen: brand lockup centered on near-black
            // background. Holds for ~600ms then crossfades to the AR view.
            // Absorbs taps for the first half of its fade.
            splashOverlay
        }
        .sheet(isPresented: $showHangar) {
            HangarView()
        }
        .task {
            // Dismiss the launch splash after ~600ms, then crossfade to
            // the AR view over 400ms. This runs once when ContentView
            // first appears (no id: to retrigger), so the splash fires
            // exactly at launch.
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeOut(duration: 0.4)) {
                splashOpacity = 0
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
        // Pin housekeeping. If the engine moved off the pinned plane
        // (target left visibility → sticky → idle, or center-driven
        // logic switched onto a different plane), clear the pin so
        // we stop fighting the engine on the next frame.
        .onChange(of: lockOn.state.targetIcao24) { _, newIcao in
            if let pin = pinnedIcao, newIcao != pin {
                pinnedIcao = nil
            }
        }
        // 1 Hz replay capture loop. Re-launches whenever the recorder
        // toggles on; tears down when it toggles off (Task is cancelled
        // because .task(id:) re-runs on id change).
        .task(id: recorder.isRecording) {
            guard recorder.isRecording else { return }
            while recorder.isRecording, !Task.isCancelled {
                recordReplayTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $selectedAircraft) { obs in
            AircraftDetailView(observed: obs, manager: adsb, observerLocation: location.cllocation)
        }
        .sheet(isPresented: Binding(
            get: { replayURL != nil },
            set: { if !$0 { replayURL = nil } }
        )) {
            if let replayURL {
                ReplayReportView(url: replayURL)
            } else {
                EmptyView()
            }
        }
    }

    // MARK: - Hangar entry

    /// Tray glyph in the top-trailing corner with a green count
    /// badge. Tapping presents `HangarView` as a sheet. The badge
    /// is hidden when the user has no catches yet — keeps the AR
    /// view from showing a "0" they have no context for.
    private var hangarButton: some View {
        Button {
            showHangar = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.85))
                    .padding(8)
                    .background(Brand.Color.bgPrimary.opacity(0.35), in: .circle)
                    .shadow(color: .black.opacity(0.5), radius: 2)

                if !catches.isEmpty {
                    Text("\(catches.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Brand.Color.alertNormal, in: .capsule)
                        .offset(x: 6, y: -4)
                }
            }
        }
        .accessibilityLabel("Open hangar (\(catches.count) catches)")
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
                .foregroundStyle(Brand.Color.textPrimary.opacity(showDebug ? 0.9 : 0.45))
                .padding(8)
                .background(Brand.Color.bgPrimary.opacity(showDebug ? 0.45 : 0.20), in: .circle)
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
        .accessibilityLabel(showDebug ? "Hide debug overlays" : "Show debug overlays")
    }

    // MARK: - Launch splash

    /// Brand splash screen: centered airplane glyph + TAILSPOT wordmark
    /// on a near-black background. Shown at launch for ~600ms, then
    /// crossfades to transparent. The splash absorbs taps for the first
    /// half of its fade to prevent accidental AR gestures mid-animation.
    @ViewBuilder
    private var splashOverlay: some View {
        if splashOpacity > 0 {
            ZStack {
                Brand.Color.bgPrimary.ignoresSafeArea()
                HStack(spacing: 14) {
                    Image(systemName: "airplane")
                        .font(.system(size: 56))
                        .foregroundStyle(Brand.Color.cyan)
                    Text("TAILSPOT")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(Brand.Color.textPrimary)
                        .tracking(4)
                }
            }
            .opacity(splashOpacity)
            .allowsHitTesting(splashOpacity > 0.5)
        }
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
        // Cyan is the brand color and it OWNS the lock indicator.
        // Acquiring still uses amber to telegraph "warming up" via
        // color (caution = "future action might be needed"), then
        // snaps to brand cyan on lock. Tap-pin and auto-lock look
        // identical — the user gets there via different paths but
        // the result is the same "you have it."
        switch state {
        case .idle:
            return .init(boxSize: 0, color: .clear, opacity: 0, showLabel: false)
        case .acquiring:
            let p = lockOn.acquisitionProgress(now: now)
            let size = acquiringSizeMax - (acquiringSizeMax - lockedSize) * CGFloat(p)
            // Fade in as we acquire.
            let opacity = 0.35 + 0.55 * p
            return .init(boxSize: size, color: Brand.Color.alertCaution, opacity: opacity, showLabel: false)
        case .locked:
            return .init(boxSize: lockedSize, color: Brand.Color.cyan, opacity: 1.0, showLabel: true)
        case .sticky(_, let lostAt):
            // Fade the brackets but keep them visible for the
            // stickyHoldDuration window so the user can read the label.
            let elapsed = now.timeIntervalSince(lostAt)
            let fade = max(0, 1 - elapsed / lockOn.stickyHoldDuration)
            return .init(boxSize: lockedSize, color: Brand.Color.cyan, opacity: fade, showLabel: true)
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
                .font(Brand.Font.hudCallsign)
                .foregroundStyle(Brand.Color.cyan)

            if let airline {
                Text(airline)
                    .font(Brand.Font.hudData)
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.95))
            }
            if let makeModel {
                Text(makeModel)
                    .font(Brand.Font.hudData)
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.85))
            }

            Text(stats)
                .font(Brand.Font.hudData)
                .foregroundStyle(Brand.Color.textPrimary.opacity(0.85))
        }
        .shadow(color: .black, radius: 2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Brand.Color.bgPrimary.opacity(0.65), in: .rect(cornerRadius: 4))
    }

    // MARK: - Top: sensor readout

    private var sensorReadout: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tailspot — POC Day 2")
                .font(.headline)

            Group {
                Text(formatLocation())
                Text(formatHeading())
                    .foregroundStyle(isHeadingAccuracyBad ? Brand.Color.alertCaution : Brand.Color.textPrimary)
                Text(formatAttitude())
                adsbStatusRow
                recordingRow
                analyzeRow
                if !cameraAuthorized {
                    Text("camera: not authorized")
                }
            }
            .font(.system(.caption, design: .monospaced))
        }
        .foregroundStyle(Brand.Color.textPrimary)
        .padding(12)
        .background(Brand.Color.bgPrimary.opacity(0.55), in: .rect(cornerRadius: 12))
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
            .foregroundStyle(Brand.Color.textPrimary)
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
                            .foregroundStyle(Brand.Color.textPrimary.opacity(0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: 320)
        }
        .background(Brand.Color.bgPrimary.opacity(0.7))
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
                .foregroundStyle(Brand.Color.textPrimary.opacity(0.7))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(Brand.Color.textPrimary)
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
                .foregroundStyle(adsb.useMock ? Brand.Color.alertCaution : Brand.Color.alertNormal)
                .bold()
            Spacer()
        }
        .contentShape(.rect)        // make the whole row hit-testable
        .onTapGesture {
            adsb.useMock.toggle()
        }
    }

    /// Tap-to-toggle row for the replay recorder. Idle → "Record
    /// session"; active → "REC <count>  <basename>" with a red dot.
    /// File lands in `Documents/replays/`; retrieve via
    /// `xcrun devicectl device copy from --device <udid>
    /// --domain-type appDataContainer
    /// --domain-identifier com.landesberg.Tailspot
    /// --source Documents/replays --destination ./replays`.
    private var recordingRow: some View {
        HStack(spacing: 8) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(recorder.isRecording ? Brand.Color.alertWarning : Brand.Color.textPrimary.opacity(0.85))
            if recorder.isRecording {
                Text("REC \(recorder.eventCount)  \(recorder.currentFileURL?.lastPathComponent ?? "—")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Record session")
            }
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture {
            toggleRecording()
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            do {
                _ = try recorder.start()
            } catch {
                Log.ui.error("Failed to start replay recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Debug-overlay row that loads the most recent recording from
    /// `Documents/replays/` and presents `ReplayReportView`. Disabled
    /// (greyed) when there are no recordings on disk — a one-off
    /// FileManager check on every body eval is cheap enough.
    private var analyzeRow: some View {
        let latest = ReplayRecorder.mostRecentRecording()
        return HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(latest == nil ? Brand.Color.textTertiary : Brand.Color.textPrimary.opacity(0.85))
            Text(latest.map { "Analyze \($0.lastPathComponent)" }
                 ?? "No recordings yet")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .contentShape(.rect)
        .opacity(latest == nil ? 0.5 : 1.0)
        .onTapGesture {
            if let latest { replayURL = latest }
        }
    }

    /// One tick's worth of sensor state + the currently-visible ADS-B
    /// snapshot. Fed to the recorder by the 1 Hz loop above. Captures
    /// the current zoom factor so the analyzer can reconstruct the
    /// effective FOV when replaying.
    private func recordReplayTick() {
        let visible = adsb.observed.filter(\.isLikelyVisibleToObserver)
        let tick = ReplayEvent.Tick(
            timestamp: Date(),
            sensor: .init(
                latitude: location.latitude,
                longitude: location.longitude,
                altitudeMeters: location.altitude,
                horizontalAccuracyMeters: location.horizontalAccuracy,
                headingDeg: location.heading,
                headingAccuracyDeg: location.headingAccuracy,
                pitchRad: motion.pitch,
                rollRad: motion.roll,
                yawRad: motion.yaw,
                cameraElevationDeg: motion.cameraElevationDeg,
                zoomFactor: Double(zoom)
            ),
            aircraft: visible.map { ReplayEvent.AircraftSnapshot($0.aircraft) }
        )
        recorder.recordTick(tick)
    }

    // MARK: - Tap-to-ID

    /// Tap handler for the AR overlay. Three outcomes:
    ///   - Tapped on (or very near) the currently-pinned plane → toggle
    ///     off, fall back to center-driven lock.
    ///   - Tapped near a different visible plane → pin to it and
    ///     `forceLock` the engine straight to green (no acquisition
    ///     delay — the tap is an explicit choice).
    ///   - Tapped in empty sky (no plane within the tap zone) → clear
    ///     any active pin.
    ///
    /// `tapZoneRadius` is generous (100 px) so users don't have to be
    /// pixel-perfect; at high zoom planes are spread apart on screen
    /// so the ambiguity is small.
    private func handleTap(
        at point: CGPoint,
        in screenSize: CGSize,
        visible: [ObservedAircraft],
        phoneHeadingDeg: Double,
        cameraElevationDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double,
        now: Date
    ) {
        let hit = closestTargetIcao24(
            in: visible,
            at: point,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            lockZoneRadius: 100
        )
        switch hit {
        case nil:
            // Empty-sky tap clears any pin.
            if pinnedIcao != nil { recorder.recordUnpin(at: now) }
            pinnedIcao = nil
        case pinnedIcao:
            // Tap-same-plane toggles off — explicit "cancel."
            recorder.recordUnpin(at: now)
            pinnedIcao = nil
        case let icao?:
            pinnedIcao = icao
            recorder.recordTapPin(icao24: icao, at: now)
            // Skip the 0.6 s acquisition animation; the user just
            // pointed at this plane, snap-green is the right feel.
            lockOn.forceLock(targetIcao24: icao, now: now)
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
