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
    /// see an icao24 actually hits OpenSky. Kicked off the moment a
    /// pin lands (driven by .task(id:) on targetIcao24) so by the
    /// time the lock visuals render, the label content is usually
    /// already populated.
    @State private var lockedMetadata: AircraftMetadata?
    /// Cache of metadata for every visible plane. Powers the ambient
    /// per-plane label's rarity teaser — without prefetch, every
    /// non-pinned label would render "COMMON" until that plane became
    /// the pin. Driven by a `.task(id:)` keyed on the sorted set of
    /// visible icao24s; the MetadataCache actor dedupes hits across
    /// re-runs so this is cheap after the first fill.
    @State private var ambientMetadata: [String: AircraftMetadata?] = [:]
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
    /// leaving visibility also clears. Taps drive `forceLock()` on
    /// the engine — the only way into `.locked` after Task 4.
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
    /// NOTE: T7 un-wired the read at the button site when collapsing
    /// the multi-button chrome. T8 will re-wire inside the new merged
    /// `performCatch(mode:)`. Reveal-dismiss callbacks still clear it.
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
    /// `performCatch(mode:)` via `presentReveal`; cleared by the user
    /// via the reveal's dismiss buttons.
    @State private var pendingReveal: PendingReveal?
    /// Carries the multi-catch reveal payload when the user
    /// captures N≥2 planes from a single frame. Non-nil → full-screen
    /// `MultiCatchReveal` sheet is presented.
    @State private var pendingMultiReveal: PendingMultiReveal?
    /// Counter that triggers `sensoryFeedback(.success)` once per
    /// catch (Bool trigger collapses repeats; a counter doesn't).
    @State private var catchHaptic = 0
    /// Opacity of the launch splash screen. Starts at 1.0 (opaque),
    /// animates to 0 after ~600ms, then the AR view underneath becomes
    /// interactive. The splash absorbs taps for the first half of the
    /// fade so no gestures fire while it's mostly visible.
    @State private var splashOpacity: Double = 1.0
    /// Active empty-tap ripple, if any: (tap point, timestamp). Set by
    /// `showEmptyTapRipple` when a tap lands in truly empty sky (no
    /// plane within the widened 250 px search). Auto-clears after 1.0 s
    /// so the ripple doesn't linger.
    @State private var emptyRipple: (CGPoint, Date)? = nil

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
                // crosshair, no per-aircraft labels (Task 5 will add
                // ambient labels). The user taps a plane to pin it; the
                // engine jumps straight to .locked via forceLock(), and
                // the label renders at the pinned plane's projected
                // position. Tap the locked label to open the detail
                // sheet (with the Catch button).
                //
                // The 30 Hz TimelineView drives engine state transitions
                // (e.g., pinned plane leaving the lock zone → sticky →
                // idle). The engine is a pure state machine — repeated
                // update() calls with the same target are idempotent —
                // so calling it from inside the TimelineView body is safe.
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

                            // All-frame ambient labels. Every visible
                            // plane gets a faint cyan corner-bracket
                            // pair + small "callsign · RARITY" label
                            // at its projected screen position. The
                            // pinned plane (if any) renders brighter +
                            // thicker brackets and an expanded label
                            // that includes points; other planes dim
                            // to ~35 % so the pin reads as primary.
                            //
                            // Tap handling lives on the underlying
                            // Color.clear background layer above
                            // (handleTap) — labels themselves are
                            // `.allowsHitTesting(false)` so they
                            // don't intercept taps meant for the
                            // plane behind them.
                            let pinnedIcaoForLabels = lockOn.state.targetIcao24
                            ForEach(visible, id: \.aircraft.icao24) { obs in
                                if let pos = obs.screenPosition(
                                    phoneHeadingDeg: heading,
                                    cameraElevationDeg: camEl,
                                    in: geo.size,
                                    hfovDeg: effectiveHfov,
                                    vfovDeg: effectiveVfov
                                ) {
                                    let icao = obs.aircraft.icao24
                                    let isPinned = icao == pinnedIcaoForLabels
                                    // For the pinned plane prefer the
                                    // already-loaded lockedMetadata
                                    // (which the .task(id:) path keeps
                                    // current); fall back to the
                                    // ambient prefetch dict. The dict
                                    // also catches every other visible
                                    // plane.
                                    let metaForPlane: AircraftMetadata? = isPinned
                                        ? (lockedMetadata ?? (ambientMetadata[icao] ?? nil))
                                        : (ambientMetadata[icao] ?? nil)
                                    PlaneLabel(
                                        aircraft: obs,
                                        position: pos,
                                        isPinned: isPinned,
                                        isDimmed: pinnedIcaoForLabels != nil && !isPinned,
                                        metadata: metaForPlane
                                    )
                                }
                            }

                            if visible.isEmpty {
                                // Empty-sky overlay. Shown when nothing
                                // is in view. Quiet center reticle +
                                // a status pill anchored low so it
                                // doesn't compete with the top-center
                                // compass / zoom affordances.
                                emptySkyOverlay(rawCount: adsb.observed.count)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .allowsHitTesting(false)
                            }

                            // Empty-tap ripple. Shown when a tap lands
                            // on truly empty sky (no plane within the
                            // widened 250 px search). Brief cyan ring
                            // + NO AIRCRAFT HERE text at the tap point;
                            // auto-clears after 1 s.
                            if let (point, since) = emptyRipple {
                                EmptyTapRippleView(at: point, since: since)
                                    .allowsHitTesting(false)
                            }

                            // Bottom capture bar: hangar tray (left),
                            // big central capture button, profile
                            // (right). Built inside the TimelineView
                            // so the capture button's appearance and
                            // payload react to the per-frame visible
                            // set + pin state.
                            //
                            // Spec § 3.2: a single always-present
                            // capture button. The visible-count + pin
                            // drive the mode (disabled / single /
                            // multi). When in multi-mode a small
                            // magenta ×N badge appears in the
                            // top-right corner of the circle. The
                            // floating magenta capture-zone overlay
                            // was removed — the badge on the unified
                            // button replaces it as the multi-mode
                            // affordance.
                            let visibleIcaos = visible.map(\.aircraft.icao24)
                            let pinForCapture = lockOn.state.targetIcao24
                            let mode: CaptureMode = {
                                if let pin = pinForCapture,
                                   visibleIcaos.contains(pin) {
                                    return .single(pin)
                                }
                                if visibleIcaos.isEmpty {
                                    return .disabled
                                }
                                if visibleIcaos.count == 1 {
                                    return .single(visibleIcaos[0])
                                }
                                return .multi(visibleIcaos)
                            }()
                            VStack {
                                Spacer()
                                captureBar(mode: mode)
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
        // Ambient metadata prefetch for all-frame labels. The id is a
        // content-keyed signature of the currently-visible icao24
        // set (sorted, joined) so it only re-runs when membership
        // actually changes — not on every TimelineView tick. The
        // MetadataCache actor dedupes lookups, so the first sighting
        // of an icao24 fires a single OpenSky request and every later
        // observation is a free in-memory hit.
        .task(id: visibleIcaoSignature) {
            let icaos = adsb.observed
                .filter(\.isLikelyVisibleToObserver)
                .map(\.aircraft.icao24)
            // Prune session-stale entries. `ambientMetadata` is a view-
            // local mirror of the bounded MetadataCache actor; without
            // this filter the dict would grow unboundedly over a long
            // session as planes leave + re-enter the visible set.
            let currentSet = Set(icaos)
            ambientMetadata = ambientMetadata.filter { currentSet.contains($0.key) }
            for icao in icaos where ambientMetadata[icao] == nil {
                let value = await adsb.metadata(for: icao)
                ambientMetadata[icao] = value
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
                },
                isDuplicate: reveal.isDuplicate
            )
            .presentationBackground(.clear)
        }
        // Multi-catch reveal — N≥2 PokeCards staggered in with a
        // chime+haptic per fresh card, combo banner climbing across
        // the reveal, ALREADY CAUGHT stamps inline on duplicates.
        // T11 routes every (fresh+dup) total ≥ 2 through here from
        // `presentReveal`.
        .fullScreenCover(item: $pendingMultiReveal) { multi in
            MultiCatchReveal(
                entries: multi.entries,
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

    /// Content-keyed signature of the currently-visible icao24 set,
    /// used as the id on the ambient-metadata prefetch task. Sorting
    /// + joining ensures the value is stable across observed-array
    /// re-orderings (which happen on every fetch) so the task only
    /// re-runs when membership actually changes.
    private var visibleIcaoSignature: String {
        adsb.observed
            .filter(\.isLikelyVisibleToObserver)
            .map(\.aircraft.icao24)
            .sorted()
            .joined(separator: ",")
    }

    // MARK: - Catch reveal payloads

    /// Snapshot of the catch needed to render the reveal sheet —
    /// kept separate from the live Catch so the reveal stays stable
    /// even if SwiftData state churns underneath.
    ///
    /// `isDuplicate` is set by `performCatch(mode:)` when the icao24
    /// was already in the user's Hangar — T10 will render the
    /// "ALREADY CAUGHT" stamp + quieter chrome based on this flag.
    /// T8 just threads it through.
    struct PendingReveal: Identifiable, Equatable {
        let id = UUID()
        let plane: PokePlane
        let entryNumber: Int
        var isDuplicate: Bool = false
    }

    /// Snapshot of a multi-catch run for `MultiCatchReveal`. Entries
    /// preserve both fresh + duplicate icaos so the reveal can render
    /// the ALREADY CAUGHT stamp inline (T11). The dedupe + dedup-
    /// counted combo math live in the view itself.
    struct PendingMultiReveal: Identifiable, Equatable {
        let id = UUID()
        let entries: [MultiCatchReveal.Entry]
        let lastEntryNumber: Int
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

    // MARK: - Bottom capture bar

    /// Snapshot of the catch options visible to the user on the
    /// current frame — used to drive the capture button's appearance
    /// and payload. Computed inline at 30 Hz inside the TimelineView
    /// from the visible aircraft set + tap-pin so the button stays
    /// in sync without any extra plumbing.
    ///
    /// Spec § 3.2:
    /// - `.disabled` when no aircraft are visible (button faded).
    /// - `.single(icao)` for either (a) an explicitly tap-pinned plane
    ///   that is still visible, or (b) the lone visible plane.
    /// - `.multi(icaos)` when ≥2 planes are visible and no pin is set;
    ///   the unified button shows a magenta `×N` corner badge.
    private enum CaptureMode {
        case disabled
        case single(String)        // icao24
        case multi([String])       // icao24 list
    }

    /// Bottom capture bar — hangar (left), big central capture
    /// button, profile (right). The central button is a single
    /// always-present circle; mode drives its enabled state and
    /// whether a `×N` badge appears in the top-right corner.
    private func captureBar(mode: CaptureMode) -> some View {
        HStack {
            bottomHangarButton
            Spacer()
            captureButton(mode: mode)
            Spacer()
            bottomProfileButton
        }
        .padding(.horizontal, 28)
    }

    /// Merged capture path. Single entry point used by the unified
    /// capture button regardless of whether the user is catching one
    /// plane (pin or lone visible) or several (≥2 visible, no pin).
    ///
    /// Per-icao dedup gate: `Catch.exists(icao24:in:)` decides whether
    /// to insert a new row or record the icao as a duplicate. New rows
    /// share one JPEG (captured once, persisted per row to keep the
    /// per-row `photoFilename` self-contained — same shape as the
    /// old `performMultiCatch`). After all rows land, `presentReveal`
    /// picks the appropriate reveal sheet payload.
    ///
    /// Re-entry is guarded by `captureInFlight`; the flag clears in
    /// the reveal's dismiss callbacks (and on the fall-through where
    /// no reveal is presented).
    private func performCatch(mode: CaptureMode) {
        let icaos: [String]
        switch mode {
        case .disabled:         return
        case .single(let icao): icaos = [icao]
        case .multi(let list):  icaos = list
        }
        guard !icaos.isEmpty else { return }
        guard !captureInFlight else { return }
        captureInFlight = true

        // Snapshot observer pose + visible-aircraft map up front. The
        // map is keyed by icao24 so the per-row loop is O(N) (not N×M
        // linear scans).
        let observerLat = location.latitude ?? 0
        let observerLon = location.longitude ?? 0
        // `Dictionary(uniquingKeysWith:)` over `uniqueKeysWithValues:` —
        // if upstream ever emits two observations with the same icao24
        // (reannotation race, future provider quirk) we deduplicate
        // instead of crashing the catch button.
        let visibleByIcao = Dictionary(
            adsb.observed.map { ($0.aircraft.icao24, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        Task { @MainActor in
            // One JPEG, reused for every new row in this catch. If the
            // camera isn't ready (auth denied, session not running),
            // `captureJPEG` returns nil — Catches are still valid
            // without a photo. Capture first so a slow shutter doesn't
            // double-fire the dedup gate when the user re-taps.
            let photoData = await captureBridge.captureJPEG()
            if photoData == nil {
                Log.adsb.notice("Catch: camera capture returned no data")
            }
            let now = Date()

            var newCatches: [Catch] = []
            var duplicates: [String] = []

            for icao in icaos {
                if Catch.exists(icao24: icao, in: modelContext) {
                    duplicates.append(icao)
                    continue
                }
                // Metadata: prefer the locked one (pinned plane,
                // manually resolved on lock) when this icao is the
                // pin, then the ambient prefetch cache, then a direct
                // manager lookup. Reordered so the pinned-snapshot
                // wins over a possibly-stale ambient hit.
                let metadata: AircraftMetadata?
                if let locked = lockedMetadata,
                   icao == lockOn.state.targetIcao24 {
                    metadata = locked
                } else if let cached = ambientMetadata[icao] ?? nil {
                    metadata = cached
                } else {
                    metadata = await adsb.metadata(for: icao)
                }

                let observed = visibleByIcao[icao]
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
                    observerLat: observerLat,
                    observerLon: observerLon,
                    slantDistanceMeters: observed?.slantDistanceMeters ?? 0
                )
                modelContext.insert(row)
                newCatches.append(row)
            }

            if !newCatches.isEmpty {
                do {
                    try modelContext.save()
                } catch {
                    Log.adsb.error("Catch save failed: \(error.localizedDescription, privacy: .public)")
                }
                // One haptic per catch event regardless of N — the
                // reveal carries the multiplicity message.
                catchHaptic &+= 1
                Log.adsb.notice("Caught \(newCatches.count, privacy: .public) plane(s); \(duplicates.count, privacy: .public) duplicate(s)")
            } else if !duplicates.isEmpty {
                Log.adsb.notice("Catch: all \(duplicates.count, privacy: .public) target(s) already in Hangar")
            }

            presentReveal(newCatches: newCatches, duplicates: duplicates,
                          visibleByIcao: visibleByIcao)
        }
    }

    /// Picks the right reveal payload based on what landed.
    ///
    /// - Single (1 fresh OR 1 dup) → `CardReveal` via `pendingReveal`.
    /// - Multi (≥2 combined fresh + dup) → `MultiCatchReveal` via
    ///   `pendingMultiReveal`. Fresh and dup entries are interleaved
    ///   in the same order they were captured; the reveal renders
    ///   ALREADY CAUGHT stamps inline on dups and only credits fresh
    ///   tails toward the combo + points (T11).
    ///
    /// Duplicate-only case (single dup): synthesizes a `PokePlane`
    /// from the already-stored row + (when available) the current
    /// live observation for fresh alt/speed/distance.
    private func presentReveal(
        newCatches: [Catch],
        duplicates: [String],
        visibleByIcao: [String: ObservedAircraft]
    ) {
        let uniqueIcaoCount = Set(catches.map(\.icao24)).count
        let totalCount = newCatches.count + duplicates.count

        // Multi path — combine fresh + dups into a single ordered
        // entry list. Dup fetches that fail (icao vanished between
        // the dedup gate and the fetch) are dropped silently rather
        // than dropping the whole reveal.
        if totalCount >= 2 {
            var entries: [MultiCatchReveal.Entry] = []
            for c in newCatches {
                let observed = visibleByIcao[c.icao24]
                let plane = pokePlane(from: c, observed: observed)
                entries.append(.init(plane: plane, isDuplicate: false))
            }
            for dupIcao in duplicates {
                if let existing = fetchExistingCatch(icao: dupIcao) {
                    let observed = visibleByIcao[dupIcao]
                    let plane = pokePlane(from: existing, observed: observed)
                    entries.append(.init(plane: plane, isDuplicate: true))
                }
            }
            if entries.count >= 2 {
                pendingMultiReveal = PendingMultiReveal(
                    entries: entries,
                    lastEntryNumber: uniqueIcaoCount
                )
                return
            }
            // Degenerate: lost enough dup fetches that we're back
            // below 2. Fall through to the single-card paths below.
        }

        if let first = newCatches.first {
            let observed = visibleByIcao[first.icao24]
            let plane = pokePlane(from: first, observed: observed)
            pendingReveal = PendingReveal(
                plane: plane,
                entryNumber: uniqueIcaoCount,
                isDuplicate: false
            )
            return
        }

        if let dupIcao = duplicates.first,
           let existing = fetchExistingCatch(icao: dupIcao) {
            let observed = visibleByIcao[dupIcao]
            let plane = pokePlane(from: existing, observed: observed)
            pendingReveal = PendingReveal(
                plane: plane,
                entryNumber: uniqueIcaoCount,
                isDuplicate: true
            )
            return
        }

        // Nothing to present (e.g., all icaos somehow vanished from
        // the model store between the dedup check and the fetch). Drop
        // the in-flight latch so the button isn't soft-locked.
        captureInFlight = false
    }

    /// Fetches the most-recent stored `Catch` for the given icao24,
    /// or nil if none. Used by `presentReveal` to synthesize a
    /// `PokePlane` for duplicate entries (both single + multi paths).
    private func fetchExistingCatch(icao: String) -> Catch? {
        let key = icao.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var descriptor = FetchDescriptor<Catch>(
            predicate: #Predicate { $0.icao24 == key },
            sortBy: [SortDescriptor(\.caughtAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Build a presentational `PokePlane` from a stored `Catch`,
    /// borrowing live alt/speed values from `observed` when the
    /// catch is still in view. Used by both the new-catch and
    /// duplicate paths so the reveal renders consistently.
    private func pokePlane(from row: Catch, observed: ObservedAircraft?) -> PokePlane {
        let altFt = (observed?.aircraft.altitudeMeters).map { Int(($0 * 3.28084).rounded()) }
        let speedKt: Int? = observed?.aircraft.velocityMps.map { Int(($0 * 1.94384).rounded()) }
        let distMeters = observed?.slantDistanceMeters ?? row.slantDistanceMeters
        return PokePlane(
            callsign: row.callsign,
            model: row.model,
            carrier: row.operatorName,
            rarity: row.resolvedRarity,
            type: row.resolvedType,
            altText: altFt.map { "\($0.formatted(.number)) ft" },
            speedText: speedKt.map { "\($0) kt" },
            distText: String(format: "%.1f km", distMeters / 1000),
            photoURL: row.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) }
        )
    }

    /// Big central capture button. A single circle that is always
    /// present; multi-mode adds a small magenta `×N` badge in the
    /// top-right corner.
    private func captureButton(mode: CaptureMode) -> some View {
        let isMulti: Bool = {
            if case .multi = mode { return true }
            return false
        }()
        let count: Int = {
            if case .multi(let icaos) = mode { return icaos.count }
            return 0
        }()
        let isEnabled: Bool = {
            if case .disabled = mode { return false }
            return true
        }()

        return Button {
            guard isEnabled else { return }
            performCatch(mode: mode)
        } label: {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(Brand.Color.bgPrimary.opacity(0.7))
                        .frame(width: 72, height: 72)
                    Circle()
                        .strokeBorder(Brand.Color.cyan, lineWidth: 2.5)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(Brand.Color.cyan.opacity(0.15))
                        .frame(width: 60, height: 60)
                    Text("CAPTURE")
                        .font(.system(size: 10, weight: .bold,
                                      design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(Brand.Color.cyan)
                }
                if isMulti {
                    Text("×\(count)")
                        .font(.system(size: 9, weight: .bold,
                                      design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Brand.Color.alertAdvisory, in: .capsule)
                        .overlay(
                            Capsule()
                                .strokeBorder(Brand.Color.bgPrimary,
                                              lineWidth: 2)
                        )
                        .offset(x: 4, y: -4)
                }
            }
            .opacity(isEnabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(captureA11y(mode: mode))
    }

    private func captureA11y(mode: CaptureMode) -> String {
        switch mode {
        case .disabled:         return "Capture (no aircraft in view)"
        case .single(let icao): return "Capture \(icao)"
        case .multi(let icaos): return "Capture \(icaos.count) aircraft"
        }
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
    ///     `forceLock` the engine straight to a locked state (the tap
    ///     is an explicit choice, no acquisition delay).
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
        // Spec § 3.1: four-branch behavior.
        //   1. Tap directly on a plane (≤100 px) → pin (toggle if same).
        //   2. Tap empty sky while pinned        → clear pin.
        //   3. Tap empty sky while not pinned    → widen radius to
        //      250 px and pin the nearest visible plane to the tap.
        //   4. Truly empty frame                 → ripple at tap point.
        let cap = min(screenSize.width, screenSize.height) / 2
        let pinned = pinnedIcao

        // (1) Narrow-radius hit-test: ≤100 px (scaled by zoom, capped
        // at half the screen) so a deliberate tap on a labeled plane
        // pins immediately.
        let narrowRadius = min(100 * zoom, cap)
        if let icao = closestTargetIcao24(
            in: visible,
            at: point,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            lockZoneRadius: narrowRadius
        ) {
            if icao == pinned {
                // Tap-same-plane toggles off — explicit "cancel."
                // Both writes required: T5's .onChange housekeeping
                // covers engine → view only; without unpin() the engine
                // would still hold .locked until forced.
                recorder.recordUnpin(at: now)
                pinnedIcao = nil
                lockOn.unpin()
            } else {
                pinnedIcao = icao
                recorder.recordTapPin(icao24: icao, at: now)
                // forceLock is the only way into .locked — the user
                // just pointed at this plane, so the engine jumps
                // straight to a locked state.
                lockOn.forceLock(targetIcao24: icao, now: now)
            }
            return
        }

        // (2) Empty sky while pinned → clear the pin.
        if pinned != nil {
            recorder.recordUnpin(at: now)
            pinnedIcao = nil
            lockOn.unpin()
            return
        }

        // (3) Empty sky, no pin → "try harder": widen to 250 px and
        // pin the nearest visible plane (if any falls inside).
        let wideRadius = min(250 * zoom, cap)
        if let icao = closestTargetIcao24(
            in: visible,
            at: point,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            lockZoneRadius: wideRadius
        ) {
            pinnedIcao = icao
            recorder.recordTapPin(icao24: icao, at: now)
            lockOn.forceLock(targetIcao24: icao, now: now)
            return
        }

        // (4) Truly empty frame — brief NO AIRCRAFT HERE ripple at
        // the tap point.
        showEmptyTapRipple(at: point)
    }

    /// Trigger a brief NO AIRCRAFT HERE ripple at the given tap
    /// location. Auto-clears after 1.0 s.
    private func showEmptyTapRipple(at point: CGPoint) {
        let now = Date()
        emptyRipple = (point, now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if let r = emptyRipple, r.1 == now {
                emptyRipple = nil
            }
        }
    }
}

// MARK: - Per-plane ambient label

/// Per-plane label rendered above the aircraft's projected screen
/// position. Every visible plane gets one: faint cyan corner brackets
/// + a small "CALLSIGN · RARITY" pill. The pinned plane (if any) swaps
/// to the bright/expanded variant — thicker, larger brackets and an
/// expanded pill that includes the rarity's base-point award.
///
/// `.allowsHitTesting(false)` so taps fall through to the underlying
/// gesture layer in ContentView (which handles pin/unpin). The
/// dim/bright pin contrast is the only signal that a tap landed.
private struct PlaneLabel: View {
    let aircraft: ObservedAircraft
    let position: CGPoint
    let isPinned: Bool
    /// True when something ELSE is pinned. Dims this label to ~35 %
    /// so the pinned plane reads as primary.
    let isDimmed: Bool
    /// Cached metadata for this plane, if available. Drives the
    /// rarity classification — without metadata the classifier
    /// falls back to (.common, .narrow).
    let metadata: AircraftMetadata?

    var body: some View {
        let (rarity, _) = AircraftClassifier.classify(
            manufacturer: metadata?.manufacturerName,
            model: metadata?.model,
            operatorName: metadata?.operatorName
        )
        let callsign = aircraft.aircraft.callsign?
            .trimmingCharacters(in: .whitespaces)
            .nonEmpty
            ?? aircraft.aircraft.icao24.uppercased()
        let bracketBoxSize: CGFloat = isPinned ? 56 : 36
        let bracketLineWidth: CGFloat = isPinned ? 2.5 : 1.2
        let bracketOpacity: Double = isPinned ? 1.0 : 0.55

        VStack(spacing: 2) {
            LockBrackets(
                boxSize: bracketBoxSize,
                color: Brand.Color.cyan,
                opacity: bracketOpacity,
                lineWidth: bracketLineWidth
            )
            HStack(spacing: 4) {
                Text(callsign)
                    .font(.system(
                        size: isPinned ? 11 : 9,
                        weight: .bold,
                        design: .monospaced
                    ))
                    .foregroundStyle(Brand.Color.cyan)
                if isPinned {
                    Text("· \(rarity.label) +\(rarity.basePoints)")
                        .font(.system(size: 9, weight: .semibold,
                                      design: .monospaced))
                        .foregroundStyle(rarity.tint)
                } else {
                    Text("· \(rarity.label)")
                        .font(.system(size: 8, weight: .semibold,
                                      design: .monospaced))
                        .foregroundStyle(rarity.tint)
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Brand.Color.bgPrimary.opacity(0.55),
                        in: .rect(cornerRadius: 4))
        }
        .position(position)
        .opacity(isDimmed ? 0.35 : 1.0)
        .allowsHitTesting(false)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
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

// MARK: - Empty-tap ripple

/// Brief NO AIRCRAFT HERE feedback at the tap point. Shown when the
/// user taps an area with no nearby visible aircraft (after the
/// widened 250 px search has also come up empty). Expands a thin
/// cyan ring from 20 → 100 pt over ~0.8 s and fades both ring and
/// caption to zero. `since` is the trigger timestamp — read by the
/// inner `TimelineView` to drive the animation off the date diff
/// rather than `.withAnimation`, so the view is self-contained.
private struct EmptyTapRippleView: View {
    let at: CGPoint
    let since: Date

    var body: some View {
        TimelineView(.animation) { ctx in
            let dt = ctx.date.timeIntervalSince(since)
            let progress = min(1.0, dt / 0.8)
            ZStack {
                Circle()
                    .stroke(Brand.Color.cyan.opacity(1.0 - progress),
                            lineWidth: 1.5)
                    .frame(width: CGFloat(20 + progress * 80),
                           height: CGFloat(20 + progress * 80))
                if progress < 0.95 {
                    Text("NO AIRCRAFT HERE")
                        .font(.system(size: 9, weight: .semibold,
                                      design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Brand.Color.cyan.opacity(1.0 - progress))
                        .padding(.top, 60)
                }
            }
            .position(at)
        }
    }
}

#Preview {
    ContentView()
}
