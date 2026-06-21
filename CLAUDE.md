# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, design-canvas port ✅, TestFlight v0 shipping to internal testers ✅, backend next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

Only the **live** `Current state` block lives below; prior per-session rounds are in `CHANGELOG.md` (newest first). When you finish a round, move the previous `Current state` block to the top of `CHANGELOG.md` and write the new one here — don't stack them in this file.

## Current state (as of 2026-06-21 — two rounds: trophies/achievements overhaul shipped (#56); ADS-B source cutover (below))

**Trophies / achievements overhaul SHIPPED 2026-06-21 (PR #56).** The Trophies
tab is rebuilt around a real **unlock moment**: `TrophyUnlockView` is a
full-screen "NEW TROPHY" celebration (cyan hex, glow + rotating ray-burst,
haptic, Reduce-Motion + VoiceOver paths) driven by `TrophyUnlockCenter` +
`UserDefaultsTrophyLedger` — the ledger records which awards have been *shown*,
so a newly-earned one is detected as a transition and fired exactly once
(commit-on-shown, seeds silently on first run so existing testers aren't
flooded, one-time "trophy case" recap on update). Fires `trophy_unlocked` /
`trophy_recap_shown` via the PostHog REST pipeline (`Analytics.swift`). The
roster is now **binary** — every achievement earned-or-not, no bronze→platinum
metals, no medals/badges split, no stat header; earned hexes render in a
distinct **cyan** (off the rarity/legendary gold). Count families split into
**milestone chains** that reveal progressively via `Achievement.prerequisite`
(Centurion appears only after Catcher); two unearned states — **visible** (real
name + a quiet `62/100`) and **secret** (a locked `???` placeholder). ~56
achievements incl. a new reverse-geocoded `Catch.country` trophy (Mr.
Worldwide) and a big av-geek/everyday expansion; 31 custom hex icons reviewable
in a DEBUG `⚑ Icons` gallery. Pure `Trophies.swift` (diff/aggregation +
heuristic aircraft-tag classifier) and `TrophyBoard` filtering are unit-tested.
**Deferred:** scoring/points/rareness + medal-system rework (PLAN §9 #10);
Constellation/Quintet stay secret-dormant until multi-catch ships (§9 #5); the
catch-a-kind heuristic matcher wants real-world tuning as catches land.

---

**ADS-B source cutover — branch `fix/mock-mode-field-safety` (off `main`, not yet merged). Triggered
by a field session in Bali where a real Citilink flight (CTV9661) "failed to
capture" and was identified as a "United Airlines B737" that doesn't exist.**

- **Root cause (from the on-device replay `2026-06-21T02:14:32Z` + os_log):**
  the app was in **MOCK** mode. A single tap on the debug source-row flips
  Tailspot-API → MOCK, and once the wrench overlay is closed there was NO
  indication you were seeing synthetic planes. The "United 737" was the
  `MockADSBSource` `UAL248`/`a3b15e` fixture verbatim (`BOEING 737-800 /
  United Airlines`). The fake catch saved to the Hangar **and queued for
  upload to the real backend** (`CatchUploader` had no mock guard). On the
  live source the real CTV9661 was correctly ingested (`shown=1`) but sat at
  bearing ~222–256° while the phone pointed heading 76° — off-screen behind
  the user — hence "nothing spotted."

- **Fix (per Noah's call: remove both, don't patch around them):**
  - **Mock source removed entirely** — deleted `MockADSBSource.swift`, the
    `useMock` toggle, and the source-cycle UI. The replay harness
    (`ReplayRecorder`/`ReplayAnalyzer`) covers offline testing now.
  - **OpenSky removed entirely** — deleted `OpenSkyClient.swift` and the silent
    backend→OpenSky failover (it hid backend problems mid-session). The shared
    error enum moved to `ADSBSourceError` in `ADSBSource.swift`. `ADSBManager`
    now has a single injectable `source` (`init(source:)`), no `useBackend`.
    `CatchBackfill` uses the backend client for metadata.
  - **Credential apparatus removed** — no `OPENSKY_*` in `Tailspot.xcconfig`,
    `Info.plist`, the secrets template, or `ci_post_clone.sh`. The shipped
    binary now carries **no extractable API secret** beyond the optional
    PostHog analytics key, ending the credential-leak surface (two prior leaks
    were both OpenSky). The OpenSky secret can be deleted on its console once a
    build with this cutover reaches testers (no tester impact).

- **If the backend is unreachable now**, the app surfaces an error / empty sky
  (visible) instead of degrading to a sparser source — the intended trade for
  debugging clarity.

**Tests: full iOS suite green locally (`** TEST SUCCEEDED **`); app builds
clean (`** BUILD SUCCEEDED **`). Removed the obsolete mock-integration test +
the entire backend-toggle test suite; swapped `OpenSkyClient.ClientError` →
`ADSBSourceError` in fixtures.**

**Waiting on Noah / next:** field-test this branch (`bin/deploy`), then PR →
merge → TestFlight. **Delete the existing fake "United 737" catch** from the
Hangar (it predates the `isMock` tag, so it's untagged; it may have already
hit the backend — worth checking the backend hangar/leaderboard for icao
`a3b15e`). Then retire the OpenSky console credential. Still open from before:
PR #13 visual-confirm device eyeball; PostHog key (`POSTHOG_API_KEY`); legal +
privacy-policy hosting (PR #15); website redesign.

## Working model

- Solo developer (Noah) with no prior iOS experience. Claude writes code; Noah runs it on his iPhone 16 (iOS 26.3.1) and reports back.
- Field-test location: Berkeley/Oakland CA — under SFO/OAK approach corridors, dense ADS-B coverage. The backend source includes adsb.lol MLAT, so GA, helicopters, and some military traffic now appear (they were invisible under the old OpenSky free tier). Noah also field-tests while travelling (e.g. Bali) — don't assume a US location.
- Preference: **explain-as-we-go.** When introducing a Swift / SwiftUI / iOS pattern Noah hasn't seen, narrate it in the commit message or inline comments. He is learning iOS in parallel with shipping.
- Pick the simplest viable iOS choice at every fork: SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods/SPM deps yet.

## Build and run

Two paths:

- **Claude-driven (default):** `bin/deploy` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches on Noah's paired iPhone wirelessly. There is no CI on deploys; run the unit-test suite first when touching testable code (see Tests).
- **Manual (Noah's IDE workflow):** Xcode `⌘R` against the connected iPhone. Useful when you want Xcode's debugger / live `os_log` console.

The iOS Simulator cannot provide real GPS, compass, or camera, so the iPhone is required for any runtime / field testing.

### Remote-deploy loop

- `bin/deploy [--no-build] [--no-launch] [--dry-run]` — device UDID, scheme, and paths come from `tools/deploy/config.sh`; override locally via `tools/deploy/config.local.sh` (gitignored — the committed UDID is Noah's). Wireless dev pairing must already be active (confirm with `xcrun devicectl list devices`). `--launch` is implicit.
- `bin/log-tail [-n N] [-f]` — reads `~/Library/Logs/tailspot/device.log`. **Currently a no-op stub:** the host macOS `log` binary doesn't accept `--device <UDID>`, so `bin/log-start` exits 0 with a notice. Fix planned (PLAN.md §9 #3); until then, inspect runtime behavior via Xcode's Console or `os_log` viewer.

Failure modes that need Noah, not a retry:

- `xcrun devicectl install` fails (e.g. "developer disk image could not be mounted") → surface the message and stop. Usually: unlock the phone, re-pair via USB, or open Xcode once to mount the DDI.
- `devicectl process launch` returns a Locked error → the phone must be unlocked; ask Noah and retry the launch step.
- `xcodebuild` can't find the destination ("Unable to find a destination") → check `xcrun devicectl list devices`; state `unavailable` means USB re-pair or opening Xcode once to re-establish the handshake.

### Doc-staleness Stop hook

`.claude/settings.json` registers a `Stop` hook running `bin/doc-staleness-check` at the end of each turn: if unpushed commits exist on `main` and none touched `CLAUDE.md` or `PLAN.md`, it blocks the turn and asks for a doc refresh (`Current state` here, §9 in PLAN.md) before stopping — replace the live `Current state` block and move the old one to `CHANGELOG.md`. The point: a session can be cleared at any time and the next agent reads docs that match what's on disk. The script self-locates via `git rev-parse --show-toplevel`. `.claude/settings.json` is gitignored; to make the hook follow the repo to other machines, add `!.claude/settings.json` to `.gitignore` and commit.

## Secrets: PostHog key only (OpenSky removed 2026-06-21)

**The app no longer ships any ADS-B API secret.** The OpenSky source (the only credentialed one — OAuth2 client-credentials) and the synthetic mock source were both removed in the 2026-06-21 cutover. ADS-B now comes solely from the Tailspot backend (`api.tailspot.app`), which needs no per-app secret. There is no `OpenSkyClient`, no `MockADSBSource`, no `useMock` / `useBackend` toggle, and no OAuth credential apparatus — `ADSBManager` has a single injectable `source` (`TailspotBackendClient()` in prod, a fixture in tests).

**The one remaining build-time secret is the PostHog analytics key, and it's optional.** `ios/Tailspot/Tailspot.secrets.xcconfig` (gitignored) holds `POSTHOG_API_KEY`; the committed `Tailspot.xcconfig` `#include?`s it; Info.plist substitutes `$(POSTHOG_API_KEY)`; Xcode Cloud writes the same file via `ci_post_clone.sh` from a workflow env var. When absent, `Analytics.swift` is a silent no-op. It's a write-only anonymous-analytics key — baked into the binary is acceptable.

**Leak hygiene still applies** (two real leaks in this repo's history, both OpenSky). Inspect `git diff --cached` before every commit for any secret string; finding `paste-your-` means you staged the example template (fine), a real value means abort. Secrets belong only in the gitignored `Tailspot.secrets.xcconfig` — never in `.swift` files, plists, commit messages, or a staged secrets file.

**The OpenSky secret can now be retired safely.** It was deliberately kept un-rotated as the failover rung so old TestFlight builds wouldn't break. Once a build with this cutover reaches testers, no shipped binary uses OpenSky any more, so the credential can be deleted on the OpenSky console (no tester impact) — closing the leak surface for good.

## Tests

Unit tests live in `ios/Tailspot/TailspotTests/` and use Swift Testing (`@Test`, `#expect`, `@Suite`) — not XCTest. UI tests in `TailspotUITests/` are Xcode template scaffolding, slow (~3 min cold sim), and not part of the regular workflow.

Run after substantive code changes, and always before committing/deploying when touching Geo, Aircraft decoding, ADSBManager, the backend source client, or anything they depend on:

```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

First run is slow (~3 min, sim cold-boot); cached runs ~30–60 s. Last verified green: 349 tests, 0 failures (2026-06-11, on `feat/leaderboard-live`; 321 on `main`). Browse `TailspotTests/` directly for what's covered — inline inventories here drifted and aren't worth maintaining.

`ADSBManager.init(liveSource:mockSource:)` has defaulted params so production uses real sources and tests substitute a `FixedSource` fixture. Don't break this default-init shape — `ContentView`'s `@StateObject private var adsb = ADSBManager()` depends on it.

## MainActor default isolation (Xcode 26)

The Xcode 26 app template sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type, extension, and global is implicitly `@MainActor` unless explicitly marked otherwise. New in Xcode 26; affects every file we add.

Convention in this repo:

- **UI / state-holding types stay MainActor.** `LocationManager`, `MotionManager`, `ADSBManager`, SwiftUI views — all rely on @Published mutations being main-thread-safe by construction.
- **Pure data, geometry, and Sendable cross-actor types are explicitly `nonisolated`.** `Aircraft`, `FailableDecodable`, the `ADSBSource` protocol, `ADSBSourceError`, `TailspotBackendClient`, `Geo` and its private number-extension all carry `nonisolated`.
- **Extensions get their own isolation.** `nonisolated struct Aircraft` does NOT propagate to `extension Aircraft: Decodable {}` — that extension also needs `nonisolated extension Aircraft: Decodable`. Same for any other extensions on nonisolated types.

If you see a warning like *"main actor-isolated conformance of X to Y cannot be used in nonisolated context"* — the fix is almost always `nonisolated` on the extension.

## Architectural baseline

These decisions are settled (PLAN.md §1) and shouldn't be relitigated without a real reason:

- **Plane identification is geometric, not visual.** Inputs are GPS + true-north heading + camera elevation + ADS-B aircraft positions; the ID is angular correlation, not ML/CoreML object detection. **However**, per PLAN.md §1.1a, the *AR reticle placement* may eventually use CV (Vision + YOLOv8 COCO airplane class) to lock onto the actual plane image rather than the predicted position. Deferred but planned.
- **Backend from day 1**, not optional — needed for ADS-B caching, anti-cheat, sync, leaderboards. **Not yet built.** Phase 1.
- **Disambiguation is a v1 design problem**, not polish: when multiple aircraft fall within the angular tolerance, render an overlay tag for *each* and let the user tap one. Already in code.
- **The Tailspot backend** (`api.tailspot.app`, adsb.lol + MLAT) is the ADS-B provider — the single source as of the 2026-06-21 cutover (OpenSky-direct and the mock source were removed). The `ADSBSource` protocol still abstracts it, so swapping or adding a provider is one file's worth of work.
- **Photos:** commissioned illustrated cards (aircraft type × airline livery), not real photos. Sidesteps licensing.

## Key code patterns

These are the load-bearing patterns in the current codebase. Understand them before refactoring.

### ADSBSource protocol + injectable manager

`ADSBManager.init(source: ADSBSource = TailspotBackendClient())` lets the UI use the real backend source and tests inject a fixture. There is exactly one source now (OpenSky-direct and the mock source were removed in the 2026-06-21 cutover), so there's no runtime source toggle — the protocol seam exists purely so tests can substitute a fixture (and a future source can drop in). `ContentView`'s `@StateObject private var adsb = ADSBManager()` depends on the no-arg default.

### Split fetch from annotation

`ADSBManager` runs **two** concurrent Tasks:

1. **`pollTask`** — every `pollInterval` (20 s default), calls `source.aircraftInBbox(...)` and stashes the result in private `rawAircraft`. Backs off exponentially to a 120 s cap on `ClientError.rateLimited` (429).
2. **`reAnnotationTask`** — every `reAnnotationInterval` (1 s default), re-reads `rawAircraft`, forward-extrapolates each plane via `Aircraft.extrapolatedPosition(at: Date())`, recomputes bearing/elevation/distance from the current observer location, publishes `observed`.

This is what makes AR reticles glide smoothly between fetches. Keep these decoupled — don't merge them back into one loop.

### Pitch vs. camera elevation

`CMAttitude.pitch ≈ +π/2` when the phone is held upright in portrait, not 0. Camera elevation above the horizon is `90° − pitch`. Wrapped in `MotionManager.cameraElevationDeg`. **Never pass raw `motion.pitch` into projection math** — always `motion.cameraElevationDeg`. Both `Geo.screenPosition` and `ObservedAircraft.screenPosition` take `cameraElevationDeg`, not `phonePitchDeg`, for this reason.

### LocationManager `headingOrientation`

Pinned to `.portrait` in `LocationManager.init` so true-north heading is reported relative to a stable reference even if iOS rotates the UI. Don't remove this line.

### Visibility filter

`ObservedAircraft.isLikelyVisibleToObserver` (`elevationDeg > 0 && slantDistanceMeters < 30_000`) gates BOTH the AR overlay AND the bottom list in `ContentView`. (Earlier versions left the list unfiltered as a debug view; the 30 km cap was tightened from 100 km after field testing.) If a user reports "missing plane labels," check whether the plane is below horizon or past 30 km first — that's the filter doing its job, not a bug. Tune `maxVisibleDistanceMeters` to change.

### CMMotion / CLLocation / AVCapture concurrency

- Sensor wrappers (`LocationManager`, `MotionManager`) are `ObservableObject` classes with `@Published` properties; owned by a SwiftUI view via `@StateObject`.
- A file that uses `@Published` / `ObservableObject` but does **not** `import SwiftUI` must `import Combine` explicitly — SwiftUI re-exports Combine but pure model files don't get it transitively.
- All `@Published` mutations must happen on the main thread. Background callbacks (CMMotion queue, AVCapture queue, URLSession completion) hop via `DispatchQueue.main.async` before mutating state. `ADSBManager` sidesteps this with `@MainActor` on the class.
- Camera (`AVCaptureSession`) configuration and `startRunning` run on a dedicated serial `DispatchQueue` — never on main.
- The motion-manager reference frame is `.xArbitraryZVertical` (gravity-aligned only). True-north alignment comes from `CLLocationManager`'s heading. Revisit when ARKit lands.

### Logging through `Log.swift`

All app-side logging flows through `Log.swift`, a thin enum of `os.Logger` instances grouped by category:

```swift
Log.openSky.info("token cache hit")
Log.adsb.error("metadata lookup failed for \(icao, privacy: .public)")
Log.ui.notice("camera setup failed")
```

The subsystem is always `"com.landesberg.tailspot"` — `bin/log-tail` predicates on this so the Mac sees a filtered stream instead of the device's full firehose. Use `privacy: .public` on string interpolations whose contents you actually want to read in `log` output (Apple redacts string interpolations by default).

**Do not `print(...)` from app code.** Existing `print` calls were migrated; new ones won't be visible in the deploy-loop logs.

### Source error type

`ADSBSourceError` (in `ADSBSource.swift`) is the source-neutral transport-error enum (`badURL` / `rateLimited` / `http(status:)` / `decoding`). `TailspotBackendClient` throws it; `ADSBManager.refresh` matches `ADSBSourceError.rateLimited` to drive the 429 backoff. (Formerly `OpenSkyClient.ClientError`; promoted to a shared type in the 2026-06-21 cutover when OpenSky was deleted.)

### Metadata lookup + cache

Per-icao24 metadata (manufacturer / model / registration / operator) is fetched via the backend source's `aircraftMetadata(icao24:)` and stored in a per-session `MetadataCache` actor (cap 500, bounded LRU). `ADSBManager.metadata(for:)` is the single entry point: cache hit → return; miss → fetch + cache (including `nil` 404 results as known-misses, so we don't re-fetch them). Transport errors are NOT cached so a later tap retries. Consumed by `AircraftDetailView.task` and `ContentView.task(id: lockOn.state.targetIcao24)`. (The Hangar's offline backfill, `CatchBackfill`, uses its own `TailspotBackendClient` instance — it isn't reachable from the manager.)

### Lock-on state machine

`LockOnEngine` is a pure state machine (`idle` / `acquiring` / `locked` / `sticky`) — no SwiftUI, no screen geometry. `ContentView` runs a 30 Hz `TimelineView`, computes `closestTargetIcao24(...)` against the visible aircraft each frame, and feeds it into `engine.update(...)`. Visuals (yellow → green corner brackets + identification label) read directly from `engine.state` and `engine.acquisitionProgress(now:)`. Tuning knobs: `engine.acquisitionDuration` (0.6 s), `engine.stickyHoldDuration` (2.0 s), and the `lockZoneRadius` argument to `closestTargetIcao24` (80 px). Tests live in `LockOnEngineTests.swift` and cover every transition.

### Catch flow + SwiftData

`Catch` is a v1 `@Model` class with a flat schema (icao24, callsign, model, manufacturer, `operatorName`, caughtAt, observerLat/Lon, slantDistanceMeters). `operatorName` was added in Hangar v0; existing rows from before that field shipped come back as nil (SwiftData lightweight migration). Duplicates of the same icao24 are explicitly allowed — dedupe is a Hangar concern, not a model concern. `ModelContainer` is created in `TailspotApp.init` and injected via `.modelContainer(_)`; views consume via `@Environment(\.modelContext)`. Tests use `ModelConfiguration(isStoredInMemoryOnly: true)` so the suite doesn't touch disk.

### Hangar collection

`HangarView` is a sheet presented from `ContentView` (tray glyph in the top-trailing corner; green count badge fed by a lightweight `@Query` in ContentView). Inside the sheet a `@Query(sort: \Catch.caughtAt, order: .reverse)` powers an inset-grouped `List`, sectioned via `HangarGrouping.group(_:by:)` — a **pure function** in its own file so the grouping logic is unit-testable without spinning up SwiftUI. The grouping segmented picker lives inline as the first list section (not the toolbar), so the nav title can keep showing the catch count.

Two grouping modes today: `.aircraftType` (manufacturer + model) and `.airline` (operatorName). Each mode has its own fallback chain ending in a single "Unknown" bucket that always sorts to the end. Row subtitles deliberately show whichever of (operator, type) ISN'T already in the section header so rows add information instead of restating it.

`CatchDetailView` is a **frozen-moment view with a narrow backfill exception** (spec 2026-06-06): on open it may fill **nil-only** fields that are properties of the airframe, not the moment — registration, typecode, manufacturer, model, placeName, and operatorName (the last is best-effort *current* operator, not as-flown; documented in code). Recorded values are never overwritten, and moment-data (altitude, speed, distance, date) is never backfilled. v0 has **no dedupe** (each tap = each row in its section). **Delete** exists in two places — the red trash pill in `CatchDetailView` and a Hangar swipe-delete context menu — both require confirmation and both delete photo files alongside the SwiftData row. If catches grow to hundreds, the per-body re-grouping in `HangarView.groupedList` will want memoization.

### Replay recorder

`ReplayRecorder` is a `@MainActor ObservableObject` that writes JSONL to `Documents/replays/replay-<utc>.jsonl`. One `session-start` header line, then one `tick` line per recorded moment. JSONL (not a single JSON array) so a crash mid-write leaves a still-decodable file — `ReplayJSONL.decode(_:)` drops a trailing partial line silently.

`ReplayEvent` is a discriminated union: `case sessionStart(SessionStart)` and `case tick(Tick)`. Wire format keeps the `type` discriminator flat with the payload fields (`{"type":"tick", "timestamp": ..., "sensor": ..., "aircraft": [...]}`) so individual lines stay readable by eye. Bump `ReplayRecorder.schemaVersion` when an existing field's meaning changes.

`AircraftSnapshot` is **separate from `Aircraft`** even though it carries the same fields. Aircraft has a positional OpenSky-shaped `Decodable`; the replay format wants stable named-key Codable. Keeping them separate means future OpenSky decoder changes don't ripple into recorded files.

`SensorSnapshot.zoomFactor` is `Double?` (optional) for back-compat — files recorded before camera zoom shipped don't have the field; the analyzer treats nil as 1.0.

**Tap-pin events ARE captured.** `ReplayEvent.tapPin(TapPin)` and `ReplayEvent.unpin(Unpin)` get written between ticks whenever the user tap-pins or clears. The analyzer sorts all events by timestamp (so a future merged or concatenated input source can't reorder them at the millisecond level), walks them in order, maintains a running `pinnedIcao`, and on `.tapPin` calls `engine.forceLock(...)` so the replay's lock-on path matches live behavior. Pinned plane no longer visible → analyzer's per-tick `pinStillVisible` check falls back to the center-driven target (same as ContentView).

ContentView drives the recorder via a `.task(id: recorder.isRecording)` loop that fires `recordReplayTick()` once per second while recording, then exits when the user taps **Record session** off. The 1 Hz cadence is enough to drive lock-on / projection validation; visual-confirmation work that needs per-frame samples will want a faster tick (or a separate stream).

Retrieve recorded files from the phone with: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier com.landesberg.Tailspot --source Documents/replays --destination ./replays`. (The recorder doesn't ship a UI export today — `Documents/` is the universal escape hatch.)

### Camera zoom + tap-to-ID

Two coupled AR interactions:

- **Zoom** is digital (`AVCaptureDevice.videoZoomFactor`), 1×–5× capped in `CameraPreview.zoomRange`. ContentView owns the `zoom` `@State`, pipes it to `CameraPreview`, and divides `baseHfovDeg / baseVfovDeg` by it when computing screen positions. `PreviewView.setZoom` guards on `lastAppliedZoom` so the constant `updateUIView` calls (driven by the 30 Hz TimelineView) don't thrash `device.lockForConfiguration`.
- **Tap-to-ID** sets `pinnedIcao` and immediately `forceLock`s the engine onto the tapped plane — no 0.6 s acquisition delay, because the user explicitly pointed. `closestTargetIcao24` grew an `at: CGPoint?` parameter (default = screen center); the tap handler calls it with the tap location and a generous 100 px radius. Tap rules:
  - empty sky → clear pin (back to center-driven lock)
  - same plane as current pin → toggle off
  - different plane → switch pin + force-lock
- Pin housekeeping: `.onChange(of: lockOn.state.targetIcao24)` clears the pin when the engine moves off it (sticky-expired, or center-driven switched). The TimelineView body checks `pinStillVisible` before feeding the pin into `engine.update`, so a stale pin can't lock the bracket-finder onto a missing icao.

Pinch + tap share a `Color.clear` background layer via `.gesture` + `.simultaneousGesture`. The locked label's `.onTapGesture` (further up the Z-stack) still wins for taps that land on it. `lockZoneRadius` stays in pixels (UI affordance, not angular tolerance) — at high zoom, the same 80 px covers a tighter angular wedge, which is exactly the disambiguation tap-to-ID needs.

`baseHfovDeg` (56°) and `baseVfovDeg` (72°) are approximations for the iPhone 16 main wide camera in portrait. Refine by querying `AVCaptureDevice.activeFormat.videoFieldOfView` if drift becomes visible.

### Replay analyzer

`ReplayAnalyzer` is the offline-replay side. Pure-Swift `@MainActor struct` with three tuning knobs (`screenSize`, FOV degrees, `lockZoneRadius`) and one method: `analyze(_: [ReplayEvent]) -> ReplayReport` (or `analyze(fileURL:)` for the file shortcut). It walks events in order, builds a fresh `LockOnEngine`, and feeds each tick through:

1. Reconstruct observer `CLLocation` from the sensor row (nil if no GPS fix yet — those ticks get an empty `aircraft` array).
2. For each aircraft snapshot, `ObservedAircraft.annotate(_:observer:now:)` (the same helper `ADSBManager.reAnnotate` uses) computes bearing/elevation/slant.
3. Filter by `isLikelyVisibleToObserver`.
4. Project each visible plane to screen, call `closestTargetIcao24(...)`, drive the lock-on engine.
5. Emit one `ReplayTickReport` per tick, including the engine state after.

Why this design: when you change projection math, visibility cutoffs, or lock-on tuning, the live app picks it up *and* recorded sessions re-analyze with the new behavior. No copy-paste between live and replay paths. The "no human-readable summary yet" gap (PLAN §9 #3 follow-up) is the next thing to fill — the structured report is already accurate.

### Debug overlay toggle

The sensor readout and aircraft-list panels are hidden by default; a wrench glyph in the top-right corner toggles them via `@State var showDebug`. The source row inside the sensor readout is now a static `[TAILSPOT API]` indicator (the LIVE/MOCK/OpenSky toggle was removed in the 2026-06-21 cutover — there's only one source). Field-testing UI stays clean.

## Repository layout

See PLAN.md §8 for the file-by-file layout. Quick highlights:

- `PLAN.md` — product + technical plan
- `CLAUDE.md` — this file
- `ios/Tailspot/Tailspot.xcodeproj/xcshareddata/xcschemes/Tailspot.xcscheme` — the **only** shared scheme. See "Secrets: PostHog key only" before editing it or running `git add ios/`.
- `ios/Tailspot/Tailspot/` — Xcode project source. Uses **Xcode 16 synchronized folders**: any `*.swift` dropped into this directory is automatically added to the Xcode project. No manual "Add Files to Project" step.
- `backend/`, `shared/`, `tools/replay-harness/` — planned (PLAN.md §8); not created yet.

## Permission strings

`NSCameraUsageDescription` and `NSLocationWhenInUseUsageDescription` live in the target's **Info** tab in Xcode (Custom iOS Target Properties), not in any source file under version control. Adding a new permission requires a manual Xcode UI step — Claude cannot add them via file edits. Flag it explicitly when needed.

## Workflow notes

**TestFlight is live (since 2026-05-26), but shipping is MANUAL as of 2026-06-16.** Merging to `main` no longer reaches testers: the Xcode Cloud Branch-Changes start condition was removed (it was pinging testers on every merge). `main` is the always-green integration line; a TestFlight build happens only when someone clicks **Start Build** in Xcode Cloud (App Store Connect → Xcode Cloud → workflow → Start Build on `main`, or Xcode → Integrate → Start Build), which bundles everything merged since the last build.

- **`main` is the integration line; ship is a separate, batched, manual step.** All changes reach `main` via a PR with a green **Unit tests** check (GitHub Actions); branch protection blocks direct pushes, admins included. Branch → field-test with `bin/deploy` → PR → squash-merge → **lands on `main` (does NOT ship)**. Merge freely; batch the TestFlight build via a deliberate Start Build when ready. Autonomous commit + `bin/deploy` + merges happen freely; **only Noah triggers the ship** (the build going to testers is his call). Canonical process: `CONTRIBUTING.md`.
- **Build numbers auto-bump in CI.** `ios/Tailspot/ci_scripts/ci_pre_xcodebuild.sh` rewrites `CURRENT_PROJECT_VERSION` to match `CI_BUILD_NUMBER` per Xcode Cloud archive. Don't touch `CURRENT_PROJECT_VERSION` in `project.pbxproj` manually — the committed value stays at `1`.
- **Keep the SAME `MARKETING_VERSION` by default; let the build number increment.** Per Noah (2026-06-08): TestFlight/App Review clears builds under an already-approved version string faster than a fresh version. Bump `MARKETING_VERSION` (edit `project.pbxproj`, e.g. `0.2.x → 0.3.0`) only for major changes worth flagging to testers. (Supersedes the earlier bump-per-user-visible-change habit.)
- **SwiftData migrations stay lightweight.** Once testers have catches, every model change must be additive (new optional fields with defaults). Breaking schema changes lose tester data; if ever needed, bump the model version explicitly with a custom migration.
- **Watch crash logs.** App Store Connect → Tailspot → TestFlight → Crashes aggregates real-tester crashes — free diagnostic surface, check after every TestFlight build.
- **Tester bug reports:** Settings → bottom of page shows version + build, tap to copy — ask testers to paste `Tailspot 0.1.1 (build N)` into reports.
- **Don't force-push to `main` without explicit user authorization.** If a leak requires history rewriting, surface the trade-offs to Noah and let him decide.
- Tests before pushing/deploying and credential hygiene: see the Tests and Credentials sections — those rules apply to every commit.

## Open questions still on the table

PLAN.md §6 lists deferred questions with working defaults: photo strategy (illustrated cards), privacy posture (location-when-in-use), launch region (US + Western Europe), backend hosting (Fly.io + Postgres). Don't promote a default to a real decision without asking Noah.

## Where to pick up

PLAN.md §9 is the authoritative backlog. **As of 2026-05-26, TestFlight v0 is live** — internal testers can install Build 11+ (the first build with the CFBundleVersion-bump CI script working end-to-end). The app icon is the B-lockon concept; Hangar glyph is SF Symbol `airplane.path.dotted`; mock surfaces have `ComingSoonBanner`s; debug wrench is gated to Debug builds; Settings shows a tap-to-copy version footer. See the Current state entry at the top.

Earlier landings (left for context): full design-canvas port (Trophies, Sets, Profile hub, MapKit map, mock Leaderboard + ShareLink, Settings, Notifications, 4-step Onboarding); Capture & Hangar redesign (all-frame ambient labels, unified capture button with multi-catch, 3-state lock engine, segmented Hangar with Sets/Recent/Trophies, model-slot drill-down, PokeCard-first tail detail); Hangar v1 (dedupe + swipe-delete); replay recorder + analyzer; camera zoom + tap-to-ID; Brand tokens; Planespotters photo integration; Game-system spine.

Top of the queue now (per PLAN.md §9):

1. **Backend wiring** (PLAN §9 #2) — real anonymous leaderboard, public-hangar visits, push notifications, curated rarity-table refresh. Multi-week effort. Until then, Leaderboard + Public Hangar render mock data and Notifications toggles just persist intent.
2. **Visual confirmation** (Vision + COCO airplane class; PLAN §9 #3).
3. **Capture `os_log` output from the device** (PLAN §9 #4).
4. **Multi-catch AR state + 3-card fan reveal** (PLAN §9 #5) — detect 2-5 visible planes in a single magenta capture frame, hold-to-capture, fan-reveal N cards. CardReveal is parameterizable for multi; the AR detection logic is the new work.

Lower priority: ~~OpenSky secret rotation (#6)~~ — resolved by the 2026-06-21 cutover (OpenSky removed entirely; retire the console credential once a cutover build reaches testers).

**Phase B and Phase C** of the original visual identity (HUD label redesign, Hangar polish, app icon, onboarding) are largely superseded by the design-canvas direction now landing in PLAN §9 #2-#6. Don't relitigate Phase B/C — port the canvas surfaces directly.

**Design source.** The canvas handoff lives in `design/` (HTML/JSX prototype, ~340K). Open with `python3 -m http.server 4173 --directory design && open http://127.0.0.1:4173/`. 33 artboards across 10 sections — splash/brand, onboarding, AR home, AR states, catch flow, detail, hangar, sets, gamification (rarity / types / trophies / trophy-unlock), public surfaces (leaderboard, map, share, public-hangar), profile/settings/notifs. **The prototype is for reference, not for direct porting** — recreate visuals in SwiftUI; don't port the JSX structure.
