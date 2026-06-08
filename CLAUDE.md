# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, design-canvas port ✅, TestFlight v0 shipping to internal testers ✅, backend next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

Only the **live** `Current state` block lives below; prior per-session rounds are in `CHANGELOG.md` (newest first). When you finish a round, move the previous `Current state` block to the top of `CHANGELOG.md` and write the new one here — don't stack them in this file.

## Current state (as of session ending 2026-06-07 [aircraft-identity overhaul: classification, FAA fallback])

**Shipping as TestFlight v0.2.0.** Built on the 2026-06-06 naming/catch-detail
work (ICAO DOC 8643 table, `AircraftNaming`, Catch schema +5 fields, `CatchDetailView`
AIRFRAME panel + delete). Field testing and a full data audit exposed a second
layer of problems: the DOC 8643 table had messy manufacturer strings, `AircraftType`
classification was broken for rotorcraft and GA, OpenSky 404s for US aircraft
left entire class of airframes unresolved, and the replay recorder was silently
recording only the filtered-visible subset (defeating the ReplayAnalyzer when
visibility filtered everything out). All fixed. Architecture principle established:
**every derived property (canonical name + aircraft type) resolves from the ICAO
typecode through authoritative reference data — DOC 8643 for names, DOC 8643
description/engine/wake for type — never from OpenSky's free-text fields; a
collection-wide background backfill (`CatchBackfill`) ensures old catches carry
a typecode.** Key files: `AircraftNaming.swift`, `CatchBackfill.swift`,
`IcaoRegistry.swift`, `FAARegistry.swift`, `ReverseGeocode.swift`; bundled
resources `AircraftTypes.json`, `faa-aircraft.bin`, `faa-models.json`; generators
`tools/generate-aircraft-types.py`, `tools/generate-faa-registry.py`; reference
data `tools/data/faa_aircraft_characteristics.xlsx`.

1. **Canonical-manufacturer normalization + FAA cross-check in the generator.**
   `tools/generate-aircraft-types.py` now normalizes messy OpenSky/DOC 8643 make
   strings to clean brand names ("Gulfstream Aerospace"→"Gulfstream",
   "Canadair"→"Bombardier"), strips doubled-brand model prefixes, and cross-checks
   ~5 military/conversion mis-picks against the committed FAA Aircraft
   Characteristics Database (`tools/data/faa_aircraft_characteristics.xlsx`). FAA
   wingspan/length data carried into ~92 entries as bonus metadata. `OVERRIDES`
   table extended accordingly; regeneration is idempotent.

2. **Airbus engine-variant collapse + Boeing 737 MAX short-codes in
   `AircraftNaming.cleanedModel`.** Engine-suffix variants collapse to family
   names ("A380-842"→"A380-800", "A321-271NX"→"A321neo"). Bare OpenSky model
   strings "737-8" / "737-9" (no typecode, no suffix) collapse to "737 MAX 8" /
   "737 MAX 9" — converging the no-typecode catch path with the typecode path.
   "737-800" NG stays distinct. Convergence pinned by parameterized tests in
   `AircraftNamingTests`.

3. **`AircraftType` classified from the typecode via DOC 8643 authoritative data.**
   `AircraftTypes.json` now carries a `type` field per entry (derived from
   DOC 8643 description + engine + wake categories). `Catch.resolvedType` reads it
   via `IcaoRegistry`. This fixes the core misclassification: helicopters (R44,
   EC35) and light GA (Cessna 172) were landing in `narrow` because the string
   classifier had no rotorcraft awareness and defaulted unknowns to `narrow`. New
   default is `.ga`; the string classifier (no-typecode fallback only) gained
   helicopter awareness. Type distribution across 2,612 entries: ga 2227,
   narrow 223, wide 61, regional 40, biz 39, mil 22. `AircraftTypeResolutionTests`
   pins every type bucket with representative icao24s.

4. **Collection-wide typecode backfill (`CatchBackfill.swift`).** On Hangar open,
   `CatchBackfill.backfillIfNeeded(in:)` fetches a typecode for every catch
   missing one (one OpenSky call per icao24, cached, fill-only-if-nil, runs in a
   background Task). Ensures the entire collection resolves through the clean table,
   not just newly caught planes. `CatchBackfillTests` covers the fill/skip
   semantics and the 404-fallback path.

5. **Sets model list sorts alphabetically** (was tail-count descending). Unknown
   bucket still forced to last. Fixes the jarring reorder on each catch.

6. **Replay recorder fix.** `ReplayRecorder.recordReplayTick` was silently recording
   only the visibility-filtered subset (`adsb.observed` post-filter), so when the
   filter rejected everything (a contrail cruising past the distance cap) the JSONL
   tick carried zero aircraft — defeating the ReplayAnalyzer's purpose. Now records
   the full annotated set before filtering. Found while diagnosing a contrail that
   was filtered as "no aircraft in range" and produced an empty replay.

7. **FAA-registry fallback for US aircraft OpenSky 404s (`IcaoRegistry.swift`,
   `FAARegistry.swift`).** US icao24↔N-number is a deterministic bit-level
   encoding; a bundled FAA snapshot (313,376 US aircraft, ~3.5 MB, binary-searched
   via `faa-aircraft.bin` + model table `faa-models.json`, generated by
   `tools/generate-faa-registry.py` from the public FAA Civil Aircraft Registry)
   supplies make/model/type when OpenSky has no record. Verified: Cirrus SR20
   (a9eefa), Embraer E175 (a8d71c), Pilatus PC-12 (a00965) recover; foreign tails
   (Korean 71c575) correctly stay unknown. Community aggregators (hexdb.io, adsbdb)
   404 the same airframes — shared OpenSky lineage, so they don't help. FAA fallback
   is wired into `CatchBackfill` as the OpenSky-404 path. `FAARegistryTests` and
   `IcaoRegistryTests` pin the round-trip encoding + lookup.

8. **ADS-B metadata sources research doc.** `docs/superpowers/research/2026-06-07-adsb-metadata-sources.md`
   documents when/how to move off OpenSky for metadata. Key findings: the baked
   single credential makes the 4,000/day quota a global bucket (exhausts at ~4
   simultaneous spotters); OpenSky terms are research-only (commercial use
   prohibited); adsb.lol (ODbL) is the one MLAT source whose license permits a
   distributed app; the planned backend is the keystone next step (fixes credential
   exhaustion + MLAT licensing + stale bundle at once). **NOT being built now —
   deferred to the backend round.** See the research doc for provider comparison
   table and decision matrix.

**Tests: 244 → 287, 0 failures.** New suites: `AircraftNamingTests` (extended),
`AircraftTypeResolutionTests`, `CatchBackfillTests`, `IcaoRegistryTests`,
`FAARegistryTests`, `ReverseGeocodeTests` (extended).

**`MARKETING_VERSION` 0.1.4 → 0.2.0** (major user-visible surface: standardized
aircraft identity + authoritative classification + catch-detail overhaul).

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
2. If any exist and **none** of them touched `CLAUDE.md` or `PLAN.md`, emits `{"decision":"block","reason":"..."}` so the turn doesn't end — Claude is asked to refresh the docs (`Current state` in CLAUDE.md and §9 in PLAN.md) and push before stopping. When refreshing, replace the live `Current state` block and move the old one to `CHANGELOG.md` (see "Read PLAN.md first") rather than appending a new block.
3. Otherwise silent.

The point: a session can be cleared at any time and the next agent reads docs that match what's on disk. The script self-locates via `git rev-parse --show-toplevel`, so it works regardless of the cwd the hook fires from. `.claude/settings.json` itself is gitignored (everything under `.claude/` is) — to make this hook follow the repo to other machines, add `!.claude/settings.json` to `.gitignore` and commit.

### OpenSky credentials

For LIVE mode the app authenticates via OAuth2 client-credentials. OpenSky's anonymous tier (400 credits/day) is exhausted in ~1.3 hr at the 20 s default poll rate; the registered tier (4000 credits/day) is comfortable for testing.

**Canonical path (post-TestFlight):** edit `ios/Tailspot/Tailspot.secrets.xcconfig` (gitignored) with your OpenSky `client_id` + `client_secret`. The committed `Tailspot.xcconfig` `#include?`s it, which feeds Info.plist via `$(OPENSKY_CLIENT_ID)` substitution; `OpenSkyClient.init` reads them from `Bundle.main.infoDictionary` at runtime. Same file Xcode Cloud reads (via `ci_post_clone.sh` writing it from workflow env vars).

`OpenSkyClient.init`'s resolution order is **explicit → env vars → Bundle**. Env vars from the user-only xcscheme still work, but **prefer the xcconfig path**: a stale xcscheme value will silently win over a fresh secrets file and waste a debugging hour (this happened once already this session). Single source of truth = the xcconfig.

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

The current suite is **287 tests, 0 failures** across `TailspotTests/`, broadly:

- **Geometry / projection** — `GeoTests`, `ClosestTargetTests` (FOV/zoom-aware lock zone).
- **OpenSky wire format** — `AircraftDecodingTests`, `AircraftMetadataDecodingTests`.
- **Manager + cache** — `ADSBManagerTests` (annotation, sort, errors, extrapolation, visibility predicate, rate-limit backoff), `ADSBManagerMetadataTests`, `MetadataCacheTests`.
- **Catch + Hangar** — `CatchTests` (SwiftData insert/fetch, classifier-driven rarity/type snapshot, duplicate-rejection via `Catch.exists`), `HangarGroupingTests`, `ModelSlot` resolution.
- **Lock-on** — `LockOnEngineTests` covers the post-T4 3-state machine (idle / locked / sticky), `forceLock`, `unpin`.
- **Replay** — `ReplayRecorderTests`, `ReplayJSONLTests` (tapPin/unpin events), `ReplayAnalyzerTests`.
- **Game system** — `GameSystemEnumTests`, `AircraftClassifierTests` (curated rule table, operator any-of gate, legacy-token regression).
- **Photos + brand** — `PlanespottersClientTests`, `BrandTests`.
- **Multi-catch** — `MultiCatchComboTests` (combo-multiplier ladder).
- **Catch photo** — `CatchPhotoComposerTests` (aspect-fill transform + bracket compose).
- **Trophies** — `TrophiesTests`.
- **Naming + classification** — `AircraftNamingTests` (DOC 8643 table sweeps, Boeing customer-code fallback, engine-variant collapse, 737 MAX short-codes), `AircraftTypeResolutionTests` (typecode→type for every DOC 8643 bucket including rotorcraft + GA).
- **Geocoding** — `ReverseGeocodeTests` (pure place-name formatting for every placemark shape).
- **Registry + FAA fallback** — `IcaoRegistryTests` (icao24 encoding round-trip, lookup correctness), `FAARegistryTests` (US registry binary-search, foreign-tail non-match, fallback-to-nil for unknown).
- **Backfill** — `CatchBackfillTests` (fill-only-if-nil semantics, OpenSky-404 FAA fallback path, caching).

Look in `TailspotTests/` directly for the per-`@Test` enumeration — keeping it inline here drifted out of date and is no longer worth maintaining.

`ADSBManager.init(liveSource:mockSource:)` has defaulted params so production uses real sources and tests substitute a `FixedSource` fixture. **Do not break this default-init shape** — `ContentView`'s `@StateObject private var adsb = ADSBManager()` depends on it.

## Credentials: xcconfig is canonical, scheme env vars are a footgun

**Canonical path (post-TestFlight):** `ios/Tailspot/Tailspot.secrets.xcconfig` (gitignored) holds the real OpenSky values; the committed `Tailspot.xcconfig` `#include?`s it; Info.plist substitutes `$(OPENSKY_CLIENT_ID)` / `$(OPENSKY_CLIENT_SECRET)`; `OpenSkyClient.init` reads them from `Bundle.main.infoDictionary` at runtime. Same file Xcode Cloud writes via `ci_post_clone.sh` from workflow env vars. **One source of truth.**

**The xcscheme path still works but is deprecated** — `OpenSkyClient.init` checks `ProcessInfo.environment` after explicit creds but before the bundle. The historical pattern was to add env vars to a user-only xcscheme. **Don't.** A stale xcscheme value silently wins over a fresh secrets file (this bit us once already this session — fresh xcconfig creds didn't work because the user had an old xcscheme value still set from earlier). If you must use the scheme path for dev, keep one source populated, not both.

Rules that still apply:

1. **The committed shared scheme is bare** — no env vars. `.gitignore` allows exactly one shared scheme file (`Tailspot.xcscheme`) via a `!` exception so `xcodebuild` works on fresh clones; every other `*.xcscheme` is ignored, but **gitignore does NOT protect already-tracked files**. If you ever do touch the shared scheme, **always `git diff` the staged set before committing**. Look for `OPENSKY_CLIENT_SECRET`, `EnvironmentVariable`, or `paste-your-` (the placeholder text in `Tailspot.secrets.example.xcconfig` — finding this in a diff means you staged the example template, not the real secrets file, which is fine; finding the real secret means abort).
2. **If a secret leaks**: tell Noah immediately, rotate on OpenSky's API console (don't wait), update `Tailspot.secrets.xcconfig` locally, push a new build to Xcode Cloud (which picks up the new env vars). Both prior leaks in this repo's history are still recoverable from GitHub's dangling-objects cache; rotation is the actual mitigation, not history rewriting.
3. **Rotation warns testers.** The secret is baked into shipped binaries; rotating it OAuth-fails every old TestFlight build until the tester updates. Communicate ahead of any rotation (see Workflow notes).

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

`CatchDetailView` is a **frozen-moment view with a narrow backfill
exception** (spec 2026-06-06): on open it may fill **nil-only** fields
that are properties of the airframe, not the moment — registration,
typecode, manufacturer, model, placeName, and operatorName (the last
is best-effort *current* operator, not as-flown; documented in code).
Recorded values are never overwritten, and moment-data (altitude,
speed, distance, date) is never backfilled. A catch's recorded facts
still must not be retroactively rewritten. v0 has **no dedupe** (each tap = each row in its section). **Delete** exists in two places — the red trash pill in `CatchDetailView` and a Hangar swipe-delete context menu — both require confirmation and both delete photo files alongside the SwiftData row. If catches grow to hundreds, the per-body re-grouping in `HangarView.groupedList` will want memoization.

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

**Now that TestFlight is shipping to real testers** (since 2026-05-26), `main` is a tester-facing branch: any push there can be picked up by the next Xcode Cloud build and installed on a tester's phone. The rules below changed accordingly.

- **`main` is shippable.** Don't push WIP. For changes that take more than a day, work on a feature branch and merge to main only when the change is tested locally. Single-commit fixes can go to main if tested first.
- **Build numbers auto-bump in CI.** `ios/Tailspot/ci_scripts/ci_pre_xcodebuild.sh` rewrites `CURRENT_PROJECT_VERSION` to match `CI_BUILD_NUMBER` for every Xcode Cloud archive. **Don't touch `CURRENT_PROJECT_VERSION` in `project.pbxproj` manually** — the committed value stays at `1`; CI changes it per-build.
- **Bump `MARKETING_VERSION` deliberately.** Edit `project.pbxproj` to go `0.1.0 → 0.1.1` for a bugfix batch, `0.2.0` for a new feature surface, etc. Bump this for any TestFlight build that introduces user-visible changes you want testers to notice in the version string. Build number stays auto-incrementing.
- **Run tests before pushing.** `xcodebuild test ...` (see Tests section). When touching Geo / Aircraft / ADSBManager / OpenSky / Mock / their tests, a green local run is non-negotiable — failing tests waste a 5-15 minute CI cycle.
- **Inspect `git diff --cached` before every commit** for `OPENSKY`, `client_secret`, or `EnvironmentVariable` strings. If you see them, abort and fix the scheme before committing. Two leaks in this repo's history already.
- **SwiftData migrations stay lightweight.** Once testers have catches, every model change must be additive (new optional fields with defaults). Breaking schema changes lose tester data. If you ever need a breaking change, bump model version explicitly with a custom migration.
- **Don't rotate OpenSky creds without warning testers.** The secret is in the shipped binary; rotating it OAuth-fails every old TestFlight build until the tester updates. They'll see "API limit" forever. Communicate ahead of rotations. The real fix is the backend proxy (PLAN.md §1).
- **Watch crash logs.** App Store Connect → Tailspot → TestFlight → Crashes aggregates them from real testers — free diagnostic surface, check after every TestFlight build.
- **Settings → bottom of page shows the version + build, tap to copy.** When a tester reports a bug, ask them to tap the footer in Settings; they paste `Tailspot 0.1.1 (build N)` directly into the report.
- **Don't force-push to `main` without explicit user authorization.** The auto-mode classifier will deny it. If a leak requires history rewriting, surface the request to Noah with the trade-offs spelled out and let him decide.
- **Don't commit credentials in any form** — not in `.swift` files, not in `.xcscheme` files, not in plist values, not in commit messages, not in `Tailspot.secrets.xcconfig` (gitignored, but verify it's not staged before committing).

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

Lower priority: OpenSky secret rotation (#6, demoted per Noah).

**Phase B and Phase C** of the original visual identity (HUD label redesign, Hangar polish, app icon, onboarding) are largely superseded by the design-canvas direction now landing in PLAN §9 #2-#6. Don't relitigate Phase B/C — port the canvas surfaces directly.

**Design source.** The canvas handoff lives in `design/` (HTML/JSX prototype, ~340K). Open with `python3 -m http.server 4173 --directory design && open http://127.0.0.1:4173/`. 33 artboards across 10 sections — splash/brand, onboarding, AR home, AR states, catch flow, detail, hangar, sets, gamification (rarity / types / trophies / trophy-unlock), public surfaces (leaderboard, map, share, public-hangar), profile/settings/notifs. **The prototype is for reference, not for direct porting** — recreate visuals in SwiftUI; don't port the JSX structure.

**Using the deploy loop:** `bin/deploy` builds, installs, and launches on Noah's paired iPhone. Always `xcodebuild test ...` before deploying when product code changes. The phone has to be unlocked for `devicectl process launch` to succeed; on a Locked error, ask Noah to unlock and retry the launch step. If `xcodebuild` itself can't find the destination (UDID returns "Unable to find a destination"), check `xcrun devicectl list devices` — state `unavailable` means the phone needs USB re-pair or Xcode opened once to re-establish the handshake.
