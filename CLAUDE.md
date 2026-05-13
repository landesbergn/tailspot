# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, Phase 0 main next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

## Current state (as of session ending 2026-05-07)

**Friday POC milestone (§3.0a in PLAN.md): DELIVERED.** Field-tested in Berkeley with real planes; labels land on or near actual aircraft. Beyond the original POC scope, the following also ships:

- Live/Mock ADS-B toggle (tap the ADSB status row to flip between OpenSky and synthetic data for couch-testing). 5 hand-picked mock aircraft at fixed bearings/distances/altitudes.
- AR cyan reticle box per aircraft, with compact label (callsign / FL / km) below.
- Tap a reticle → `AircraftDetailView` sheet with every field we have (units: ft primary / m parens for altitude; mph primary / kt parens for speed).
- Forward-extrapolation of ADS-B positions to "now" using each aircraft's track + velocity.
- 1 Hz re-annotation loop in `ADSBManager` so reticles glide smoothly between 20 s network fetches.
- Visibility filter: AR labels only appear for aircraft above the horizon AND within 100 km slant distance. Bottom list is unfiltered.
- OAuth2 client-credentials auth against OpenSky (registered tier = 4000 credits/day vs 400 anonymous). 429-aware exponential backoff.
- 44 unit tests in `TailspotTests/` covering geometry, OpenSky decoding (incl. FailableDecodable lossy behavior), annotation, sort order, error handling, extrapolation, visibility predicate, screen projection.

**Deliberately not yet built:** catch flow, collection / hangar, persistence (SwiftData), backend, ARKit drift correction, achievements, scoring, visual confirmation (CV/ML on the camera feed), aircraft type lookup, origin/destination route info, replay harness. See PLAN.md §3.0b for the prioritized backlog. Don't try to "fix" what isn't built.

## Working model

- Solo developer (Noah) with no prior iOS experience. Claude writes code; Noah runs it on his iPhone 16 (iOS 26.3.1) and reports back.
- Field-test location: Berkeley/Oakland CA — under SFO/OAK approach corridors, dense ADS-B coverage. OpenSky free-tier MLAT is excluded, so most small GA, helicopters, and military traffic are invisible. Expect this.
- Preference: **explain-as-we-go.** When introducing a Swift / SwiftUI / iOS pattern Noah hasn't seen, narrate it in the commit message or inline comments. He is learning iOS in parallel with shipping.
- Pick the simplest viable iOS choice at every fork: SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods/SPM deps yet.

## Build and run

The iOS app is built and run from Xcode (`⌘R` on Noah's machine) on a physical iPhone. Claude does not run device builds; Noah does. There are no scripts and no CI.

The iOS Simulator cannot provide real GPS, compass, or camera, so a physical device is required for runtime testing of this app.

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

The current suite (44 tests) covers:
- `GeoTests`: distance, bearing (cardinal + 0/360 sweep), elevation, project round-trip, **screenPosition** (target straight ahead → center, out-of-FOV → nil, 0/360° wraparound from high & low headings, elevation above center).
- `AircraftDecodingTests`: full positional-JSON decode, null-position throws, FailableDecodable swallows bad entries, callsign trim, geo-vs-baro altitude precedence, all-altitudes-null → 0.
- `ADSBManagerTests`: annotation correctness, on-ground filtering, sort-by-slant-distance, error → `lastError` without crashing, success clears previous error, `lastFetched` timestamp, mock-source integration produces 5 aircraft, rate-limit error surfaces as backoff message, forward-extrapolation (moves along track / no-ops when timestamp/velocity missing / age-too-large), visibility predicate (above-horizon-and-close, below horizon, exactly-horizon, too-far, edge-of-range).

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

`ObservedAircraft.isLikelyVisibleToObserver` (`elevationDeg > 0 && slantDistanceMeters < 100_000`) gates AR-overlay rendering in `ContentView`. The bottom list does NOT filter — it's the unfiltered reference / debug view. If a user reports "missing plane labels," check whether the plane is below horizon or past 100 km first; that's the filter doing its job, not a bug.

### CMMotion / CLLocation / AVCapture concurrency

- Sensor wrappers (`LocationManager`, `MotionManager`) are `ObservableObject` classes with `@Published` properties; owned by a SwiftUI view via `@StateObject`.
- A file that uses `@Published` / `ObservableObject` but does **not** `import SwiftUI` must `import Combine` explicitly — SwiftUI re-exports Combine but pure model files don't get it transitively.
- All `@Published` mutations must happen on the main thread. Background callbacks (CMMotion queue, AVCapture queue, URLSession completion) hop via `DispatchQueue.main.async` before mutating state. `ADSBManager` sidesteps this with `@MainActor` on the class.
- Camera (`AVCaptureSession`) configuration and `startRunning` run on a dedicated serial `DispatchQueue` — never on main.
- The motion-manager reference frame is `.xArbitraryZVertical` (gravity-aligned only). True-north alignment comes from `CLLocationManager`'s heading. Revisit when ARKit lands.

### OpenSky OAuth token caching

`OpenSkyClient` uses `OSAllocatedUnfairLock<CachedToken?>` for its token cache so the class can be `Sendable` without an `actor`. Tokens refresh when within 30 s of expiry. Don't replace this with an actor unless you also rework the `ADSBSource` protocol's isolation.

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

Noah queued **aircraft type lookup** as the next session's first piece. See PLAN.md §3.0b #3 — fetch metadata from OpenSky's `/metadata/aircraft/icao/{icao24}` per unique ICAO seen, cache, surface in `AircraftDetailView` (currently shows `—`) and optionally on the compact label. ~45–60 min.
