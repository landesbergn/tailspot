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

    /// Compass accuracy must exceed this (degrees) for the caution
    /// badge to be considered. Bumped from 10° to 25° because typical
    /// urban CL readings are 10–20° even when the compass is fine —
    /// 10° fired the badge constantly. At 25° the bracket-vs-plane
    /// offset is unambiguously visible to the user, so the warning
    /// carries information.
    private static let compassBadThreshold: Double = 25
    /// Hysteresis floor: once the badge is up, accuracy must improve
    /// below this to dismiss. Prevents flicker when readings hover
    /// at the bad threshold.
    private static let compassGoodThreshold: Double = 15
    /// Seconds of continuously-bad readings before the badge appears.
    /// A momentary spike (passing under a bridge, briefly near a car)
    /// shouldn't surface a warning.
    private static let compassBadDebounce: TimeInterval = 4.0

    @Environment(\.modelContext) private var modelContext
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
    /// Drives the Profile sheet (gamification hub: stats, trophies,
    /// sets, map, leaderboard, settings, notifications, share).
    /// Opened via the person glyph in the top-trailing corner.
    @State private var showProfile = false
    /// Drives the compass calibration sheet. Tapping the AR
    /// caution badge sets this true; the sheet explains what's
    /// wrong and shows the figure-8 calibration motion.
    @State private var showCompassSheet = false
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
    /// Bridges to `PreviewView` so the auto-catch path can grab a
    /// still photo. `PreviewView.bridgeCapture(to:)` installs the
    /// capture closure at `makeUIView` time. Held via `@State` (not
    /// `@StateObject`) — it's a one-method mailbox, not a publisher.
    @State private var captureBridge = CameraCaptureBridge()
    /// Guards re-entry of the capture button while a catch is in
    /// flight. Cleared when the user dismisses the reveal sheet.
    @State private var captureInFlight = false
    /// Latched compass warning. Set true after `compassBadDebounce`
    /// seconds of continuously-bad readings; cleared when accuracy
    /// crosses back under `compassGoodThreshold`. Drives the
    /// caution badge so the badge isn't flicker-driven by every CL
    /// heading update.
    @State private var showCompassWarning = false
    /// Debounce task that flips `showCompassWarning` to true after
    /// the bad-reading streak is long enough. Cancelled on any good
    /// reading so we don't show a stale warning after the compass
    /// settles.
    @State private var compassDebounceTask: Task<Void, Never>?
    /// Carries the card-reveal moment data when a catch just landed.
    /// Non-nil → full-screen reveal sheet is presented. Set inside
    /// `performAutoCatch`; cleared by the user via the reveal's
    /// dismiss buttons.
    @State private var pendingReveal: PendingReveal?
    /// Carries the multi-catch reveal payload when the user
    /// captures N≥2 planes from a single frame. Non-nil → full-screen
    /// `MultiCatchReveal` sheet is presented.
    @State private var pendingMultiReveal: PendingMultiReveal?
    /// Multi-catch zone radius in points. Wider than the single-catch
    /// lock zone (80 px) so the frame meaningfully captures multiple
    /// planes. Scales with zoom for the same reason `lockZoneRadius`
    /// does inside `handleTap`.
    private static let multiCatchBaseRadius: CGFloat = 180
    /// Counter that triggers `sensoryFeedback(.success)` once per
    /// catch (Bool trigger collapses repeats; a counter doesn't).
    @State private var catchHaptic = 0
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
                    CameraPreview(zoomFactor: zoom, captureBridge: captureBridge)
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

                        // Multi-catch detection. Compute the icao24
                        // list inside a wider center zone every tick.
                        // Capped at 5 for UI sanity (the fan reveal
                        // doesn't scale beyond 5 cards).
                        let multiRadius = min(
                            Self.multiCatchBaseRadius * zoom,
                            min(geo.size.width, geo.size.height) / 2
                        )
                        let zone = icaosInZone(
                            in: visible,
                            phoneHeadingDeg: heading,
                            cameraElevationDeg: camEl,
                            screenSize: geo.size,
                            hfovDeg: effectiveHfov,
                            vfovDeg: effectiveVfov,
                            zoneRadius: multiRadius
                        )
                        let multiCandidates = Array(zone.prefix(5))

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
                            } else if visible.isEmpty {
                                // Empty-sky overlay. Shown when nothing
                                // is in view and no lock is engaged.
                                // Quiet center reticle + a status pill
                                // anchored low so it doesn't compete
                                // with the top-center compass / zoom
                                // affordances.
                                emptySkyOverlay(rawCount: adsb.observed.count)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .allowsHitTesting(false)
                            }

                            // Multi-catch capture frame. Drawn when
                            // 2+ planes are inside the wider multi-
                            // catch zone AND nothing is pinned (pin
                            // owns the single-catch path). The
                            // floating button is gone — the bottom
                            // capture bar takes over as the CTA, and
                            // its appearance reacts to the same
                            // condition.
                            if isMultiCaptureActive(
                                multiCandidates: multiCandidates
                            ) {
                                multiCatchFrame(radius: multiRadius)
                                    .position(x: geo.size.width / 2,
                                              y: geo.size.height / 2)
                                    .allowsHitTesting(false)
                            }

                            // Bottom capture bar: hangar tray (left),
                            // big central capture button, profile
                            // (right). Built inside the TimelineView
                            // so the capture button's appearance and
                            // payload react to the per-frame target
                            // / multi-candidate computation.
                            VStack {
                                Spacer()
                                captureBar(
                                    singleTarget: lockOn.state.targetIcao24,
                                    multiCandidates: multiCandidates
                                )
                                .padding(.bottom, 28)
                            }
                            .frame(width: geo.size.width,
                                   height: geo.size.height)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .ignoresSafeArea()

                // Top-center floating affordances: compass-caution
                // badge (when the heading reading is unreliable) and
                // the zoom indicator (when zoomed past 1×). Stacked so
                // both can be present at once.
                VStack(spacing: 8) {
                    cautionBadge
                    zoomPill
                    Spacer()
                }
                .padding(.top, 12)
                .animation(.easeInOut(duration: 0.2), value: isHeadingAccuracyBad)
                .animation(.easeInOut(duration: 0.2), value: zoom > 1.01)

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

                // Top-trailing control: debug wrench only. Hangar
                // and profile moved to the bottom capture bar so the
                // primary action ("press capture") and the navigation
                // (Hangar / Profile) live together at thumb height.
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
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
        .sheet(isPresented: $showProfile) {
            ProfileScreen()
        }
        .sheet(isPresented: $showCompassSheet) {
            CompassCalibrationSheet(location: location)
        }
        .task {
            // Dismiss the launch splash after ~600ms, then crossfade to
            // the AR view over 400ms. This runs once when ContentView
            // first appears (no id: to retrigger), so the splash fires
            // exactly at launch.
            try? await Task.sleep(for: .milliseconds(1400))
            withAnimation(.easeOut(duration: 0.6)) {
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
        // Compass-warning debounce. Watches CL's heading accuracy
        // and only flips the badge on after a sustained-bad streak.
        // Hysteresis floor on the dismiss side keeps the badge stable
        // when accuracy hovers near the threshold.
        .onChange(of: location.headingAccuracy ?? -1) { _, newAcc in
            updateCompassWarning(accuracy: newAcc)
        }
        // Success haptic — counter (not Bool) lets multiple catches
        // each fire.
        .sensoryFeedback(.success, trigger: catchHaptic)
        // Card-reveal moment. Replaces the v0 green flash overlay.
        // Presented full-screen so the rarity bloom + holo card fill
        // the device. Dismiss path either closes the sheet (Keep
        // spotting) or closes + opens the Hangar (View in Hangar).
        .fullScreenCover(item: $pendingReveal) { reveal in
            CardReveal(
                plane: reveal.plane,
                entryNumber: reveal.entryNumber,
                onDismiss: {
                    pendingReveal = nil
                    captureInFlight = false
                },
                onViewInHangar: {
                    pendingReveal = nil
                    captureInFlight = false
                    showHangar = true
                }
            )
            .presentationBackground(.clear)
        }
        // Multi-catch reveal — N≥2 PokeCards fanned out with combo
        // math. Triggered by `performMultiCatch` after the user taps
        // the magenta [N]× CATCH button.
        .fullScreenCover(item: $pendingMultiReveal) { multi in
            MultiCatchReveal(
                planes: multi.planes,
                lastEntryNumber: multi.lastEntryNumber,
                onDismiss: {
                    pendingMultiReveal = nil
                    captureInFlight = false
                },
                onViewInHangar: {
                    pendingMultiReveal = nil
                    captureInFlight = false
                    showHangar = true
                }
            )
            .presentationBackground(.clear)
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

    // MARK: - Auto-catch

    /// Build a `Catch` row from the currently-pinned plane, grab a
    /// still photo from the camera, save the photo to disk, persist
    /// the Catch, and flash a confirmation. Called once per pin
    /// session after the sustain timer fires. Errors are surfaced to
    /// the log but never bubble up — a Catch without a photo is still
    /// a valid Catch.
    private func performAutoCatch(icao: String) async {
        let observed = adsb.observed.first { $0.aircraft.icao24 == icao }
        let metadata = lockedMetadata
        let now = Date()

        // Grab a JPEG from AVCapturePhotoOutput. Capture before we
        // mark caught so a slow capture doesn't double-fire if the
        // user re-taps.
        let photoData = await captureBridge.captureJPEG()
        let photoFilename = photoData.flatMap {
            CatchPhotoStore.save($0, icao24: icao, at: now)
        }
        if photoData == nil {
            Log.adsb.notice("Auto-catch \(icao, privacy: .public): camera capture returned no data")
        }

        let row = Catch(
            icao24: icao,
            callsign: observed?.aircraft.callsign,
            model: metadata?.model,
            manufacturer: metadata?.manufacturerName,
            operatorName: metadata?.operatorName,
            photoFilename: photoFilename,
            caughtAt: now,
            observerLat: location.latitude ?? 0,
            observerLon: location.longitude ?? 0,
            slantDistanceMeters: observed?.slantDistanceMeters ?? 0
        )
        modelContext.insert(row)
        do {
            try modelContext.save()
        } catch {
            Log.adsb.error("Auto-catch save failed for \(icao, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        catchHaptic &+= 1   // overflow-safe ++; SwiftUI only cares that it changed
        Log.adsb.notice("Caught \(icao, privacy: .public) (rarity=\(row.resolvedRarity.rawValue, privacy: .public))")

        // Build the reveal payload. Entry number = count of unique
        // icao24 in the Hangar AFTER this catch lands — the catch
        // we just inserted is included in `catches` because the
        // @Query auto-updates synchronously when the modelContext
        // saves.
        let uniqueIcaoCount = Set(catches.map(\.icao24)).count
        let altFt = (observed?.aircraft.altitudeMeters).map { Int(($0 * 3.28084).rounded()) }
        let speedKt: Int? = observed?.aircraft.velocityMps.map { Int(($0 * 1.94384).rounded()) }
        let pokePlane = PokePlane(
            callsign: row.callsign,
            model: row.model,
            carrier: row.operatorName,
            rarity: row.resolvedRarity,
            type: row.resolvedType,
            altText: altFt.map { "\($0.formatted(.number)) ft" },
            speedText: speedKt.map { "\($0) kt" },
            distText: String(format: "%.1f km", row.slantDistanceMeters / 1000),
            photoURL: photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
        )
        pendingReveal = PendingReveal(plane: pokePlane, entryNumber: uniqueIcaoCount)
    }

    /// Snapshot of the catch needed to render the reveal sheet —
    /// kept separate from the live Catch so the reveal stays stable
    /// even if SwiftData state churns underneath.
    struct PendingReveal: Identifiable, Equatable {
        let id = UUID()
        let plane: PokePlane
        let entryNumber: Int
    }

    /// Snapshot of a multi-catch run for `MultiCatchReveal`.
    struct PendingMultiReveal: Identifiable, Equatable {
        let id = UUID()
        let planes: [PokePlane]
        let lastEntryNumber: Int
    }

    // MARK: - Multi-catch handler

    /// Inserts a Catch row per icao24 in the input list and triggers
    /// `MultiCatchReveal`. Unlike `performAutoCatch`, this is fired
    /// explicitly by the user (button tap), not a sustain timer.
    /// Camera is captured once and the photoFilename is attached to
    /// each row.
    @MainActor
    private func performMultiCatch(icaos: [String]) async {
        guard icaos.count >= 2 else { return }
        let now = Date()
        let photoData = await captureBridge.captureJPEG()

        var planes: [PokePlane] = []

        for icao in icaos {
            let observed = adsb.observed.first { $0.aircraft.icao24 == icao }
            // Each multi-catch row needs metadata. Walk the cache;
            // a miss here means we fall back to nil — better than
            // blocking the moment on a network round-trip.
            let metadata = await adsb.metadata(for: icao)
            let photoFilename = photoData.flatMap {
                CatchPhotoStore.save($0, icao24: icao, at: now)
            }
            let row = Catch(
                icao24: icao,
                callsign: observed?.aircraft.callsign,
                model: metadata?.model,
                manufacturer: metadata?.manufacturerName,
                operatorName: metadata?.operatorName,
                photoFilename: photoFilename,
                caughtAt: now,
                observerLat: location.latitude ?? 0,
                observerLon: location.longitude ?? 0,
                slantDistanceMeters: observed?.slantDistanceMeters ?? 0
            )
            modelContext.insert(row)

            // Build a PokePlane for the reveal — use the just-saved
            // photo so the fan shows the user's actual moment.
            let altFt = (observed?.aircraft.altitudeMeters).map { Int(($0 * 3.28084).rounded()) }
            let speedKt: Int? = observed?.aircraft.velocityMps.map { Int(($0 * 1.94384).rounded()) }
            planes.append(PokePlane(
                callsign: row.callsign,
                model: row.model,
                carrier: row.operatorName,
                rarity: row.resolvedRarity,
                type: row.resolvedType,
                altText: altFt.map { "\($0.formatted(.number)) ft" },
                speedText: speedKt.map { "\($0) kt" },
                distText: String(format: "%.1f km", row.slantDistanceMeters / 1000),
                photoURL: photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
            ))
        }

        do {
            try modelContext.save()
        } catch {
            Log.adsb.error("Multi-catch save failed: \(error.localizedDescription, privacy: .public)")
        }

        // Bump haptic counter so the user feels the catch.
        catchHaptic &+= 1
        Log.adsb.notice("Multi-caught \(icaos.count, privacy: .public) planes")

        let uniqueIcaoCount = Set(catches.map(\.icao24)).count
        pendingMultiReveal = PendingMultiReveal(
            planes: planes,
            lastEntryNumber: uniqueIcaoCount
        )
    }

    // MARK: - Top-center overlays

    /// Compass-bad caution badge. Slim capsule with an amber dot +
    /// "COMPASS ±N°" — quieter than the prior amber-bordered card so
    /// it doesn't dominate the AR view when readings are mediocre.
    /// Tap opens `CompassCalibrationSheet` for the figure-8
    /// instructions. Surfaces only after `compassBadDebounce` seconds
    /// of consistently-bad readings (see `updateCompassWarning`).
    @ViewBuilder
    private var cautionBadge: some View {
        if isHeadingAccuracyBad {
            Button {
                showCompassSheet = true
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Brand.Color.alertCaution)
                        .frame(width: 5, height: 5)
                    Text("COMPASS \(formatHeadingAccuracyShort())")
                        .font(.system(size: 10, weight: .bold,
                                      design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(Brand.Color.alertCaution)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Compass off by \(formatHeadingAccuracyShort()). Tap to calibrate.")
            .transition(.opacity)
        }
    }

    /// Zoom indicator. Faint capsule top-center; hidden at 1.0×.
    @ViewBuilder
    private var zoomPill: some View {
        if zoom > 1.01 {
            Text(String(format: "%.1f×", zoom))
                .font(.system(.caption, design: .monospaced).bold())
                .foregroundStyle(Brand.Color.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
                .transition(.opacity)
        }
    }

    /// Compact form of the heading accuracy for the caution badge.
    /// Returns "±N°" rounded to the nearest degree. Negative / nil
    /// accuracy treated as unknown.
    private func formatHeadingAccuracyShort() -> String {
        guard let acc = location.headingAccuracy, acc >= 0 else { return "±?°" }
        return String(format: "±%.0f°", acc)
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

    // MARK: - Multi-catch visuals

    /// The magenta dashed capture frame drawn around the multi-catch
    /// zone. Pulses subtly so it reads as "live" without being a full
    /// breathing animation.
    private func multiCatchFrame(radius: CGFloat) -> some View {
        let side = radius * 2
        return TimelineView(.animation(minimumInterval: 1.0/30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let phase = (cos(t * 3) + 1) / 2     // 0…1, ~1 s period
            let glow = 0.35 + 0.25 * phase
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    Brand.Color.alertAdvisory,
                    style: StrokeStyle(lineWidth: 2, dash: [10, 6])
                )
                .frame(width: side, height: side)
                .shadow(color: Brand.Color.alertAdvisory.opacity(glow), radius: 18)
        }
    }

    // MARK: - Bottom capture bar

    /// Snapshot of the catch options visible to the user on the
    /// current frame — used to drive the capture button's appearance
    /// and payload. Computed inline at 30 Hz inside the TimelineView
    /// so the button stays in sync with the lock-on / multi-zone
    /// state without any extra plumbing.
    private enum CaptureMode {
        case idle
        case single(icao: String)
        case multi(icaos: [String])
    }

    /// True when the multi-catch capture frame should render and the
    /// bottom button should switch to the magenta multi style.
    /// The pin flow owns the single-catch path; a single lock that's
    /// already engaged also takes precedence over multi.
    private func isMultiCaptureActive(multiCandidates: [String]) -> Bool {
        multiCandidates.count >= 2
            && pinnedIcao == nil
            && !lockOn.state.isLockedOrSticky
    }

    /// Decide the capture mode for the current frame. Single-lock
    /// wins when an icao is being tracked (acquiring / locked /
    /// sticky); multi wins only when the engine is idle and the
    /// multi-zone has 2+ planes; otherwise idle.
    private func captureMode(
        singleTarget: String?,
        multiCandidates: [String]
    ) -> CaptureMode {
        if let icao = singleTarget {
            return .single(icao: icao)
        }
        if isMultiCaptureActive(multiCandidates: multiCandidates) {
            return .multi(icaos: multiCandidates)
        }
        return .idle
    }

    /// Bottom capture bar — hangar (left), big central capture
    /// button, profile (right). The central button changes color +
    /// label based on the current capture mode (cyan + reticle for a
    /// single lock, magenta with "N×" for a multi-zone catch, dimmed
    /// for no available target). Direct tap = immediate catch; no
    /// hold required.
    private func captureBar(
        singleTarget: String?,
        multiCandidates: [String]
    ) -> some View {
        let mode = captureMode(
            singleTarget: singleTarget,
            multiCandidates: multiCandidates
        )
        return HStack {
            bottomHangarButton
            Spacer()
            captureButton(mode: mode)
            Spacer()
            bottomProfileButton
        }
        .padding(.horizontal, 28)
    }

    /// Big central capture button. The visual + tap target the user
    /// sees as the primary AR action.
    @ViewBuilder
    private func captureButton(mode: CaptureMode) -> some View {
        switch mode {
        case .idle:
            captureButtonIdle
        case .single(let icao):
            captureButtonSingle(icao: icao)
        case .multi(let icaos):
            captureButtonMulti(icaos: icaos)
        }
    }

    /// Cyan single-lock capture button. Glows + scales subtly when
    /// the engine is fully locked (vs still acquiring) so the user
    /// can read "ready to catch" at a glance.
    private func captureButtonSingle(icao: String) -> some View {
        let ready = lockOn.state.isLockedOrSticky
        return Button {
            guard !captureInFlight else { return }
            captureInFlight = true
            Task { await performAutoCatch(icao: icao) }
        } label: {
            ZStack {
                Circle()
                    .fill(Brand.Color.cyan)
                Circle()
                    .strokeBorder(Brand.Color.bgPrimary, lineWidth: 4)
                Image(systemName: "viewfinder")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Brand.Color.bgPrimary)
            }
            .frame(width: 76, height: 76)
            .shadow(color: Brand.Color.cyan.opacity(ready ? 0.55 : 0.3),
                    radius: ready ? 22 : 12, y: 6)
            .scaleEffect(ready ? 1.0 : 0.94)
            .animation(.easeOut(duration: 0.18), value: ready)
        }
        .buttonStyle(.plain)
        .disabled(captureInFlight)
        .opacity(captureInFlight ? 0.5 : 1.0)
        .accessibilityLabel("Capture aircraft")
    }

    /// Magenta multi-catch capture button. "N×" / "CATCH" stacked
    /// matches the design canvas's `BottomControlsMulti`.
    private func captureButtonMulti(icaos: [String]) -> some View {
        let n = icaos.count
        return Button {
            guard !captureInFlight else { return }
            captureInFlight = true
            Task { await performMultiCatch(icaos: icaos) }
        } label: {
            ZStack {
                Circle()
                    .fill(Brand.Color.alertAdvisory)
                Circle()
                    .strokeBorder(Brand.Color.bgPrimary, lineWidth: 4)
                VStack(spacing: 0) {
                    Text("\(n)×")
                        .font(.system(size: 22, weight: .heavy,
                                      design: .monospaced))
                        .foregroundStyle(Brand.Color.bgPrimary)
                    Text("CATCH")
                        .font(.system(size: 9, weight: .bold,
                                      design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Brand.Color.bgPrimary)
                }
            }
            .frame(width: 84, height: 84)
            .shadow(color: Brand.Color.alertAdvisory.opacity(0.55),
                    radius: 22, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(captureInFlight)
        .opacity(captureInFlight ? 0.5 : 1.0)
        .accessibilityLabel("Capture \(n) planes")
    }

    /// Dimmed capture button shown when no plane is in range to
    /// catch. Tappable but produces only a soft haptic — gives the
    /// user feedback without firing a no-op catch.
    private var captureButtonIdle: some View {
        Button {
            // Soft "nothing to catch" feedback so a press isn't
            // silent. The same haptic counter the catch path uses
            // would be too celebratory; a UISelectionFeedback-style
            // bump (via .sensoryFeedback elsewhere) would be ideal,
            // but a noop is acceptable for v1.
        } label: {
            ZStack {
                Circle()
                    .fill(Brand.Color.bgPrimary.opacity(0.6))
                Circle()
                    .strokeBorder(Brand.Color.textPrimary.opacity(0.25),
                                  lineWidth: 2)
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.4))
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel("Aim at a plane to capture")
    }

    /// Hangar button in the bottom bar. Square-ish 56×56 chip with
    /// the count badge — matches the design canvas `BottomControls`.
    private var bottomHangarButton: some View {
        Button {
            showHangar = true
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Brand.Color.bgPrimary.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Brand.Color.textPrimary.opacity(0.08),
                                          lineWidth: 1)
                    )
                    .frame(width: 56, height: 56)
                HangarGlyph(
                    lineWidth: 2,
                    tint: Brand.Color.textPrimary.opacity(0.9)
                )
                .frame(width: 26, height: 26)
                .frame(width: 56, height: 56)
                if !catches.isEmpty {
                    Text("\(catches.count)")
                        .font(.system(size: 10, weight: .bold,
                                      design: .monospaced))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Brand.Color.alertNormal, in: .capsule)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open hangar (\(catches.count) catches)")
    }

    /// Profile button in the bottom bar. Mirrors the hangar button's
    /// visual weight so the two flank the capture button evenly.
    private var bottomProfileButton: some View {
        Button {
            showProfile = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Brand.Color.bgPrimary.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Brand.Color.textPrimary.opacity(0.08),
                                          lineWidth: 1)
                    )
                    .frame(width: 56, height: 56)
                Image(systemName: "person.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Brand.Color.textPrimary.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open profile")
    }

    // MARK: - Empty-sky state

    /// Overlay shown when no aircraft are above the horizon + within
    /// the visibility cap. Restraint-first per the field feedback
    /// (the chat-canvas "scanning screen" with radar pings was
    /// noisy): faint center reticle + a status pill anchored well
    /// below screen center so it doesn't fight the compass / zoom
    /// pills up top.
    ///
    /// `rawCount` is the count of bbox-level aircraft (pre-visibility
    /// filter). When > 0 we can tell the user "no aircraft in view ·
    /// N in range" so they understand traffic IS there, just below
    /// the horizon or past 30 km.
    private func emptySkyOverlay(rawCount: Int) -> some View {
        let lastErr = adsb.lastError
        let transient = adsb.lastErrorIsTransient
        let neverFetched = adsb.lastFetched == nil && lastErr == nil
        let pillText: String = {
            if let lastErr { return lastErr.uppercased() }
            if neverFetched { return "SCANNING SKY…" }
            if rawCount > 0 {
                return "NO AIRCRAFT IN VIEW · \(rawCount) IN RANGE"
            }
            return "NO AIRCRAFT IN RANGE"
        }()
        // Hard errors (auth, transport) → amber caution. Transient
        // errors (auto-recovering rate-limit backoff) and the neutral
        // states share the textSecondary tint so the user isn't
        // alarmed by a state the system is already handling.
        let pillTint: Color = (lastErr != nil && !transient)
            ? Brand.Color.alertCaution
            : Brand.Color.textSecondary
        return GeometryReader { geo in
            ZStack {
                emptyReticle
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pillTint)
                            .frame(width: 6, height: 6)
                            .modifier(EmptyPulse(active: lastErr == nil || transient))
                        Text(pillText)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(pillTint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
                    .padding(.bottom, geo.size.height * 0.18)
                }
            }
        }
    }

    /// Faint cyan corner-bracket box at screen center. 88×88 px;
    /// 24 % opacity so it stays out of the way until it becomes the
    /// only thing on screen.
    private var emptyReticle: some View {
        LockBrackets(boxSize: 88, color: Brand.Color.cyan, opacity: 0.24)
    }

    // MARK: - Lock-on visuals (continued)

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

    /// Identification card shown below a locked target. Lines in
    /// decreasing emphasis: callsign + rarity/type tags, airline,
    /// make + model, altitude + speed + distance. Lines for which
    /// we don't yet have data are simply omitted — keeps the card
    /// from filling with dashes while the metadata fetch is in flight.
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
        // Distance from the observer. Useful at-a-glance — currently
        // the user has to tap into the detail sheet to see it.
        let distText = String(format: "%.1f km", obs.slantDistanceMeters / 1000)
        let stats = [altText, speedText, distText].compactMap(\.self).joined(separator: "  ·  ")

        // Classify on the fly — same heuristic the Catch will land
        // with if the user catches this plane. Doing it inline (vs
        // caching) is fine: the classifier is a quick substring scan
        // and the lock label re-renders at 30 Hz with the same input.
        let (rarity, type) = AircraftClassifier.classify(
            manufacturer: metadata?.manufacturerName,
            model: metadata?.model,
            operatorName: metadata?.operatorName
        )

        return VStack(alignment: .leading, spacing: 3) {
            Text(cs)
                .font(Brand.Font.hudCallsign)
                .foregroundStyle(Brand.Color.cyan)

            // Rarity + type tags — gives the user an instant tier
            // read before tapping in. Only render when metadata has
            // actually landed; pre-metadata the classifier would just
            // default-bucket everything to (common, narrow) which is
            // noise.
            if metadata != nil {
                TagRow(rarity: rarity, type: type, size: .sm)
            }

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

    /// Reflects the latched compass-warning state — true only after
    /// `compassBadDebounce` seconds of continuously-bad heading
    /// accuracy. See `updateCompassWarning(accuracy:)`. Kept as a
    /// property so the few call sites that read it (badge, debug
    /// heading row) stay simple.
    private var isHeadingAccuracyBad: Bool { showCompassWarning }

    /// State machine driving the compass warning. Called from
    /// `.onChange(of:location.headingAccuracy)`:
    /// - Accuracy crosses `compassBadThreshold` → start a debounce
    ///   task; if it stays bad for `compassBadDebounce` seconds, flip
    ///   the badge on.
    /// - Accuracy crosses `compassGoodThreshold` (hysteresis floor) →
    ///   cancel any pending debounce and flip the badge off.
    /// - Anything in between keeps the current state.
    private func updateCompassWarning(accuracy: Double) {
        let bad = accuracy > Self.compassBadThreshold
        let good = accuracy >= 0 && accuracy < Self.compassGoodThreshold

        if showCompassWarning {
            if good {
                showCompassWarning = false
                compassDebounceTask?.cancel()
                compassDebounceTask = nil
            }
            return
        }

        if bad {
            // Already arming — let the existing task keep counting.
            if compassDebounceTask != nil { return }
            compassDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.compassBadDebounce))
                guard !Task.isCancelled else { return }
                let acc = location.headingAccuracy ?? -1
                if acc > Self.compassBadThreshold {
                    showCompassWarning = true
                }
                compassDebounceTask = nil
            }
        } else {
            // Accuracy improved (or went unknown) before the streak
            // completed — reset the debounce.
            compassDebounceTask?.cancel()
            compassDebounceTask = nil
        }
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
    /// [MOCK] tag and the auth state ([AUTH] / [ANON]). Tapping
    /// anywhere on the row flips the source. The auth tag is
    /// purely diagnostic — it surfaces whether OpenSky credentials
    /// reached the app process at launch.
    private var adsbStatusRow: some View {
        HStack(spacing: 8) {
            Text(formatADSBStatus())
            Text(adsb.useMock ? "[MOCK]" : "[LIVE]")
                .foregroundStyle(adsb.useMock ? Brand.Color.alertCaution : Brand.Color.alertNormal)
                .bold()
            if !adsb.useMock {
                Text(adsb.liveSourceIsAuthed ? "[AUTH]" : "[ANON]")
                    .foregroundStyle(adsb.liveSourceIsAuthed
                                     ? Brand.Color.alertNormal
                                     : Brand.Color.alertCaution)
                    .bold()
            }
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
    /// `tapZoneRadius` scales with the current zoom (`100 × zoom`, capped
    /// at half the smaller screen dimension). The reason: brackets are
    /// drawn at the geometric projection of each plane, but the compass
    /// heading has real-world error (typically 5–15° in coastal /
    /// bridge-heavy areas). At base zoom that error translates to ~35 px
    /// of bracket-vs-plane disagreement; at 4× zoom it's ~140 px,
    /// which would otherwise put the user's tap outside any fixed
    /// pixel radius — they couldn't catch a plane they could clearly see.
    /// Scaling keeps the *angular* tap tolerance constant across zoom.
    /// The cap protects against turning the lock-on into a no-op when
    /// the user zooms in dense traffic.
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
        let cap = min(screenSize.width, screenSize.height) / 2
        let tapRadius = min(100 * zoom, cap)
        let hit = closestTargetIcao24(
            in: visible,
            at: point,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            lockZoneRadius: tapRadius
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

// MARK: - Empty-sky pulse

/// Slow 0.4 → 1.0 opacity breathe at ~1 Hz. Used on the empty-sky
/// status dot so it telegraphs "actively scanning" without being
/// a radar sweep. Disabled (`active: false`) when the pill is
/// surfacing an error string — at that point we don't want the
/// liveness signal contradicting the message.
private struct EmptyPulse: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // Cosine breathing: 0.4 → 1.0 → 0.4 once per ~1.4 s.
            let phase = (cos(t * 4.5) + 1) / 2     // 0…1
            let opacity = active ? (0.4 + 0.6 * phase) : 1.0
            content.opacity(opacity)
        }
    }
}

#Preview {
    ContentView()
}
