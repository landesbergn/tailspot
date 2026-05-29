# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, the phased roadmap (Friday POC ✅, design-canvas port ✅, TestFlight v0 shipping to internal testers ✅, backend next), risks (including the credential-leak incident), and what's still on the table. Read it before proposing structural changes.

## Current state (as of session ending 2026-05-29 [typography + onboarding shipped])

**Shipping as TestFlight v0.1.2.** Second feature drop today. The
2026-05-27 "first-tester feedback" work that had been sitting in a
local stash on Noah's machine now lands on main. Four UX fixes:

1. **"Reticles" copy dropped.** Two user-visible strings used the
   word (OnboardingFlow permissions step + HangarView empty state).
   Replaced with plainer language ("labels match the plane in view",
   "aim at a plane, then tap to catch it").

2. **Aviation typography — SF Pro + B612 Mono.** SF Pro stays for
   body/UI text (iOS-native); monospace swaps from SF Mono to
   **B612 Mono** (Airbus's open-source cockpit MFD font, SIL OFL 1.1).
   This is where the aviation feel hits hardest — callsigns, ICAO
   codes, headings, badge labels, wordmark. Files at
   `ios/Tailspot/Tailspot/B612Mono-{Regular,Bold,Italic,BoldItalic}.ttf`
   (~530KB total), registered in Info.plist via `UIAppFonts`. All
   137 ad-hoc `.system(... design: .monospaced)` callsites swept to
   `Brand.Font.mono(size:weight:italic:)` (new helper). B612 Mono
   ships in Regular + Bold only; SwiftUI weight requests map
   regular/medium → Regular, semibold/bold/heavy/black → Bold.
   `Brand.Font.wordmark` / `hudCallsign` / `hudData` retained as
   thin aliases over the helper. Process note: the perl sweep
   initially used `[^,]+?` which over-matched across `.system(...)`
   boundaries (regex spanned past `)` and ate `design: .monospaced`
   from a sibling callsite); reverted and re-ran with `[^,)]+?`.
   Document the safer form if doing any similar sweep again.

3. **Permission prompts moved into onboarding step 2.** Previously
   iOS surfaced the camera + location alerts at the end of
   onboarding when ContentView mounted — testers found the gap
   confusing. Now `OnboardingFlow.advance()` triggers
   `requestSystemPermissions()` when leaving the Permissions step,
   firing `AVCaptureDevice.requestAccess(for: .video)` plus
   `LocationManager.requestPermissionAndStart()` via a transient
   `@StateObject` LocationManager. CMMotion needs no prompt and
   stays informational on the row. ContentView still creates its
   own LocationManager later; iOS just doesn't re-prompt because
   auth state is already decided.

4. **Figure-8 calibration step removed from onboarding.** Awkward
   and rarely needed at launch. `totalSteps` dropped to 3 (Welcome
   → Permissions → Handle). The compass-warning badge in the AR
   view still opens `CompassCalibrationSheet` (with the figure-8
   animation) when accuracy genuinely degrades — same in-app
   trigger, just no upfront prompt. `Figure8Animation` struct
   retained for the sheet.

**Tests:** 176 still pass (no behavioral tests touched — the sweep
changed presentation only). Font loading is exercised by the host-
app build that runs before the test suite, so a missing or
unregistered .ttf would break the build.

**External TestFlight remains approved** (since 2026-05-26 Build 18).
v0.1.2 builds auto-approve for external testers via App Store
Connect → TestFlight → External Testing.

**MARKETING_VERSION bumped 0.1.1 → 0.1.2.** CFBundleVersion stays
at 1 locally; Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites per
archive.

**Open follow-ups specific to this round:**
- Field-test the new typography on device. The B612 Mono swap is
  unmissable but its weight mapping (collapses 4 SwiftUI weights
  into 2 physical faces) may look slightly heavier than SF Mono
  did at small sizes. Calibrate if needed.
- The semantic-size patterns (`.system(.body, design: .monospaced)`
  etc.) were converted to fixed sizes (17 / 12 / 11). This loses
  Dynamic Type scaling for those few callsites. Acceptable for v0
  but worth a `Brand.Font.mono(_:weight:)` TextStyle overload if
  Dynamic Type matters later.
- `design/font-explorer.html` — side-by-side font preview built
  during the typography decision. Reference material; remove if
  it gets stale.

## Current state (as of session ending 2026-05-29 [catch-photo bracket overlay + bigger reticles])

**Shipped as TestFlight v0.1.1.** First post-v0 feature drop. Two
landings on main this session, both user-visible to testers.

1. **Catch photos now show which plane you caught.** New
   `CatchPhotoComposer` (pure CG/UIKit, no SwiftUI) decodes the
   captured JPEG, runs the screen→photo pixel transform assuming
   `.resizeAspectFill` (which `CameraPreview` uses), and re-renders
   with the cyan corner-bracket box drawn at the plane's on-screen
   position at capture time. Multi-catch saves one bracket per
   plane on each plane's own photo file.

   The path is: ContentView projects every visible plane to screen
   once per TimelineView frame (`onScreenProjected: [(icao, pos)]`),
   stashes the icao→position map, and threads `screenSize` +
   `positions` through `captureBar` → `captureButton` →
   `performCatch`. At save time the loop looks up `positions[icao]`,
   builds a `CatchPhotoComposer.BracketOverlay`, and calls
   `compose(jpegData:overlay:)`. Fall-through: if compose returns
   nil (bad JPEG, zero-area screen) OR positions misses the icao
   (the plane was on-screen when the button rendered but not in
   the dict at fire time), we save the raw JPEG. No catch is lost.

   `AspectFillTransform` factored out as its own struct so the
   coordinate math is unit-testable without touching UIImage.
   Tests cover same-aspect, wide-photo crops-sides, tall-photo
   crops-top, iPhone 12MP sanity, the compose smoke path, and
   invalid-input fall-throughs (176 tests total — added 7).

2. **Bigger lock-on reticles** for alignment forgiveness. The 56pt
   pinned bracket read tight in field testing: small sensor noise
   or HFOV mis-cal pushed the plane just outside the box. New
   sizes — pinned 140, ambient 96, empty-sky center 200, photo
   overlay 140 (matches pinned so saved photos show the same
   framing). Arm length stays `max(8, boxSize * 0.22)`, so arms
   scale proportionally.

**Tests:** 176 pass (169 baseline + 7 for CatchPhotoComposer).
Reticle bumps don't touch tests — they're presentation constants.

**Doc-staleness hook now guards on main.** `bin/doc-staleness-check`
used to false-fire on feature branches (its check is HEAD-vs-
`origin/main`, which is always ahead on a feature branch even when
that branch is fully pushed to its own remote). Added a one-line
guard: `[ "$current_branch" = "main" ] || exit 0`. Feature-branch
sessions no longer get blocked by the Stop hook — doc updates
land with the merge into main, where the hook still fires.

**MARKETING_VERSION bumped 0.1.0 → 0.1.1** (two configs in
`project.pbxproj`). `CURRENT_PROJECT_VERSION` stays at 1 locally;
Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites it to
`CI_BUILD_NUMBER` per archive.

**Open follow-ups specific to this round:**
- Field-test the new 140pt pinned reticle. If still too tight,
  bump further; if too loose, dial back. The photo-overlay constant
  in `CatchPhotoComposer.bracketScreenBoxSize` must stay in lockstep
  with the live `LockBrackets` size in `ContentView` so saved photos
  match what testers saw.
- The bracket's center is the *predicted* screen position (from
  ADS-B + extrapolation + projection). Eventually the long-term
  fix for "box should land on the actual plane" is CV detection
  (PLAN §9 #3 Vision + COCO airplane class) — let the bracket
  snap to the detected airplane bbox rather than the prediction.
  Until that lands, the bigger box is the cheap forgiveness.

## Current state (as of session ending 2026-05-26 [TestFlight v0 prep])

**TestFlight v0 prep — landed 2026-05-26.** Everything required to
build, sign, and upload a TestFlight build is in place. See
`docs/testflight-handoff.md` for the step-by-step. Highlights:

- **Credentials baked via xcconfig + Info.plist.** Tailspot.xcconfig
  (committed) `#include?`s Tailspot.secrets.xcconfig (gitignored,
  holds real OpenSky values). Build-time substitution flows into
  Info.plist keys `OpenSkyClientID` / `OpenSkyClientSecret`. New
  resolution order in `OpenSkyClient.init`: explicit creds → env
  vars → `Bundle.main.infoDictionary` → nil/anonymous. Env-var path
  preserves Noah's existing dev loop; the bundle path is the only
  one that survives TestFlight / home-screen / `devicectl` launches.
  **Security accepted:** the values are in the shipped binary,
  extractable from any `.ipa`. v0 risk for 1-2 trusted testers;
  backend proxy is the path for wider distribution (PLAN.md §1).
- **Manual `Info.plist`** at `ios/Tailspot/Info.plist` replaces the
  previously-auto-generated one. Adds `ITSAppUsesNonExemptEncryption=false`
  and the custom OpenSky keys. The Tailspot target switched from
  `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_KEY_*` build settings to
  `INFOPLIST_FILE=Info.plist`. The Info.plist sits at the project
  root (outside the synchronized `Tailspot/` folder) so it's not
  bundled as a duplicate resource.
- **Privacy manifest** at `ios/Tailspot/Tailspot/PrivacyInfo.xcprivacy`.
  Declares UserDefaults (`CA92.1`) + FileTimestamp (`0A2A.1`)
  required-reason API usage, and the two data categories we collect
  (precise location + photos — app-functionality only, not linked
  to identity, not tracking). Update when the backend ships.
- **Version + build number scheme.** `MARKETING_VERSION=0.1.0`,
  `CURRENT_PROJECT_VERSION=1`. Bump `CURRENT_PROJECT_VERSION` on
  every TestFlight upload (App Store Connect requires monotonic
  per marketing version); bump `MARKETING_VERSION` on meaningful
  feature drops.
- **App icon.** Programmatically generated 1024×1024 PNGs (3
  luminosity variants — light / dark / tinted) via
  `tools/generate-app-icon.swift`. Cyan→navy gradient + HangarGlyph,
  consistent with brand tokens. Re-run the script to regenerate,
  or replace the PNGs directly in `AppIcon.appiconset/`.
- **xcconfig precedence trick.** `Tailspot.xcconfig` defines
  `OPENSKY_CLIENT_ID =` (empty) as default, then `#include?`s the
  optional secrets file. Last-wins is xcconfig precedence — when
  the secrets file is present its assignments override the empty
  defaults; when missing, the empty defaults stand and Info.plist
  resolves to empty strings (anonymous mode). The `?` on
  `#include?` makes missing-file a no-error condition.

**Tests:** 169 still pass. The credential change is additive (env-var
fallback preserves existing tests that don't touch OpenSky live calls).

**Open follow-ups specific to TestFlight:**
- App Store Connect record creation, signing, Archive + Upload all
  live in Apple UIs — see `docs/testflight-handoff.md`.
- Privacy policy URL needed if/when adding external testers (>10
  beyond your team). Internal testers are sufficient for v0.

**Xcode Cloud (added 2026-05-26):** Apple's CI runs two scripts
checked into `ios/Tailspot/ci_scripts/`:

- `ci_post_clone.sh` materializes `Tailspot.secrets.xcconfig` from
  workflow env vars (`OPENSKY_CLIENT_ID` / `_SECRET`, both marked
  secret in the workflow's Environment Variables). When env vars
  are absent the script no-ops; build runs anonymous.
- `ci_pre_xcodebuild.sh` seds `CURRENT_PROJECT_VERSION` in
  `project.pbxproj` to match Apple's `CI_BUILD_NUMBER` before
  archive. Without this every CI archive shipped with
  `CFBundleVersion=1` and App Store Connect silently dropped
  subsequent uploads as duplicates — Xcode Cloud reported "build
  succeeded" while TestFlight stayed pinned to Build 1 forever.
  Local builds keep the committed value (1); only Xcode Cloud
  rewrites.

**Xcode Cloud setup gotchas that ate hours this session:**
1. Workflow's "Project or Workspace" field defaults to repo root;
   our project is at `ios/Tailspot/Tailspot.xcodeproj` — must be set
   explicitly or builds fail with the misleading "scheme Tailspot
   does not exist" error.
2. Workflow needs a TestFlight distribution **Post-Action**
   ("TestFlight Internal Testing"), separate from the Archive
   action. Without it, the archive succeeds but never reaches
   TestFlight.
3. Don't put trailing whitespace/newlines in env-var values; App
   Store Connect's UI rejects with "invalid value due to invalid
   value" without saying which character offended.

**Post-TestFlight polish landed same day (2026-05-26):**
- App icon swapped from the generated HangarGlyph-on-gradient to
  the B-lockon concept (cyan AR corner brackets framing a white
  airplane symbol on a navy gradient — references the AR mechanic).
  Generator: `tools/generate-icon-options.swift`. Picked variant's
  three PNGs (light/dark/tinted) committed in `AppIcon.appiconset/`;
  `tools/icon-options/` is gitignored.
- `ComingSoonPill` + `ComingSoonBanner` components (`ComingSoonPill.swift`).
  Applied to Leaderboard, Public Hangar, and Notifications screens
  with amber `hammer.fill` glyph so testers know these are mocks
  pending backend.
- Debug wrench toggle in `ContentView` wrapped in `#if DEBUG`.
  TestFlight (Release) builds show no wrench; local Xcode dev
  (Debug) keeps it.
- 8 Swift 6 prep warnings cleared (Log isolation, PhotoCaptureDelegate
  nonisolated, HangarGrouping no longer claims nonisolated when it
  touches `@MainActor Catch` state, MultiCatchReveal @ViewBuilder
  drop, Trophies closure @Sendable).
- Hangar glyph swapped to SF Symbol `airplane.path.dotted` (plane
  with dashed trail). Replaces the hand-drawn peaked-pentagon Shape
  in `HangarGlyph.swift`. Callers unchanged — same `HangarGlyph(tint:)`
  API, `lineWidth` retained as unused param for source compat.
- Settings → bottom of page renders `Tailspot 0.1.0 (build N) · tap
  to copy`. Tap copies the version line to the clipboard with a
  soft haptic; testers paste it verbatim into bug reports.

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

The current suite is **169 tests** across `TailspotTests/`, broadly:

- **Geometry / projection** — `GeoTests`, `ClosestTargetTests` (FOV/zoom-aware lock zone).
- **OpenSky wire format** — `AircraftDecodingTests`, `AircraftMetadataDecodingTests`.
- **Manager + cache** — `ADSBManagerTests` (annotation, sort, errors, extrapolation, visibility predicate, rate-limit backoff), `ADSBManagerMetadataTests`, `MetadataCacheTests`.
- **Catch + Hangar** — `CatchTests` (SwiftData insert/fetch, classifier-driven rarity/type snapshot, duplicate-rejection via `Catch.exists`), `HangarGroupingTests`, `ModelSlot` resolution.
- **Lock-on** — `LockOnEngineTests` covers the post-T4 3-state machine (idle / locked / sticky), `forceLock`, `unpin`.
- **Replay** — `ReplayRecorderTests`, `ReplayJSONLTests` (tapPin/unpin events), `ReplayAnalyzerTests`.
- **Game system** — `GameSystemEnumTests`, `AircraftClassifierTests` (curated rule table, operator any-of gate, legacy-token regression).
- **Photos + brand** — `PlanespottersClientTests`, `BrandColorHexTests`.
- **Multi-catch** — `MultiCatchComboTests` (combo-multiplier ladder).

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

`CatchDetailView` is a **read-only snapshot** — no live re-fetch of metadata or position. A catch is a frozen moment; tomorrow's metadata/distance must not retroactively rewrite it. v0 has **no dedupe** (each tap = each row in its section) and **no delete UI**; both are deferred. If catches grow to hundreds, the per-body re-grouping in `HangarView.groupedList` will want memoization.

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
