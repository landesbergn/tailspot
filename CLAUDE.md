# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, Phase 0 main next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

## Current state (as of session ending 2026-05-16)

**Friday POC (§3.0a) DELIVERED May 5–7, 2026.** Field-tested in Berkeley with real planes; labels land on or near actual aircraft.

**Phase 0c — Remote-deploy loop (§3.0c) DELIVERED 2026-05-13.** Bash-driven build / install / launch / log-stream pipeline so Claude can iterate directly on Noah's paired iPhone. See "Remote-deploy loop" below.

**Beyond the POC, currently shipping:**

- **AR lock-on interaction.** Clean default view (just camera). Aim within ~80 px of a plane's projected position → yellow corner brackets close in for ~0.6 s → snap solid green with a label showing callsign / airline / make+model / altitude · speed. 2 s sticky-hold after target leaves. Tap the locked label → detail sheet. State machine in `LockOnEngine.swift`; visuals in `ContentView.swift`.
- **Catch flow v0.** "Catch this plane" button in `AircraftDetailView` inserts a `Catch` SwiftData row (icao24, callsign, model, manufacturer, **operatorName**, caughtAt, observer lat/lon, slant distance). `ModelContainer` set up in `TailspotApp`. Each tap is a discrete event; dedupe is a Hangar concern.
- **Hangar v0 (collection).** Tray glyph in the top-trailing corner of `ContentView` (with green count badge) opens `HangarView` as a sheet. Inset-grouped list of every `Catch`, sectioned by aircraft type (manufacturer + model) by default; segmented picker toggles to airline grouping (uses the new `operatorName` column). Tap any row → read-only `CatchDetailView` showing the frozen snapshot (no live re-fetch — a catch from yesterday should look the same tomorrow). v0 explicitly **does not dedupe** (5 catches of UAL248 = 5 rows) and **has no delete** — both deferred. Grouping logic is a pure function in `HangarGrouping.swift` with 7 dedicated tests.
- **Aircraft type lookup.** Per-icao24 fetch from OpenSky's `/metadata/aircraft/icao/{icao24}` via `OpenSkyClient.aircraftMetadata`, lazily on lock-acquisition or detail-sheet appearance. In-memory LRU `MetadataCache` (cap 500) dedups; 404s are cached as known-misses.
- **Live/Mock ADS-B toggle** (in the debug overlay). 5 hand-picked mock aircraft with metadata fixtures (BOEING 737-800 / AIRBUS A320 / etc.); the 5th has no metadata, intentionally, so the cache-miss path is field-testable.
- **Heading-accuracy color cue.** Heading line in the sensor readout turns red when `CLHeading.headingAccuracy > 15°`.
- **Visibility filter.** AR overlay AND debug aircraft list both show only aircraft above the horizon AND within 30 km slant distance. Bbox fetch is still 50 km — out-of-range planes are hidden, not dropped.
- **Debug overlay, hidden by default.** Wrench glyph in the top-right toggles the sensor readout (top) and nearby-aircraft list (bottom). The LIVE/MOCK toggle lives in the sensor readout.
- **Forward-extrapolation** of ADS-B positions to "now"; **1 Hz re-annotation** for smooth bracket tracking; **OAuth2 client-credentials** auth against OpenSky (4000 credits/day registered tier); **429-aware backoff**.
- **82 unit tests** in `TailspotTests/` covering geometry, OpenSky decoding, annotation, sort, error handling, extrapolation, visibility predicate, screen projection, aircraft-metadata decoding, MetadataCache LRU+miss-as-hit semantics, ADSBManager metadata-cache-and-fallback, SwiftData Catch persistence (including the operatorName default), LockOnEngine state transitions (idle/acquiring/locked/sticky), and HangarGrouping (both modes, fallbacks, sort order, empty input, whitespace folding).

**Deliberately not yet built:** Hangar dedupe + delete (deferred from v0), backend, ARKit drift correction, achievements/scoring, visual confirmation (CV/ML on the camera feed), origin/destination route info, replay harness, device-side `os.Logger` capture (only system-emitted lines reach `bin/log-tail` today; see PLAN.md §9 #10). See PLAN.md §9 for the prioritized backlog. Don't try to "fix" what isn't built.

## Working model

- Solo developer (Noah) with no prior iOS experience. Claude writes code; Noah runs it on his iPhone 16 (iOS 26.3.1) and reports back.
- Field-test location: Berkeley/Oakland CA — under SFO/OAK approach corridors, dense ADS-B coverage. OpenSky free-tier MLAT is excluded, so most small GA, helicopters, and military traffic are invisible. Expect this.
- Preference: **explain-as-we-go.** When introducing a Swift / SwiftUI / iOS pattern Noah hasn't seen, narrate it in the commit message or inline comments. He is learning iOS in parallel with shipping.
- Pick the simplest viable iOS choice at every fork: SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods/SPM deps yet.

## Build and run

Two paths:

- **Claude-driven (default this session and after):** `bin/deploy` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches on Noah's paired iPhone wirelessly. See "Remote-deploy loop" below for details and rules. There is no CI; Claude runs the unit-test suite before deploys.
- **Manual (Noah's IDE workflow):** Xcode `⌘R` against the connected iPhone. Useful when you want Xcode's debugger / live `os_log` console.

The iOS Simulator cannot provide real GPS, compass, or camera, so the iPhone is required for any runtime / field testing.

### Remote-deploy loop

For tighter iteration than ⌘R-in-Xcode, the repo ships a Bash-driven loop:

- `bin/deploy [--no-build] [--no-launch] [--dry-run]` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches the app on Noah's paired iPhone. The device UDID, scheme, and paths come from `tools/deploy/config.sh`; override locally via `tools/deploy/config.local.sh` (gitignored). Wireless dev pairing must already be active (confirm with `xcrun devicectl list devices`). `--launch` is implicit; use `--no-launch` to install without auto-starting.
- `bin/log-tail [-n N] [-f]` — reads `~/Library/Logs/tailspot/device.log`. **Currently a no-op stub:** the host macOS `log` binary on this machine does not accept `--device <UDID>`, so `bin/log-start` exits 0 with a notice and no streaming runs. Fix planned (PLAN.md §9 #3); until then, inspect runtime behavior via Xcode's Console or `os_log` viewer.
- All app-side logging flows through `Log.swift` (subsystem `com.landesberg.tailspot`).

Rules:
- **Run unit tests before `bin/deploy`** when touching testable code. The loop will happily deploy a broken build.
- If `xcrun devicectl install` fails (e.g., "developer disk image could not be mounted"), surface the message and stop — don't silently retry. Most such failures need Noah's action: unlock the phone, re-pair via USB, or open Xcode once to mount the DDI.
- The device UDID in `tools/deploy/config.sh` is Noah's. A different developer overrides via `tools/deploy/config.local.sh`.

### Doc-staleness Stop hook

`.claude/settings.json` registers a `Stop` hook that runs `bin/doc-staleness-check` at the end of each Claude turn. The check:

1. Looks for unpushed commits on `main` (`git log origin/main..HEAD`).
2. If any exist and **none** of them touched `CLAUDE.md` or `PLAN.md`, emits `{"decision":"block","reason":"..."}` so the turn doesn't end — Claude is asked to refresh the docs (`Current state` in CLAUDE.md and §9 in PLAN.md) and push before stopping.
3. Otherwise silent.

The point: a session can be cleared at any time and the next agent reads docs that match what's on disk. The script self-locates via `git rev-parse --show-toplevel`, so it works regardless of the cwd the hook fires from. `.claude/settings.json` itself is gitignored (everything under `.claude/` is) — to make this hook follow the repo to other machines, add `!.claude/settings.json` to `.gitignore` and commit.

### OpenSky credentials

For LIVE mode the app authenticates via OAuth2 client-credentials. OpenSky's anonymous tier (400 credits/day) is exhausted in ~1.3 hr at the 20 s default poll rate; the registered tier (4000 credits/day) is comfortable for testing.

Read at runtime from process environment:
- `OPENSKY_CLIENT_ID`
- `OPENSKY_CLIENT_SECRET`

These belong in the **user-only** Xcode scheme (Edit Scheme → Run → Arguments → Environment Variables), so they get saved under `xcuserdata/` and stay out of git. See "Credentials and the shared-scheme trap" below for the rules that prevent these from leaking.

OpenSky's OAuth endpoint is on the **older Keycloak path with the `/auth/` prefix** — `https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token`. The modern path without `/auth/` returns 404. This is empirically verified and documented in a comment in `OpenSkyClient.swift`. The API docs are at https://openskynetwork.github.io/opensky-api/rest.html.

## Tests

Unit tests live in `ios/Tailspot/TailspotTests/` and use Swift Testing (`@Test`, `#expect`, `@Suite`) — not XCTest. UI tests in `TailspotUITests/` exist as Xcode template scaffolding but are slow (~3 min on cold sim) and not part of the regular workflow.

**Claude runs the unit tests after substantive code changes** with:
```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```
First run is slow (~3 min, sim cold-boot). Cached subsequent runs are ~30–60 s. Run before committing whenever you touch testable code (Geo, Aircraft decoding, ADSBManager, OpenSky client, or anything they depend on).

The current suite (82 tests) covers:
- `GeoTests`: distance, bearing (cardinal + 0/360 sweep), elevation, project round-trip, **screenPosition** (target straight ahead → center, out-of-FOV → nil, 0/360° wraparound from high & low headings, elevation above center).
- `AircraftDecodingTests`: full positional-JSON decode, null-position throws, FailableDecodable swallows bad entries, callsign trim, geo-vs-baro altitude precedence, all-altitudes-null → 0.
- `ADSBManagerTests`: annotation correctness, on-ground filtering, sort-by-slant-distance, error → `lastError` without crashing, success clears previous error, `lastFetched` timestamp, mock-source integration produces 5 aircraft, rate-limit error surfaces as backoff message, forward-extrapolation (moves along track / no-ops when timestamp/velocity missing / age-too-large), visibility predicate (above-horizon-and-close, below horizon, exactly-horizon, too-far, edge-of-range).
- `AircraftMetadataDecodingTests`: full /metadata/aircraft/icao payload, tolerates missing/null optionals, throws on missing icao24.
- `MetadataCacheTests`: not-fetched vs hit-nil-miss distinction, LRU eviction at cap.
- `ADSBManagerMetadataTests`: cache consultation, dedupe of repeated lookups, errors don't poison the cache (use `CountingMetadataSource` fixture).
- `CatchTests`: SwiftData `Catch` insert/fetch (including `operatorName`), duplicates allowed, nil-optional metadata tolerated, `operatorName` defaults to nil when omitted. Uses `ModelConfiguration(isStoredInMemoryOnly: true)` so tests don't touch disk.
- `LockOnEngineTests`: full state-machine coverage (idle / acquiring / locked / sticky) and `acquisitionProgress` ramp.
- `HangarGroupingTests`: pure-function grouping for the Hangar view — both modes (aircraft type, airline), fallback chain (manufacturer-only / model-only / Unknown), Unknown bucket sorts last, rows within a group sort most-recent-first, empty input → empty array, whitespace trimming and empty-string folding for both modes.

`ADSBManager.init(liveSource:mockSource:)` has defaulted params so production uses real sources and tests substitute a `FixedSource` fixture. **Do not break this default-init shape** — `ContentView`'s `@StateObject private var adsb = ADSBManager()` depends on it.

## Credentials and the shared-scheme trap

**This bit me twice. Read it.** Xcode's `Edit Scheme… → Environment Variables` writes those values into the *shared* scheme (`xcshareddata/xcschemes/Tailspot.xcscheme`) by default. If you `git add ios/` afterwards, the file with the credentials gets staged and committed.

Rules:

1. **Add env vars to a user-only scheme**, not the shared one. In Xcode's `Manage Schemes…` dialog, uncheck the "Shared" column for your local copy, or duplicate the scheme as user-only. User-only schemes go to `xcuserdata/` which is `.gitignore`d.
2. **`.gitignore` allows exactly one shared scheme file** (`Tailspot.xcscheme`) via a `!` exception, so `xcodebuild` can find a scheme on fresh clone. **Every other `*.xcscheme` is ignored.** Gitignore rules are at the top of the file.
3. **Gitignore does NOT protect already-tracked files.** If Xcode rewrites `Tailspot.xcscheme` with env vars (because someone edited the shared scheme), those changes will stage. **Always `git diff` the staged set before committing.** Look for `OPENSKY_CLIENT_SECRET` or `EnvironmentVariable` in the diff.
4. **If a secret leaks anyway**: tell Noah immediately, rotate the secret on OpenSky's API console (don't wait), and either force-push (destructive — requires explicit user authorization) or accept the leak in git log and rely on rotation as the actual fix. Both leaks in this repo's history are recoverable from GitHub's dangling-objects cache for ~90 days — rotation is the mitigation.

## MainActor default isolation (Xcode 26)

The Xcode 26 app template sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every type, extension, and global is implicitly `@MainActor` unless explicitly marked otherwise. New in Xcode 26; affects every file we add.

Convention in this repo:

- **UI / state-holding types stay MainActor.** `LocationManager`, `MotionManager`, `ADSBManager`, SwiftUI views — all rely on @Published mutations being main-thread-safe by construction.
- **Pure data, geometry, and Sendable cross-actor types are explicitly `nonisolated`.** `Aircraft`, `FailableDecodable`, the `ADSBSource` protocol, `OpenSkyClient`, `MockADSBSource`, `Geo` and its private number-extension all carry `nonisolated`.
- **Extensions get their own isolation.** `nonisolated struct Aircraft` does NOT propagate to `extension Aircraft: Decodable {}` — that extension also needs `nonisolated extension Aircraft: Decodable`. Same for any other extensions on nonisolated types.

If you see a warning like *"main actor-isolated conformance of X to Y cannot be used in nonisolated context"* — the fix is almost always `nonisolated` on the extension.

## Architectural baseline

These decisions are settled (PLAN.md §1) and shouldn't be relitigated without a real reason:

- **Plane identification is geometric, not visual.** Inputs are GPS + true-north heading + camera elevation + ADS-B aircraft positions; the ID is angular correlation, not ML/CoreML object detection. **However**, per PLAN.md §1.1a, the *AR reticle placement* may eventually use CV (Vision + YOLOv8 COCO airplane class) to lock onto the actual plane image rather than the predicted position. Deferred but planned.
- **Backend from day 1**, not optional — needed for ADS-B caching, anti-cheat, sync, leaderboards. **Not yet built.** Phase 1.
- **Disambiguation is a v1 design problem**, not polish: when multiple aircraft fall within the angular tolerance, render an overlay tag for *each* and let the user tap one. Already in code.
- **OpenSky free tier** is the v1 ADS-B provider — Tailspot is free with no monetization, so OpenSky's non-commercial terms fit. The `ADSBSource` protocol abstracts this; swapping to a paid provider is one file's worth of work.
- **Photos:** commissioned illustrated cards (aircraft type × airline livery), not real photos. Sidesteps licensing.

## Key code patterns

These are the load-bearing patterns in the current codebase. Understand them before refactoring.

### ADSBSource protocol + injectable manager

`ADSBManager.init(liveSource: ADSBSource = OpenSkyClient(), mockSource: ADSBSource = MockADSBSource())` lets the UI use real sources and tests inject fixtures. The `useMock` `@Published` flag switches between them at runtime; flipping it kicks an immediate refresh via `refreshNow()`.

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

### OpenSky OAuth token caching

`OpenSkyClient` uses `OSAllocatedUnfairLock<CachedToken?>` for its token cache so the class can be `Sendable` without an `actor`. Tokens refresh when within 30 s of expiry. Don't replace this with an actor unless you also rework the `ADSBSource` protocol's isolation.

### Metadata lookup + cache

Per-icao24 metadata (manufacturer / model / registration / operator) is fetched via `OpenSkyClient.aircraftMetadata(icao24:)` and stored in a per-session `MetadataCache` actor (cap 500, bounded LRU). `ADSBManager.metadata(for:)` is the single entry point: cache hit → return; miss → fetch + cache (including `nil` 404 results as known-misses, so we don't re-fetch them). Transport errors are NOT cached so a later tap retries. Consumed by `AircraftDetailView.task` and `ContentView.task(id: lockOn.state.targetIcao24)`.

### Lock-on state machine

`LockOnEngine` is a pure state machine (`idle` / `acquiring` / `locked` / `sticky`) — no SwiftUI, no screen geometry. `ContentView` runs a 30 Hz `TimelineView`, computes `closestTargetIcao24(...)` against the visible aircraft each frame, and feeds it into `engine.update(...)`. Visuals (yellow → green corner brackets + identification label) read directly from `engine.state` and `engine.acquisitionProgress(now:)`. Tuning knobs: `engine.acquisitionDuration` (0.6 s), `engine.stickyHoldDuration` (2.0 s), and the `lockZoneRadius` argument to `closestTargetIcao24` (80 px). Tests live in `LockOnEngineTests.swift` and cover every transition.

### Catch flow + SwiftData

`Catch` is a v1 `@Model` class with a flat schema (icao24, callsign, model, manufacturer, `operatorName`, caughtAt, observerLat/Lon, slantDistanceMeters). `operatorName` was added in Hangar v0; existing rows from before that field shipped come back as nil (SwiftData lightweight migration). Duplicates of the same icao24 are explicitly allowed — dedupe is a Hangar concern, not a model concern. `ModelContainer` is created in `TailspotApp.init` and injected via `.modelContainer(_)`; views consume via `@Environment(\.modelContext)`. Tests use `ModelConfiguration(isStoredInMemoryOnly: true)` so the suite doesn't touch disk.

### Hangar collection

`HangarView` is a sheet presented from `ContentView` (tray glyph in the top-trailing corner; green count badge fed by a lightweight `@Query` in ContentView). Inside the sheet a `@Query(sort: \Catch.caughtAt, order: .reverse)` powers an inset-grouped `List`, sectioned via `HangarGrouping.group(_:by:)` — a **pure function** in its own file so the grouping logic is unit-testable without spinning up SwiftUI. The grouping segmented picker lives inline as the first list section (not the toolbar), so the nav title can keep showing the catch count.

Two grouping modes today: `.aircraftType` (manufacturer + model) and `.airline` (operatorName). Each mode has its own fallback chain ending in a single "Unknown" bucket that always sorts to the end. Row subtitles deliberately show whichever of (operator, type) ISN'T already in the section header so rows add information instead of restating it.

`CatchDetailView` is a **read-only snapshot** — no live re-fetch of metadata or position. A catch is a frozen moment; tomorrow's metadata/distance must not retroactively rewrite it. v0 has **no dedupe** (each tap = each row in its section) and **no delete UI**; both are deferred. If catches grow to hundreds, the per-body re-grouping in `HangarView.groupedList` will want memoization.

### Debug overlay toggle

The sensor readout and aircraft-list panels are hidden by default; a wrench glyph in the top-right corner toggles them via `@State var showDebug`. The LIVE/MOCK source toggle lives inside the sensor readout — so it's only reachable when debug is on. Field-testing UI stays clean.

## Repository layout

See PLAN.md §8 for the file-by-file layout. Quick highlights:

- `PLAN.md` — product + technical plan
- `CLAUDE.md` — this file
- `ios/Tailspot/Tailspot.xcodeproj/xcshareddata/xcschemes/Tailspot.xcscheme` — the **only** shared scheme; gitignored from accidental modification. Read "Credentials and the shared-scheme trap" before editing this file or running `git add ios/`.
- `ios/Tailspot/Tailspot/` — Xcode project source. Uses **Xcode 16 synchronized folders**: any `*.swift` dropped into this directory is automatically added to the Xcode project. No manual "Add Files to Project" step.
- `backend/`, `shared/`, `tools/replay-harness/` — planned (PLAN.md §8); not created yet.

## Permission strings

`NSCameraUsageDescription` and `NSLocationWhenInUseUsageDescription` live in the target's **Info** tab in Xcode (Custom iOS Target Properties), not in any source file under version control. Adding a new permission requires a manual Xcode UI step — Claude cannot add them via file edits. Flag it explicitly when needed.

## Workflow notes

- **Run tests before committing** when touching Geo / Aircraft / ADSBManager / OpenSky / Mock / their tests. See the `xcodebuild test` command in the Tests section.
- **Inspect `git diff --cached` before every commit** for `OPENSKY`, `client_secret`, or `EnvironmentVariable` strings. If you see them, abort and fix the scheme before committing.
- **Don't force-push to `main` without explicit user authorization.** The auto-mode classifier will deny it. If a leak requires history rewriting, surface the request to Noah with the trade-offs spelled out and let him decide.
- **Don't commit credentials in any form** — not in `.swift` files, not in `.xcscheme` files, not in plist values, not in commit messages.

## Open questions still on the table

PLAN.md §6 lists deferred questions with working defaults: photo strategy (illustrated cards), privacy posture (location-when-in-use), launch region (US + Western Europe), backend hosting (Fly.io + Postgres). Don't promote a default to a real decision without asking Noah.

## Where to pick up

PLAN.md §9 is the authoritative backlog. As of 2026-05-16, **Hangar v0 has shipped** (see "Hangar collection" pattern above). Top of the queue now:

1. **Rotate the leaked OpenSky client secret** (PLAN §9 #2; 10 min Noah action, no code). Pure-housekeeping; unblocked.
2. **Capture `os_log` output from the device** (PLAN §9 #3) — `bin/log-tail` currently only sees system-emitted lines, not `Log.swift` calls. Candidates: in-app file logging that `Log.swift` mirrors to `Documents/`, or wrapping `xcrun devicectl device process launch --console`.
3. **Replay harness** (PLAN §9 #4) — record `(sensor stream + ADS-B snapshot + observer pose)` to disk during a session; replay offline through the ID engine. Phase-0-main infra.
4. **Hangar v1 polish** (not on PLAN.md yet; flag when relevant): dedupe (group repeat catches of the same icao24 with a "×N" badge), swipe-to-delete with confirm, illustrated cards for top type×airline combos. Defer until Noah has real catch volume to design against.
5. **Visual confirmation** (Vision + COCO airplane class; PLAN §1.1a). Most invasive of the lot; tackle after replay harness exists so accuracy can be measured.

**Using the deploy loop:** `bin/deploy` builds, installs, and launches on Noah's paired iPhone. Always `xcodebuild test ...` before deploying when product code changes. The phone has to be unlocked for `devicectl process launch` to succeed; on a Locked error, ask Noah to unlock and retry the launch step. If `xcodebuild` itself can't find the destination (UDID returns "Unable to find a destination"), check `xcrun devicectl list devices` — state `unavailable` means the phone needs USB re-pair or Xcode opened once to re-establish the handshake.
