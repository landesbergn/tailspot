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
import CoreLocation   // CLAuthorizationStatus cases in the denied-recovery check
import StoreKit       // \.requestReview environment action (the review ask)
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
    /// at the bad threshold. Shared with the calibration sheet via
    /// `CompassAccuracy.goodDeg` so the two can't disagree again.
    private static let compassGoodThreshold: Double = CompassAccuracy.goodDeg
    /// Seconds of continuously-bad readings before the badge appears.
    /// A momentary spike (passing under a bridge, briefly near a car)
    /// shouldn't surface a warning.
    private static let compassBadDebounce: TimeInterval = 4.0

    @Environment(\.modelContext) private var modelContext
    /// Drives lifecycle teardown: when the app resigns active we stop the
    /// motion + ADS-B loops (no one's looking, no network worth running);
    /// on return to active we restart them. See the `.onChange(of:
    /// scenePhase)` handler below. (The app-level scenePhase handler in
    /// TailspotApp owns the upload/sync-on-foreground side, separately.)
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var location = LocationManager()
    @StateObject private var motion = MotionManager()
    @StateObject private var adsb = ADSBManager()
    /// LEGACY catch mode only (`CatchMode.legacy`): the tap-to-pin state
    /// machine. Stays `.idle` for the whole session while the frame mode
    /// is live — nothing calls `update`/`forceLock` on it there.
    @StateObject private var lockOn = LockOnEngine()
    /// Catch-mode A/B switch (2026-09-02, see `CatchMode.swift`). The raw
    /// stored choice; `catchMode` below is what the view actually runs
    /// (Release builds ignore the store). The wrench-panel `catchModeRow`
    /// is the only writer — via `setCatchMode`, which also clears the
    /// mode-specific state the other mode left behind.
    @AppStorage(CatchMode.storageKey) private var catchModeRaw: String = CatchMode.default.rawValue
    private var catchMode: CatchMode { CatchMode.effective(stored: catchModeRaw) }
    /// Field-session recorder for replay/regression. Off by default;
    /// the debug overlay carries a tap-to-start row. When active a 1 Hz
    /// task captures the current sensor state + visible aircraft and
    /// appends a tick line to `Documents/replays/replay-<utc>.jsonl`.
    @StateObject private var recorder = ReplayRecorder()
    /// Captures the session's os.Logger output to a `.log` paired with the
    /// recording (U3); driven by the same record toggle as the recorder.
    @State private var logCapture = LogCapture()
    @State private var cameraAuthorized = false
    /// True only after an explicit camera denial (vs. not-yet-asked) — the
    /// difference between "wait for the prompt" and "show Open Settings".
    @State private var cameraDenied = false
    /// Hidden by default. Tap the small wrench glyph in the top-right
    /// to reveal the sensor readout (top) + nearby-aircraft list
    /// (bottom). Field-testing UI is intentionally clean; raw sensor
    /// dumps are for inspection, not normal use.
    @State private var showDebug = false
    #if DEBUG
    /// Cycles the debug "Simulate catch" preset (tier) on each tap.
    @State private var simCatchIndex = 0
    /// Bumped to force the wrench panel's STREAK row to re-read the
    /// override, which lives in UserDefaults where SwiftUI can't see it.
    @State private var streakDebugRefresh = 0
    /// Last line the STREAK row printed (permission state, what's queued,
    /// or the result of a manual fire).
    @State private var streakDebugStatus = "—"
    #endif
    /// DEBUG-only: presents the trophy-icon gallery for visual review.
    @State private var showIconGallery = false
    /// Drives the Hangar sheet (collection of past catches). Opened
    /// via the tray glyph in the top-trailing corner.
    @State private var showHangar = false
    /// Drives the Profile sheet (gamification hub: stats, trophies,
    /// sets, map, leaderboard, settings, notifications, share).
    /// Opened via the person glyph in the top-trailing corner.
    @State private var showProfile = false
    /// Becomes true only once the Hangar/Profile presentation animation has
    /// settled. The request flags above flip at tap time, and even the sheet
    /// content's `onAppear` runs before its first visible frame is committed;
    /// using either signal directly for camera occlusion detaches the preview
    /// first and exposes a black frame while the destination is still loading.
    @State private var primarySheetVisible = false
    /// Drives the compass calibration sheet. Tapping the AR
    /// caution badge sets this true; the sheet explains what's
    /// wrong and shows the figure-8 calibration motion.
    @State private var showCompassSheet = false
    /// Lightweight @Query used only to render the catch-count badge
    /// on the Hangar button. HangarView runs its own @Query for the
    /// actual list — keeping these separate means ContentView's body
    /// doesn't re-evaluate the full sorted list on every catch.
    @Query private var catches: [Catch]
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
    /// User-asserted planes (frame-is-the-catch, 2026-08-28): icao24 →
    /// the last instant the plane was confirmed on frame (or the assert
    /// time, until the 1 Hz prune first sees it). An assertion is the
    /// user saying "there's a plane here you're not showing me" — a tap
    /// on a faint-tier label, or an empty-sky tap whose diagnosis says
    /// `filtered` / `off-frame` (the FDX1268 / DAL972 rescue classes).
    /// Asserted planes label bright, are guaranteed a press slot, and
    /// are exempt from the occlusion demote. Lifetime (D5): refreshed
    /// while the plane projects onto the frame, dropped after
    /// `assertedGraceSeconds` off-frame or the moment it leaves the
    /// data — pruned at 1 Hz in the ambient poll task, never in `body`.
    @State private var assertedPlanes: [String: Date] = [:]
    /// LEGACY catch mode only: the tap-pinned plane. Overrides the
    /// center-driven closest-target heuristic; tap-elsewhere clears,
    /// tap-same-plane toggles off, the plane leaving visibility clears
    /// (via the 1 Hz `pruneLegacyPin`). Taps drive `forceLock()` on the
    /// engine — the only way into `.locked`. Always nil in the frame mode.
    @State private var pinnedIcao: String?
    /// LEGACY catch mode only: tap-to-reveal (2026-06-19) — a plane the
    /// user tapped even though the visibility filter hid it (the FDX1268
    /// class). Surfaced as visible for labeling / lock / catch only while
    /// it is the pin; always kept equal to `pinnedIcao` while set, cleared
    /// together with it. The frame mode's equivalent is `assertedPlanes`.
    @State private var revealedIcao: String?
    /// The AR view's current size, captured from the GeometryReader so
    /// the 1 Hz asserted-plane prune can project without a body pass.
    @State private var arScreenSize: CGSize = .zero
    /// URL of the recording the user wants to analyze. Non-nil →
    /// `ReplayReportView` sheet is presented for that file.
    @State private var replayURL: URL?
    /// Bridges to `PreviewView` so the auto-catch path can grab a
    /// still photo. `PreviewView.bridgeCapture(to:)` installs the
    /// capture closure at `makeUIView` time. Held via `@State` (not
    /// `@StateObject`) — it's a one-method mailbox, not a publisher.
    @State private var captureBridge = CameraCaptureBridge()
    /// Frame tap for visual confirmation — same mailbox pattern as
    /// captureBridge. Wired to the pipeline in the root `.task` below.
    @State private var frameBridge = CameraFrameBridge()
    /// Visual confirmation: detector + tracker behind the camera tap
    /// (SWIFT-DESIGN.md). Publishes per-icao corrected positions that the
    /// lock bracket prefers over the geometric prediction.
    @StateObject private var visualConfirm = VisualConfirmationPipeline()
    /// Guards re-entry of the capture button while a catch is in
    /// flight. Cleared when the user dismisses the reveal sheet.
    /// NOTE: T7 un-wired the read at the button site when collapsing
    /// the multi-button chrome. T8 will re-wire inside the new merged
    /// `performCatch(mode:)`. Reveal-dismiss callbacks still clear it.
    @State private var captureInFlight = false
    /// Post-catch confirm (2026-07-04, replaces the pre-catch block nudge):
    /// the suspected rows of the just-revealed catch, stashed by `runCatch`
    /// and promoted into `pendingSuspectReview` when the reveal dismisses —
    /// the review must never interrupt the reveal moment itself.
    @State private var suspectAwaitingReview: [Catch] = []
    /// Streak notification pre-prompt, staged by the catch path when the
    /// just-landed catch made the streak worth protecting (eligibility in
    /// `StreakReminders.shouldOfferAsk`) and promoted at reveal dismiss —
    /// never shown over the reveal ceremony or a Keep/Discard review.
    /// The value is the current streak the card quotes.
    @State private var pendingStreakAsk: Int? = nil
    /// The presented pre-prompt card (nil = hidden). One-shot: presenting
    /// latches `StreakReminders.permissionAskedKey` immediately, so a kill
    /// mid-card still counts as asked.
    @State private var streakAsk: Int? = nil
    /// True while the visible card was forced by the wrench's 🔔 Ask —
    /// keeps the ask-shown/response events real-promotions-only (the
    /// debug-seam rule: debug paths stay out of telemetry).
    @State private var streakAskFromDebug = false
    /// Non-nil → the one-question Keep/Discard review dialog is up.
    @State private var pendingSuspectReview: SuspectReview?
    /// Ambient "you're indoors" hint, shown proactively when the camera
    /// has read a confident not-sky frame for a sustained spell (so a
    /// brief misread doesn't nag). Auto-clears the moment it sees sky.
    @State private var pointedIndoors = false
    @State private var indoorStreak = 0
    /// When the hint appeared — feeds `indoor_hint_cleared`'s duration.
    @State private var indoorHintShownAt: Date?
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
    /// When the in-card BONUS ROUND's chips popped — the deliberation clock for
    /// the `_answered`/`_skipped` elapsed-ms telemetry. Stamped by the reveal's
    /// `onGuessShown` (chips-pop) callback, read by `onGuessResolved`.
    @State private var guessShownAt: Date?
    /// Bonus-round cadence + kind decider (game-layer PR3). Owns the persistent
    /// UserDefaults counters; one instance for the app's life. `@State` holds
    /// the reference stably across body re-renders (no observation needed —
    /// it's a plain decision object, not an ObservableObject).
    @State private var guessScheduler = GuessScheduler()
    /// Owns the trophy unlock queue + ledger. Seeded on its first
    /// `enqueueNewUnlocks` (fired by the `catches`-count task below), so an
    /// existing tester is never flooded. Survives the Hangar sheet as a
    /// `@StateObject`, so a moment interrupted by backgrounding re-renders
    /// on return (the overlay is declarative, bound to `hasPending`).
    @StateObject private var unlockCenter = TrophyUnlockCenter()
    /// Hangar restore-from-server (PLAN §9 #7, issue #58): checks once per
    /// launch whether this (Keychain-surviving) device identity holds
    /// catches on the backend while the local Hangar is empty — the
    /// reinstall signature — and, if so, drives the restore prompt overlay.
    @StateObject private var restoreManager = HangarRestoreManager()
    /// One-shot recovery runner (see MissedCatchRepair). Holds no observable
    /// state — it just needs somewhere to live — so a plain `let`, not a
    /// `@StateObject`.
    private let missedCatchRepair = MissedCatchRepairRunner()
    /// Counter that triggers `sensoryFeedback(.success)` once per
    /// catch (Bool trigger collapses repeats; a counter doesn't).
    @State private var catchHaptic = 0
    /// Same-frame capture acknowledgment (capture-lag work, 2026-08-13):
    /// the impact haptic + shutter flash fire at the TAP, not at pipeline
    /// end — a working press must be distinguishable from a missed one
    /// before any async work starts. Counter, like `catchHaptic`.
    @State private var captureTapHaptic = 0
    /// Drives the brief white shutter-flash overlay; set true at the tap,
    /// animated back to false ~70 ms later.
    @State private var captureFlash = false
    /// Collapsed by default. Tap the NEARBY AIRCRAFT header in the
    /// debug panel to expand the per-plane list.
    @State private var showAircraftList = false
    /// Active empty-tap ripple, if any: (tap point, timestamp). Set by
    /// `showEmptyTapRipple` when a tap lands in truly empty sky (no
    /// plane within the widened 250 px search). Auto-clears after 1.0 s
    /// so the ripple doesn't linger.
    @State private var emptyRipple: (CGPoint, Date)? = nil
    /// The ONE active transient top toast, or nil. Grounded / far-tap /
    /// save-fail / streak all share this slot, so two can never stack into
    /// overlapping capsules — the failure mode three independent overlays
    /// made possible. The timestamp guards the auto-clear against clearing
    /// a NEWER toast (same pattern as `emptyRipple`).
    @State private var topToast: (kind: TopToast, at: Date)? = nil
    /// Set when the post-catch `modelContext.save()` throws; flushed into
    /// the save-failure toast when the reveal dismisses (presenting at
    /// catch time would hide it behind the full-screen reveal). Without
    /// this the reveal has already played, so a lost catch reads as a
    /// success (error-copy pass, 2026-08-14).
    @State private var pendingSaveFailToast = false
    /// Reminder-tap → camera-toast channel, injected by `TailspotApp`. The
    /// delegate is app-level and the toast slot is ContentView-private, so
    /// the streak line crosses the boundary through this small observable.
    @Environment(StreakToastRelay.self) private var streakRelay
    /// Cached content signature of the currently-visible icao24 set — the id
    /// that keys the ambient-metadata prefetch `.task(id:)`. CACHED (not a
    /// computed var) so `body` doesn't rebuild it (map+sort+join over all
    /// observed) on every 30 Hz frame; it's recomputed only when `observed`
    /// republishes (~1 Hz) in `.onReceive(adsb.$observed)`. Membership-change
    /// semantics are unchanged — the string only differs when the set does.
    @State private var visibleIcaoSignature = ""
    /// Session latch for the "first plane seen" activation telemetry. The fire
    /// itself is once-per-install (persisted), but this short-circuits the
    /// per-tick filter work in `.onReceive(adsb.$observed)` after it's latched.
    @State private var firstPlaneSeenLatched = false
    /// Cached most-recent replay recording for the debug `analyzeRow`, so that
    /// row doesn't do a FileManager directory scan on every body eval. Refreshed
    /// when the debug panel opens and after a recording is toggled off.
    @State private var latestRecordingURL: URL?

    var body: some View {
        ZStack {
            // Main AR view and overlays (camera, lock brackets, debug panels, etc.)
            ZStack {
                if cameraAuthorized {
                    // isActive: the capture session powers down while an
                    // opaque sheet covers the AR view or the app resigns
                    // active — the ISP + 30 fps frame delivery were the
                    // biggest controllable battery drain (audit HIGH;
                    // Noah green-lit the camera lever 2026-07-19). Clear-
                    // background reveals don't occlude, so the live sky
                    // stays visible behind them.
                    CameraPreview(zoomFactor: zoom, captureBridge: captureBridge,
                                  frameBridge: frameBridge,
                                  isActive: scenePhase == .active && !arOccluded)
                        .ignoresSafeArea()
                        // PRIVACY (GA posture, 2026-07-11): the live camera view
                        // is excluded from PostHog session replay STRUCTURALLY,
                        // not via .postHogMask(). Replay's screenshot capture
                        // uses drawHierarchy(afterScreenUpdates:false), which
                        // cannot read AVCaptureVideoPreviewLayer's out-of-process
                        // video surface — the camera region records as black
                        // (verified live in the 2026-06 replay-debugging round).
                        // Do NOT re-add .postHogMask() here: this view spans the
                        // whole window, and PostHog redacts by drawing each
                        // masked view's rect over the flat screenshot — a
                        // full-window rect blacks out EVERY replay frame,
                        // including the AR overlays on top and the sheets
                        // presented over this root (that was the all-black-replay
                        // bug). The structural guarantee is pinned by
                        // SessionReplayPrivacyTests: PreviewView must stay backed
                        // by AVCaptureVideoPreviewLayer (never a drawable
                        // image/Metal blit, which drawHierarchy WOULD capture).
                } else {
                    Brand.Color.bgPrimary.ignoresSafeArea()
                }

                // Recovery for explicitly-denied permissions. Before this,
                // a camera denial was a silent black void and a location
                // denial a forever-"waiting" GPS — both first-run dead ends
                // with no way back short of finding Settings unaided.
                if cameraDenied || locationDenied {
                    permissionRecoveryOverlay
                }

                // AR overlay (frame-is-the-catch, 2026-08-28). Every
                // visible plane carries an ambient label; press membership
                // (bright tier, size-ranked, ≤ maxCatchTargets) decides
                // which render full-bright — those are exactly what the
                // capture button catches. Taps assert planes the app
                // isn't showing (faint promotion / hidden rescue); they
                // never select a target.
                //
                // The 30 Hz TimelineView re-derives projections and
                // membership every frame. Membership is pure — repeated
                // update() calls with the same target are idempotent —
                // so calling it from inside the TimelineView body is safe.
                GeometryReader { geo in
                    let effectiveHfov = Self.baseHfovDeg / zoom
                    let effectiveVfov = Self.baseVfovDeg / zoom

                    // `paused: arOccluded` freezes this 30 Hz render loop
                    // while an opaque sheet covers the AR view — no point
                    // re-projecting labels the user can't see. It resumes the
                    // instant the sheet dismisses. The clear-background catch
                    // reveals deliberately DON'T set arOccluded (they show the
                    // live AR behind the card), so labels keep gliding there.
                    TimelineView(.animation(minimumInterval: 1.0/30.0, paused: arOccluded)) { context in
                        let now = context.date
                        // Interactive-visible set: the ambient visibility tier
                        // (suppressed while `pointedIndoors`) PLUS any
                        // user-asserted plane — see `interactiveVisible`.
                        // GROUNDED planes are excluded even from the asserted
                        // clause: a parked plane must never label or catch
                        // (the tap path never asserts one — this guard is
                        // belt-and-suspenders).
                        let visible = interactiveVisible(adsb.observed)
                        let heading = location.heading ?? 0
                        let camEl = motion.cameraElevationDeg
                        // Camera roll from the gravity vector (robust at the
                        // portrait hold where Euler roll is unreliable). The
                        // basis is built once per frame and reused for every
                        // label projection below; the tap path takes `roll`
                        // and rebuilds the identical basis internally.
                        let roll = Geo.rollDeg(
                            gravityX: motion.gravityX, gravityY: motion.gravityY, gravityZ: motion.gravityZ
                        )
                        let basis = Geo.cameraBasis(
                            headingDeg: heading, cameraElevationDeg: camEl, rollDeg: roll
                        )

                        // Frame-is-the-catch (2026-08-28): project every
                        // visible plane once; the projections drive the label
                        // layer, the press membership, and the bracket
                        // overlays baked into the saved photo. The frame IS
                        // the zone — there is no catch radius and no pin.
                        let onScreenProjected: [(icao: String, position: CGPoint)] = visible.compactMap { obs in
                            guard let pos = obs.screenPosition(
                                basis: basis,
                                in: geo.size,
                                hfovDeg: effectiveHfov,
                                vfovDeg: effectiveVfov
                            ) else { return nil }
                            return (obs.aircraft.icao24, pos)
                        }
                        let onScreenPositions: [String: CGPoint] = Dictionary(
                            onScreenProjected.map { ($0.icao, $0.position) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        // The per-frame selection — label styles, the
                        // capture mode, the pinned-label draw override —
                        // resolved in ONE place for whichever catch mode is
                        // live (`resolveFrameSelection`): frame mode runs
                        // `chooseCatchMembers` (D1·2/D3·2); legacy mode runs
                        // the LockOnEngine tick + zone/dominance selection.
                        // Pulled out of `body` so the branch costs the
                        // type-checker nothing (ContentView is at budget).
                        let frame = resolveFrameSelection(
                            visible: visible,
                            onScreenPositions: onScreenPositions,
                            screenSize: geo.size,
                            headingDeg: heading,
                            cameraElevationDeg: camEl,
                            rollDeg: roll,
                            hfovDeg: effectiveHfov,
                            vfovDeg: effectiveVfov,
                            now: now
                        )

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
                                                phoneHeadingAccuracyDeg: location.headingAccuracy,
                                                cameraElevationDeg: camEl,
                                                rollDeg: roll,
                                                hfovDeg: effectiveHfov,
                                                vfovDeg: effectiveVfov,
                                                now: now
                                            )
                                        }
                                )

                            // All-frame labels (frame-is-the-catch, D3·2).
                            // Three states, driven by press membership:
                            //   chosen   — full-bright, expanded label with
                            //              points: what a press catches, ≤3.
                            //   quiet    — bright-tier but unchosen. Only
                            //              exists on a >3-bright frame; steps
                            //              down so the ×N badge always equals
                            //              the full-bright count.
                            //   faint    — beyond-confidence tier (2026-06-12
                            //              doctrine): in the data, not in the
                            //              press. Tap to promote.
                            //
                            // Tap handling lives on the underlying
                            // Color.clear background layer above
                            // (handleTap) — labels themselves are
                            // `.allowsHitTesting(false)` so they
                            // don't intercept taps meant for the
                            // plane behind them.
                            ForEach(visible, id: \.aircraft.icao24) { obs in
                                let icao = obs.aircraft.icao24
                                // Legacy mode draws the pinned label at the
                                // detector's live fix when one exists (pre-
                                // catch only — the photo path keeps
                                // `onScreenPositions`); frame mode has no
                                // override, so this IS the projection.
                                if let pos = frame.labelPositions[icao] {
                                    let style = frame.style(for: icao)
                                    let metaForPlane: AircraftMetadata? =
                                        ambientMetadata[icao] ?? nil
                                    PlaneLabel(
                                        aircraft: obs,
                                        position: pos,
                                        style: style,
                                        metadata: metaForPlane
                                    )
                                    // VoiceOver: frame mode reads the plane's
                                    // details (D7 — activation carries no
                                    // behavior; a chosen plane says so in the
                                    // value); legacy mode keeps its pin/unpin
                                    // action. One bundled modifier so the
                                    // chain length is the same in both.
                                    // Nearest plane reads first via sort
                                    // priority.
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(planeAccessibilityLabel(
                                        obs, metadata: metaForPlane))
                                    .modifier(PlaneLabelAccessibility(
                                        style: style,
                                        legacyPinToggle: catchMode == .legacy
                                            ? { accessibilityTogglePin(icao: icao) }
                                            : nil))
                                    .accessibilitySortPriority(-obs.slantDistanceMeters)
                                }
                            }

                            if visible.isEmpty || adsb.lastError != nil {
                                // Empty-sky overlay. Shown when nothing
                                // is in view — OR whenever the feed is
                                // erroring, even with planes still on
                                // screen (error-copy pass, 2026-08-14):
                                // extrapolated labels keep gliding on
                                // stale data during an outage, and
                                // catching against 90-second-old
                                // positions with no warning undercuts
                                // "is the catch real?". The pill's
                                // error variant wins its text switch,
                                // so this never shows "NO AIRCRAFT"
                                // over visible planes.
                                // Quiet center reticle +
                                // a status pill anchored low so it
                                // doesn't compete with the top-center
                                // compass / zoom affordances.
                                // Grounded planes are excluded from the "N
                                // NEARBY" count — they're not below-horizon
                                // or too-far traffic, they're parked.
                                emptySkyOverlay(
                                    // count(where:) tallies without allocating
                                    // the intermediate filtered array (hot path,
                                    // every empty-sky frame).
                                    rawCount: adsb.observed.count(where: { !$0.grounded })
                                )
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

                            // The central capture button stays inside the
                            // TimelineView because its appearance and payload
                            // react to per-frame membership. Hangar/Profile are
                            // rendered once outside this 30 Hz subtree below.
                            // A single always-present capture button with
                            // ONE cause (frame-is-the-catch, D-round 1):
                            // lit exactly when the press membership is
                            // non-empty, ×N badge = chosen count, disabled
                            // only on a genuinely member-less frame. A
                            // press catches exactly the chosen set the
                            // labels are showing full-bright. (Legacy mode:
                            // pin / lone plane / zone + dominance — see
                            // `legacyCaptureMode`.)
                            VStack {
                                Spacer()
                                captureButton(mode: frame.mode, screenSize: geo.size,
                                              positions: onScreenPositions)
                                // Clear the home-indicator gesture zone: pad
                                // from the safe-area bottom when there is one
                                // (`geo` sits inside .ignoresSafeArea(), so the
                                // proxy still reports the insets the expansion
                                // crossed). Falls back to the original 28 pt on
                                // home-button devices — and if the proxy ever
                                // reports zero, behavior is exactly pre-change.
                                .padding(.bottom, max(28, geo.safeAreaInsets.bottom + 12))
                            }
                            .frame(width: geo.size.width,
                                   height: geo.size.height)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    // Mirror the AR view's size into state (initial: true
                    // covers first layout) for the 1 Hz asserted-plane
                    // prune, which projects on-frame checks outside any
                    // GeometryReader.
                    .onChange(of: geo.size, initial: true) { _, size in
                        arScreenSize = size
                    }

                    // Static navigation controls must not inherit the AR
                    // TimelineView's 30 Hz invalidation cadence. A clear
                    // capture-sized spacer preserves the established layout
                    // while taps fall through to the live capture button.
                    VStack {
                        Spacer()
                        HStack {
                            bottomHangarButton
                            Spacer()
                            Color.clear
                                .frame(width: 72, height: 72)
                                .allowsHitTesting(false)
                            Spacer()
                            bottomProfileButton
                        }
                        .padding(.horizontal, 28)
                        .padding(.bottom, max(28, geo.safeAreaInsets.bottom + 12))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .ignoresSafeArea()

                // Top-center floating surfaces share one layout owner so
                // SwiftUI can stack their measured heights. The indoor hint
                // and transient toast used to be separate root overlays with
                // a fixed 60 pt top offset; a tall compass warning therefore
                // overlapped them instead of pushing them down.
                VStack(spacing: 8) {
                    VStack(spacing: 8) {
                        cautionBadge
                        zoomPill
                        #if DEBUG
                        // "Badge the lying screen": while the legacy mode is
                        // live the AR view behaves like the App Store build,
                        // not this branch — say so on screen, always.
                        catchModeBadge
                        #endif
                    }
                    // Keep the loud compass banner off the screen edges
                    // without narrowing the notice/toast region below it.
                    .padding(.horizontal, 16)
                    // Preserve the notices' old 60 pt resting offset when no
                    // compass/zoom affordance is showing: 12 outer padding +
                    // 40 reserved here + 8 stack spacing = 60. When an
                    // affordance is taller, its measured height wins.
                    .frame(minHeight: 40, alignment: .top)

                    indoorHintBanner
                    topToastBanner
                    Spacer()
                }
                .padding(.top, 12)
                .animation(.easeInOut(duration: 0.2), value: isHeadingAccuracyBad)
                .animation(.easeInOut(duration: 0.2), value: zoom > 1.01)
                // One-shot warning haptic the moment the compass latches
                // bad — a felt cue so the banner isn't purely visual (you
                // may be staring at the plane, not the HUD). Fires only on
                // the false→true edge; recovery is silent.
                .sensoryFeedback(trigger: showCompassWarning) { _, isBad in
                    isBad ? .warning : nil
                }

                // Debug overlays — hidden by default; revealed by the
                // wrench toggle below.
                if showDebug {
                    VStack(spacing: 0) {
                        sensorReadout
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        #if DEBUG
                        // Force the trophy-unlock moment so the animation /
                        // haptic / a11y / hidden-reveal path can be eyeballed
                        // on-device without waiting for an organic crossing.
                        HStack(spacing: 8) {
                            Button("✦ Catch") { simulateCatch() }
                            Button("⚑ Unlock") { unlockCenter.debugEnqueueSample(secret: false) }
                            Button("⚑ Secret") { unlockCenter.debugEnqueueSample(secret: true) }
                            Button("⚑ Icons") { showIconGallery = true }
                            // Un-burn the once-per-version review-ask stamp so
                            // the tap-through-a-trophy → rating-sheet path can
                            // be exercised repeatedly (dev builds always show
                            // the sheet; see ReviewPrompt.swift).
                            Button("★ Rearm") { ReviewPrompter.shared.debugClearStamp() }
                        }
                        .font(Brand.Font.mono(size: 11, weight: .bold))
                        .buttonStyle(.bordered)
                        .tint(Brand.Color.cyan)
                        .padding(.horizontal, 12)

                        streakDebugRow
                        #endif

                        Spacer(minLength: 0)

                        aircraftList
                    }
                    .transition(.opacity)
                }

                // Top-trailing control: debug wrench only. Hangar
                // and profile moved to the bottom capture bar so the
                // primary action ("press capture") and the navigation
                // (Hangar / Profile) live together at thumb height.
                //
                // `#if DEBUG` so the wrench (and the panels it toggles)
                // is absent from TestFlight / App Store Release builds —
                // testers see a clean AR view, not the sensor readout
                // dev affordance. Local Xcode Run builds keep it.
                #if DEBUG
                VStack {
                    HStack(spacing: 10) {
                        Spacer()
                        debugToggleButton
                    }
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    Spacer()
                }
                #endif
            }
        }
        .overlay { trophyUnlockOverlay }
        // Restore prompt + streak pre-prompt share one overlay link — body's
        // modifier chain is AT the type-check budget (PR #184), so additions
        // ride existing links instead of adding new ones. The two can't
        // co-fire: restore needs an EMPTY Hangar, the streak ask a 2-day
        // catch streak.
        .overlay { hangarRestoreOverlay; streakAskOverlay }
        // Seed at launch and re-diff on every new catch (idempotent +
        // deduped). Drives the catch-flow celebration; the reveal cover
        // shows first, then this overlay once it dismisses.
        .task(id: catches.count) {
            unlockCenter.enqueueNewUnlocks(from: catches)
        }
        // Hangar restore check — once per launch, self-gating (empty local
        // Hangar + registered identity + server catches > 0). It waits for
        // TailspotApp's launch registration rather than registering itself,
        // so a fresh install can't race two POST /v1/devices calls.
        .task {
            await restoreManager.checkIfNeeded(context: modelContext)
        }
        // One-shot recovery of two catches that never reached the server (see
        // MissedCatchRepair). Double-gated on device id + a fixed uuid
        // allowlist, so on every other install this returns immediately
        // without touching the network. Delete once it has run.
        .task {
            await missedCatchRepair.runIfNeeded(context: modelContext)
        }
        // When the Hangar closes, re-diff — a country backfill done inside
        // CatchDetailView can cross Mr. Worldwide while the sheet was open.
        .onChange(of: showHangar) { _, isShowing in
            if !isShowing {
                primarySheetVisible = false
                unlockCenter.enqueueNewUnlocks(from: catches)
            }
        }
        // Same on Profile close — the leaderboard fetches inside that sheet
        // (ProfileScreen standing + LeaderboardScreen boards) refresh the
        // cached server facts, and a Monday crown can cross Top Flight /
        // Dynasty / Chart Topper while it's open. Re-diffing here makes the
        // FIRST live crossing celebrate as soon as the sheet dismisses.
        .onChange(of: showProfile) { _, isShowing in
            if !isShowing {
                primarySheetVisible = false
                unlockCenter.enqueueNewUnlocks(from: catches)
            }
        }
        .sheet(isPresented: $showHangar) {
            HangarView()
                .task { await occludeARAfterPrimarySheetPresents() }
        }
        .sheet(isPresented: $showProfile) {
            ProfileScreen()
                .task { await occludeARAfterPrimarySheetPresents() }
        }
        .sheet(isPresented: $showCompassSheet) {
            CompassCalibrationSheet(location: location)
        }
        #if DEBUG
        .sheet(isPresented: $showIconGallery) { TrophyIconGallery() }
        #endif
        .task {
            await requestCameraPermission()
            location.requestPermissionAndStart()
            motion.start()
            adsb.start { location.cllocation }
        }
        // Occlusion gating: while an opaque sheet covers the AR view, stop the
        // 30 Hz motion feed and the 1 Hz re-annotation. The 10 s ADS-B poll
        // keeps running so data stays fresh. Resume both when the sheet
        // dismisses. Clear-background reveals never flip arOccluded, so they
        // don't reach here (see `arOccluded`). The detector target is
        // cleared too (a nil target makes the pipeline skip inference) —
        // only the legacy mode ever sets one (pre-press tracking of the
        // pinned plane); the frame mode runs the detector at catch time
        // only, so for it this is a no-op. The render loop re-establishes
        // the legacy target on its next tick.
        .onChange(of: arOccluded) { _, occluded in
            if occluded {
                motion.stop()
                adsb.pauseReAnnotation()
                visualConfirm.updateTarget(nil)
            } else {
                motion.start()
                adsb.resumeReAnnotation()
            }
        }
        // Lifecycle teardown: when the app resigns active nobody's looking, so
        // stop the motion feed and BOTH ADS-B loops (no network worth running
        // between resign-active and suspension) and drop the detector target.
        // On return to active, restart the ADS-B loops (idempotent) and the
        // motion feed — but only if the AR is actually on screen. If a sheet is
        // still up we also re-pause re-annotation, since arOccluded didn't
        // change across the background trip so its onChange won't fire. The
        // first-launch startup runs in the `.task` above (scenePhase starts
        // `.active`, and onChange fires only on CHANGES) so the two don't
        // double-start. LocationManager is intentionally left untouched here
        // (GPS lifecycle is out of scope).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                adsb.start { location.cllocation }
                if arOccluded {
                    adsb.pauseReAnnotation()
                } else {
                    motion.start()
                }
            case .inactive, .background:
                motion.stop()
                adsb.stop()
                visualConfirm.updateTarget(nil)
            @unknown default:
                break
            }
        }
        // Refresh the cached most-recent recording when the debug panel opens
        // (and see `toggleRecording`) so `analyzeRow` doesn't scan the replays
        // directory on every body eval.
        .onChange(of: showDebug) { _, isShowing in
            if isShowing { latestRecordingURL = ReplayRecorder.mostRecentRecording() }
        }
        // Ambient metadata prefetch for all-frame labels. The id is a
        // content-keyed signature of the currently-visible icao24
        // set (sorted, joined) so it only re-runs when membership
        // actually changes — not on every TimelineView tick. The
        // MetadataCache actor dedupes lookups, so the first sighting
        // of an icao24 fires a single OpenSky request and every later
        // observation is a free in-memory hit.
        .task(id: visibleIcaoSignature) {
            // Body extracted to a method: the inline task-group closure made
            // this one expression too complex for the type checker (compile
            // error), and a named function with explicit types is clearer
            // anyway.
            await prefetchAmbientMetadata()
        }
        // Compass-warning debounce. Watches CL's heading accuracy
        // and only flips the badge on after a sustained-bad streak.
        // Hysteresis floor on the dismiss side keeps the badge stable
        // when accuracy hovers near the threshold.
        .onChange(of: location.headingAccuracy ?? -1) { _, newAcc in
            updateCompassWarning(accuracy: newAcc)
        }
        // Catch feedback surface: pipeline-end success haptic + tap-time
        // impact haptic + shutter flash (see `performCatch`). Bundled into
        // ONE modifier because `body` is a single expression already at the
        // type-check budget — adding chain links here times out the compiler.
        .modifier(CaptureFeedback(
            catchHaptic: catchHaptic,
            tapHaptic: captureTapHaptic,
            flash: captureFlash
        ))
        // Card-reveal moment. Replaces the v0 green flash overlay.
        // Presented full-screen so the rarity bloom + holo card fill
        // the device. Dismiss path either closes the sheet (Keep
        // spotting) or closes + opens the Hangar (View in Hangar).
        .fullScreenCover(item: $pendingReveal) { reveal in
            CatchRevealView(
                plane: reveal.plane,
                entryNumber: reveal.entryNumber,
                onDismiss: {
                    pendingReveal = nil
                    captureInFlight = false
                    guessShownAt = nil
                    presentSuspectReviewIfNeeded()
                },
                onViewInHangar: {
                    pendingReveal = nil
                    captureInFlight = false
                    guessShownAt = nil
                    showHangar = true
                    presentSuspectReviewIfNeeded()
                },
                isDuplicate: reveal.isDuplicate,
                // In-card BONUS ROUND (game-layer PR3; in-card per Noah
                // 2026-07-10). The round is threaded INTO the reveal — no
                // separate cover. Telemetry fires here: `shown` when the chips
                // pop, `answered`/`skipped` on resolve; the ✦ Catch simulator
                // keeps its `isSimulated` mute (no telemetry, transient row).
                guess: reveal.guess,
                // With an early-shell loader the question can arrive AFTER
                // presentation, so the callbacks must exist whenever a loader
                // does — they only ever fire once chips actually pop.
                onGuessShown: (reveal.guess == nil && reveal.loader == nil) ? nil : {
                    guessShownAt = Date()
                    if !reveal.isSimulated {
                        CatchTelemetry.fireGuessRoundShown(kind: .route)
                    }
                },
                onGuessResolved: (reveal.guess == nil && reveal.loader == nil) ? nil : { answeredValue, correct in
                    let elapsedMs = guessShownAt.map { Int(Date().timeIntervalSince($0) * 1000) }
                    // Freeze the outcome onto the row (like serverUuid — after
                    // the row is born). A SKIP / dismiss (nil value) freezes
                    // nothing, leaving all three guess fields nil. The shell
                    // path's row arrives via the loader (it didn't exist at
                    // presentation).
                    if let answeredValue, let row = reveal.loader?.row ?? reveal.row {
                        row.guessKind = GuessKind.route.rawValue
                        row.guessValue = answeredValue
                        row.guessCorrect = correct
                        if !reveal.isSimulated {
                            try? modelContext.save()
                            CatchTelemetry.fireGuessRoundAnswered(
                                kind: .route, correct: correct, elapsedMs: elapsedMs)
                        }
                    } else if !reveal.isSimulated {
                        CatchTelemetry.fireGuessRoundSkipped(kind: .route, elapsedMs: elapsedMs)
                    }
                },
                streakDays: reveal.streakDays,
                loader: reveal.loader
            )
            .presentationBackground(.clear)
        }
        // Multi-catch reveal — N≥2 catch cards staggered in with a
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
                    presentSuspectReviewIfNeeded()
                },
                onViewInHangar: {
                    pendingMultiReveal = nil
                    captureInFlight = false
                    showHangar = true
                    presentSuspectReviewIfNeeded()
                }
            )
            .presentationBackground(.clear)
        }
        // Post-catch confirm: one Keep/Discard question for the suspected
        // rows of the catch that just revealed. Keep vouches (un-quarantines
        // → uploads next scene-activation); Discard deletes — the earned
        // confirm/deny signal. Cancel-free by design: dismissing without
        // answering leaves the rows quarantined locally, re-asked never
        // (they stay in the Hangar, off the leaderboard).
        .confirmationDialog(
            suspectReviewQuestion,
            isPresented: suspectReviewPresented,
            titleVisibility: .visible
        ) {
            suspectReviewActions
        }
        // 1 Hz replay capture loop. Re-launches whenever the recorder
        // toggles on; tears down when it toggles off (Task is cancelled
        // because .task(id:) re-runs on id change).
        .task(id: recorder.isRecording) {
            // Mirror the recording flag into the detection pipeline so it
            // saves ground-truth crop frames alongside the replay JSONL.
            visualConfirm.setRecording(recorder.isRecording)
            guard recorder.isRecording else { return }
            while recorder.isRecording, !Task.isCancelled {
                recordReplayTick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            // Wire the camera frame tap into the detection pipeline once.
            // The handler runs on the camera's video queue; ingestFrame is
            // nonisolated and lock-guarded for exactly that.
            frameBridge.frameHandler = { [weak visualConfirm] buffer in
                visualConfirm?.ingestFrame(buffer)
                // Activation funnel: the first camera frame EVER means the
                // user reached a live AR view (permissions granted, session
                // up). Once-per-install latch inside; the guard is a cached
                // UserDefaults bool read, cheap enough for the frame path.
                ActivationTelemetry.fireARFirstFrameOnce()
            }
        }
        // Activation funnel: the first time any plane label is actually
        // visible (post-filter), the user has something to catch. ~1 Hz
        // re-annotation cadence; once-per-install latch inside the fire.
        // Skipped while pointedIndoors — no label rendered means the user
        // did NOT see a plane, and this latch fires once per install.
        .onReceive(adsb.$observed) { observed in
            // Recompute the prefetch-task signature HERE (~1 Hz, on each
            // `observed` publish) instead of in `body` on every 30 Hz frame.
            // Must run before the latch's early-return below, or the signature
            // would freeze once the activation telemetry latches.
            visibleIcaoSignature = interactiveVisible(observed)
                .map(\.aircraft.icao24)
                .sorted()
                .joined(separator: ",")

            // Activation funnel: fire once when the first plane is actually
            // visible (post-filter). The fire is once-per-install (persisted);
            // `firstPlaneSeenLatched` short-circuits the per-tick filter work
            // for the rest of this session once we've reached that point.
            guard !firstPlaneSeenLatched else { return }
            guard !pointedIndoors else { return }
            let visible = observed.filter(\.isLikelyVisibleToObserver)
            guard !visible.isEmpty else { return }
            ActivationTelemetry.fireFirstPlaneSeenOnce(visibleCount: visible.count)
            firstPlaneSeenLatched = true
        }
        // Ambient indoor hint: poll the gate verdict ~1 Hz off the
        // already-computed sky features (no extra camera work) and
        // debounce a sustained not-sky read into `pointedIndoors`.
        .task {
            // Sleep FIRST: SwiftUI runs a `.task` body synchronously inside
            // the view update that attaches it, up to the first suspension —
            // so a compute-then-sleep loop mutates @State (`indoorStreak`)
            // mid-update on its first tick ("Modifying state during view
            // update", 2026-07-20). The streak needs 5 ticks before anything
            // shows, so a first-tick delay changes nothing observable.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                indoorHintTick()
                pruneAssertedPlanes()
                pruneLegacyPin()
            }
        }
        .sheet(isPresented: replaySheetPresented) {
            if let replayURL {
                ReplayReportView(url: replayURL)
            } else {
                EmptyView()
            }
        }
    }

    /// Extracted from `body` for the same type-check-budget reason as
    /// `suspectReviewPresented` — inline derived Bindings in the modifier
    /// chain are what pushed CI's compiler past its time limit.
    private var replaySheetPresented: Binding<Bool> {
        Binding<Bool>(
            get: { replayURL != nil },
            set: { if !$0 { replayURL = nil } }
        )
    }

    /// The interactive-visible set: the ambient visibility tier PLUS any
    /// user-asserted plane. One definition for the label render loop, the
    /// metadata prefetch, and its signature — they must agree or labels
    /// render without their metadata.
    ///
    /// The ambient tier is suppressed entirely while `pointedIndoors`
    /// (2026-07-12, NYC couch session): the geometric band can't know about
    /// walls, and dense airspace (Manhattan: river-corridor GA at 2–3 km,
    /// LGA finals at 8 km) keeps planes inside the band that are plainly
    /// invisible from indoors. When the whole frame reads not-sky for the
    /// sustained streak, no ambient label renders; asserted planes survive
    /// (explicit intent — the user just said they can see one). Same
    /// 5 s-debounced signal as the "Not many planes indoors." hint, so
    /// the labels disappear exactly when that hint explains why.
    private func interactiveVisible(_ observed: [ObservedAircraft]) -> [ObservedAircraft] {
        observed.filter {
            ($0.isLikelyVisibleToObserver && !pointedIndoors)
                || (!$0.grounded && assertedPlanes[$0.aircraft.icao24] != nil)
                // Legacy mode's tap-reveal (frame mode never sets it).
                || (!$0.grounded && $0.aircraft.icao24 == revealedIcao)
        }
    }

    /// LEGACY catch mode: pin housekeeping, 1 Hz. If the engine moved off
    /// the pinned plane (target left visibility → sticky → idle), clear the
    /// pin so the view stops fighting the engine. The pre-#229 app did
    /// this from an `.onChange(of: lockOn.state.targetIcao24)`; it rides
    /// the existing 1 Hz task here so `body`'s modifier chain (at the
    /// type-check budget) doesn't grow — the engine's own 2 s sticky hold
    /// already dominates the latency. A revealed plane is only visible
    /// *because* it's pinned, so the reveal drops with the pin.
    private func pruneLegacyPin() {
        guard let pin = pinnedIcao, lockOn.state.targetIcao24 != pin else { return }
        pinnedIcao = nil
        revealedIcao = nil
    }

    /// 1 Hz lifetime keeper for `assertedPlanes` (D5: on frame + grace).
    /// Refreshes the stamp while the plane still projects onto the AR
    /// frame at the current pose; once off frame, the assertion expires
    /// `assertedGraceSeconds` after the last on-frame instant. Leaves the
    /// data entirely (or turns up grounded) → dropped immediately. Runs
    /// from the 1 Hz ambient poll task, never inside `body`.
    private func pruneAssertedPlanes(now: Date = Date()) {
        guard !assertedPlanes.isEmpty else { return }
        let observedByIcao = Dictionary(
            adsb.observed.map { ($0.aircraft.icao24, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let heading = location.heading ?? 0
        let roll = Geo.rollDeg(
            gravityX: motion.gravityX, gravityY: motion.gravityY, gravityZ: motion.gravityZ
        )
        let basis = Geo.cameraBasis(
            headingDeg: heading,
            cameraElevationDeg: motion.cameraElevationDeg,
            rollDeg: roll
        )
        var next = assertedPlanes
        for (icao, lastOnFrame) in assertedPlanes {
            guard let obs = observedByIcao[icao], !obs.grounded else {
                next.removeValue(forKey: icao)
                continue
            }
            let onFrame = arScreenSize != .zero && obs.screenPosition(
                basis: basis, in: arScreenSize,
                hfovDeg: Self.baseHfovDeg / zoom, vfovDeg: Self.baseVfovDeg / zoom
            ) != nil
            if onFrame {
                next[icao] = now
            } else if now.timeIntervalSince(lastOnFrame) > Self.assertedGraceSeconds {
                next.removeValue(forKey: icao)
            }
        }
        if next != assertedPlanes { assertedPlanes = next }
    }

    // MARK: - Per-frame selection (catch-mode funnel)

    /// Everything the 30 Hz AR frame needs from the live catch mode's
    /// selection rules: which labels render at which style, where the
    /// labels draw, and what the capture button would catch. Built once
    /// per frame by `resolveFrameSelection` — the single place both
    /// catch modes branch for rendering.
    private struct FrameSelection {
        /// Capture button mode (the press payload).
        let mode: CaptureMode
        /// Full-bright labels: frame mode's chosen set (≤ maxCatchTargets)
        /// or legacy mode's pinned plane.
        let bright: Set<String>
        /// Stepped-down (but not faint) labels: frame mode's overflow —
        /// bright-tier planes past the cap — or, in legacy mode, every
        /// unpinned bright-tier plane (there is no chosen highlight there:
        /// the button's payload is invisible until the press, as shipped).
        let quiet: Set<String>
        /// Label draw positions: the geometric projection, except legacy
        /// mode's pinned plane snaps to the detector's live fix.
        let labelPositions: [String: CGPoint]
        /// Legacy mode: the engine's current target (pin / sticky).
        let pinned: String?

        func style(for icao: String) -> PlaneLabel.Style {
            if icao == pinned { return .pinned }
            if bright.contains(icao) { return .chosen }
            if quiet.contains(icao) { return .quiet }
            return .faint
        }
    }

    /// Resolve the frame's selection for whichever catch mode is live.
    /// Called from inside the TimelineView body every frame, so it must
    /// stay free of @State writes: the legacy path's `lockOn.update` is a
    /// pure idempotent state-machine tick (the pre-#229 app called it
    /// from exactly this spot) and `visualConfirm.updateTarget` is a
    /// lock-only write by design.
    private func resolveFrameSelection(
        visible: [ObservedAircraft],
        onScreenPositions: [String: CGPoint],
        screenSize: CGSize,
        headingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double,
        now: Date
    ) -> FrameSelection {
        switch catchMode {
        case .frame:
            // Press membership: bright (.full-tier) planes on frame,
            // occlusion-demoted via the live sky grid, asserted planes
            // guaranteed, ranked by apparent size, capped at
            // `maxCatchTargets`. Pure — see `chooseCatchMembers` for the
            // D1·2/D3·2 rules.
            let localGrid = visualConfirm.latestLocalGrid
            let occlusionDemotes = visualConfirm.localGateEnforcing
            let membership = chooseCatchMembers(
                visible.compactMap { obs -> MembershipCandidate? in
                    let icao = obs.aircraft.icao24
                    guard let pos = onScreenPositions[icao] else { return nil }
                    let asserted = assertedPlanes[icao] != nil
                    let occluded: Bool = {
                        guard occlusionDemotes, !asserted,
                              let grid = localGrid else { return false }
                        let f = grid.features(atScreenPoint: pos, screenSize: screenSize)
                        return LocalSkyGate().verdict(f) == .notSky
                    }()
                    return MembershipCandidate(
                        icao24: icao,
                        arcmin: obs.apparentSizeArcminutes,
                        isFullTier: obs.visibilityTier == .full,
                        isAsserted: asserted,
                        isOccluded: occluded
                    )
                }
            )
            let mode: CaptureMode
            switch membership.chosen.count {
            case 0:  mode = .disabled
            case 1:  mode = .single(membership.chosen[0])
            default: mode = .multi(membership.chosen)
            }
            return FrameSelection(
                mode: mode,
                bright: Set(membership.chosen),
                quiet: Set(membership.overflow),
                labelPositions: onScreenPositions,
                pinned: nil
            )

        case .legacy:
            // Target choice: the explicit tap-pinned plane (if still
            // visible) wins; otherwise fall back to whichever visible
            // plane is nearest to screen center. A pin pointing at a
            // no-longer-visible plane is ignored here; `pruneLegacyPin`
            // clears it once the engine lets go.
            let centerClosest = closestTargetIcao24(
                in: visible,
                phoneHeadingDeg: headingDeg,
                cameraElevationDeg: cameraElevationDeg,
                rollDeg: rollDeg,
                screenSize: screenSize,
                hfovDeg: hfovDeg,
                vfovDeg: vfovDeg
            )
            let pinStillVisible = pinnedIcao.map { id in
                visible.contains { $0.aircraft.icao24 == id }
            } ?? false
            let engineTarget = pinStillVisible ? pinnedIcao : centerClosest
            lockOn.update(closestTargetIcao24: engineTarget, now: now)
            let pinned = lockOn.state.targetIcao24

            // Visual confirmation: tell the detector where the current
            // lock target is predicted to be; it picks it up on its next
            // frame. `arOccluded` guard: a PAUSED TimelineView still
            // re-renders on external state changes, and an unguarded write
            // would re-arm the detector behind an open sheet right after
            // the occlusion handler cleared it.
            visualConfirm.updateTarget(
                arOccluded ? nil : pinned.flatMap { icao in
                    onScreenPositions[icao].map {
                        .init(icao24: icao, predictedScreen: $0, screenSize: screenSize)
                    }
                }
            )
            // The pinned plane's bracket snaps to the detector's fix when
            // one is live; everything else stays at the geometric
            // prediction. Pre-catch only — the photo path uses the
            // geometric `onScreenPositions`.
            var labelPositions = onScreenPositions
            if let pinned, let fix = visualConfirm.fixes[pinned]?.screenPoint,
               labelPositions[pinned] != nil {
                labelPositions[pinned] = fix
            }
            // Unpinned bright-tier planes render at the shipped ambient
            // weight; faint tier (and everything else while a pin is set)
            // dims — the pinned/dimmed hierarchy as shipped.
            let quiet: Set<String> = pinned == nil
                ? Set(visible.filter { $0.visibilityTier == .full }.map(\.aircraft.icao24))
                : []
            return FrameSelection(
                mode: legacyCaptureMode(
                    visible: visible, onScreenPositions: onScreenPositions,
                    pinned: pinned, screenSize: screenSize,
                    headingDeg: headingDeg, cameraElevationDeg: cameraElevationDeg,
                    rollDeg: rollDeg, hfovDeg: hfovDeg, vfovDeg: vfovDeg
                ),
                bright: [],
                quiet: quiet,
                labelPositions: labelPositions,
                pinned: pinned
            )
        }
    }

    /// LEGACY catch mode's capture-button payload (the shipped spec § 3.2
    /// + the 2026-07 refinements): an explicit pin still on screen wins;
    /// else the TIGHT central catch zone (anti-cheat L1 — aim, don't
    /// spray); a lone on-frame plane stays catchable when the zone is
    /// empty (#145); multiple in-zone planes single-catch the visually
    /// dominant one (the A319-class fix) or multi-catch a comparable
    /// cluster.
    private func legacyCaptureMode(
        visible: [ObservedAircraft],
        onScreenPositions: [String: CGPoint],
        pinned: String?,
        screenSize: CGSize,
        headingDeg: Double,
        cameraElevationDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double
    ) -> CaptureMode {
        if let pin = pinned, onScreenPositions[pin] != nil {
            return .single(pin)
        }
        let candidates = catchCandidates(
            in: visible,
            phoneHeadingDeg: headingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            zoneRadius: Self.catchZoneRadius
        )
        if candidates.isEmpty {
            // Central catch zone empty, but a LONE plane anywhere on frame
            // stays catchable (fix/lone-plane-catchable #145). Two+ on
            // frame still require aim or a tap.
            if onScreenPositions.count == 1, let only = onScreenPositions.keys.first {
                return .single(only)
            }
            return .disabled
        }
        if candidates.count == 1 {
            return .single(candidates[0].icao24)
        }
        if let dominant = dominantAimTarget(
            candidates, headingAccuracyDeg: location.headingAccuracy
        ) {
            return .single(dominant)
        }
        return .multi(candidates.map(\.icao24))
    }

    #if DEBUG
    /// Wrench-panel row: the catch-mode A/B switch. FRAME (this branch's
    /// frame-is-the-catch) ↔ LEGACY (the shipped zones-and-pins model).
    /// Tap to flip; persists across launches on this Debug install only.
    private var catchModeRow: some View {
        HStack(spacing: 8) {
            Text("Catch mode:")
            Text("[\(catchMode.label)]")
                .foregroundStyle(catchMode == .legacy
                                 ? Brand.Color.alertCaution
                                 : Brand.Color.textTertiary)
                .bold()
            Text(catchMode == .frame ? "membership · tap asserts"
                                     : "zone · pin · dominance")
                .foregroundStyle(Brand.Color.textTertiary)
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { setCatchMode(catchMode.toggled) }
    }

    /// Always-on screen badge while the LEGACY mode is live, so a field
    /// session (and its screenshots) can't mistake shipped behaviour for
    /// this branch's. Nothing renders in the frame mode.
    @ViewBuilder
    private var catchModeBadge: some View {
        if catchMode == .legacy {
            Text("LEGACY CATCH MODE")
                .font(Brand.Font.mono(size: 10, weight: .bold))
                .foregroundStyle(Brand.Color.alertCaution)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Brand.Color.bgElevated.opacity(0.92), in: .capsule)
                .overlay(Capsule().strokeBorder(Brand.Color.alertCaution.opacity(0.45), lineWidth: 1))
                .accessibilityLabel("Legacy catch mode is on")
        }
    }
    #endif

    /// True when an OPAQUE modal fully covers the camera / AR view — the
    /// standard sheets: Hangar, Profile, compass calibration, the DEBUG
    /// trophy-icon gallery, and the replay report. Hangar/Profile join this
    /// set only after their presentation animation settles: their request
    /// flags and content tasks both start before SwiftUI has committed a sheet
    /// frame, and stopping the camera at either earlier point exposes its black
    /// backing view. While occluded we power
    /// down the sensors + the 30 Hz render loop the user can't see (see
    /// `.onChange(of: arOccluded)` and the `paused:` TimelineView).
    ///
    /// The catch-reveal covers (`pendingReveal` / `pendingMultiReveal`) are
    /// DELIBERATELY EXCLUDED: they present with `.presentationBackground(.clear)`
    /// so the live AR shows THROUGH the card — pausing labels/motion under
    /// them would visibly freeze the sky behind the reveal (a regression).
    /// Only fully-opaque presentations belong here. (`showIconGallery` and
    /// `replayURL` are only ever set in DEBUG, but their state exists in all
    /// builds, so reading them here compiles everywhere and stays false in
    /// Release.)
    private var arOccluded: Bool {
        primarySheetVisible
            || showCompassSheet
            || showIconGallery
            || replayURL != nil
    }

    /// SwiftUI starts a sheet content task before the presentation animation
    /// has produced its first stable frame. Keep the live camera attached for
    /// that short transition, then retain the existing power-saving shutdown
    /// for the rest of the opaque sheet's lifetime. The task is cancelled if
    /// the sheet disappears before the delay completes.
    private func occludeARAfterPrimarySheetPresents() async {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, showHangar || showProfile else { return }
        primarySheetVisible = true
    }

    /// Ambient-label metadata prefetch body (the `.task(id: visibleIcaoSignature)`
    /// above). Prunes session-stale entries — `ambientMetadata` is a view-local
    /// mirror of the bounded MetadataCache actor; without the filter the dict
    /// would grow unboundedly over a long session as planes leave + re-enter
    /// the visible set — then fetches the not-yet-known icaos with a BOUNDED
    /// number of lookups in flight (was a serial loop — 15 fresh planes ≈ 3 s
    /// to fully label at ~200 ms/lookup; 3-wide cuts that to ~1 s without
    /// stampeding the backend). Cancellation propagates: `.task(id:)` cancels
    /// this when the signature changes or the view disappears; each child bails
    /// early on `Task.isCancelled`, and the loop stops feeding new work once
    /// cancelled. Results apply as they arrive, so labels still populate
    /// incrementally like the old loop.
    private func prefetchAmbientMetadata() async {
        let icaos: [String] = interactiveVisible(adsb.observed).map(\.aircraft.icao24)
        let currentSet = Set(icaos)
        ambientMetadata = ambientMetadata.filter { currentSet.contains($0.key) }

        let pending: [String] = icaos.filter { ambientMetadata[$0] == nil }
        guard !pending.isEmpty else { return }

        // Bind the manager to a local so the child tasks capture the
        // (MainActor-isolated, hence Sendable) manager, not `self`.
        let manager = adsb
        let maxConcurrent = 3
        typealias Lookup = (icao: String, value: AircraftMetadata?)
        await withTaskGroup(of: Lookup?.self) { group in
            var iterator = pending.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let icao = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return (icao, await manager.metadata(for: icao))
                }
            }

            for _ in 0..<maxConcurrent { addNext() }
            while inFlight > 0, let result = await group.next() {
                inFlight -= 1
                if let result { ambientMetadata[result.icao] = result.value }
                if Task.isCancelled { break }
                addNext()
            }
        }
    }

    // MARK: - Catch reveal payloads

    /// Snapshot of the catch needed to render the reveal sheet —
    /// kept separate from the live Catch so the reveal stays stable
    /// even if SwiftData state churns underneath.
    ///
    /// `isDuplicate` is set by `performCatch(mode:)` when the icao24
    /// was already in the user's Hangar → the "ALREADY CAUGHT" stamp +
    /// quieter chrome.
    ///
    /// `guess`/`row`/`isSimulated` carry the in-card BONUS ROUND (game-layer
    /// PR3; in-card per Noah 2026-07-10): when a fresh single catch fires a
    /// round, the reveal is presented immediately WITH the question and the
    /// fresh `row` to freeze the answer onto. Not `Equatable` (holds a SwiftData
    /// row); `Identifiable` is all `.fullScreenCover(item:)` needs.
    struct PendingReveal: Identifiable {
        let id = UUID()
        let plane: CardPlane
        let entryNumber: Int
        var isDuplicate: Bool = false
        /// The in-card bonus-round question, or nil for a plain reveal.
        var guess: GuessRoundQuestion? = nil
        /// The fresh row the answer freezes onto (guessKind/Value/Correct). nil
        /// for a plain reveal or the ✦ Catch simulation's transient row.
        var row: Catch? = nil
        /// ✦ Catch simulation — the in-card round plays, but no telemetry and no
        /// persistence (transient row).
        var isSimulated: Bool = false
        /// Early-shell conduit (capture-lag work, 2026-08-13): non-nil when the
        /// reveal presented at TAP time as a loading shell and the pipeline is
        /// still filling it — `plane` above is then just the initial snapshot,
        /// and the finished plane/row/guess arrive through the loader. nil on
        /// the settled paths (multi fallback, simulator), where `plane`/`row`/
        /// `guess` are final at presentation exactly as before.
        var loader: RevealLoader? = nil
        /// Current day-streak after this catch (nil = below the chip
        /// threshold). On the shell path the value arrives via the loader
        /// instead; ✦ Catch passes it directly so the line is previewable.
        var streakDays: Int? = nil
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


    /// Proactive ambient hint while the phone is pointed indoors — so the
    /// user knows to head outside before they even try to catch. Driven by
    /// the debounced `pointedIndoors`; auto-clears when aimed at sky.
    /// Copy is the app's dry-clinical voice (Noah, 2026-07-10 — the
    /// winking-emoji draft was off-voice), same register as the grounded
    /// toast below.
    @ViewBuilder
    private var indoorHintBanner: some View {
        if pointedIndoors {
            Text("Not many planes indoors.")
                .font(Brand.Font.mono(size: 12, weight: .semibold))
                .foregroundStyle(Brand.Color.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Brand.Color.bgElevated.opacity(0.92), in: .capsule)
                .overlay(Capsule().strokeBorder(Brand.Color.alertCaution.opacity(0.45), lineWidth: 1))
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// The single transient top toast (grounded / far-tap / save-fail /
    /// streak). One shared capsule, one shared state: message and border
    /// vary by kind — save-fail is `alertWarning` RED, because losing a
    /// catch is data loss and that is exactly what red is reserved for (the
    /// FAA colour rule in Brand.swift); the rest are caution amber.
    ///
    /// The outer ZStack is ALWAYS present (empty when there is no toast),
    /// which is load-bearing: the streak-relay watch hangs off it, so it
    /// stays live while keeping another modifier link out of `body`.
    private var topToastBanner: some View {
        ZStack(alignment: .top) {
            if let toast = topToast {
                Text(toast.kind.message)
                    .font(Brand.Font.mono(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Brand.Color.bgElevated.opacity(0.92), in: .capsule)
                    .overlay(Capsule().strokeBorder(toast.kind.borderColor, lineWidth: 1))
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: streakRelay.streakLine) { _, line in
            if let line {
                presentTopToast(.streak(line: line), duration: 4.0)
                streakRelay.streakLine = nil
            }
        }
    }

    /// Show `kind` as the single top toast for ~`duration` s. The timestamp
    /// guards the auto-clear against clearing a newer toast.
    private func presentTopToast(_ kind: TopToast, duration: TimeInterval = 3.0) {
        let shownAt = Date()
        withAnimation(.easeInOut(duration: 0.2)) { topToast = (kind, shownAt) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if topToast?.at == shownAt {
                withAnimation(.easeInOut(duration: 0.3)) { topToast = nil }
            }
        }
    }

    /// Present the save-failure toast (flushed at reveal dismiss — showing
    /// it at catch time would hide it behind the full-screen reveal).
    private func presentSaveFailToast() { presentTopToast(.saveFail) }

    /// Present the beyond-eyeshot toast.
    private func presentFarTapToast(slantMeters: Double) {
        presentTopToast(.farTap(slantMeters: slantMeters))
    }

    /// Present the parked-plane toast for ~3 s, record the attempt for the
    /// "Ground Stop" secret badge, and fire the one telemetry event. The
    /// unlock check runs immediately after recording so the badge's moment
    /// lands now, not on the next catch.
    private func presentGroundedTapToast(icao24: String) {
        presentTopToast(.grounded)
        TrophyEventStore().record(.groundedCatchAttempt)
        CatchTelemetry.fireGroundedAttempt(icao24: icao24)
        unlockCenter.enqueueNewUnlocks(from: catches)
    }

    /// Compass-bad caution banner. Surfaces only after
    /// `compassBadDebounce` s of readings past `compassBadThreshold`
    /// (latched via `updateCompassWarning`), then shouts: a filled-amber
    /// banner with a pulsing warning glyph, the live "COMPASS OFF ±N°"
    /// readout, and a plain line that the on-screen labels can't be
    /// trusted until it's fixed. Tap opens `CompassCalibrationSheet`.
    ///
    /// Deliberately LOUD — the prior slim translucent capsule was too
    /// easy to miss with a plane in frame, which is exactly how the SFO
    /// field misID slipped through (2026-07-13: a ~40°-off compass
    /// mis-projected every plane, so a huge 777 read as a distant
    /// Cessna). A one-shot warning haptic fires when it first appears
    /// (the `.sensoryFeedback` on the top-center stack). It does NOT
    /// gate catching — warn loudly, keep the shutter live (Noah's call).
    @ViewBuilder
    private var cautionBadge: some View {
        if isHeadingAccuracyBad {
            Button {
                showCompassSheet = true
                ActivationTelemetry.fireCompassSheetOpened(
                    headingAccuracyDeg: location.headingAccuracy
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("COMPASS OFF \(formatHeadingAccuracyShort())")
                            .font(Brand.Font.mono(size: 14, weight: .bold))
                            .tracking(1.0)
                        Text("Labels may be wrong — tap to calibrate")
                            .font(Brand.Font.mono(size: 10, weight: .regular))
                            .opacity(0.85)
                    }
                }
                // Dark text/glyph on amber — the classic caution read,
                // and the only high-contrast pairing (amber-on-dark is
                // reserved for the quieter data HUD).
                .foregroundStyle(Brand.Color.bgSurface)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Brand.Color.alertCaution,
                            in: RoundedRectangle(cornerRadius: Brand.Radius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.row)
                        .strokeBorder(Brand.Color.bgSurface.opacity(0.15), lineWidth: 1)
                )
                // Amber glow so it lifts off the live camera behind it.
                .shadow(color: Brand.Color.alertCaution.opacity(0.5), radius: 12, y: 2)
                .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.row))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Compass off by \(formatHeadingAccuracyShort()). Labels may be wrong. Tap to calibrate.")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Zoom indicator. Faint capsule top-center; hidden at 1.0×.
    @ViewBuilder
    private var zoomPill: some View {
        if zoom > 1.01 {
            Text(String(format: "%.1f×", zoom))
                .font(Brand.Font.mono(size: 12, weight: .bold))
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
                // 32 pt visible disc; inset expands the hit region to 44.
                .contentShape(Rectangle().inset(by: -6))
        }
        .accessibilityLabel(showDebug ? "Hide debug overlays" : "Show debug overlays")
    }

    // MARK: - Trophy unlock overlay

    /// The trophy-unlock celebration, presented over the AR as a gated
    /// overlay (not a third `fullScreenCover`, which would race the reveal
    /// covers' dismissal). Shown only when nothing else is on top: no card
    /// reveal, no sheet. A fallback unlock discovered while a sheet is open
    /// surfaces when the sheet dismisses (the `catches`-count and
    /// `showHangar` tasks re-enqueue).
    @ViewBuilder
    private var trophyUnlockOverlay: some View {
        if unlockCenter.hasPending,
           pendingReveal == nil, pendingMultiReveal == nil,
           !showHangar, !showProfile, !showCompassSheet,
           !restoreManager.isPresenting {
            TrophyUnlockView(center: unlockCenter)
                .transition(.opacity)
        }
    }

    // MARK: - Hangar restore overlay

    /// The restore-from-server prompt (offer → restoring → done), same gated-
    /// overlay presentation as the trophy moment. In practice it only ever
    /// appears on a just-reinstalled app with an empty Hangar, so the "nothing
    /// else on top" gates are belt-and-suspenders.
    @ViewBuilder
    private var hangarRestoreOverlay: some View {
        if restoreManager.isPresenting,
           pendingReveal == nil, pendingMultiReveal == nil,
           !showHangar, !showProfile, !showCompassSheet {
            HangarRestorePromptView(
                manager: restoreManager,
                context: modelContext,
                unlockCenter: unlockCenter
            )
            .transition(.opacity)
        }
    }

    /// Streak notification pre-prompt: a bottom card, presented once ever
    /// (see `presentSuspectReviewIfNeeded`), asking to protect the streak
    /// with the evening nudge. Accepting fires the SYSTEM permission prompt
    /// — the pre-prompt exists so that prompt lands with context instead of
    /// ambushing at cold launch. Solid card, not `.glassEffect` (bare glass
    /// siblings swallow taps on views below — the Profile bug, PR #127).
    ///
    /// All prose, no mono (Noah, 2026-08-19). Copy is his: the question
    /// leads, the mechanism explains itself in one line, and neither
    /// mentions the reminder hour or a day threshold — numbers in the copy go stale
    /// the moment a constant moves.
    @ViewBuilder
    private var streakAskOverlay: some View {
        if let days = streakAsk {
            VStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 7) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Brand.Color.alertCaution)
                            // flame.fill's ink sits high in its layout box, so plain
                            // centring leaves it ~1 pt above the text. Same nudge as
                            // the Profile card's flame, scaled to this glyph size.
                            .offset(y: 1)
                            .accessibilityHidden(true)
                        HStack(spacing: 5) {
                            Text("\(days)")
                                .font(.system(.subheadline, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(Brand.Color.textPrimary)
                            Text("day streak")
                                .font(.system(.subheadline, weight: .medium))
                                .foregroundStyle(Brand.Color.textSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(days) day streak")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Protect your streak?")
                            .font(.system(.title3, weight: .bold))
                            .foregroundStyle(Brand.Color.textPrimary)
                        Text("Turn on notifications to help keep your streak going.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Button {
                            if !streakAskFromDebug {
                                StreakTelemetry.fireAskResponse(accepted: true, streakDays: days)
                            }
                            withAnimation(.easeIn(duration: 0.2)) { streakAsk = nil }
                            Task { @MainActor in
                                _ = await StreakReminderCenter.shared.requestPermission()
                                await StreakReminderCenter.shared.sync(context: modelContext)
                            }
                        } label: {
                            Text("Notify me")
                                .font(Brand.Font.button)
                                .foregroundStyle(Brand.Color.bgPrimary)
                                .padding(.vertical, 13)
                                .frame(maxWidth: .infinity)
                                .background(Brand.Color.cyan,
                                            in: .rect(cornerRadius: Brand.Radius.row))
                        }
                        .buttonStyle(.plain)
                        Button {
                            if !streakAskFromDebug {
                                StreakTelemetry.fireAskResponse(accepted: false, streakDays: days)
                            }
                            withAnimation(.easeIn(duration: 0.2)) { streakAsk = nil }
                        } label: {
                            Text("Not now")
                                // Same size as the primary, one weight
                                // down: declining stays easy to hit and
                                // easy to read, without competing.
                                .font(.system(.callout, weight: .medium))
                                .foregroundStyle(Brand.Color.textSecondary)
                                .padding(.vertical, 13)
                                .padding(.horizontal, 20)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
                .padding(20)
                .background(Brand.Color.bgElevated,
                            in: .rect(cornerRadius: Brand.Radius.card))
                .padding(.horizontal, 16)
                // Clear the capture bar (its buttons sit ~100 pt tall with
                // the home indicator inset).
                .padding(.bottom, 110)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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

        /// The target icao24 list this mode resolves to (empty when disabled).
        var icaos: [String] {
            switch self {
            case .disabled:        return []
            case .single(let i):   return [i]
            case .multi(let list): return list
            }
        }
    }

    /// How long a user assertion survives OFF frame (D5, 2026-08-28): the
    /// asserted plane stays labeled + catchable while it projects onto the
    /// frame, plus this grace once it slips off (pan away and back without
    /// re-tapping). Leaves the data → dropped immediately. Tunable in
    /// field test.
    private static let assertedGraceSeconds: TimeInterval = 15

    /// LEGACY catch mode — anti-cheat L1: radius (screen points) of the
    /// central catch zone the capture button draws its targets from.
    /// Tighter than whole-frame so a catch means "I aimed at this plane."
    /// In points (not degrees) so it scales with zoom. The lock zone is
    /// 80; this starts a touch wider so a centred plane with mild compass
    /// drift still qualifies.
    private static let catchZoneRadius: CGFloat = 100

    /// LEGACY catch mode — aim-confidence floor for the uncertain-aim flag
    /// (Gate 5). Below this, a CENTER (non-tapped) catch made under a poor
    /// compass, off the crosshair, and on a small target is flagged as
    /// maybe-the-wrong-plane → Keep/Discard after the reveal (never
    /// blocks). Conservative so it flags only clearly marginal catches
    /// (fail-open). See `aimConfidence`.
    private static let uncertainAimConfidenceFloor: Double = 0.3

    /// Payload for the post-catch Keep/Discard review dialog: the suspected
    /// rows of the just-revealed catch and the one question asked about them.
    private struct SuspectReview {
        let rows: [Catch]
        let question: String
    }

    /// The review dialog's presentation binding, question, and actions —
    /// extracted from `body`'s modifier chain: an inline derived `Binding`
    /// there pushed the whole-body expression past the CI compiler's
    /// type-check time limit (the faster dev Mac squeaked through).
    private var suspectReviewPresented: Binding<Bool> {
        Binding<Bool>(
            get: { pendingSuspectReview != nil },
            set: { if !$0 { pendingSuspectReview = nil } }
        )
    }

    private var suspectReviewQuestion: String {
        pendingSuspectReview?.question ?? ""
    }

    @ViewBuilder
    private var suspectReviewActions: some View {
        // Buttons agree in number with the question — "did you really see
        // them?" answered by "I saw it" read like different conversations.
        let plural = (pendingSuspectReview?.rows.count ?? 1) > 1
        Button(plural ? "I saw them — keep" : "I saw it — keep") { resolveSuspectReview(keep: true) }
        Button(plural ? "Discard them" : "Discard it", role: .destructive) { resolveSuspectReview(keep: false) }
    }

    /// Promote the stashed suspected rows into the review dialog. Called from
    /// the reveal's dismiss callbacks so the question lands right AFTER the
    /// card moment, never on top of it (post-catch confirm, 2026-07-04).
    private func presentSuspectReviewIfNeeded() {
        // Also the reveal-dismissal flush point for the save-failure toast:
        // presenting it at catch time would hide it behind the full-screen
        // reveal and it would expire unseen.
        var momentClaimed = false
        if pendingSaveFailToast {
            pendingSaveFailToast = false
            presentSaveFailToast()
            momentClaimed = true
        }
        // Streak notification pre-prompt (one-shot). Only an UNCONTESTED
        // dismissal promotes it: a pending Keep/Discard review or a jump to
        // the Hangar wins the moment and the ask is dropped, not queued —
        // eligibility re-stages it on the next streak catch. Presenting
        // latches the asked bit immediately, so it can never fire twice.
        if let askDays = pendingStreakAsk {
            pendingStreakAsk = nil
            if suspectAwaitingReview.isEmpty, !showHangar,
               pendingReveal == nil, pendingMultiReveal == nil {
                UserDefaults.standard.set(true, forKey: StreakReminders.permissionAskedKey)
                streakAskFromDebug = false
                StreakTelemetry.fireAskShown(streakDays: askDays)
                withAnimation(.easeOut(duration: 0.25)) { streakAsk = askDays }
                momentClaimed = true
            }
        }
        guard !suspectAwaitingReview.isEmpty else {
            maybeRequestReview(momentClaimed: momentClaimed)
            return
        }
        let rows = suspectAwaitingReview.filter { !$0.isDeleted && $0.suspectReason != nil }
        suspectAwaitingReview = []
        guard !rows.isEmpty else {
            maybeRequestReview(momentClaimed: momentClaimed)
            return
        }
        let question: String
        if rows.count == 1, let row = rows.first,
           let reason = row.suspectReason.flatMap(CatchSuspicion.init(rawValue:)) {
            question = reason.question(slantKm: row.slantDistanceMeters / 1000)
        } else {
            question = CatchSuspicion.multiQuestion(count: rows.count)
        }
        pendingSuspectReview = SuspectReview(rows: rows, question: question)
    }

    /// The SwiftUI review-request action — Apple's canonical StoreKit
    /// plumbing for a SwiftUI app. Read here and passed into the prompter;
    /// the raw scene-based `AppStore.requestReview(in:)` proved unreliable
    /// on-device (2026-08-25: analytics fired, sheet never showed).
    @Environment(\.requestReview) private var requestReview

    /// Lowest-priority claimant of the post-reveal moment (v1.1 R7): the
    /// App Store rating ask, only when nothing else took the moment — no
    /// toast, no streak pre-prompt, no suspect Keep/Discard, no Hangar
    /// jump, no pending trophy celebration. Contested → drop, not queue;
    /// eligibility is durable (the Hangar), so it re-tries when the next
    /// catch's reveal closes. Thresholds + the once-per-version stamp live
    /// in `ReviewPrompt.swift`.
    private func maybeRequestReview(momentClaimed: Bool) {
        guard !momentClaimed, streakAsk == nil, pendingSuspectReview == nil,
              !showHangar, pendingReveal == nil, pendingMultiReveal == nil,
              !unlockCenter.hasPending else { return }
        ReviewPrompter.shared.catchMomentEnded(
            totalCatches: catches.count,
            // Day buckets via Streaks.dayKey — the frozen insert-time label
            // (the one-owner rule; recomputing from caughtAt in the current
            // zone would disagree with the streak card after a flight home).
            distinctCatchDays: Set(catches.map { Streaks.dayKey(for: $0) }).count,
            // SwiftUI's own action, delayed past the reveal cover's dismiss
            // transition (a request made mid-transition is silently dropped
            // — field-observed 2026-08-25).
            present: {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(800))
                    requestReview()
                }
            }
        )
    }

    /// Apply the review answer to every row it covered. Keep vouches — the
    /// flag clears and the row uploads immediately (same per-catch sweep the
    /// non-suspect path fires; the scene-activation sweep stays the retry
    /// net). Discard deletes the row + photo and fires the deny signals.
    private func resolveSuspectReview(keep: Bool) {
        guard let review = pendingSuspectReview else { return }
        pendingSuspectReview = nil
        for row in review.rows where !row.isDeleted {
            guard let reason = row.suspectReason.flatMap(CatchSuspicion.init(rawValue:)) else { continue }
            if keep {
                CatchTelemetry.fireSuspectKept(icao24: row.icao24, reason: reason)
                row.suspectReason = nil
            } else {
                CatchTelemetry.fireSuspectDiscarded(icao24: row.icao24, reason: reason)
                // A discard IS a delete — fire the north-star deny signal too.
                CatchTelemetry.fireDeleted(
                    icao24: row.icao24, count: 1, rarity: row.resolvedRarity.rawValue
                )
                CatchPhotoStore.delete(filename: row.photoFilename)
                modelContext.delete(row)
            }
        }
        try? modelContext.save()
        if keep {
            Task { await CatchUploader().uploadPending(context: modelContext) }
        }
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
    /// Build the capture-time targeting diagnostics blob for one caught plane
    /// (pure debugging — see `CatchCaptureDiagnostics`). Rounds values for a
    /// compact JSON; the caught plane's offset is computed directly from its
    /// observation so it's present even if it drifted out of the catch zone by
    /// capture time. Pose values come in from the caller's SHUTTER-PRESS
    /// snapshot — never read the live sensors here (the pipeline runs seconds
    /// past the press; see the snapshot comment in `runCatch`).
    private func buildCaptureDiagnostics(
        for icao: String,
        observed: ObservedAircraft?,
        candidates: [CatchCandidate],
        basis: Geo.CameraBasis,
        headingDeg: Double?,
        headingAccuracyDeg: Double?,
        cameraElevationDeg: Double,
        rollDeg: Double,
        zoom: CGFloat,
        wasTapped: Bool
    ) -> String? {
        func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
        let targetOffset: Double? = observed.map { obs in
            let v = Geo.cameraFrameVector(
                targetBearingDeg: obs.bearingDeg, targetElevationDeg: obs.elevationDeg, basis: basis
            )
            return v.z <= 0 ? 180.0 : atan2((v.x*v.x + v.y*v.y).squareRoot(), v.z) * 180 / .pi
        }
        let alts = candidates.filter { $0.icao24 != icao }.prefix(4).map {
            CatchCaptureDiagnostics.Alternative(
                icao24: $0.icao24, offsetDeg: r1($0.offsetDeg),
                slantKm: r1($0.slantMeters / 1000), arcmin: r1($0.arcmin)
            )
        }
        let diag = CatchCaptureDiagnostics(
            headingDeg: headingDeg.map(r1),
            cameraElevationDeg: r1(cameraElevationDeg),
            rollDeg: r1(rollDeg),
            zoom: (Double(zoom) * 100).rounded() / 100,
            headingAccuracyDeg: headingAccuracyDeg.map(r1),
            targetOffsetDeg: targetOffset.map(r1),
            targetArcmin: observed.map { r1($0.apparentSizeArcminutes) },
            wasTapped: wasTapped,
            candidateCount: candidates.count,
            alternatives: alts.isEmpty ? nil : Array(alts),
            selector: catchMode == .legacy ? "prominence-v1" : "membership-v1"
        )
        return diag.jsonString()
    }

    private func performCatch(
        mode: CaptureMode,
        screenSize: CGSize,
        positions: [String: CGPoint]
    ) {
        let icaos = mode.icaos
        guard !icaos.isEmpty else { return }
        guard !captureInFlight else { return }

        // Acknowledge the tap in THIS frame: impact haptic + shutter flash.
        // Everything after this point is async (shutter ~0.2–0.6 s, detector,
        // compose) — without this beat a working press was indistinguishable
        // from a missed one until the reveal, ~1.4 s later (field report
        // 2026-08-13). The success haptic at pipeline end is unchanged.
        captureTapHaptic &+= 1
        captureFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.easeOut(duration: 0.3)) { captureFlash = false }
        }

        // Post-catch confirm model (2026-07-04): the gates below RAISE
        // SUSPICION instead of blocking — the catch + reveal always proceed
        // instantly. A pre-catch nudge interrupted a moving target, and its
        // "Catch anyway" re-ran seconds later against stale aim (the JA10VA
        // field case: override caught an invisible plane 62.6 km out).
        // Suspected rows quarantine from upload and get one Keep/Discard
        // question after the reveal (`presentSuspectReviewIfNeeded`).
        var suspicions: [String: CatchSuspicion] = [:]

        // Gate 1 — indoor (v1 whole-frame authenticity gate). A confident
        // "not sky" suspects the whole tap; everything else passes (fail open).
        let skyFeatures = visualConfirm.latestSkyFeatures
        let gpsAccuracy = location.horizontalAccuracy
        if computeOutdoorVerdict(features: skyFeatures, gps: gpsAccuracy) == .notSky {
            CatchTelemetry.fireBlockedOutdoors(
                verdict: .notSky, features: skyFeatures, gpsAccuracyMeters: gpsAccuracy
            )
            for icao in icaos {
                suspicions[icao] = CatchSuspicion.preferred(suspicions[icao], .indoor)
            }
        }

        // Gate 2 — angular-size floor (L3). A plane too small-and-distant to
        // resolve by eye is doubtful (independent of occlusion, which the
        // localized sky gate owns). Per-target: specks are caught + flagged,
        // never dropped — the review question owns the outcome now.
        let observedByIcao = Dictionary(
            adsb.observed.map { ($0.aircraft.icao24, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for icao in icaos {
            // No observation (shouldn't happen — it was on screen) → fail open.
            guard let obs = observedByIcao[icao], !obs.clearsCatchSizeFloor else { continue }
            CatchTelemetry.fireBlockedSize(
                arcmin: obs.apparentSizeArcminutes,
                slantKm: obs.slantDistanceMeters / 1000
            )
            suspicions[icao] = CatchSuspicion.preferred(suspicions[icao], .tooFar)
        }

        // Gate 3 — localized sky gate (L2). Judge the patch under each
        // target's bracket. SHADOW (debug toggle) → telemetry only;
        // enforcing (the default) → a confidently-occluded bracket
        // (building/tree under it) raises suspicion.
        let enforcing = visualConfirm.localGateEnforcing
        if let grid = visualConfirm.latestLocalGrid {
            let gate = LocalSkyGate()
            for icao in icaos {
                guard let pos = positions[icao] else { continue }
                let f = grid.features(atScreenPoint: pos, screenSize: screenSize)
                let v = gate.verdict(f)
                let wouldBlock = (v == .notSky)
                CatchTelemetry.fireLocalGate(
                    verdict: v, features: f, wouldBlock: wouldBlock, enforcing: enforcing
                )
                if wouldBlock, enforcing {
                    suspicions[icao] = CatchSuspicion.preferred(suspicions[icao], .occluded)
                }
            }
        }

        // Gate 5 — uncertain aim — LEGACY mode only. Retired from the frame
        // mode with the crosshair (2026-08-28): its premise was "the reticle
        // says which plane you meant"; under frame-is-the-catch there is no
        // picking, so there is no mis-pick. Per-plane honesty stays with
        // gates 1–3 above.
        if catchMode == .legacy {
            applyUncertainAimGate(icaos: icaos, observedByIcao: observedByIcao,
                                  suspicions: &suspicions)
        }

        runCatch(icaos: icaos, screenSize: screenSize, positions: positions,
                 suspicions: suspicions)
    }

    /// Gate 5 (LEGACY catch mode, 2026-07-13). A CENTER (non-tapped) catch
    /// whose target sits off the crosshair AND is too small to resolve, made
    /// under a POOR compass, may be the WRONG plane — the reticle can't be
    /// trusted to say which plane you meant (the A319 field mis-catch:
    /// bagged a 12.9 km cruise jet instead of a closer, lower plane). Flag,
    /// never block: the reveal proceeds, then one Keep/Discard question. An
    /// explicit tap (`lockOn.state.targetIcao24`) is a deliberate choice and
    /// is exempt.
    private func applyUncertainAimGate(
        icaos: [String],
        observedByIcao: [String: ObservedAircraft],
        suspicions: inout [String: CatchSuspicion]
    ) {
        guard let acc = location.headingAccuracy, acc >= Self.compassGoodThreshold,
              let heading = location.heading else { return }
        let roll = Geo.rollDeg(
            gravityX: motion.gravityX, gravityY: motion.gravityY, gravityZ: motion.gravityZ
        )
        let basis = Geo.cameraBasis(
            headingDeg: heading, cameraElevationDeg: motion.cameraElevationDeg, rollDeg: roll
        )
        for icao in icaos where icao != lockOn.state.targetIcao24 {
            guard let obs = observedByIcao[icao] else { continue }
            let v = Geo.cameraFrameVector(
                targetBearingDeg: obs.bearingDeg, targetElevationDeg: obs.elevationDeg, basis: basis
            )
            let offsetDeg = v.z <= 0 ? 180.0
                : atan2((v.x*v.x + v.y*v.y).squareRoot(), v.z) * 180 / .pi
            let conf = aimConfidence(
                offsetDeg: offsetDeg, arcmin: obs.apparentSizeArcminutes, headingAccuracyDeg: acc
            )
            guard conf < Self.uncertainAimConfidenceFloor else { continue }
            CatchTelemetry.fireUncertainAim(
                offsetDeg: offsetDeg, arcmin: obs.apparentSizeArcminutes,
                headingAccuracyDeg: acc, confidence: conf
            )
            suspicions[icao] = CatchSuspicion.preferred(suspicions[icao], .uncertainAim)
        }
    }

    /// Project an aircraft's shutter-press observation through the
    /// shutter-press pose — the bracket's geometric prediction. This used
    /// to re-read the LIVE pose after the shutter returned (the idea:
    /// account for hand drift during shutter latency), but a slow shutter
    /// inverted it — the "live" pose was the phone being lowered after the
    /// press, projecting the plane off where the photo shows it (ASA1374,
    /// 2026-08-26). Drift between press and exposure is the detector
    /// snap's job; geometry sticks to the press instant. nil when the
    /// plane wasn't observed at press or the compass was down — caller
    /// falls back to the tap-time position.
    private func pressScreenPosition(
        for icao: String,
        in observed: [ObservedAircraft],
        screenSize: CGSize,
        headingDeg: Double?,
        cameraElevationDeg: Double,
        rollDeg: Double,
        zoom: CGFloat
    ) -> CGPoint? {
        guard let obs = observed.first(where: { $0.aircraft.icao24 == icao }),
              let heading = headingDeg else { return nil }
        let basis = Geo.cameraBasis(
            headingDeg: heading,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg
        )
        return obs.screenPosition(
            basis: basis,
            in: screenSize,
            hfovDeg: Self.baseHfovDeg / zoom,
            vfovDeg: Self.baseVfovDeg / zoom
        )
    }

    /// The actual catch — capture the JPEG, build + save the rows, fire
    /// `catch_performed`, present the reveal. Bypasses the authenticity
    /// gate (the gate decision lives in `performCatch`; the nudge's
    /// "Catch anyway" calls this directly).
    private func runCatch(
        icaos: [String],
        screenSize: CGSize,
        positions: [String: CGPoint],
        suspicions: [String: CatchSuspicion] = [:]
    ) {
        guard !icaos.isEmpty else { return }
        guard !captureInFlight else { return }
        captureInFlight = true

        // Snapshot observer pose + visible-aircraft map up front. The
        // map is keyed by icao24 so the per-row loop is O(N) (not N×M
        // linear scans).
        let observerLat = location.latitude ?? 0
        let observerLon = location.longitude ?? 0
        // SHUTTER-PRESS SNAPSHOT (2026-08-26 ASA1374 field case): everything
        // pose-derived downstream — the bracket's fallback projection and the
        // capture diagnostics — must reflect the aim at THIS instant, not
        // whenever the async pipeline gets around to reading the sensors. A
        // slow shutter (~2 s on Debug builds) meant the "current" pose was
        // the phone being LOWERED post-press: diagnostics recorded a
        // -21.7° elevation / 41.5°-off-target catch of a plane the user had
        // dead-centered, and the fallback bracket landed on empty sky.
        let pressObserved = adsb.observed
        let pressHeading = location.heading
        let pressHeadingAccuracy = location.headingAccuracy
        let pressElevationDeg = motion.cameraElevationDeg
        let pressRollDeg = Geo.rollDeg(
            gravityX: motion.gravityX, gravityY: motion.gravityY, gravityZ: motion.gravityZ
        )
        let pressZoom = zoom
        // `Dictionary(uniquingKeysWith:)` over `uniqueKeysWithValues:` —
        // if upstream ever emits two observations with the same icao24
        // (reannotation race, future provider quirk) we deduplicate
        // instead of crashing the catch button.
        let visibleByIcao = Dictionary(
            pressObserved.map { ($0.aircraft.icao24, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Pipeline stage clock (fed to `catch_pipeline_timing` at the end —
        // the storyboard's numbers were estimates; this measures the field).
        let tapAt = Date()

        // EARLY REVEAL SHELL (capture-lag work, 2026-08-13). Single-target
        // catches present the reveal NOW — before the shutter — as a loading
        // shell over tap-time data: the dedup verdict and entry number are
        // cheap local fetches that used to run after the detector for no
        // reason, callsign/typecode/rarity/alt/speed ride the live feed
        // (the route is withheld until pipeline end — see `shellCardPlane`),
        // and the photo slot holds `SkyPlaceholder` until the pipeline
        // delivers the still through the loader. The reveal's own split-flap
        // settle (~2 s) covers the fill window, so loading reads as the
        // ceremony, not as waiting. Multi-catches keep the settled flow —
        // `MultiCatchReveal` is built from finished rows.
        var earlyLoader: RevealLoader? = nil
        if icaos.count == 1, let icao = icaos.first {
            // Narrowed duplicate rule (v1.1, scope R11): same airframe +
            // same callsign + same local day. The live feed's callsign is
            // the flight identity — the same one persisted on the row below.
            let isDup = Catch.isDuplicate(
                icao24: icao,
                callsign: visibleByIcao[icao]?.aircraft.callsign,
                on: Streaks.dayKey(for: tapAt),
                in: modelContext
            )
            // "ENTRY #N" = unique AIRFRAMES after this catch, which is no
            // longer the same question as "is this a duplicate": under R12 a
            // second sighting of a known tail on a new day is a full new row
            // but NOT a new entry number.
            let entryNumber = Set(catches.map(\.icao24)).count
                + (Catch.airframeCaught(icao24: icao, in: modelContext) ? 0 : 1)
            let shellPlane: CardPlane?
            if isDup {
                // A duplicate re-reveals the EXISTING catch — complete
                // already (old photo included), just presented ~1 s sooner.
                shellPlane = fetchExistingCatch(icao: icao).map {
                    cardPlane(from: $0, observed: visibleByIcao[icao])
                }
            } else {
                shellPlane = visibleByIcao[icao].map {
                    shellCardPlane(observed: $0, metadata: cachedMetadata(for: icao))
                }
            }
            if let shellPlane {
                let loader = RevealLoader(plane: shellPlane)
                earlyLoader = loader
                pendingReveal = PendingReveal(
                    plane: shellPlane,
                    entryNumber: entryNumber,
                    isDuplicate: isDup,
                    loader: loader
                )
                // Freeze the viewfinder into the shell's photo slot: convert
                // the pipeline's latest tapped frame (≤ ~125 ms old at 8 fps)
                // off-main and hand it to the loader — it lands during the
                // cover animation, so the slot opens showing the actual sky
                // instead of a placeholder. Fresh catches only: a duplicate
                // shell already carries the existing catch's photo.
                if !isDup {
                    Task.detached(priority: .userInitiated) { [visualConfirm] in
                        guard let frame = visualConfirm.latestFrameImage() else { return }
                        await MainActor.run { loader.provisionalPhoto = frame }
                    }
                }
            }
        }

        Task { @MainActor in
            // Backstop: the latch is normally cleared by the reveal's
            // dismiss callbacks, but if this task exits before a reveal
            // is presented (e.g. an error/cancellation at an await) the
            // catch button would soft-lock. Clear it unless a sheet
            // actually went up. The early shell counts as up from the start
            // (its dismiss callbacks own the latch from presentation on).
            var revealPresented = (earlyLoader != nil)
            defer { if !revealPresented { captureInFlight = false } }
            // However this task exits, the shell must stop reading as
            // "loading" — a photo-less catch settles to the classic
            // placeholder instead of a perpetual loading slot.
            defer { earlyLoader?.pipelineFinished = true }
            // Catch-time route resolve (see CatchBackfill.resolveCatchTimeRoute):
            // the backend attaches routes a poll LATE, so a freshly-caught
            // plane usually froze a route-less row and the bonus round couldn't
            // fire. Kick the resolve NOW — concurrently with the shutter/detector
            // below — for the single-catch path (the only guess-eligible one),
            // and only when the live feed carried no route to begin with. Awaited
            // just before the row is built; because it overlaps the ~19-pass
            // detector snap it adds no perceptible latency to the reveal.
            let routeResolve: Task<BackendAircraft.Route?, Never>? = {
                guard icaos.count == 1, let icao = icaos.first,
                      let obs = visibleByIcao[icao],
                      obs.aircraft.originIcao == nil, obs.aircraft.destIcao == nil
                else { return nil }
                let callsign = obs.aircraft.callsign
                // The plane's live position + track ride along so the server
                // can pick the current LEG of a multi-leg filing (ONT–SFO–ORD
                // → "ONT → SFO" on the arrival) and reject a stale filing the
                // plane is nowhere near (2026-07-19).
                let lat = obs.aircraft.latitude
                let lng = obs.aircraft.longitude
                let track = obs.aircraft.trackDeg
                return Task {
                    await CatchBackfill.resolveCatchTimeRoute(
                        callsign: callsign, lat: lat, lng: lng, track: track
                    )
                }
            }()
            // One JPEG, reused for every new row in this catch. If the
            // camera isn't ready (auth denied, session not running),
            // `captureJPEG` returns nil — Catches are still valid
            // without a photo. Capture first so a slow shutter doesn't
            // double-fire the dedup gate when the user re-taps.
            let shutterStart = Date()
            let photoData = await captureBridge.captureJPEG()
            let shutterMs = Int(Date().timeIntervalSince(shutterStart) * 1000)
            if photoData == nil {
                Log.adsb.notice("Catch: camera capture returned no data")
            }
            let now = Date()
            var snapMs: Int? = nil
            var composeMs: Int? = nil

            // Bracket snap (D4·2 — catch-time-only assignment, 2026-08-28):
            // geometry places each bracket, but compass wobble plus hand
            // drift during the ~0.2-0.6 s shutter latency leaves it off the
            // plane in the saved photo (field reports 2026-07-04/05). Per
            // chosen target (the press is capped at `maxCatchTargets`):
            //   1. Re-project from the SHUTTER-PRESS pose — tap-time screen
            //      coordinates are stale by the time the photo exists.
            //   2. Ring-search the captured still around that prediction
            //      (CatchPhotoSnapper), anchored per plane, and snap to the
            //      plane it finds.
            //   3. Enforce unique assignment across targets — no detection
            //      serves two brackets (`resolveSnapConflicts`); the loser
            //      falls back to its geometric prediction. Membership is
            //      already frozen: vision moves brackets, never edits the
            //      caught set.
            var bracketPositions = positions
            // Gate 4 — L4 detector soft-gate (anti-cheat PR3), fed by the
            // SAME still search: the snapper's ring pass is the strongest
            // detector evidence the catch path has, so its outcome doubles
            // as the corroboration signal. Judged only inside the detector's
            // competence envelope (daylight + expected footprint above the
            // model's resolution floor — DetectorGate); out-of-envelope and
            // multi-catches are never doubted. SHADOW by default: telemetry
            // always fires, suspicion only when the debug flag enforces.
            var suspicions = suspicions
            var detectorVerdict: DetectorGateVerdict?
            var singleSnap: CatchPhotoSnapper.Snap?
            var singleSnapped: CGPoint?
            if let data = photoData, !icaos.isEmpty {
                let predictions: [(icao: String, predicted: CGPoint)] = icaos.compactMap { icao in
                    let predicted = pressScreenPosition(
                        for: icao, in: pressObserved, screenSize: screenSize,
                        headingDeg: pressHeading, cameraElevationDeg: pressElevationDeg,
                        rollDeg: pressRollDeg, zoom: pressZoom
                    ) ?? positions[icao]
                    return predicted.map { (icao, $0) }
                }
                // Detached: each search is up to ~19 CoreML passes (fine
                // ring + coarse ring + refine) plus a 12 MP resample; never
                // on the MainActor. Sequential inside the one task — CoreML
                // serializes on the ANE anyway.
                let snapStart = Date()
                let outcomes = await Task.detached(priority: .userInitiated) {
                    () -> [(icao: String, predicted: CGPoint, snap: CatchPhotoSnapper.Snap)] in
                    predictions.map { p in
                        (p.icao, p.predicted, CatchPhotoSnapper.snapOutcome(
                            jpegData: data,
                            predictedScreen: p.predicted,
                            screenSize: screenSize
                        ))
                    }
                }.value
                snapMs = Int(Date().timeIntervalSince(snapStart) * 1000)
                let resolved = resolveSnapConflicts(outcomes.map {
                    TargetSnap(icao24: $0.icao, predicted: $0.predicted,
                               snapped: $0.snap.screenPoint)
                })
                for snap in resolved {
                    let outcome: String
                    if let snapped = snap.snapped {
                        bracketPositions[snap.icao24] = snapped
                        outcome = "snapped"
                    } else if CGRect(origin: .zero, size: screenSize).contains(snap.predicted) {
                        bracketPositions[snap.icao24] = snap.predicted
                        outcome = "fallback"
                    } else {
                        // The re-projected target was outside the frame at
                        // exposure and the detector found nothing — baking a
                        // clipped bracket at the frame edge points at nothing
                        // and reads as a bug (2026-07-08 ACA708 field photo).
                        // Save the photo bracket-free instead.
                        bracketPositions.removeValue(forKey: snap.icao24)
                        outcome = "offframe"
                    }
                    let correction = snap.snapped.map {
                        Int(hypot($0.x - snap.predicted.x, $0.y - snap.predicted.y).rounded())
                    }
                    Log.adsb.notice("Catch photo snap: \(outcome, privacy: .public) correction=\(correction ?? 0, privacy: .public)pt")
                    Analytics.capture("catch_photo_snap", [
                        "outcome": .string(outcome),
                        "correction_pt": .int(correction ?? 0),
                        "targets": .int(icaos.count),
                    ])
                }
                if icaos.count == 1 {
                    singleSnap = outcomes.first?.snap
                    singleSnapped = resolved.first?.snapped
                }
            }
            if let snap = singleSnap, let icao = icaos.first {
                // A live preview fix also corroborates (fresh by construction
                // — it expires after ~1 s of detector misses). Only the
                // legacy mode tracks pre-press, so in the frame mode this is
                // always false and the still search is the whole evidence.
                let liveFix = visualConfirm.fixes[icao] != nil
                // Envelope footprint only when the still was actually
                // searched — an undecodable photo must fail open.
                let footprintPx: Double? = snap.searched
                    ? visibleByIcao[icao].flatMap { obs in
                        snap.photoWidthPx.flatMap { photoWidth in
                            DetectorGate.expectedFootprintPx(
                                wingspanMeters: obs.aircraft.estimatedWingspanMeters,
                                slantMeters: obs.slantDistanceMeters,
                                effectiveHfovDeg: Self.baseHfovDeg / pressZoom,
                                photoWidthPx: photoWidth
                            )
                        }
                    }
                    : nil
                let meanLum = visualConfirm.latestSkyFeatures?.meanLuminance
                let verdict = DetectorGate().verdict(
                    sawPlane: singleSnapped != nil || liveFix,
                    expectedFootprintPx: footprintPx,
                    meanLuminance: meanLum
                )
                detectorVerdict = verdict
                let enforcing = visualConfirm.detectorGateEnforcing
                CatchTelemetry.fireDetectorGate(
                    verdict: verdict, snapHit: singleSnapped != nil, liveFix: liveFix,
                    expectedFootprintPx: footprintPx, meanLuminance: meanLum,
                    enforcing: enforcing
                )
                if verdict == .noDetection, enforcing {
                    suspicions[icao] = CatchSuspicion.preferred(suspicions[icao], .noDetection)
                }
            }

            // Snapshot BEFORE inserting: was the Hangar empty? (The
            // first_plane_catch activation event fires on the tap that
            // takes it 0 → N.)
            let priorCatchCount = (try? modelContext.fetchCount(
                FetchDescriptor<Catch>()
            )) ?? 0

            // Capture-time targeting diagnostics (pure debugging — never gates
            // or scores). Built from the SHUTTER-PRESS snapshot, not the live
            // sensors — by this point the pipeline is seconds past the press
            // and the phone may already be lowered, which recorded nonsense
            // (-21.7° elevation on a dead-centered catch — ASA1374,
            // 2026-08-26). Press-time is what makes a "wrong plane" mis-catch
            // diagnosable from the row (the A319 field case, 2026-07-13).
            let diagBasis = Geo.cameraBasis(
                headingDeg: pressHeading ?? 0,
                cameraElevationDeg: pressElevationDeg, rollDeg: pressRollDeg
            )
            // Frame mode: every on-frame plane (the frame is the zone).
            // Legacy mode: the 100 pt central catch zone, as shipped.
            let diagCandidates: [CatchCandidate] = catchMode == .legacy
                ? catchCandidates(
                    in: pressObserved, phoneHeadingDeg: pressHeading ?? 0,
                    cameraElevationDeg: pressElevationDeg, rollDeg: pressRollDeg,
                    screenSize: screenSize,
                    hfovDeg: Self.baseHfovDeg / pressZoom, vfovDeg: Self.baseVfovDeg / pressZoom,
                    zoneRadius: Self.catchZoneRadius
                )
                : frameDiagCandidates(
                    in: pressObserved, phoneHeadingDeg: pressHeading ?? 0,
                    cameraElevationDeg: pressElevationDeg, rollDeg: pressRollDeg,
                    screenSize: screenSize,
                    hfovDeg: Self.baseHfovDeg / pressZoom, vfovDeg: Self.baseVfovDeg / pressZoom
                )

            var newCatches: [Catch] = []
            var duplicates: [String] = []

            // Await the catch-time route resolve kicked off above (nil unless
            // this was a single catch whose live feed carried no route). It ran
            // during the shutter/detector work, so this is usually already done.
            // Merged onto the fresh row below — equivalent to the Hangar
            // backfill's per-callsign heal, just applied AT catch so the bonus
            // round can render. Only the fully-nil-route case is filled (never
            // a one-sided as-observed route — see the row's route comment).
            let resolvedRoute = await routeResolve?.value

            for icao in icaos {
                // Narrowed duplicate rule (scope R11/R12) — see
                // `Catch.isDuplicate`. Keyed off `now`, the same instant
                // written to `caughtAt` below, so a catch taken across a
                // midnight boundary is gated against the day it is filed
                // under rather than the day the shutter opened.
                if Catch.isDuplicate(
                    icao24: icao,
                    callsign: visibleByIcao[icao]?.aircraft.callsign,
                    on: Streaks.dayKey(for: now),
                    in: modelContext
                ) {
                    duplicates.append(icao)
                    continue
                }
                // Metadata: the ambient prefetch cache (which covers every
                // labeled plane), then a direct manager lookup.
                let metadata: AircraftMetadata?
                if let cached = ambientMetadata[icao] ?? nil {
                    metadata = cached
                } else {
                    metadata = await adsb.metadata(for: icao)
                }

                let observed = visibleByIcao[icao]
                // Superimpose the cyan lock-on bracket around the plane
                // at its captured-frame screen position so the saved
                // JPEG records which plane this catch represents. If the
                // plane has no recorded position (unusual — it was on
                // screen when the button rendered, but the dict missed)
                // we fall back to the raw photo bytes.
                // The composer also reports WHERE the plane sits in the
                // photo (the bracket center, normalized 0…1); persisted so
                // photo displays crop around the plane, not the frame center.
                var photoFocus: CGPoint? = nil
                var photoFilename: String? = nil
                if let data = photoData {
                    let composeStart = Date()
                    let overlayPos = bracketPositions[icao]
                    // Detached like the snapper above: the 12 MP decode +
                    // bracket bake + JPEG re-encode + disk write were a
                    // synchronous MainActor block (~0.1–0.4 s) that froze
                    // the camera preview mid-capture. The composer and
                    // store are `nonisolated` — hop off to run them.
                    let saved = await Task.detached(priority: .userInitiated) {
                        () -> (filename: String?, focus: CGPoint?) in
                        let toSave: Data
                        var focus: CGPoint? = nil
                        if let pos = overlayPos {
                            let overlay = CatchPhotoComposer.BracketOverlay(
                                screenPosition: pos,
                                screenSize: screenSize
                            )
                            if let composed = CatchPhotoComposer.compose(
                                jpegData: data, overlay: overlay
                            ) {
                                toSave = composed.jpegData
                                focus = composed.normalizedFocus
                            } else {
                                toSave = data
                            }
                        } else {
                            // No bracket to bake (missing position or
                            // off-frame target) — still normalize orientation
                            // and cap the size so a raw 12 MP sensor still
                            // never lands in the Hangar verbatim.
                            toSave = CatchPhotoComposer.normalizedWithoutBracket(
                                jpegData: data) ?? data
                        }
                        let filename = CatchPhotoStore.save(toSave, icao24: icao, at: now)
                        // Warm the reveal's decode cache while still off-main
                        // so the early shell's photo swap-in is a cache hit,
                        // not a ~12 MP main-thread decode mid-flap-animation.
                        if let filename,
                           let url = CatchPhotoStore.url(forFilename: filename) {
                            await RevealPhoto.preloadDecoded(url: url)
                        }
                        return (filename, focus)
                    }.value
                    photoFilename = saved.filename
                    photoFocus = saved.focus
                    composeMs = (composeMs ?? 0)
                        + Int(Date().timeIntervalSince(composeStart) * 1000)
                }
                let row = Catch(
                    icao24: icao,
                    callsign: observed?.aircraft.callsign,
                    model: metadata?.model,
                    manufacturer: metadata?.manufacturerName,
                    operatorName: metadata?.operatorName
                        ?? Airlines.name(forCallsign: observed?.aircraft.callsign),
                    photoFilename: photoFilename,
                    caughtAt: now,
                    observerLat: observerLat,
                    observerLon: observerLon,
                    slantDistanceMeters: observed?.slantDistanceMeters ?? 0,
                    // Prefer the LIVE feed's type/registration (adsb.lol carries
                    // them for essentially every airframe, incl. foreign tails the
                    // FAA-only /v1/metadata endpoint can't resolve), falling back
                    // to the metadata endpoint. See Catch.preferredAirframeField.
                    registration: Catch.preferredAirframeField(
                        feed: observed?.aircraft.registration, metadata: metadata?.registration),
                    typecode: Catch.preferredAirframeField(
                        feed: observed?.aircraft.typecode, metadata: metadata?.typecode),
                    // Emitter category is feed-only (the metadata endpoint has no
                    // such field), so record the live value as-observed.
                    category: observed?.aircraft.category,
                    altitudeMeters: observed?.aircraft.altitudeMeters,
                    velocityMps: observed?.aircraft.velocityMps,
                    // Route (origin → destination): record as-observed from
                    // the feed; nil when the feed had none. A fully-nil route
                    // may later heal via CatchBackfill's per-callsign lookup
                    // (2026-07-04) — a one-sided as-observed route never does.
                    // `resolvedRoute` is that SAME lookup pulled forward to
                    // catch time (single-catch, feed-had-no-route path) so the
                    // bonus round can render; it's a complete origin+dest pair
                    // or nil, so it never fabricates a one-sided journey.
                    originIcao: observed?.aircraft.originIcao ?? resolvedRoute?.originIcao,
                    destIcao: observed?.aircraft.destIcao ?? resolvedRoute?.destIcao,
                    originIata: observed?.aircraft.originIata ?? resolvedRoute?.originIata,
                    destIata: observed?.aircraft.destIata ?? resolvedRoute?.destIata,
                    originName: observed?.aircraft.originName ?? resolvedRoute?.originName,
                    destName: observed?.aircraft.destName ?? resolvedRoute?.destName,
                    // Post-catch confirm: a gate-suspected row is born
                    // quarantined (skipped by CatchUploader) until the
                    // post-reveal review clears or deletes it.
                    suspectReason: suspicions[icao]?.rawValue,
                    photoFocusX: photoFocus.map { Double($0.x) },
                    photoFocusY: photoFocus.map { Double($0.y) }
                )
                row.captureDiagnosticsJSON = buildCaptureDiagnostics(
                    for: icao, observed: observed, candidates: diagCandidates,
                    basis: diagBasis,
                    headingDeg: pressHeading,
                    headingAccuracyDeg: pressHeadingAccuracy,
                    cameraElevationDeg: pressElevationDeg,
                    rollDeg: pressRollDeg,
                    zoom: pressZoom,
                    // Frame mode: a user assertion; legacy mode: the pin.
                    wasTapped: assertedPlanes[icao] != nil
                        || icao == lockOn.state.targetIcao24
                )
                modelContext.insert(row)
                newCatches.append(row)
            }

            if !newCatches.isEmpty {
                do {
                    try modelContext.save()
                } catch {
                    Log.adsb.error("Catch save failed: \(error.localizedDescription, privacy: .public)")
                    // Surfaced after the reveal dismisses (see
                    // `presentSuspectReviewIfNeeded`) — silently losing a
                    // catch the reveal just celebrated reads as success.
                    pendingSaveFailToast = true
                }
                // One haptic per catch event regardless of N — the
                // reveal carries the multiplicity message.
                catchHaptic &+= 1
                Log.adsb.notice("Caught \(newCatches.count, privacy: .public) plane(s); \(duplicates.count, privacy: .public) duplicate(s)")
                // Per-catch immediate upload (2026-08-24): push the fresh
                // non-suspect row(s) to the backend NOW instead of waiting
                // for the next foreground transition — a first-time user
                // otherwise opened Profile/Leaderboard with 0 server-side
                // points and no rank. Fire-and-forget; uploadPending is
                // idempotent and serverUuid-deduped, so overlapping the
                // scene-activation sweep is safe, and a failure just defers
                // to that sweep.
                Task { await CatchUploader().uploadPending(context: modelContext) }
                // Reverse-geocode the observer position ONCE for the
                // batch (every row shares it) and stamp the new rows.
                // Post-save and fire-and-forget: a catch never waits
                // on — or fails because of — the geocoder. Offline →
                // placeName stays nil; CatchDetailView's backfill
                // retries on a later open.
                Task { @MainActor in
                    let (place, country) = await ReverseGeocode.placeAndCountry(
                        lat: observerLat, lon: observerLon
                    )
                    guard place != nil || country != nil else { return }
                    for row in newCatches where !row.isDeleted {
                        if row.placeName == nil { row.placeName = place }
                        if row.country == nil { row.country = country }
                    }
                    try? modelContext.save()
                    // A late country stamp can cross Mr. Worldwide — re-diff.
                    unlockCenter.enqueueNewUnlocks(from: catches)
                }
            } else if !duplicates.isEmpty {
                Log.adsb.notice("Catch: all \(duplicates.count, privacy: .public) target(s) already in Hangar")
            }

            // Catch-confirmation telemetry (north-star). One event per
            // processed target: new catches carry rarity/type/slant,
            // duplicates record the dedup hit. Fire-and-forget.
            for row in newCatches {
                CatchTelemetry.firePerformed(
                    row,
                    visualConfirmEnabled: visualConfirm.enabled,
                    visualFixConfidence: visualConfirm.fixes[row.icao24]?.confidence,
                    // Anti-cheat signals: how many this tap caught (L1 → ~1) and
                    // the caught plane's apparent size (L3 → trending bigger).
                    multiN: newCatches.count,
                    angularSizeArcmin: visibleByIcao[row.icao24]?.apparentSizeArcminutes,
                    // Only ever non-nil for a single-target catch, so it can't
                    // mislabel a multi-catch row.
                    detectorVerdict: detectorVerdict,
                    catchMode: catchMode
                )
            }
            for icao in duplicates { CatchTelemetry.fireDuplicate(icao24: icao) }

            // Activation milestone: this tap took the Hangar from empty to
            // its first catch(es). Latched inside fireFirstCatch.
            if priorCatchCount == 0, let first = newCatches.first {
                CatchTelemetry.fireFirstCatch(first)
            }

            // Daily streak bookkeeping. Every successful catch action makes
            // today a catch-day, and under the narrowed duplicate rule that
            // is always reflected in a `Catch` row: a fresh catch writes one,
            // and a duplicate can only BE a duplicate because an earlier row
            // from today already exists (Streaks.swift, rule 3).
            //
            // `catches` is the @Query slice, which may not have observed this
            // tap's inserts yet — so prior days are read with those rows
            // filtered out (making "is this the day's first catch?" exact,
            // not a race), and today is then unioned in explicitly.
            var streakDaysForReveal: Int? = nil
            if !newCatches.isEmpty || !duplicates.isEmpty {
                let todayKey = Streaks.dayKey(for: now)
                let priorRows = catches.filter { row in
                    !newCatches.contains(where: { $0 === row })
                }
                // ONE entry point, shared with the Profile card. This used
                // to call `Streaks.currentStreak` directly, which is how the
                // two screens came to report different streaks minutes apart
                // (2026-08-21) — the debug override is applied inside the
                // day-set funnel, and this path was reaching past it.
                let current = Streaks.summary(
                    catches: priorRows, assumingCatchOn: todayKey, asOf: now
                ).current
                // Telemetry reads the REAL rows, always: a forced streak is
                // for looking at, and `streak_extended` is a fact about the
                // user that lands in PostHog forever.
                let realPriorDays = Streaks.realDaySet(catches: priorRows)
                if !realPriorDays.contains(todayKey) {
                    let realCurrent = Streaks.currentStreak(
                        days: realPriorDays.union([todayKey]), todayKey: todayKey
                    )
                    StreakTelemetry.fireExtended(streakDays: realCurrent)
                }
                if current >= StreakReminders.minimumStreak {
                    streakDaysForReveal = current
                }
                earlyLoader?.streakDays = streakDaysForReveal
                // Re-plan the protection nudge (a catch today pushes it to
                // tomorrow evening) and stage the one-time permission ask if
                // this streak just became worth protecting. Async because the
                // authorization status read is; lands well before the reveal
                // dismisses (its ceremony runs ≥1.7 s).
                Task { @MainActor in
                    let center = StreakReminderCenter.shared
                    if StreakReminders.shouldOfferAsk(
                        currentStreak: current,
                        enabled: center.remindersEnabled,
                        alreadyAsked: UserDefaults.standard.bool(
                            forKey: StreakReminders.permissionAskedKey),
                        authStatusIsNotDetermined:
                            await center.authorizationStatus() == .notDetermined
                    ) {
                        pendingStreakAsk = current
                    }
                    await center.sync(context: modelContext)
                }
            }

            // Post-catch confirm: record each quarantined row and stash the
            // suspected set — the reveal's dismiss callbacks promote it into
            // the Keep/Discard dialog (never shown on top of the reveal).
            let suspected = newCatches.filter { $0.suspectReason != nil }
            for row in suspected {
                guard let reason = row.suspectReason
                    .flatMap(CatchSuspicion.init(rawValue:)) else { continue }
                CatchTelemetry.fireSuspected(
                    icao24: row.icao24,
                    reason: reason,
                    arcmin: visibleByIcao[row.icao24]?.apparentSizeArcminutes,
                    slantKm: row.slantDistanceMeters / 1000
                )
            }
            suspectAwaitingReview = suspected

            // In-card BONUS ROUND (game-layer PR3; in-card per Noah 2026-07-10).
            // Only a fresh SINGLE catch is eligible — a duplicate awards no
            // points to bonus and a multi-catch owns its own MultiCatchReveal,
            // so those paths are untouched. The scheduler (cadence + kind) runs
            // ONLY here, so its UserDefaults counters advance on exactly the
            // catches that could host a round. When it fires AND an honest
            // question builds, the reveal is presented immediately WITH the
            // question threaded in (no separate cover); otherwise, plain reveal.
            let firstFresh = newCatches.first
            let guessInputs = GuessRoundPlanner.inputs(
                freshCount: newCatches.count,
                duplicateCount: duplicates.count,
                suspectReason: firstFresh?.suspectReason,
                originIcao: firstFresh?.originIcao,
                destIcao: firstFresh?.destIcao
            )
            var guessPayload: (question: GuessRoundQuestion, row: Catch)?
            if guessInputs.isFreshSingle, let row = firstFresh {
                let kind = guessScheduler.decideForRecordedCatch(
                    isFreshSingle: true,
                    isDuplicate: false,
                    isSuspect: guessInputs.isSuspect,
                    routeAvailable: guessInputs.routeAvailable
                )
                if kind != nil, let question = buildGuessQuestion(row: row) {
                    guessPayload = (question, row)
                }
            }

            let presentMs: Int
            let revealMode: String
            if let loader = earlyLoader {
                // The shell has been up since tap time — hand it the finished
                // catch. Swapping the whole CardPlane keeps photo/route/
                // first-of-type consistent in one update; the row rides along
                // for the guess round to freeze onto; the question (if the
                // scheduler fired one) pops when the reveal settles.
                if let row = newCatches.first {
                    loader.plane = cardPlane(from: row, observed: visibleByIcao[row.icao24])
                    loader.row = row
                    if let payload = guessPayload { loader.guess = payload.question }
                }
                // If the user tap-skipped and dismissed the shell before the
                // pipeline finished, the dismiss callbacks already ran — any
                // late-arriving suspicion review must present itself.
                if pendingReveal == nil {
                    presentSuspectReviewIfNeeded()
                }
                revealPresented = (pendingReveal != nil)
                presentMs = 0
                revealMode = "shell"
            } else {
                presentReveal(newCatches: newCatches, duplicates: duplicates,
                              visibleByIcao: visibleByIcao, guess: guessPayload,
                              streakDays: streakDaysForReveal)
                revealPresented = (pendingReveal != nil || pendingMultiReveal != nil)
                presentMs = Int(Date().timeIntervalSince(tapAt) * 1000)
                revealMode = pendingMultiReveal != nil ? "multi"
                    : (pendingReveal != nil ? "settled" : "none")
            }
            CatchTelemetry.firePipelineTiming(
                mode: revealMode,
                shutterMs: shutterMs,
                snapMs: snapMs,
                composeMs: composeMs,
                presentMs: presentMs,
                totalMs: Int(Date().timeIntervalSince(tapAt) * 1000),
                catchMode: catchMode
            )
        }
    }

    /// Build the route guess question off a fresh catch row, or nil when no
    /// honest option set can be rendered (e.g. the airport distractor pool is
    /// too thin for the correct answer's region). Production RNG.
    private func buildGuessQuestion(row: Catch) -> GuessRoundQuestion? {
        var rng = SystemRandomNumberGenerator()
        return GuessOptions.routeQuestion(
            originIcao: row.originIcao,
            destIcao: row.destIcao,
            observerLat: row.observerLat,
            observerLon: row.observerLon,
            using: &rng
        ).map { GuessRoundQuestion(route: $0) }
    }

    /// One ~1 Hz tick of the ambient indoor-hint debounce: read the gate
    /// verdict, advance the streak, flip `pointedIndoors` on a sustained
    /// change, and fire the hint telemetry on each flip. Lives OUTSIDE
    /// `body` — inlining this work in the `.task` closure pushed
    /// ContentView.body over the compiler's type-check budget (2026-08-27;
    /// see the ~880-line lesson from PR #184).
    ///
    /// Telemetry (2026-08-27 night-FP audit): the hint rode the same
    /// verdict as the catch gate but was invisible in analytics. Shown
    /// carries the tripping frame's features (same payload as
    /// catch_blocked_outdoors); cleared carries how long it was up. Rapid
    /// show/clear pairs are the flapping signature — deliberately not
    /// smoothed here.
    private func indoorHintTick() {
        let skyFeatures = visualConfirm.latestSkyFeatures
        let gpsAccuracy = location.horizontalAccuracy
        let verdict = computeOutdoorVerdict(features: skyFeatures, gps: gpsAccuracy)
        indoorStreak = verdict == .notSky ? indoorStreak + 1 : 0
        let indoors = indoorStreak >= 5   // ~5 s sustained (was 3 —
                                          // the ambient nag was too eager, 2026-07-01)
        guard indoors != pointedIndoors else { return }
        withAnimation { pointedIndoors = indoors }
        if indoors {
            indoorHintShownAt = Date()
            CatchTelemetry.fireIndoorHintShown(
                features: skyFeatures, gpsAccuracyMeters: gpsAccuracy
            )
        } else if let shownAt = indoorHintShownAt {
            indoorHintShownAt = nil
            CatchTelemetry.fireIndoorHintCleared(
                shownSeconds: Int(Date().timeIntervalSince(shownAt).rounded())
            )
        }
    }

    /// v1 authenticity gate decision. Pure: maps the latest camera-frame
    /// sky features + GPS accuracy to the "pointed at open sky?" verdict.
    /// Missing features (camera not warmed up) → `.uncertain`, which
    /// always allows (fail open). Telemetry + the enforce/block decision
    /// live at the call site (`performCatch`).
    private func computeOutdoorVerdict(features: SkyFeatures?, gps: Double?) -> SkyVerdict {
        features.map { SkyCheck().verdict(features: $0, gpsAccuracyMeters: gps) } ?? .uncertain
    }

    /// Picks the right reveal payload based on what landed.
    ///
    /// - Single (1 fresh OR 1 dup) → `CatchRevealView` via `pendingReveal`.
    /// - Multi (≥2 combined fresh + dup) → `MultiCatchReveal` via
    ///   `pendingMultiReveal`. Fresh and dup entries are interleaved
    ///   in the same order they were captured; the reveal renders
    ///   ALREADY CAUGHT stamps inline on dups and only credits fresh
    ///   tails toward the combo + points (T11).
    ///
    /// Duplicate-only case (single dup): synthesizes a `CardPlane`
    /// from the already-stored row + (when available) the current
    /// live observation for fresh alt/speed/distance.
    #if DEBUG
    /// Debug-only: fabricate a catch at a cycling tier and fire the reveal,
    /// so the catch / reveal / economy can be eyeballed on-device without a
    /// real plane (the synthetic ADS-B source was removed). Non-persisting —
    /// shows the reveal card without writing to the Hangar.
    #if DEBUG
    /// STREAK row of the wrench panel. The feature's three surfaces all key
    /// off streak LENGTH and an evening clock, so without this the only way to
    /// see any of them is to catch planes on N consecutive days and then
    /// wait for the evening. The override is DEBUG-only and printed back on
    /// the line above in amber whenever it's live — a stuck override that
    /// quietly makes the Profile lie is the mock-mode failure mode.
    @ViewBuilder
    private var streakDebugRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("STREAK")
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(StreakDebug.label)
                    .foregroundStyle(StreakDebug.override == nil
                                     ? Brand.Color.textTertiary
                                     : Brand.Color.alertCaution)
                Text("·")
                    .foregroundStyle(Brand.Color.textTertiary)
                Text(streakDebugStatus)
                    .foregroundStyle(Brand.Color.textTertiary)
            }
            .font(Brand.Font.mono(size: 10, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            HStack(spacing: 8) {
                // nil → 2 → 3 → … → 12 → nil. Re-plans on every step so the
                // pending reminder always matches what the panel claims.
                Button("🔥 \(StreakDebug.override.map { "\($0.current)d" } ?? "Set")") {
                    StreakDebug.cycle()
                    streakDebugRefresh &+= 1
                    Task { await StreakReminderCenter.shared.sync(context: modelContext) }
                }
                // At-risk vs safe — the branch the card's state line and the
                // planner's "today" test both hang off.
                Button(streakSummaryNow.caughtToday ? "🔥 Safe" : "🔥 Risk") {
                    StreakDebug.toggleCaughtToday()
                    streakDebugRefresh &+= 1
                    Task { await StreakReminderCenter.shared.sync(context: modelContext) }
                }
                .disabled(StreakDebug.override == nil)
                // The real notification, 10 s out: same id, same content, same
                // delegate — only the trigger differs, plus a marker that
                // lets it through the camera-silence rule (this button IS on
                // the camera). Re-reads the status once it has landed so the
                // row reports what the delegate actually did with it.
                Button("🔔 Fire") {
                    let streak = max(streakSummaryNow.current, StreakReminders.minimumStreak)
                    Task {
                        streakDebugStatus = await StreakReminderCenter.shared
                            .debugFireReminder(streakAtStake: streak)
                        try? await Task.sleep(for: .seconds(13))
                        streakDebugStatus = await StreakReminderCenter.shared.debugStatusLine()
                    }
                }
                // The one-shot pre-prompt, unlatched so it can be re-tested.
                Button("🔔 Ask") {
                    streakAskFromDebug = true
                    withAnimation(.easeOut(duration: 0.25)) {
                        streakAsk = max(streakSummaryNow.current, StreakReminders.minimumStreak)
                    }
                }
                // Clear the override AND the asked latch, then re-plan from
                // the real Hangar — back to a truthful device.
                Button("↺ Reset") {
                    StreakDebug.clear()
                    UserDefaults.standard.removeObject(forKey: StreakReminders.permissionAskedKey)
                    // The debug fire has its own slot, so `sync` below won't
                    // clear it — Reset has to.
                    UNUserNotificationCenter.current().removePendingNotificationRequests(
                        withIdentifiers: [StreakReminders.debugNotificationId])
                    UNUserNotificationCenter.current().removeDeliveredNotifications(
                        withIdentifiers: [StreakReminders.debugNotificationId])
                    StreakReminderCenter.lastForegroundDecision = nil
                    streakDebugRefresh &+= 1
                    Task {
                        await StreakReminderCenter.shared.sync(context: modelContext)
                        streakDebugStatus = await StreakReminderCenter.shared.debugStatusLine()
                    }
                }
            }
            .font(Brand.Font.mono(size: 11, weight: .bold))
            .buttonStyle(.bordered)
            .tint(Brand.Color.cyan)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // `streakDebugRefresh` is read here so mutating it re-evaluates the
        // row — the override lives in UserDefaults, which SwiftUI can't
        // observe on its own.
        .id(streakDebugRefresh)
        .task {
            streakDebugStatus = await StreakReminderCenter.shared.debugStatusLine()
        }
    }

    /// The live summary the panel reports and its buttons act on — override
    /// included, since that is the whole point of the row.
    private var streakSummaryNow: Streaks.Summary {
        Streaks.summary(catches: catches)
    }
    #endif

    private func simulateCatch() {
        struct Sim {
            let icao, callsign, model, mfr, op, typecode: String
            let alt, vel, dist: Double
            let origin, dest, originName, destName: String?
        }
        let presets: [Sim] = [
            Sim(icao: "5101c7", callsign: "RCH872", model: "Boeing C-17 Globemaster III",
                mfr: "Boeing", op: "U.S. Air Force", typecode: "C17",
                alt: 8500, vel: 215, dist: 9200, origin: "KSUU", dest: "PHIK",
                originName: "Travis AFB", destName: "Honolulu"),
            Sim(icao: "a4e172", callsign: "N4521C", model: "Cessna 172",
                mfr: "Cessna", op: "Private", typecode: "C172",
                alt: 1100, vel: 52, dist: 3800, origin: nil, dest: nil,
                originName: nil, destName: nil),
            Sim(icao: "a9bc53", callsign: "JBU613", model: "Airbus A220-300",
                mfr: "Airbus", op: "JetBlue", typecode: "BCS3",
                alt: 10800, vel: 232, dist: 14500, origin: "KBOS", dest: "KSFO",
                originName: "Boston Logan", destName: "San Francisco"),
            Sim(icao: "3b7440", callsign: "GEC8160", model: "Boeing 747-400",
                mfr: "Boeing", op: "Lufthansa Cargo", typecode: "B744",
                alt: 11200, vel: 251, dist: 22000, origin: "RJAA", dest: "KSFO",
                originName: "Tokyo Narita", destName: "San Francisco"),
            Sim(icao: "ae0b52", callsign: "DOOM11", model: "Boeing B-52 Stratofortress",
                mfr: "Boeing", op: "U.S. Air Force", typecode: "B52",
                alt: 12200, vel: 244, dist: 31000, origin: "KBAD", dest: nil,
                originName: "Barksdale AFB", destName: nil),
        ]
        let s = presets[simCatchIndex % presets.count]
        simCatchIndex += 1
        let c = Catch(
            icao24: s.icao, callsign: s.callsign, model: s.model, manufacturer: s.mfr,
            operatorName: s.op, caughtAt: Date(),
            observerLat: 37.8, observerLon: -122.27,  // fabricated — observer coords irrelevant to the reveal
            slantDistanceMeters: s.dist, typecode: s.typecode,
            altitudeMeters: s.alt, velocityMps: s.vel,
            originIcao: s.origin, destIcao: s.dest,
            originName: s.originName, destName: s.destName
        )
        // Route the simulation through the REAL in-card guess seam whenever the
        // preset carries a route and a question builds — the debug button is how
        // the bonus-round pacing gets felt without field-catching. No telemetry,
        // no persistence (isSimulated + transient row). The route-less presets
        // (C172, and the B-52 with a nil destination + uncurated origin) still
        // preview the plain reveal.
        let question = buildGuessQuestion(row: c)
        // Carry the streak so ✦ Catch previews the reveal's streak line too —
        // with the wrench override set, that's the only way to see the line
        // at an arbitrary length without catching for real on N days.
        let streak = Streaks.summary(catches: catches).current
        pendingReveal = PendingReveal(
            plane: cardPlane(from: c, observed: nil),
            entryNumber: Set(catches.map(\.icao24)).count + 1,
            isDuplicate: false,
            guess: question,
            row: question != nil ? c : nil,
            isSimulated: true,
            streakDays: streak >= StreakReminders.minimumStreak ? streak : nil
        )
    }
    #endif

    private func presentReveal(
        newCatches: [Catch],
        duplicates: [String],
        visibleByIcao: [String: ObservedAircraft],
        guess: (question: GuessRoundQuestion, row: Catch)? = nil,
        streakDays: Int? = nil
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
                let plane = cardPlane(from: c, observed: observed)
                entries.append(.init(plane: plane, isDuplicate: false))
            }
            for dupIcao in duplicates {
                if let existing = fetchExistingCatch(icao: dupIcao) {
                    let observed = visibleByIcao[dupIcao]
                    let plane = cardPlane(from: existing, observed: observed)
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
            let plane = cardPlane(from: first, observed: observed)
            // A bonus round only ever rides a fresh single catch (the scheduler
            // gate guarantees it, so `guess.row` is `first`); it's nil on every
            // other path.
            pendingReveal = PendingReveal(
                plane: plane,
                entryNumber: uniqueIcaoCount,
                isDuplicate: false,
                guess: guess?.question,
                row: guess?.row,
                streakDays: streakDays
            )
            return
        }

        if let dupIcao = duplicates.first,
           let existing = fetchExistingCatch(icao: dupIcao) {
            let observed = visibleByIcao[dupIcao]
            let plane = cardPlane(from: existing, observed: observed)
            pendingReveal = PendingReveal(
                plane: plane,
                entryNumber: uniqueIcaoCount,
                isDuplicate: true,
                streakDays: streakDays
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
    /// `CardPlane` for duplicate entries (both single + multi paths).
    private func fetchExistingCatch(icao: String) -> Catch? {
        let key = icao.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var descriptor = FetchDescriptor<Catch>(
            predicate: #Predicate { $0.icao24 == key },
            sortBy: [SortDescriptor(\.caughtAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Build a presentational `CardPlane` from a stored `Catch`,
    /// borrowing live alt/speed values from `observed` when the
    /// catch is still in view. Used by both the new-catch and
    /// duplicate paths so the reveal renders consistently.
    private func cardPlane(from row: Catch, observed: ObservedAircraft?) -> CardPlane {
        let canonical = AircraftNaming.canonical(
            typecode: row.typecode,
            manufacturer: row.manufacturer,
            model: row.model
        )
        let distMeters = observed?.slantDistanceMeters ?? row.slantDistanceMeters
        // Route, when the catch captured one (adsb.lol doesn't carry it for
        // every plane). Display codes prefer IATA ("HND") over ICAO ("RJTT")
        // per source — live observation first, then the stored row; names
        // are the optional human-readable airport/city labels.
        let origin = observed.flatMap { $0.aircraft.originIata ?? $0.aircraft.originIcao }
            ?? row.displayOrigin
        let dest = observed.flatMap { $0.aircraft.destIata ?? $0.aircraft.destIcao }
            ?? row.displayDest
        // First-of-type: no *other* Hangar row shares this typecode. Display
        // only — the reveal ledger mirrors what the backend awards.
        let isFirstOfType = row.typecode.map { tc in
            !catches.contains { $0 !== row && $0.typecode == tc }
        } ?? false
        // Guess bonus (game-layer PR3; route-only per Noah 2026-07-09): a
        // "25% ROUTE BONUS +N" line only for a CORRECT call (wrong/skipped/
        // no-round → nil kind → no line). The amount derives live off the
        // current base like firstOfType, so it re-tiers on read. Server
        // re-verifies at upload and is authoritative.
        let guessKind: GuessKind? = (row.guessCorrect == true)
            ? row.guessKind.flatMap(GuessKind.init(rawValue:))
            : nil
        let guessBonusPoints = guessKind.map {
            // The row's own caughtAt picks the fraction era (the 2026-08-13
            // route re-balance is going-forward only) — a pre-cutover catch
            // re-tiers at its legacy +10%, mirroring the server's award.
            ScoringBonuses.guessBonus(
                base: row.resolvedRarity.basePoints, kind: $0, caughtAt: row.caughtAt
            )
        } ?? 0
        return CardPlane(
            callsign: row.callsign,
            model: canonical.displayName ?? row.model,
            // Same derivation as CatchDetailView's card: recorded operator,
            // else the callsign-prefix airline, else Private/unknown — so the
            // reveal's identity row matches the Hangar detail's exactly.
            carrier: Airlines.operatorLabel(operatorName: row.operatorName,
                                            callsign: row.callsign),
            rarity: row.resolvedRarity,
            type: row.resolvedType,
            altText: CardPlane.altText(fromMeters: observed?.aircraft.altitudeMeters ?? row.altitudeMeters),
            speedText: CardPlane.speedText(fromMps: observed?.aircraft.velocityMps ?? row.velocityMps),
            distText: String(format: "%.1f km", distMeters / 1000),
            photoURL: row.photoFilename.flatMap { CatchPhotoStore.url(forFilename: $0) },
            photoFocus: row.photoFocus,
            originIcao: origin,
            destIcao: dest,
            originName: observed?.aircraft.originName ?? row.originName,
            destName: observed?.aircraft.destName ?? row.destName,
            isFirstOfType: isFirstOfType,
            guessKind: guessKind,
            guessBonusPoints: guessBonusPoints
        )
    }

    /// Tap-time `CardPlane` for the early reveal SHELL — built from the live
    /// observation plus whatever metadata is already cached, BEFORE any row
    /// exists (CardPlane's documented pre-persistence path). Mirrors
    /// `cardPlane(from:observed:)` field-for-field where the data exists at
    /// tap time; photo and guess fields start empty, and the loader swaps in
    /// the full row-built snapshot when the pipeline finishes.
    ///
    /// The ROUTE is deliberately withheld (nil) even when the feed carries it:
    /// whether this catch gets a route BONUS ROUND isn't known until the
    /// pipeline finishes (scheduler + suspect verdict need the recorded row),
    /// and a shell that shows the real route first LEAKS THE ANSWER — the
    /// route flashed, then the masked "Where's it headed?" prompt overtook it
    /// (Noah's field report, 2026-08-25). The card's DIST fallback fills the
    /// slot instead; at pipeline end the loader swaps in plane + row + guess
    /// in one MainActor pass, so the slot resolves atomically to either the
    /// real route or the masked prompt — never one then the other.
    private func shellCardPlane(
        observed: ObservedAircraft, metadata: AircraftMetadata?
    ) -> CardPlane {
        let aircraft = observed.aircraft
        let typecode = Catch.preferredAirframeField(
            feed: aircraft.typecode, metadata: metadata?.typecode
        )
        let canonical = AircraftNaming.canonical(
            typecode: typecode,
            manufacturer: metadata?.manufacturerName,
            model: metadata?.model
        )
        // Same derivations as `Catch.resolvedRarity` / `resolvedType`:
        // typecode is authoritative; no typecode → conservative `.common`
        // plus the string classifier for the type bucket.
        let rarity = AircraftNaming.rarity(forTypecode: typecode) ?? .common
        let type = AircraftNaming.aircraftType(forTypecode: typecode)
            ?? AircraftClassifier.classify(
                manufacturer: metadata?.manufacturerName,
                model: metadata?.model,
                operatorName: metadata?.operatorName
            ).type
        // No row exists yet, so unlike `cardPlane(from:)` there's nothing to
        // exclude from the scan: first-of-type ⇔ no existing row shares the
        // typecode.
        let isFirstOfType = typecode.map { tc in
            !catches.contains { $0.typecode == tc }
        } ?? false
        return CardPlane(
            callsign: aircraft.callsign,
            model: canonical.displayName ?? metadata?.model,
            carrier: Airlines.operatorLabel(
                operatorName: metadata?.operatorName
                    ?? Airlines.name(forCallsign: aircraft.callsign),
                callsign: aircraft.callsign
            ),
            rarity: rarity,
            type: type,
            altText: CardPlane.altText(fromMeters: aircraft.altitudeMeters),
            speedText: CardPlane.speedText(fromMps: aircraft.velocityMps),
            distText: String(format: "%.1f km", observed.slantDistanceMeters / 1000),
            isFirstOfType: isFirstOfType
        )
    }

    /// Metadata already on hand at tap time — the ambient prefetch cache,
    /// which covers every labeled plane. Never the network: the shell
    /// can't wait, and the pipeline's own `adsb.metadata(for:)` fallback
    /// fills the row (and thus the loader's final snapshot) later.
    private func cachedMetadata(for icao: String) -> AircraftMetadata? {
        ambientMetadata[icao] ?? nil
    }

    /// Big central capture button. A single circle that is always
    /// present; multi-mode adds a small magenta `×N` badge in the
    /// top-right corner.
    private func captureButton(
        mode: CaptureMode,
        screenSize: CGSize,
        positions: [String: CGPoint]
    ) -> some View {
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
            performCatch(mode: mode, screenSize: screenSize, positions: positions)
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
                    // Capturing state: `captureInFlight` was previously a
                    // pure re-entry latch that nothing rendered — now the
                    // button owns it visually. Mostly visible on the multi
                    // path (the single path's reveal shell covers it fast).
                    if captureInFlight {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Brand.Color.cyan)
                    } else {
                        Text("CAPTURE")
                            .font(Brand.Font.mono(size: 10, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(Brand.Color.cyan)
                    }
                }
                if isMulti {
                    Text("×\(count)")
                        .font(Brand.Font.mono(size: 9, weight: .bold))
                        .foregroundStyle(Brand.Color.bgPrimary)
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
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .fill(Brand.Color.bgPrimary.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.Radius.card)
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
                        .font(Brand.Font.mono(size: 10, weight: .bold))
                        .foregroundStyle(Brand.Color.bgPrimary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Brand.Color.alertNormal, in: .capsule)
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Open hangar (\(CountCopy.phrase(catches.count, singular: "catch", plural: "catches")))"
        )
    }

    /// Profile button in the bottom bar. Mirrors the hangar button's
    /// visual weight so the two flank the capture button evenly.
    private var bottomProfileButton: some View {
        Button {
            showProfile = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Brand.Radius.card)
                    .fill(Brand.Color.bgPrimary.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: Brand.Radius.card)
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
    /// N nearby" so they understand traffic IS there, just below
    /// the horizon or past 30 km.
    private func emptySkyOverlay(rawCount: Int) -> some View {
        // The pill renders the ErrorCopy-mapped message ("NO INTERNET —
        // RETRYING" / "TAILSPOT UNREACHABLE — RETRYING"), never the raw
        // transport string — that stays in `lastError` for the debug
        // aircraft list and logs (error-copy pass, 2026-08-14).
        let lastErr = adsb.lastErrorUserMessage
        let neverFetched = adsb.lastFetched == nil && lastErr == nil
        let pillText: String = {
            if let lastErr { return lastErr.uppercased() }
            if neverFetched { return "SCANNING SKY…" }
            if rawCount > 0 {
                return "NO AIRCRAFT IN VIEW · \(rawCount) NEARBY"
            }
            return "NO AIRCRAFT NEARBY"
        }()
        // Errors (transport, backend down) → amber caution; the neutral
        // scanning / empty states use the textSecondary tint.
        let pillTint: Color = lastErr != nil
            ? Brand.Color.alertCaution
            : Brand.Color.textSecondary
        return GeometryReader { geo in
            ZStack {
                // No centered reticle box here by design: the camera
                // opens clean and a reticle only appears once a plane
                // is in view (the per-plane brackets in `PlaneLabel`).
                // Only the low status pill remains so the user still
                // knows whether we're scanning / out of range / errored.
                //
                // `maxWidth: .infinity` is load-bearing: it makes this
                // VStack fill the GeometryReader's width so the pill
                // centers horizontally. (GeometryReader pins content to
                // .topLeading, so without it the pill jams against the
                // left edge.) The pill used to rely on a sibling
                // `emptyReticle.position(...)` to stretch the ZStack —
                // removing that reticle (#62) silently un-centered the
                // pill. Declaring our own width stops that recurring.
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(pillTint)
                            .frame(width: 6, height: 6)
                            .modifier(EmptyPulse(active: lastErr == nil))
                        Text(pillText)
                            .font(Brand.Font.mono(size: 10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(pillTint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Brand.Color.bgPrimary.opacity(0.55), in: .capsule)
                    .padding(.bottom, geo.size.height * 0.18)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Top: sensor readout

    private var sensorReadout: some View {
        VStack(alignment: .leading, spacing: 8) {

            // SOURCE section
            Text("SOURCE")
                .font(Brand.Font.mono(size: 10))
                .foregroundStyle(Brand.Color.textTertiary)
            sourceRow
            Text(formatADSBStatus())
                .font(Brand.Font.mono(size: 12))
                .foregroundStyle(Brand.Color.textPrimary)

            // SENSORS section
            Text("SENSORS")
                .font(Brand.Font.mono(size: 10))
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.top, 8)
            Group {
                Text(formatLocation())
                Text(formatHeading())
                    .foregroundStyle(isHeadingAccuracyBad ? Brand.Color.alertCaution : Brand.Color.textPrimary)
                Text(formatCameraElevation())
                if !cameraAuthorized {
                    Text("camera: not authorized")
                }
            }
            .font(Brand.Font.mono(size: 12))
            .foregroundStyle(Brand.Color.textPrimary)

            // TOOLS section
            Text("TOOLS")
                .font(Brand.Font.mono(size: 10))
                .foregroundStyle(Brand.Color.textTertiary)
                .padding(.top, 8)
            Group {
                recordingRow
                analyzeRow
                visualConfirmRow
                gateDebugRow
                localGateRow
                detectorGateRow
                #if DEBUG
                catchModeRow
                #endif
            }
            .font(Brand.Font.mono(size: 12))
            .foregroundStyle(Brand.Color.textPrimary)
        }
        // Inner padding so content isn't jammed against the panel edge, plus a
        // hairline border for definition — declutter pass (on-device feedback
        // that the readout looked busy/ugly). Content is unchanged; it's useful
        // in shared screenshots.
        .padding(14)
        .background(Brand.Color.bgPrimary.opacity(0.6), in: .rect(cornerRadius: Brand.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Bottom: nearby-aircraft list

    private var aircraftList: some View {
        // Same predicate as the AR layer: above horizon + within
        // maxVisibleDistanceMeters. Keeps the bottom panel honest with
        // what's on-screen instead of dumping the full 50 km bbox.
        let visible = adsb.observed.filter(\.isLikelyVisibleToObserver)
        return VStack(alignment: .leading, spacing: 0) {
            // Tappable header — always visible, shows live count
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showAircraftList.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("NEARBY AIRCRAFT (\(visible.count))")
                        .font(Brand.Font.mono(size: 10))
                        .foregroundStyle(Brand.Color.textTertiary)
                    Spacer()
                    Image(systemName: showAircraftList ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Brand.Color.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if showAircraftList {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(visible) { obs in
                            aircraftRow(obs)
                        }
                        if visible.isEmpty {
                            Text(emptyListMessage)
                                .font(Brand.Font.mono(size: 12))
                                .foregroundStyle(Brand.Color.textPrimary.opacity(0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                    }
                    .padding(.bottom, 12)
                }
                .frame(maxHeight: 320)
            }
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
        .font(Brand.Font.mono(size: 11))
        .foregroundStyle(Brand.Color.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - Permission

    /// True after an explicit location denial. `.notDetermined` is NOT
    /// denied — the prompt may still be pending from onboarding.
    private var locationDenied: Bool {
        location.authorizationStatus == .denied
            || location.authorizationStatus == .restricted
    }

    private var permissionRecoveryOverlay: some View {
        PermissionRecoveryCard(cameraDenied: cameraDenied, locationDenied: locationDenied)
    }

    private func requestCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            cameraAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            cameraDenied = !cameraAuthorized
        case .denied, .restricted:
            cameraAuthorized = false
            // An explicit prior "don't allow" — unlike notDetermined, only
            // the Settings app can undo it, so the recovery overlay shows
            // an Open Settings path instead of a silent black screen.
            cameraDenied = true
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
                    // Activation funnel: how often the compass is bad enough
                    // to warn — the suspected silent killer of "label points
                    // the wrong way" first sessions.
                    ActivationTelemetry.fireCompassCautionShown(headingAccuracyDeg: acc)
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

    /// Camera elevation above the horizon — the gravity-derived angle
    /// fed into projection math. Negative = camera below horizon.
    private func formatCameraElevation() -> String {
        let camElDeg = motion.cameraElevationDeg
        return String(format: "Cam-el:  %+.1f°", camElDeg)
    }

    /// Empty-state message for the bottom list. Surfaces the actual
    /// reason — error, no fix yet, or just no traffic — instead of the
    /// blanket "Waiting for first fetch…" which used to stick around
    /// even after a failure.
    private var emptyListMessage: String {
        if let err = adsb.lastError { return err }
        if adsb.lastFetched == nil  { return "Waiting for first fetch…" }
        return "No aircraft nearby."
    }

    private func formatADSBStatus() -> String {
        if let t = adsb.lastFetched {
            let secs = Int(Date().timeIntervalSince(t))
            return String(format: "ADSB:    %d aircraft, %ds ago", adsb.observed.count, secs)
        }
        return "ADSB:    fetching…"
    }

    /// Static source indicator for the debug overlay. There's exactly one
    /// ADS-B source now (the Tailspot backend) — OpenSky and the mock source
    /// were removed in the 2026-06-21 cutover — so this is a label, not a
    /// toggle. Kept as a debug-overlay sanity line ("yes, the app is talking
    /// to api.tailspot.app").
    private var sourceRow: some View {
        HStack(spacing: 8) {
            Text("[TAILSPOT API]")
                .font(Brand.Font.mono(size: 12, weight: .bold))
                .foregroundStyle(Brand.Color.cyan)
            Spacer()
        }
    }

    /// Tap-to-toggle row for visual confirmation. Shows availability
    /// (model in bundle), the on/off state, and — when a fix is live —
    /// a cyan FIX tag with its confidence, so a field session can see at
    /// a glance whether the detector is locked onto the real plane.
    private var visualConfirmRow: some View {
        HStack(spacing: 8) {
            Text("Visual confirm:")
            if !visualConfirm.isAvailable {
                Text("[NO MODEL]").foregroundStyle(Brand.Color.alertWarning).bold()
            } else {
                Text(visualConfirm.enabled ? "[ON]" : "[OFF]")
                    .foregroundStyle(visualConfirm.enabled
                                     ? Brand.Color.alertNormal
                                     : Brand.Color.textTertiary)
                    .bold()
                if let fix = visualConfirm.fixes.values.first {
                    Text(String(format: "[FIX %.2f]", fix.confidence))
                        .foregroundStyle(Brand.Color.cyan)
                        .bold()
                }
            }
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture {
            guard visualConfirm.isAvailable else { return }
            visualConfirm.enabled.toggle()
        }
    }

    /// Live gate readout (debug): the current SkyCheck verdict + raw
    /// features off the latest camera frame, so the gate can be eyeballed
    /// in the field. "(no frame)" means the frame tap isn't delivering.
    private var gateDebugRow: some View {
        let f = visualConfirm.latestSkyFeatures
        let v = computeOutdoorVerdict(features: f, gps: location.horizontalAccuracy)
        return HStack(spacing: 8) {
            Text("Gate:")
            Text(v.rawValue)
                .foregroundStyle(v == .notSky ? Brand.Color.alertCaution : Brand.Color.textTertiary)
                .bold()
            if let f {
                Text(String(format: "e%.2f v%.3f w%+.2f l%.2f",
                            f.edgeDensity, f.tileVariance, f.warmth, f.meanLuminance))
                    .foregroundStyle(Brand.Color.textTertiary)
            } else {
                Text("(no frame)").foregroundStyle(Brand.Color.alertWarning).bold()
            }
            Spacer()
        }
    }

    /// Tap-to-toggle row for the L2 localized sky gate (debug). SHADOW
    /// (telemetry only, ships this way) ↔ ENFORCE (blocks a bracket aimed at
    /// a building/tree). Lets a field session flip enforcement on to feel the
    /// occlusion nudge before the on-device threshold is calibrated.
    private var localGateRow: some View {
        HStack(spacing: 8) {
            Text("L2 gate:")
            Text(visualConfirm.localGateEnforcing ? "[ENFORCE]" : "[SHADOW]")
                .foregroundStyle(visualConfirm.localGateEnforcing
                                 ? Brand.Color.alertCaution
                                 : Brand.Color.textTertiary)
                .bold()
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { visualConfirm.localGateEnforcing.toggle() }
    }

    /// Tap-to-toggle row for the L4 detector soft-gate (debug). SHADOW
    /// (telemetry only, ships this way) ↔ ENFORCE (an in-envelope catch the
    /// detector can't corroborate gets the post-reveal Keep/Discard). Lets a
    /// field session feel the doubt question before the shadow stream
    /// justifies flipping the default.
    private var detectorGateRow: some View {
        HStack(spacing: 8) {
            Text("L4 gate:")
            Text(visualConfirm.detectorGateEnforcing ? "[ENFORCE]" : "[SHADOW]")
                .foregroundStyle(visualConfirm.detectorGateEnforcing
                                 ? Brand.Color.alertCaution
                                 : Brand.Color.textTertiary)
                .bold()
            Spacer()
        }
        .contentShape(.rect)
        .onTapGesture { visualConfirm.detectorGateEnforcing.toggle() }
    }

    /// Tap-to-toggle row for the replay recorder. Idle → "Record
    /// session"; active → "REC <count>  <basename>" with a red dot.
    /// File lands in `Documents/replays/`; retrieve via
    /// `xcrun devicectl device copy from --device <udid>
    /// --domain-type appDataContainer
    /// --domain-identifier com.landesberg.Tailspot
    /// --source Documents/replays --destination ./replays`.
    private var recordingRow: some View {
        HStack(spacing: 10) {
            Image(systemName: recorder.isRecording ? "record.circle.fill" : "record.circle")
                .font(.title3)
                .foregroundStyle(recorder.isRecording ? Brand.Color.alertWarning : Brand.Color.textPrimary.opacity(0.85))
            if recorder.isRecording {
                Text("REC \(recorder.eventCount) +log  \(recorder.currentFileURL?.lastPathComponent ?? "—")")
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Record session")
            }
            Spacer()
        }
        // Full-width, padded tap target — a single-line row was too small to
        // hit reliably (on-device feedback). The background signals it's a
        // button and the padding grows the hit area.
        .padding(.vertical, 12)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: Brand.Radius.row)
                .fill(recorder.isRecording
                      ? Brand.Color.alertWarning.opacity(0.18)
                      : Color.white.opacity(0.07))
        )
        .contentShape(.rect)
        .onTapGesture {
            toggleRecording()
        }
    }

    private func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
            logCapture.stop()
            // A just-finished recording becomes the newest on disk — refresh
            // the cache so `analyzeRow` points at it without a per-frame scan.
            latestRecordingURL = ReplayRecorder.mostRecentRecording()
        } else {
            do {
                let url = try recorder.start()
                // Pair the session log to the recording (.jsonl → .log) and
                // capture os.Logger output for the session window (U3).
                let logURL = url.deletingPathExtension().appendingPathExtension("log")
                logCapture.start(at: logURL, since: Date())
            } catch {
                Log.ui.error("Failed to start replay recording: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Debug-overlay row that loads the most recent recording from
    /// `Documents/replays/` and presents `ReplayReportView`. Disabled
    /// (greyed) when there are no recordings on disk. Reads the CACHED
    /// `latestRecordingURL` (refreshed when the debug panel opens and after
    /// `toggleRecording`) rather than scanning the replays directory on every
    /// body eval — the debug panel re-renders often (sensor readout).
    private var analyzeRow: some View {
        let latest = latestRecordingURL
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
        // Record the FULL annotated set, NOT the visible-filtered subset.
        // The whole point of the replay → ReplayAnalyzer loop is to re-apply
        // `isLikelyVisibleToObserver` offline with different cap/elevation
        // tuning; if we pre-filter here, every plane the live filter rejected
        // (e.g. a distant contrail) is absent from the file and can never be
        // studied. `observed` already excludes stale rows (dropped in
        // annotate); it keeps below-horizon, far, and — since the grounded
        // easter egg — on-ground planes (hidden tier, `grounded` flag),
        // which is exactly what offline filter tuning needs.
        let annotated = adsb.observed
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
                zoomFactor: Double(zoom),
                gravityX: motion.gravityX,
                gravityY: motion.gravityY,
                gravityZ: motion.gravityZ
            ),
            aircraft: annotated.map { ReplayEvent.AircraftSnapshot($0.aircraft) }
        )
        recorder.recordTick(tick)
    }

    // MARK: - Tap-to-ID

    /// Record a user assertion: this plane is visibly THERE. It labels
    /// bright, is guaranteed a press slot, and is exempt from the
    /// occlusion demote; lifetime is `pruneAssertedPlanes`' job (on frame
    /// + grace). `recordTapPin` stays the replay event on purpose — a pin
    /// in a recording has always meant "the observer saw this plane
    /// here", which is exactly what an assertion is, so the offline
    /// regression bench keeps its ground-truth stream unchanged.
    private func assertPlane(
        _ icao: String, at now: Date, tapPoint: CGPoint?, reason: String
    ) {
        assertedPlanes[icao] = now
        recorder.recordTapPin(icao24: icao, at: now, tapPoint: tapPoint)
        Analytics.capture("tap_reveal", [
            "icao24": .string(icao), "reason": .string(reason),
        ])
    }

    /// The empty-sky tap's rescue, for whichever catch mode is live: the
    /// diagnosed `filtered` / `off-frame` plane becomes labeled + catchable.
    /// Frame mode asserts it (`assertPlane`); legacy mode reveals + pins it
    /// and force-locks the engine (the pre-#229 `tap_reveal` path). Same
    /// replay event and analytics either way.
    private func revealPlane(
        _ icao: String, at now: Date, tapPoint: CGPoint?, reason: String
    ) {
        switch catchMode {
        case .frame:
            assertPlane(icao, at: now, tapPoint: tapPoint, reason: reason)
        case .legacy:
            revealedIcao = icao
            pinnedIcao = icao
            recorder.recordTapPin(icao24: icao, at: now, tapPoint: tapPoint)
            lockOn.forceLock(targetIcao24: icao, now: now)
            Analytics.capture("tap_reveal", [
                "icao24": .string(icao), "reason": .string(reason),
            ])
        }
    }

    /// LEGACY catch mode: pin a visible plane (a normal pin is a visible
    /// plane, not a reveal). `forceLock` is the only way into `.locked` —
    /// the user just pointed at this plane, so the engine jumps straight
    /// to a locked state.
    private func legacyPin(_ icao: String, at now: Date, tapPoint: CGPoint?) {
        pinnedIcao = icao
        revealedIcao = nil
        recorder.recordTapPin(icao24: icao, at: now, tapPoint: tapPoint)
        lockOn.forceLock(targetIcao24: icao, now: now)
    }

    /// LEGACY catch mode: explicit "cancel". Both writes required — the
    /// 1 Hz `pruneLegacyPin` covers engine → view only; without `unpin()`
    /// the engine would still hold `.locked` until forced.
    private func legacyUnpin(at now: Date) {
        recorder.recordUnpin(at: now)
        pinnedIcao = nil
        revealedIcao = nil
        lockOn.unpin()
    }

    /// LEGACY catch mode: VoiceOver's route into pin/unpin — the same
    /// effect as a direct tap on a labeled plane minus the screen-geometry
    /// hit-test, which accessibility activation doesn't need: the element
    /// the user activated already names the plane.
    private func accessibilityTogglePin(icao: String) {
        let now = Date()
        if icao == pinnedIcao {
            legacyUnpin(at: now)
        } else {
            legacyPin(icao, at: now, tapPoint: nil)
        }
    }

    /// The ONLY writer of the catch-mode switch (wrench-panel row). Clears
    /// the state the outgoing mode owns so nothing leaks across: legacy's
    /// pin / reveal / engine lock / live detector target, frame's
    /// assertions. Persisted via `@AppStorage`; Release builds ignore it.
    private func setCatchMode(_ mode: CatchMode) {
        guard mode != catchMode else { return }
        pinnedIcao = nil
        revealedIcao = nil
        lockOn.unpin()
        visualConfirm.updateTarget(nil)
        assertedPlanes = [:]
        catchModeRaw = mode.rawValue
        Log.ui.notice("Catch mode → \(mode.label, privacy: .public)")
    }

    /// Spoken summary for a plane's AR label: callsign, airframe model
    /// when the metadata cache has it, rarity tier, and slant distance.
    private func planeAccessibilityLabel(
        _ obs: ObservedAircraft,
        metadata: AircraftMetadata?
    ) -> String {
        let callsign = obs.aircraft.callsign?
            .trimmingCharacters(in: .whitespaces)
            .nonEmpty
            ?? obs.aircraft.icao24.uppercased()
        let rarity = resolveAROverlayRarity(
            typecode: metadata?.typecode,
            manufacturer: metadata?.manufacturerName,
            model: metadata?.model,
            operatorName: metadata?.operatorName
        )
        let km = obs.slantDistanceMeters / 1000
        let distance = km < 9.95
            ? String(format: "%.1f", km)
            : String(Int(km.rounded()))
        var parts = [callsign]
        if let model = metadata?.model?.nonEmpty { parts.append(model) }
        parts.append(rarity.label.capitalized)
        parts.append("\(distance) kilometers away")
        return parts.joined(separator: ", ")
    }

    /// Tap handler for the AR overlay (frame-is-the-catch): a tap is an
    /// ASSERTION, never a selection.
    ///   - Tapped near a faint-tier labeled plane → promote it ("I can
    ///     see it"): bright label, guaranteed press slot.
    ///   - Tapped near a bright plane → deliberate no-op (D7).
    ///   - Tapped empty sky → diagnose: `filtered` / `off-frame` planes
    ///     assert into the frame; grounded / far classes toast; truly
    ///     empty sky ripples.
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
        phoneHeadingAccuracyDeg: Double?,
        cameraElevationDeg: Double,
        rollDeg: Double,
        hfovDeg: Double,
        vfovDeg: Double,
        now: Date
    ) {
        // Frame-is-the-catch tap model (2026-08-28): a tap never selects a
        // catch target — it asserts a plane the app isn't showing right.
        //   1. Tap on/near a labeled plane (≤100 px, zoom-scaled): a
        //      FAINT-tier plane promotes to bright ("I can see it"); a
        //      bright plane is a deliberate no-op (D7 — catching is the
        //      capture button's job).
        //   2. Otherwise diagnose the empty tap: `filtered` / `off-frame`
        //      planes are asserted into the frame (the rescue classes),
        //      grounded / beyond-eyeshot classes get their honest toasts,
        //      and truly empty sky ripples.
        //
        // LEGACY catch mode (the shipped spec § 3.1, four branches):
        //   1. Tap directly on a plane (≤100 px) → pin (toggle if same).
        //   2. Tap empty sky while pinned        → clear pin.
        //   3. Tap empty sky while not pinned    → widen radius to 250 px
        //      and pin the nearest visible plane to the tap.
        //   4. Truly empty frame                 → the shared diagnosis
        //      below (reveal → pin + force-lock; toasts; ripple).
        let cap = min(screenSize.width, screenSize.height) / 2
        let hitRadius = min(100 * zoom, cap)
        if let icao = closestTargetIcao24(
            in: visible,
            at: point,
            phoneHeadingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg,
            screenSize: screenSize,
            hfovDeg: hfovDeg,
            vfovDeg: vfovDeg,
            lockZoneRadius: hitRadius
        ) {
            switch catchMode {
            case .frame:
                let obs = visible.first { $0.aircraft.icao24 == icao }
                if let obs, obs.visibilityTier == .faint, assertedPlanes[icao] == nil {
                    assertPlane(icao, at: now, tapPoint: point, reason: "faint")
                }
            case .legacy:
                if icao == pinnedIcao {
                    legacyUnpin(at: now)
                } else {
                    legacyPin(icao, at: now, tapPoint: point)
                }
            }
            return
        }

        if catchMode == .legacy {
            // (legacy 2) Empty sky while pinned → clear the pin.
            if pinnedIcao != nil {
                legacyUnpin(at: now)
                return
            }
            // (legacy 3) Empty sky, no pin → "try harder": widen to 250 px
            // and pin the nearest visible plane (if any falls inside).
            let wideRadius = min(250 * zoom, cap)
            if let icao = closestTargetIcao24(
                in: visible,
                at: point,
                phoneHeadingDeg: phoneHeadingDeg,
                cameraElevationDeg: cameraElevationDeg,
                rollDeg: rollDeg,
                screenSize: screenSize,
                hfovDeg: hfovDeg,
                vfovDeg: vfovDeg,
                lockZoneRadius: wideRadius
            ) {
                legacyPin(icao, at: now, tapPoint: nil)
                return
            }
        }

        // (2) No labeled plane under the tap. Diagnose the nearest in-data
        // plane (ALL tiers, including hidden) and record the miss signal —
        // the frustrated tap is the most honest miss signal we have
        // (2026-06-12, after three field misses). If that nearest plane is one
        // the tap should REVEAL (`shouldTapReveal`), pin + force-lock it so it
        // labels and becomes catchable — the explicit tap is the intent the
        // ambient filter/frame lacks, without loosening the filter for everyone:
        //   - FILTERED (2026-06-19): airborne but hidden by the precision band
        //     (the FDX1268 class, inseparable from the MLAT firehose).
        //   - OFF-FRAME (2026-07-11): a visible-tier plane projected outside the
        //     frame — typically a compass/heading error (or high zoom) rotated
        //     the sky-model off where the plane visually sits, so no label drew
        //     even though the user was pointed right at it (the DAL972 field
        //     case: ~17° heading error at ±17° reported accuracy, 2.4× zoom).
        let diagnosis = recordEmptySkyTapDiagnosis(
            at: point, in: screenSize,
            phoneHeadingDeg: phoneHeadingDeg,
            phoneHeadingAccuracyDeg: phoneHeadingAccuracyDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg, hfovDeg: hfovDeg, vfovDeg: vfovDeg, now: now
        )
        // GROUNDED beats filtered: a parked plane is never revealed (never
        // labeled, locked, or catchable) — the tap gets the playful toast
        // instead, and the attempt feeds the "Ground Stop" secret badge.
        // Only a NEARBY parked plane (within `groundedToastMaxSlantMeters`)
        // classifies "grounded" — a distant one is "grounded-far", which the
        // subject rescue may already have replaced with an airborne plane in
        // the cone; unrescued it falls through to the plain empty ripple
        // below (the OAK-behind-the-Bay-Bridge case, 2026-08-26).
        if let d = diagnosis, d.reason == "grounded" {
            presentGroundedTapToast(icao24: d.obs.aircraft.icao24)
            return
        }
        // FILTERED-FAR (2026-07-12): airborne and hidden, but past plausible
        // reveal reach (or below the horizon) — the NYC couch case, where 110
        // in-data planes meant every tap "found" something 27–76 km away.
        // No reveal, no lock: an honest toast with the distance instead.
        // Honest means honest (2026-07-20, the Dumbarton drive): the toast
        // only shows when NOTHING airborne in data is within reveal reach,
        // and it quotes the distance-nearest plane, not the angular winner —
        // otherwise a heading error in a moving car turns it into "nearest
        // plane is 52 km out" with a 6 km arrival plainly in sight.
        if let d = diagnosis, d.reason == "filtered-far" {
            let airborne = adsb.observed
                .filter { !$0.grounded }
                .map { (slantMeters: $0.slantDistanceMeters,
                        plausiblyRevealable: $0.isPlausiblyRevealable) }
            if let slant = farTapToastSlantMeters(airborne: airborne) {
                presentFarTapToast(slantMeters: slant)
            } else {
                showEmptyTapRipple(at: point)
            }
            return
        }
        if let d = diagnosis, shouldTapReveal(reason: d.reason) {
            revealPlane(d.obs.aircraft.icao24, at: now, tapPoint: point, reason: d.reason)
            return
        }

        // Truly nothing reachable under the tap — brief NO AIRCRAFT HERE
        // ripple at the tap point.
        showEmptyTapRipple(at: point)
    }

    /// Build + record the empty-sky-tap diagnosis: score EVERY in-data
    /// aircraft (including hidden tiers — that is the point) by angular
    /// offset from the tapped direction, pick the subject via
    /// `chooseEmptySkyTapSubject` (angular-nearest, with the filtered-far
    /// rescue), classify it, write a replay event (when recording) and
    /// an analytics event (always; angles + ids only, no location).
    ///
    /// Returns the chosen plane + its classification so the caller can act
    /// on it (tap-to-reveal a `filtered` plane). Returns nil only when no
    /// aircraft are in data at all.
    @discardableResult
    private func recordEmptySkyTapDiagnosis(
        at point: CGPoint, in screenSize: CGSize,
        phoneHeadingDeg: Double, phoneHeadingAccuracyDeg: Double?,
        cameraElevationDeg: Double,
        rollDeg: Double, hfovDeg: Double, vfovDeg: Double, now: Date
    ) -> (obs: ObservedAircraft, reason: String)? {
        let basis = Geo.cameraBasis(
            headingDeg: phoneHeadingDeg,
            cameraElevationDeg: cameraElevationDeg,
            rollDeg: rollDeg
        )
        // Tap direction as angular offsets from the view axis.
        let tapAzDeg = (Double(point.x) / Double(screenSize.width) - 0.5) * hfovDeg
        let tapElDeg = (0.5 - Double(point.y) / Double(screenSize.height)) * vfovDeg

        var candidates: [EmptySkyTapCandidate] = []
        candidates.reserveCapacity(adsb.observed.count)
        for (i, obs) in adsb.observed.enumerated() {
            let v = Geo.cameraFrameVector(
                targetBearingDeg: obs.bearingDeg,
                targetElevationDeg: obs.elevationDeg,
                basis: basis
            )
            // Camera-frame angles (forward = +z); behind-camera planes get a
            // large synthetic offset so they lose to anything in front.
            let azDeg = atan2(v.x, max(v.z, 1e-6)) * 180 / .pi
            let elDeg = atan2(v.y, max(v.z, 1e-6)) * 180 / .pi
            let off = v.z <= 0
                ? 180.0
                : ((azDeg - tapAzDeg) * (azDeg - tapAzDeg)
                    + (elDeg - tapElDeg) * (elDeg - tapElDeg)).squareRoot()
            candidates.append(EmptySkyTapCandidate(
                index: i,
                offsetDeg: off,
                onScreen: obs.screenPosition(
                    basis: basis, in: screenSize, hfovDeg: hfovDeg, vfovDeg: vfovDeg
                ) != nil,
                grounded: obs.grounded,
                slantMeters: obs.slantDistanceMeters,
                tier: obs.visibilityTier,
                plausiblyRevealable: obs.isPlausiblyRevealable
            ))
        }

        let choice = chooseEmptySkyTapSubject(candidates)
        let best = choice.map {
            (obs: adsb.observed[$0.candidate.index], offsetDeg: $0.candidate.offsetDeg)
        }
        let reason = choice?.reason ?? "nothing-nearby"

        let tap = ReplayEvent.EmptyTap(
            timestamp: now,
            x: Double(point.x), y: Double(point.y),
            nearestIcao24: best?.obs.aircraft.icao24,
            nearestCallsign: best?.obs.aircraft.callsign,
            nearestSlantMeters: best?.obs.slantDistanceMeters,
            nearestElevationDeg: best?.obs.elevationDeg,
            nearestAngularOffsetDeg: best?.offsetDeg,
            reason: reason,
            headingAccuracyDeg: phoneHeadingAccuracyDeg
        )
        recorder.recordEmptyTap(tap)

        var props: [String: AnalyticsValue] = ["reason": .string(reason)]
        // True when the angular-nearest plane classified filtered-far but a
        // revealable/visible plane also sat in the tap cone and took over as
        // the subject — the Dumbarton-drive signature (a car-corrupted
        // heading letting a 50 km stranger beat the 6 km plane in sight).
        if choice?.rescued == true { props["rescued"] = .bool(true) }
        // Compass quality at the miss — a large value marks a magnetic-error
        // (off-frame) miss. -1 = OS says invalid; omit it then.
        if let acc = phoneHeadingAccuracyDeg, acc >= 0 {
            props["heading_accuracy_deg"] = .double(acc)
        }
        if let b = best {
            props["nearest_icao24"] = .string(b.obs.aircraft.icao24)
            if let cs = b.obs.aircraft.callsign { props["nearest_callsign"] = .string(cs) }
            props["nearest_slant_km"] = .double(b.obs.slantDistanceMeters / 1000)
            props["nearest_elevation_deg"] = .double(b.obs.elevationDeg)
            props["nearest_offset_deg"] = .double(b.offsetDeg)
        }
        Analytics.capture("empty_sky_tap", props)

        return best.map { ($0.obs, reason) }
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

// MARK: - Empty-sky-tap classification

/// Angular radius (degrees off the tapped direction) inside which the
/// nearest in-data plane counts as "what the user was pointing at" — the
/// tap-reveal radius. Beyond it the tap is truly empty sky.
let emptySkyTapMaxOffsetDeg: Double = 40

/// Slant bound (meters) inside which a grounded angular winner counts as
/// "the parked plane you are actually looking at" and earns the playful
/// toast. Beyond it the parked plane is invisible scenery — the Bay Bridge
/// field case (2026-08-26): freighters parked at OAK, 18 km away and dead
/// on the horizon line, beat the airborne plane in sight on angle and
/// turned every tap into the grounded toast. A far parked plane classifies
/// `grounded-far` instead: eligible for the rescue, never for the toast.
let groundedToastMaxSlantMeters: Double = 1_000

/// Classify the nearest in-data plane found under an empty-sky tap.
/// Extracted from `recordEmptySkyTapDiagnosis` so the branch that decides
/// toast-vs-reveal-vs-ripple is unit-testable without a SwiftUI view
/// (same free-function precedent as `resolveAROverlayRarity`).
///
///   - "grounded"       → parked plane under the tap, near enough to be the
///                         thing the user is looking at (within
///                         `groundedToastMaxSlantMeters`): playful toast,
///                         never a reveal (checked BEFORE the tier — a
///                         grounded plane is also `.hidden`, and reveal must
///                         lose).
///   - "grounded-far"    → parked plane under the tap but beyond the slant
///                         bound — invisible airport scenery on the horizon
///                         (the OAK-behind-the-Bay-Bridge case, 2026-08-26),
///                         not something the user can be aiming at. Subject
///                         to the same rescue as `filtered-far`; unrescued
///                         it falls through to the plain empty ripple.
///   - "filtered"        → airborne, hidden by the precision band, but within
///                         plausible reveal reach: tap-to-reveal (the FDX1268
///                         affordance).
///   - "filtered-far"    → airborne and hidden, but beyond
///                         `revealReachMeters` (or below the horizon) — not
///                         plausibly visible from here, so the tap gets the
///                         beyond-eyeshot hint instead of a reveal (the NYC
///                         couch session, 2026-07-12: 110 planes in data,
///                         nearest-tap planes 27–76 km out). Subject to the
///                         `chooseEmptySkyTapSubject` rescue and the
///                         `farTapToastSlantMeters` honesty guard — see both
///                         (the Dumbarton drive, 2026-07-20).
///   - "off-frame"       → visible tier but projected outside the screen.
///   - "on-screen"       → visible and on screen (tap just missed it).
///   - "nothing-nearby"  → nearest plane is too far off the tap direction.
///
/// Deliberately NOT `nonisolated`: it consumes `visibilityTier`, whose
/// enclosing types are MainActor-isolated (the repo default); every caller
/// (the tap handler, tests) is already on the MainActor, so this costs
/// nothing — the same trade `applyVisibilityHysteresis` documents.
func classifyEmptySkyTapNearest(
    offsetDeg: Double,
    grounded: Bool,
    slantMeters: Double,
    tier: ObservedAircraft.VisibilityTier,
    onScreen: Bool,
    plausiblyRevealable: Bool
) -> String {
    guard offsetDeg <= emptySkyTapMaxOffsetDeg else { return "nothing-nearby" }
    if grounded {
        return slantMeters <= groundedToastMaxSlantMeters ? "grounded" : "grounded-far"
    }
    if tier == .hidden { return plausiblyRevealable ? "filtered" : "filtered-far" }
    if !onScreen { return "off-frame" }
    return "on-screen"
}

/// Per-plane snapshot for empty-sky-tap subject selection — the minimal
/// facts `chooseEmptySkyTapSubject` needs, extracted from `ObservedAircraft`
/// so the selection rule is unit-testable without building full observations
/// (same free-function precedent as `classifyEmptySkyTapNearest`).
struct EmptySkyTapCandidate {
    /// Caller's index into its source array (`adsb.observed`).
    let index: Int
    /// Angular offset from the tapped direction; 180 = behind the camera.
    let offsetDeg: Double
    let onScreen: Bool
    let grounded: Bool
    /// Slant distance to the plane — bounds the grounded toast (a parked
    /// plane 18 km away is scenery, not a tap subject).
    let slantMeters: Double
    let tier: ObservedAircraft.VisibilityTier
    let plausiblyRevealable: Bool
}

/// Pick the plane an empty-sky tap is ABOUT. Normally the angular-nearest —
/// but selection is no longer blind to tier (the Dumbarton-drive bug,
/// 2026-07-20): in a moving car the compass error rotates the sky model tens
/// of degrees, so the 6 km arrival the user is looking at can project far
/// from the tap while some 50 km hidden-tier stranger lands angularly
/// nearer. Picking the stranger produced a "Nearest plane is 52 km out"
/// toast with a plane plainly in sight.
///
/// Rule: take the angular-nearest; if (and only if) it classifies
/// `filtered-far` or `grounded-far`, look for the angular-nearest plane in
/// the tap cone that the tap could actually act on — airborne AND
/// (visible-tier OR plausibly revealable) — and make THAT the subject
/// instead (`rescued: true`). Its own classification then drives the normal
/// branch: `filtered`/`off-frame` reveal, `on-screen` ripples.
///
/// `grounded-far` joined the rescue on 2026-08-26 (the Bay Bridge case):
/// freighters parked at OAK — 18 km out, exactly on the horizon line the
/// user was aiming along — won the angular race against the airborne plane
/// plainly in sight, and every tap dead-ended in the parked-plane toast.
/// A parked plane the user cannot possibly see must not outrank one they
/// can.
///
/// Deliberately NOT rescued:
///   - "grounded" primary (within `groundedToastMaxSlantMeters`) — the
///     parked-plane toast/easter egg must win: a deliberate tap on a parked
///     plane the user is looking at shouldn't reveal a plane 30° away.
///   - The NYC couch case — nothing revealable in the cone, so the rescue
///     finds no alternative and `filtered-far` stands.
func chooseEmptySkyTapSubject(
    _ candidates: [EmptySkyTapCandidate]
) -> (candidate: EmptySkyTapCandidate, reason: String, rescued: Bool)? {
    func classify(_ c: EmptySkyTapCandidate) -> String {
        classifyEmptySkyTapNearest(
            offsetDeg: c.offsetDeg, grounded: c.grounded,
            slantMeters: c.slantMeters, tier: c.tier,
            onScreen: c.onScreen, plausiblyRevealable: c.plausiblyRevealable
        )
    }
    guard let primary = candidates.min(by: { $0.offsetDeg < $1.offsetDeg }) else {
        return nil
    }
    let primaryReason = classify(primary)
    guard primaryReason == "filtered-far" || primaryReason == "grounded-far" else {
        return (primary, primaryReason, false)
    }
    let alt = candidates
        .filter {
            $0.offsetDeg <= emptySkyTapMaxOffsetDeg && !$0.grounded
                && ($0.tier != .hidden || $0.plausiblyRevealable)
        }
        .min(by: { $0.offsetDeg < $1.offsetDeg })
    guard let alt else { return (primary, primaryReason, false) }
    return (alt, classify(alt), true)
}

/// Whether the beyond-eyeshot toast may show, and with what distance.
/// The toast claims "Nearest plane is X km out" — so it must only appear
/// when that is literally TRUE of the whole in-data sky: no airborne plane
/// anywhere (any direction, not just the tap cone) is within plausible
/// reveal reach. When one is, the honest response to a far-only tap
/// direction is the plain empty ripple — asserting "nearest is 52 km"
/// while a 6 km plane sits in the data (and usually in the debug list the
/// user is cross-checking) reads as a bug, because it is one.
///
/// Returns the DISTANCE-nearest airborne slant (what "nearest" means to a
/// reader), never the angular winner's — or nil when the toast must not
/// show. `airborne` is the non-grounded in-data set.
func farTapToastSlantMeters(
    airborne: [(slantMeters: Double, plausiblyRevealable: Bool)]
) -> Double? {
    guard !airborne.contains(where: \.plausiblyRevealable) else { return nil }
    return airborne.map(\.slantMeters).min()
}

/// Whether an empty-sky tap should REVEAL its nearest in-data plane — pin +
/// force-lock so it labels and becomes catchable, the explicit-intent escape
/// hatch the ambient filter/frame lacks. Two `classifyEmptySkyTapNearest`
/// reasons qualify:
///   - "filtered"  → airborne but hidden by the precision band (FDX1268).
///   - "off-frame" → a visible-tier plane projected outside the frame, usually
///                   because a compass/heading error (or high zoom) rotated the
///                   sky-model off where the plane visually sits (DAL972,
///                   2026-07-11). The user is pointed at it; the tap grabs it.
/// "grounded" is handled earlier (a parked plane is never revealed);
/// "filtered-far" gets the beyond-eyeshot hint (a hidden plane past plausible
/// reveal reach must NOT become catchable — the NYC couch session caught a
/// Piper 75.8 km away through a wall); "grounded-far", "on-screen" and
/// "nothing-nearby" fall through to the empty-tap ripple.
func shouldTapReveal(reason: String) -> Bool {
    reason == "filtered" || reason == "off-frame"
}

// MARK: - AR-overlay rarity resolution

/// Resolves the rarity tier for a live AR-overlay label, matching the
/// single-source precedence of `Catch.resolvedRarity`:
///
///   1. Typecode → `AircraftNaming.rarity(forTypecode:)` from the
///      activity-based AircraftTypes.json table. This matches the
///      post-catch tier so the HUD and the Hangar agree.
///   2. No typecode → a single conservative default (`.common`).
///
/// SINGLE-SOURCE RULE: rarity comes only from the typecode table. The
/// string classifier (still the no-typecode TYPE source) no longer supplies
/// a rarity — its curated ladder diverged from the activity model, so the
/// no-typecode path is a flat `.common`, not a second tier ladder. The
/// `manufacturer`/`model`/`operatorName` params are retained on the
/// signature for the stable test/caller API even though rarity no longer
/// reads them.
///
/// Extracted as a free function so it can be unit-tested without
/// instantiating a SwiftUI view (divergence-a fix, 2026-06-11).
nonisolated func resolveAROverlayRarity(
    typecode: String?,
    manufacturer: String?,
    model: String?,
    operatorName: String?
) -> Rarity {
    AircraftNaming.rarity(forTypecode: typecode) ?? .common
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
    /// Label states under frame-is-the-catch (D3·2):
    ///   `chosen` — in the press: full-bright brackets, expanded label
    ///              with points. What you see full-bright is exactly
    ///              what the capture button catches.
    ///   `quiet`  — bright-tier but past the `maxCatchTargets` cap.
    ///              Only ever exists on a >3-bright frame; steps down so
    ///              the ×N badge always equals the full-bright count.
    ///   `faint`  — beyond-confidence tier (2026-06-12 doctrine): in the
    ///              data, not in the press. Tap to promote.
    ///   `pinned` — LEGACY catch mode only: the tap-pinned plane, at the
    ///              shipped weight (larger than `chosen`: 140 pt box,
    ///              3.5 pt strokes) with the expanded points label.
    enum Style: Equatable { case chosen, quiet, faint, pinned }

    let aircraft: ObservedAircraft
    let position: CGPoint
    let style: Style
    /// Cached metadata for this plane, if available. Drives the
    /// rarity classification — without metadata the classifier
    /// falls back to (.common, .narrow).
    let metadata: AircraftMetadata?

    var body: some View {
        let rarity = resolveAROverlayRarity(
            typecode: metadata?.typecode,
            manufacturer: metadata?.manufacturerName,
            model: metadata?.model,
            operatorName: metadata?.operatorName
        )
        let callsign = aircraft.aircraft.callsign?
            .trimmingCharacters(in: .whitespaces)
            .nonEmpty
            ?? aircraft.aircraft.icao24.uppercased()
        let isChosen = style == .chosen || style == .pinned
        let bracketBoxSize: CGFloat = style == .pinned ? 140 : (isChosen ? 110 : 96)
        // Wider cyan strokes so the blue reads as the focus. The dark
        // halo in `LockBrackets` is drawn at `lineWidth + 2 * haloWidth`,
        // so a ~1.5 px black outline still rings the thicker blue and
        // keeps the bracket legible against a bright sky.
        let bracketLineWidth: CGFloat = style == .pinned ? 3.5 : (isChosen ? 3 : 2.0)
        let bracketOpacity: Double = isChosen ? 1.0 : 0.55
        // Dim applies to FOREGROUND strokes/text only — never to the pill's
        // dark scrim or the brackets' halo. A whole-view .opacity multiplied
        // the 0.55 scrim down to ~0.19, leaving dimmed 8–9 pt cyan text
        // nearly scrim-less over a bright sky (and defeated the halo's
        // "held at full opacity" design).
        let dimFactor: Double = style == .faint ? 0.35 : 1.0

        VStack(spacing: 2) {
            LockBrackets(
                boxSize: bracketBoxSize,
                color: Brand.Color.cyan,
                opacity: bracketOpacity * dimFactor,
                lineWidth: bracketLineWidth
            )
            HStack(spacing: 4) {
                Text(callsign)
                    .font(Brand.Font.mono(size: isChosen ? 11 : 9, weight: .bold))
                    .foregroundStyle(Brand.Color.cyan)
                if isChosen {
                    Text("· \(rarity.label) +\(rarity.basePoints)")
                        .font(Brand.Font.mono(size: 9, weight: .semibold))
                        .foregroundStyle(rarity.tint)
                } else {
                    Text("· \(rarity.label)")
                        .font(Brand.Font.mono(size: 8, weight: .semibold))
                        .foregroundStyle(rarity.tint)
                }
            }
            // Opacity BEFORE the background so only the text fades; the
            // scrim drawn behind it stays at its full 0.55.
            .opacity(dimFactor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Brand.Color.bgPrimary.opacity(0.55),
                        in: .rect(cornerRadius: 4))
        }
        .position(position)
        .allowsHitTesting(false)
    }
}

/// The plane label's VoiceOver semantics, one modifier for both catch
/// modes so the label's modifier chain stays the same length either
/// way (ContentView.body is at the type-check budget).
///   - frame mode (`legacyPinToggle == nil`): D7 — activation carries no
///     behavior; a chosen plane says "In capture." in its value.
///   - legacy mode: the label is a (selected) button whose action toggles
///     the pin, exactly as shipped.
private struct PlaneLabelAccessibility: ViewModifier {
    let style: PlaneLabel.Style
    let legacyPinToggle: (() -> Void)?

    func body(content: Content) -> some View {
        if let legacyPinToggle {
            let isPinned = style == .pinned
            content
                .accessibilityAddTraits(isPinned ? [.isButton, .isSelected] : .isButton)
                .accessibilityHint(isPinned ? "Unpins this plane."
                                            : "Pins this plane for capture.")
                .accessibilityAction { legacyPinToggle() }
        } else {
            content
                .accessibilityValue(style == .chosen ? "In capture." : "")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Lock-on bracket shapes

/// Four L-shaped corner brackets around a center point, sized to
/// boxSize. Drawn as four separate strokes so the arms have round
/// caps and don't render a closed-rectangle look.
/// Internal (not private): `OnboardingFlow`'s welcome-step AR mock renders
/// the REAL bracket so the first thing a new user sees matches the HUD
/// (2026-07-20 onboarding feedback).
struct LockBrackets: View {
    let boxSize: CGFloat
    let color: Color
    let opacity: Double
    var armLength: CGFloat { max(8, boxSize * 0.22) }
    var lineWidth: CGFloat = 2
    /// Dark outline drawn behind the colored strokes so the brackets stay
    /// legible against a bright sky. Held at full opacity even when `opacity`
    /// fades the colored strokes, so a faint bracket keeps a crisp dark edge.
    var haloColor: Color = Brand.Color.hudBracketHalo
    var haloWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            // Halo: wider dark under-stroke, full opacity.
            corners(stroke: haloColor, width: lineWidth + 2 * haloWidth)
            // Colored brackets: faded by `opacity`; the halo behind stays crisp.
            corners(stroke: color, width: lineWidth)
                .opacity(opacity)
        }
        .frame(width: boxSize, height: boxSize)
    }

    /// The four L-shaped corner brackets stroked in one color + width.
    /// Factored out so the halo pass and the colored pass share one definition.
    private func corners(stroke: Color, width: CGFloat) -> some View {
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        return ZStack {
            CornerBracket(armLength: armLength, corner: .topLeft).stroke(stroke, style: style)
            CornerBracket(armLength: armLength, corner: .topRight).stroke(stroke, style: style)
            CornerBracket(armLength: armLength, corner: .bottomLeft).stroke(stroke, style: style)
            CornerBracket(armLength: armLength, corner: .bottomRight).stroke(stroke, style: style)
        }
    }
}

enum BracketCorner { case topLeft, topRight, bottomLeft, bottomRight }

struct CornerBracket: Shape {
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
/// liveness signal contradicting the message. Reduce Motion: a
/// steady full-opacity dot, no TimelineView ticking.
private struct EmptyPulse: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0/30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                // Cosine breathing: 0.4 → 1.0 → 0.4 once per ~1.4 s.
                let phase = (cos(t * 4.5) + 1) / 2     // 0…1
                content.opacity(0.4 + 0.6 * phase)
            }
        } else {
            content
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            // Reduce Motion: no expanding ring — a static ring + caption
            // at the tap point; the parent's 1 s auto-clear still removes it.
            ZStack {
                Circle()
                    .stroke(Brand.Color.cyan.opacity(0.7), lineWidth: 1.5)
                    .frame(width: 44, height: 44)
                Text("NO AIRCRAFT HERE")
                    .font(Brand.Font.mono(size: 9, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Brand.Color.cyan.opacity(0.9))
                    .padding(.top, 60)
            }
            .position(at)
        } else {
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
                            .font(Brand.Font.mono(size: 9, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Brand.Color.cyan.opacity(1.0 - progress))
                            .padding(.top, 60)
                    }
                }
                .position(at)
            }
        }
    }
}

/// The catch feedback surface, bundled: the pipeline-end success haptic,
/// the tap-time impact haptic, and the capture shutter flash. One
/// `.modifier` call instead of three chain links because `ContentView.body`
/// is a single expression sitting at the compiler's type-check budget —
/// growing the chain there times out the build (2026-08-13).
private struct CaptureFeedback: ViewModifier {
    let catchHaptic: Int
    let tapHaptic: Int
    let flash: Bool

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: catchHaptic)
            .sensoryFeedback(.impact(weight: .medium), trigger: tapHaptic)
            .overlay {
                Rectangle()
                    .fill(.white)
                    .opacity(flash ? 0.5 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - Top toast kinds

/// The transient top-capsule toasts `ContentView` can show — one at a time,
/// through the shared `topToast` slot. Keeping them in one type is what
/// makes "only one visible" a property of the design rather than a thing
/// three independent overlays have to remember.
nonisolated enum TopToast: Equatable {
    /// Parked-plane easter egg: the tapped plane is on the ground.
    case grounded
    /// Beyond-eyeshot empty-sky tap, with the nearest slant distance.
    case farTap(slantMeters: Double)
    /// The post-catch `save()` threw — data loss.
    case saveFail
    /// A streak-reminder tap landed; the line names the streak at stake.
    case streak(line: String)

    var message: String {
        switch self {
        case .grounded:
            return "Tailspot only works with planes in the air"
        case .farTap(let slantMeters):
            return "Nearest plane is \(Int((slantMeters / 1000).rounded())) km out — beyond eyeshot"
        case .saveFail:
            return "That catch didn't save — try again."
        case .streak(let line):
            return line
        }
    }
}

extension TopToast {
    @MainActor
    var borderColor: Color {
        switch self {
        case .grounded, .farTap: return Brand.Color.alertCaution.opacity(0.45)
        case .saveFail:          return Brand.Color.alertWarning.opacity(0.55)
        case .streak:            return Brand.Color.alertCaution.opacity(0.5)
        }
    }
}

#Preview {
    ContentView()
}
