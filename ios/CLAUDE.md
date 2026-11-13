# iOS conventions & load-bearing gotchas

<!-- Loads whenever Claude works with files under ios/. Repo-wide process
(shipping, versioning, secrets, orientation) stays in the root CLAUDE.md.
Keep each bullet to the rule and a short reason; the field incidents behind
them (DAL972, WGN211, ASA1374, the Dumbarton drive, the Bay Bridge case) are
told in code comments at the functions they shaped. -->

The traps that cause real bugs. For subsystem internals (replay recorder/analyzer,
Hangar grouping, catch membership, metadata cache, camera zoom/tap-to-assert),
read the source and each one's focused test file.

- **MainActor default isolation (Xcode 26).** `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`: every type/extension/global is implicitly `@MainActor` unless marked
  `nonisolated`. UI/state-holding types stay MainActor (`LocationManager`,
  `MotionManager`, `ADSBManager`, views); pure data/geometry/Sendable types are
  explicitly `nonisolated` (`Aircraft`, `ADSBSource`, `ADSBSourceError`,
  `TailspotBackendClient`, `Geo`). Extensions don't inherit the host's isolation
  (`nonisolated extension Aircraft: Decodable`). The warning *"main actor-isolated
  conformance … cannot be used in nonisolated context"* almost always means a
  missing `nonisolated` on an extension.
- **One ADS-B source, injectable.** `ADSBManager.init(source:)` takes a single
  `ADSBSource`; the protocol exists so tests substitute a fixture and a future
  provider can drop in. There is no runtime source toggle. If the backend is
  unreachable the app shows an error / empty sky rather than degrading, on
  purpose.
- **Split fetch from annotation.** `ADSBManager` runs two loops: `pollTask` (every
  ~10 s, matching the backend tile cache's TTL; `/v1/aircraft` has no rate limit)
  and `reAnnotationTask` (every ~1 s, forward-extrapolates each plane via
  `Aircraft.extrapolatedPosition(at:)` and recomputes bearing/elevation/distance
  from the current pose). That is what makes reticles glide between fetches;
  keep them decoupled.
- **Pitch vs. camera elevation.** `CMAttitude.pitch ≈ +π/2` when the phone is held
  upright in portrait. Camera elevation above the horizon = `90° − pitch`, wrapped
  in `MotionManager.cameraElevationDeg`. Never pass raw `motion.pitch` into
  projection math; the projection helpers take `cameraElevationDeg`.
- **Portrait-only AND iPhone-only.** `Info.plist`
  `UISupportedInterfaceOrientations` is Portrait-only, and the target is
  `TARGETED_DEVICE_FAMILY = 1`. A portrait-only build that also targets iPad
  fails App Store Connect validation (iPad multitasking demands all orientations
  or full-screen), and only Xcode Cloud's upload step catches it, not unit-test
  CI. `UIRequiresFullScreen` is ignored on the 26.2 floor, so don't reach for it.
  `LocationManager.headingOrientation` is also pinned to `.portrait` for a stable
  true-north reference. The identify math assumes an upright portrait hold:
  don't add landscape UI, don't re-add iPad, and don't remove either pin.
- **Visibility filter.** `ObservedAircraft.isLikelyVisibleToObserver` gates both
  the AR overlay and the on-screen list: above the horizon and within an
  elevation-dependent distance band (a near→full→contrail curve, field data in
  `ADSBManager.swift`). A "missing plane label" report is usually the filter
  doing its job; check below-horizon / too-far first. Visible-but-filtered planes
  are reachable by tapping: `shouldTapReveal` asserts the diagnosed plane for
  reasons `filtered`, `off-frame` (usually a compass error) and
  `filtered-precise` (past reveal reach but within
  `precisionTapRevealMaxOffsetDeg` of the tap; airborne and above the horizon
  only), and a tap on a FAINT-tier label promotes it. In `CatchMode.legacy` the
  same reasons pin + force-lock instead. Asserted planes label bright, get a
  press slot, skip the occlusion demote, and expire via the 1 Hz prune. `grounded`
  never asserts; the parked-plane toast fires only within
  `groundedToastMaxSlantMeters`, and beyond that `grounded-far` is rescued like
  `filtered-far`. The tap's subject is not simply the angular-nearest plane: see
  `chooseEmptySkyTapSubject` / `farTapToastSlantMeters`. **Don't loosen the
  ambient filter to chase one missed plane**; it brings back the MLAT clutter
  (the `FieldReplays` tests pin this).
- **Frame is the catch (behind the flag below).** Press membership is
  `chooseCatchMembers` (`CatchMembership.swift`): bright (`.full`) tier on frame,
  occlusion-demoted via the live sky grid, asserted planes guaranteed,
  arcmin-ranked, capped at `maxCatchTargets` (3). Three invariants: **bright = in
  the press** (never render a non-member full-bright), **membership freezes at
  the shutter** (catch-time vision snaps brackets and feeds gates but never edits
  the caught set), and **there is no selection** (no zones, pins or dominance;
  don't add a "pick this plane" affordance without reopening
  `docs/plans/2026-08-28-feat-frame-is-the-catch.md`). The detector runs at catch
  time only; `VisualConfirmationPipeline.updateTarget` is the kept-but-unarmed
  live-tracking upgrade path.
<!-- TEMPORARY: the next bullet describes the live frame-is-the-catch A/B
(50/50 since 2026-11-09). Once the rule is decided, delete the losing side
together with CatchMode.swift, then delete that bullet and drop the
"behind the flag" / legacy mentions above. -->
- **Catch-rule feature flag (PostHog `frame-is-the-catch`).** `CatchMode.swift`:
  `.frame` (the model above) vs `.legacy` (the zones-and-pins model in
  `LockOnEngine.swift` and its zone/dominance helpers). Default is `.legacy`: the
  flag is off for anyone it doesn't target. Resolution is one funnel,
  `CatchMode.effective`: a Debug-only wrench override (`tailspot.debug.catchMode`;
  Release never reads it) beats the PostHog value; flag off / not loaded /
  keyless analytics → `.legacy`. `CatchModeFlag` applies the PostHog value only at
  session boundaries (cold launch and each return from the background, not
  inactive→active, which a Control Center pull triggers mid-aim).
  `reconcileCatchMode` clears the outgoing mode's pins/assertions, and `runCatch`
  snapshots the mode at the press so one catch never mixes rules. Both modes
  branch at one render funnel (`resolveFrameSelection` → `FrameSelection`) plus
  the tap handler, Gate 5 and the diagnostics selector; `catch_performed` /
  `catch_pipeline_timing` carry `catch_mode`. The frame invariants above hold
  for `.frame` only. Keep the flag key stable: renaming it silently turns the
  new rule off for everyone targeted.
- **The catch pipeline reads the shutter-press snapshot, never live sensors.**
  `runCatch` snapshots pose + observations (`press*`) before its first await, and
  everything downstream uses the snapshot. The shutter can lag the press by
  seconds, and a live sensor read then captures the phone being lowered.
  Press→exposure hand drift is the detector snap's job.
- **Sensor concurrency.** Sensor wrappers are `ObservableObject` classes owned via
  `@StateObject`. All `@Published` mutations happen on the main thread:
  background callbacks (CMMotion/AVCapture queues, URLSession) hop
  `DispatchQueue.main.async` first; `ADSBManager` uses `@MainActor` instead. A
  model file using `@Published`/`ObservableObject` without `import SwiftUI` must
  `import Combine`. `AVCaptureSession` config + `startRunning` run on a dedicated
  serial queue, never main. **`MotionManager` does not publish**: a 30 Hz
  `@Published` re-ran ContentView's whole body. Anything that must track motion
  live goes inside a `TimelineView`; one-shot reads just read it.
- **Never detach the preview layer's session.** `previewLayer.session = nil`
  while a sheet covers the camera makes that sheet's buttons need two taps;
  `PreviewView.setSessionActive` hides the view instead. If a sheet button
  "needs two taps", suspect presenter-side layer work, not the button.
- **Design system.** The app is locked to dark (`preferredColorScheme(.dark)`
  at the root; light mode is dead, though existing per-view light-mode
  compensations stay). Corner radii snap to `Brand.Radius` (chip 6 / row 12 /
  card 16 / hero 26; computed radii, per-size tables, tiny 3–4 pt badge accents
  and the AR HUD brackets stay literal). Type rule: mono = instruments and data
  (readouts, labels, ALT/SPD/ENTRY #); system = anything that talks to the user,
  even when it carries a number ("11 day streak", not `DAY 11 STREAK`), and that
  includes buttons; prose heads use exactly `.brandDisplayFont()`. Don't
  freelance `.system(size: 24…30)` heads. Dynamic Type: Brand system tokens ride
  the built-in text styles and `Brand.Font.mono(…, relativeTo:)` anchors mono in
  scrollable surfaces; AR HUD readouts and card artboards stay fixed by choice
  (except `HUDStatusPill`, which scales and wraps), and don't add a bare
  `.system(size:)` to a prose surface. Chrome: custom chrome for game surfaces
  (Hangar/cards/reveals), stock-but-branded system nav for utility screens
  (Settings/Map/Leaderboard); two idioms is the design. Exit rule: putting a
  screen away is an X in the outermost top-right slot; going back one level is a
  chevron top-left. Custom chrome uses `ChromeButton(.close | .back)` (44 pt
  drawn disc); system toolbars use `Button(role: .close)`; forms keep "Cancel".
  No "Done" and no small/grey exits (unreadable outdoors). Voice is dry: no
  emoji in shipped copy, and an unclaimed profile shows a designed CLAIM state,
  never a placeholder handle. Settled by Noah, don't re-propose: Profile keeps
  its Liquid Glass, and a catch keeps its double `.success` haptic (capture +
  reveal).
- **Wrench (debug) panel speaks plain language.** It's Noah's field tool. Each
  flag is a real `Toggle` via `debugFlagRow`: a title named by effect ("Building/tree
  check", "Plane-in-photo check", "New catch rule") plus one "On: … Off: …"
  sentence, one look for every row, no hint text. Never show internal names
  (L2/L4, enforce/shadow, membership, rearm) on screen; telemetry keeps them.
  GPS/ADS-B readouts stay one line each.
- **Logging through `Log.swift`, never `print(...)`.** `os.Logger` instances by
  category (`adsb`, `location`, `motion`, `ui`, `analytics`, `metrics`);
  subsystem `com.landesberg.tailspot`. Use `privacy: .public` on interpolations
  you want to read (Apple redacts by default). `print` won't appear in the
  deploy-loop logs.
- **Analytics is one pipeline: the PostHog SDK.** `Analytics.swift` is a thin
  facade over `PostHogSDK.shared` behind the `AnalyticsSink` seam (tests inject a
  fake via `Analytics._testSink`); `PostHogSessionReplay.swift` owns one-time SDK
  setup and the launch self-heal identify. **Identity rule:** never swap the
  distinct_id under the SDK. The SDK owns the anonymous id from first launch;
  `TailspotAccountClient.ensureRegistered` calls
  `Analytics.identify(serverDeviceId)` exactly once and PostHog aliases the
  earlier anonymous activity, so the analytics person equals the backend device
  id. `DeviceID` is the backend id only; don't add a second analytics id or a
  REST capture path (that split one device into several persons). posthog-ios
  gotcha: `identify()` is a silent no-op (including `$set`) when the SDK is
  already identified under a different distinct_id; the sink routes around it
  via `AnalyticsIdentity.identifyRoute`. Never "fix" a pinned device with
  `reset()`/re-identify.
- **`ADSBSourceError`** (in `ADSBSource.swift`) is the source-neutral
  transport-error enum (`badURL`/`http(status:)`/`rateLimited`/`decoding`). Only
  the `/v1/aircraft` poll raises the status pill (`lastError` /
  `lastErrorUserMessage`), and only after a grace period: 30 s with fresh data,
  8 s cold/stale (`ADSBManager.surfaceDelay`; `isReconnecting` covers the quiet
  window). Metadata failures never raise it: they're logged, not cached, and
  retried (a 429 from `GET /v1/metadata/:icao24`, capped at 300/min/IP, logs at
  info). Cancellation is never an error (`ErrorCopy.isCancellation`):
  `.task(id:)` re-keys and `stop()` cancel in-flight requests as
  `URLError.cancelled`. `ErrorCopy` buckets: offline / weak connection (timeout,
  DNS) / unreachable.
- **`Catch` is a flat SwiftData `@Model`**; duplicate icao24 rows are allowed
  (dedupe is a Hangar concern). `captureDiagnosticsJSON` is load-bearing:
  `CatchUploader` reads the press-time pose (heading / camera elevation / heading
  accuracy) and the caught plane's ADS-B fix out of it and sends them on
  `POST /v1/catches`, the only thing the backend validator can correlate (no
  pose → verdict "unverifiable"). Adding fields to `CatchCaptureDiagnostics`
  stays JSON-only and additive (no SwiftData migration), and old blobs must keep
  decoding (absent key → nil). `CatchDetailView` is a frozen-moment view: it may
  backfill nil-only airframe fields (registration, typecode, manufacturer,
  model, placeName, operator) but never overwrites recorded values or backfills
  moment data. Deliberate exceptions: `Catch.resolvedRarity` re-derives live
  (re-tiering corrects old catches on read); a fully-nil route heals via
  `CatchBackfill`'s per-callsign `GET /v1/routes` lookup, which sends a position
  so the server can pick the right leg of a multi-leg filing and reject a stale
  one (a one-sided as-observed route is moment data and is never touched); and a
  stored route whose corridor is nowhere near the catch is cleared by
  `CatchBackfill.clearImplausibleRoutes` back into the fill pool.
- **Permission strings** (`NSCameraUsageDescription`,
  `NSLocationWhenInUseUsageDescription`) live in the target's Info tab in Xcode,
  not in any tracked file. Adding one is a manual Xcode step Claude can't do;
  flag it when needed.
- **Synchronized folders:** any `*.swift` dropped into `ios/Tailspot/Tailspot/`
  is added to the project automatically; no "Add Files" step.
