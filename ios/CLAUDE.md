# iOS conventions & load-bearing gotchas

Loaded automatically whenever Claude works with files under `ios/`. Repo-wide
process — the four rings, release/versioning rules, secrets hygiene, and the
orientation pointers to `STRATEGY.md` / `PLAN.md` / `CHANGELOG.md` — stays in the
root `CLAUDE.md`.


The traps that cause real bugs. For subsystem internals (replay recorder/analyzer,
Hangar grouping, catch membership, metadata cache, camera zoom/tap-to-assert), read
the source + each one's focused test file — they're not restated here.

- **MainActor default isolation (Xcode 26).** `SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor` — every type/extension/global is implicitly `@MainActor` unless marked
  `nonisolated`. UI/state-holding types stay MainActor (`LocationManager`,
  `MotionManager`, `ADSBManager`, views); pure data/geometry/Sendable types are
  explicitly `nonisolated` (`Aircraft`, `ADSBSource`, `ADSBSourceError`,
  `TailspotBackendClient`, `Geo`). **Extensions don't inherit the host's isolation**
  — `nonisolated extension Aircraft: Decodable`. The warning *"main actor-isolated
  conformance … cannot be used in nonisolated context"* almost always means a
  missing `nonisolated` on an extension.
- **One ADS-B source, injectable.** `ADSBManager.init(source:)` takes a single
  `ADSBSource`; the protocol seam exists only so tests substitute a fixture and a
  future provider can drop in — there is **no runtime source toggle** (the
  LIVE/MOCK/OpenSky cycle was removed; the debug row is a static `[TAILSPOT API]`
  indicator). If the backend is unreachable the app shows an error / empty sky
  rather than degrading — intended, for debugging clarity.
- **Split fetch from annotation.** `ADSBManager` runs two loops: `pollTask` (every
  ~10 s, matching the backend tile cache's TTL — `/v1/aircraft` has no rate limit)
  and `reAnnotationTask` (every ~1 s, forward-extrapolates each plane via
  `Aircraft.extrapolatedPosition(at:)` and recomputes bearing/elevation/distance
  from the current observer pose). This is what makes reticles glide between
  fetches — keep them decoupled.
- **Pitch vs. camera elevation.** `CMAttitude.pitch ≈ +π/2` when the phone is held
  upright in portrait. Camera elevation above the horizon = `90° − pitch`, wrapped
  in `MotionManager.cameraElevationDeg`. **Never pass raw `motion.pitch` into
  projection math** — the projection helpers take `cameraElevationDeg`.
- **The app is locked to portrait AND iPhone-only.** `Info.plist`
  `UISupportedInterfaceOrientations` is **Portrait-only** — that list is what pins the
  UI. The target is **`TARGETED_DEVICE_FAMILY = 1` (iPhone-only)**, set 2026-06-28.
  **Why iPhone-only, not just portrait:** a portrait-only build that *also* targets iPad
  (`"1,2"`) without `UIRequiresFullScreen=YES` builds + runs on a device fine but **fails
  App Store Connect validation** — it shows up only at the Xcode Cloud "Preparing build
  for App Store Connect" step (the iPad multitasking rule demands all orientations or
  full-screen), and GitHub Actions unit-test CI never catches it. iPhone-only sidesteps
  the rule; `UIRequiresFullScreen` is deprecated/ignored on the 26.2 floor anyway, so
  don't reach for it. On top of this, **`LocationManager.headingOrientation` is pinned
  to `.portrait`** as a belt-and-suspenders stable true-north reference. The identify
  math (heading + `90° − pitch` elevation) assumes an upright portrait hold — don't add
  landscape UI, don't re-add iPad (family `2`), and don't remove either pin.
- **Visibility filter.** `ObservedAircraft.isLikelyVisibleToObserver` gates **both**
  the AR overlay and the on-screen list: above the horizon and within an
  **elevation-dependent distance band** (a near→full→contrail curve — see the field
  data in `ADSBManager.swift`, not a single km cap). A reported "missing plane
  label" is usually the filter doing its job — check below-horizon / too-far first.
  Genuinely-visible-but-filtered planes are reachable via **tap-assert**
  (`assertedPlanes`: a tap asserts the diagnosed plane when `shouldTapReveal`
  says so — reason `filtered` (hidden by the band) **or** `off-frame` (a
  visible-tier plane projected off-screen, usually a compass/heading error;
  DAL972, 2026-07-11); a tap on a FAINT-tier label promotes it the same way.
  Asserted planes label bright, are guaranteed a press slot, skip the occlusion
  demote, and expire via the 1 Hz prune (on frame + 15 s grace). `grounded`
  never asserts, and the parked-plane toast only fires when the parked plane is
  within `groundedToastMaxSlantMeters` (1 km) — beyond that it classifies
  `grounded-far` and is rescued like `filtered-far` (parked OAK freighters on
  the horizon beat the visible plane on angle; the Bay Bridge case,
  2026-08-26)). The tap's subject is NOT simply the angular-nearest in-data
  plane: a `filtered-far`/`grounded-far` winner is rescued by the nearest
  actionable plane in the cone, and the beyond-eyeshot toast only shows when
  nothing in data is within reveal reach — quoting the distance-nearest slant
  (`chooseEmptySkyTapSubject` / `farTapToastSlantMeters`; the Dumbarton drive,
  2026-07-20 — a car-corrupted compass let a 50 km stranger beat the visible
  arrival on angle). **Don't loosen the ambient filter to chase one** — it
  resurfaces the MLAT clutter the precision lean kills (see the `FieldReplays`
  regression).
- **Frame is the catch (2026-08-28).** Press membership is `chooseCatchMembers`
  (`CatchMembership.swift`): bright (`.full`) tier on frame, occlusion-demoted
  via the live sky grid, asserted planes guaranteed, arcmin-ranked, capped at
  `maxCatchTargets` (3). Three load-bearing invariants: **bright = in the
  press** (the label hierarchy IS the catch promise — never render a
  non-member full-bright), **membership freezes at the shutter** (catch-time
  vision snaps brackets and feeds gates but never edits the caught set), and
  **there is no selection** — no zones, pins, or dominance; don't add a
  "pick this plane" affordance back without reopening the decision record
  (`docs/plans/2026-08-28-feat-frame-is-the-catch.md`). The detector runs at
  catch time only; `VisualConfirmationPipeline.updateTarget` is the kept-but-
  unarmed live-tracking upgrade path.
- **Catch-mode A/B switch (2026-09-02, Ring 0 only).** `CatchMode.swift`:
  `.frame` (the model above) vs `.legacy` (the shipped v1.1.x zones-and-pins
  model — `LockOnEngine.swift` + its zone/dominance helpers, restored for the
  comparison). UserDefaults-backed (`tailspot.debug.catchMode`), **honored
  only in DEBUG builds** — `CatchMode.effective` is `.frame` on Release, so a
  flipped phone can't leak the legacy model into TestFlight. The wrench-panel
  `catchModeRow` is the only writer (`setCatchMode` clears the other mode's
  state); a LEGACY CATCH MODE badge sits under the zoom pill while it's on.
  Both modes branch at ONE render funnel (`resolveFrameSelection` →
  `FrameSelection`) plus the tap handler, Gate 5, and the diagnostics
  selector; `catch_performed` / `catch_pipeline_timing` carry `catch_mode`.
  The legacy invariants above ("no selection", "bright = in the press") hold
  for `.frame` only — legacy renders pinned/dimmed, no chosen highlight.
  Delete `LockOnEngine.swift`, `CatchMode.swift` and the legacy tests once
  the comparison is decided.
- **The catch pipeline reads the shutter-press snapshot, never live sensors.**
  `runCatch` snapshots pose + observations (`press*`) before its first await;
  everything downstream — bracket projection, capture diagnostics — uses the
  snapshot. The shutter can lag the press by seconds (Debug builds especially),
  and a "current" sensor read then captures the phone being LOWERED: diagnostics
  recorded a −21.7° elevation, 41.5°-off catch of a dead-centered plane
  (ASA1374, 2026-08-26). Press→exposure hand drift is the detector snap's job.
- **Sensor concurrency.** Sensor wrappers are `ObservableObject` classes owned via
  `@StateObject`. All `@Published` mutations on the main thread — background
  callbacks (CMMotion/AVCapture queues, URLSession) hop `DispatchQueue.main.async`
  first; `ADSBManager` uses `@MainActor` instead. A model file using
  `@Published`/`ObservableObject` without `import SwiftUI` must `import Combine`.
  Camera `AVCaptureSession` config + `startRunning` run on a dedicated serial
  queue, never main.
- **Design system (2026-07-10 polish decisions).** The app is **locked to dark**
  (`preferredColorScheme(.dark)` at the root — keep the per-view light-mode
  compensations as belt-and-suspenders, but light mode is dead). Corner radii snap
  to **`Brand.Radius`** (chip 6 / row 12 / card 16 / hero 26; computed radii,
  per-size dims tables, tiny 3–4 pt badge accents, and the AR HUD brackets stay
  literal). Type rule: **mono = readouts/data/labels; system = human prose; prose
  heads use exactly `.brandDisplayFont()`** (the 26 pt head became a ViewModifier
  in the 2026-07-12 HIG pass so it scales via `@ScaledMetric`) — don't freelance
  `.system(size: 24…30)` heads. **Dynamic Type:** Brand system tokens ride the
  built-in text styles and `Brand.Font.mono(…, relativeTo:)` anchors mono in
  scrollable surfaces; AR HUD readouts + card artboards stay fixed BY CHOICE —
  don't "fix" them, and don't add a bare `.system(size:)` to a prose surface. Chrome rule: custom chrome for game surfaces (Hangar/cards/reveals),
  stock-but-branded system nav for utility screens (Settings/Map/Leaderboard).
- **Logging through `Log.swift`, never `print(...)`.** `os.Logger` instances by
  category (`adsb`, `location`, `motion`, `ui`, `analytics`, `metrics`); subsystem
  `com.landesberg.tailspot`. Use
  `privacy: .public` on interpolations you actually want to read (Apple redacts by
  default). `print` won't appear in the deploy-loop logs.
- **Analytics is ONE pipeline: the PostHog SDK.** `Analytics.swift` is a thin
  facade over `PostHogSDK.shared` behind the `AnalyticsSink` seam (tests inject a
  fake via `Analytics._testSink`); `PostHogSessionReplay.swift` owns one-time SDK
  setup + the launch self-heal identify. **Identity rule (load-bearing — this was
  a real bug):** never swap the distinct_id under the SDK. The SDK owns the
  anonymous id from first launch; `TailspotAccountClient.ensureRegistered` calls
  `Analytics.identify(serverDeviceId)` exactly once and PostHog aliases the prior
  anonymous activity in — so the analytics person == the backend device id
  (catches/leaderboard). `DeviceID` is the backend id only; don't reintroduce a
  second analytics id or a REST capture path (the dual pipeline fragmented one
  device into multiple persons — CHANGELOG 2026-06-27). **posthog-ios gotcha:**
  `identify()` is a SILENT no-op (handle `$set` included) when the SDK is already
  identified under a different distinct_id; the sink routes around it via
  `AnalyticsIdentity.identifyRoute` (`$set` on the pinned person) — never "fix"
  a pinned device with `reset()`/re-identify (CHANGELOG 2026-07-04).
- **`ADSBSourceError`** (in `ADSBSource.swift`) is the source-neutral
  transport-error enum (`badURL`/`http(status:)`/`decoding`); all errors surface
  uniformly via `lastError` (the OpenSky-era 429 backoff was removed —
  `/v1/aircraft` never rate-limits).
- **`Catch` is a flat SwiftData `@Model`**; duplicate icao24 rows are allowed
  (dedupe is a Hangar concern). `CatchDetailView` is a **frozen-moment** view that
  may backfill **nil-only airframe** fields (registration, typecode, manufacturer,
  model, placeName, operator) but never overwrites recorded values or backfills
  moment-data. Deliberate exceptions: `Catch.resolvedRarity` re-derives live (so
  re-tiering corrects old catches on read, no migration), a **fully-nil route**
  heals via `CatchBackfill`'s per-callsign `GET /v1/routes` lookup (2026-07-04 —
  current filing, best-effort like operatorName; since 2026-07-19 the lookup
  carries a position so the server can leg-pick a multi-leg filing and reject a
  stale one; a one-sided as-observed route is moment-data and is never touched),
  and an **implausible stored route** (its corridor nowhere near the catch —
  the first→last-collapse / stale-filing bugs, 2026-07-19) is cleared by
  `CatchBackfill.clearImplausibleRoutes` back into the fill pool.
- **Permission strings** (`NSCameraUsageDescription`,
  `NSLocationWhenInUseUsageDescription`) live in the target's **Info** tab in
  Xcode, not in any tracked source file. Adding one is a **manual Xcode step Claude
  can't do** — flag it explicitly when needed.
- **Xcode 16 synchronized folders:** any `*.swift` dropped into
  `ios/Tailspot/Tailspot/` is auto-added to the project — no "Add Files" step.
