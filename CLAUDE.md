# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repo. This file is the
**durable "how to work here"** — process, conventions, and the non-obvious traps.
Product state, the backlog, and history live in other files (below); don't mirror
them here, or this file drifts.

## Orient first: strategy, plan, history

- **`STRATEGY.md`** — the product strategy and the source of priorities. North-star
  metric is **catch-confirmation-rate** ("is the catch real?"). The approach is
  **make the catch real first, then make it a game**: Bet A — the *Real-catch
  engine* (trustworthy ID) — is the foundation; Bet B — *Collection &
  progression* — is why people return; then *Social & sharing* and the *Backend &
  data platform*. Work is organized under those four tracks. **Not doing** (don't
  propose these): monetization, Android, a web app.
- **`PLAN.md`** — architectural decisions (§1), tech stack (§2), phased roadmap
  (§3), risks (§5), open questions (§6), repo layout (§8), and **§9 — the canonical
  ranked backlog + current status.** When you need "what's next" or "what just
  shipped," read §9, not this file.
- **`CHANGELOG.md`** — per-round history, newest first.

There is **no `Current state` block in this file** — status lives in PLAN §9 +
CHANGELOG + `git log`. Read PLAN/STRATEGY before proposing anything structural or
reprioritizing work.

## Working model

- **Solo developer (Noah), no prior iOS experience.** Claude writes the code; Noah
  runs it on his iPhone 16 (iOS 26.x), field-tests, and reports back. He's learning
  iOS in parallel with shipping.
- **Explain-as-we-go.** When you introduce a Swift / SwiftUI / iOS pattern Noah
  hasn't seen, narrate it in the commit message or an inline comment.
- **Simplest viable iOS choice at every fork:** SwiftUI over UIKit, SwiftData over
  Core Data, Apple-native over third-party, no CocoaPods/SPM deps yet.
- **Field-test location varies.** Berkeley/Oakland is the home base (dense SFO/OAK
  ADS-B incl. adsb.lol MLAT — GA, helis, some military appear), but Noah also tests
  while travelling (e.g. Bali). Don't assume a US location.

## Build, run, deploy

- **`bin/deploy [--no-build] [--no-launch] [--dry-run]`** (default) — builds via
  `xcodebuild`, installs via `xcrun devicectl`, launches on Noah's paired iPhone
  wirelessly. UDID/scheme/paths in `tools/deploy/config.sh` (override via gitignored
  `config.local.sh`). Wireless pairing must be active (`xcrun devicectl list
  devices`). There is **no CI on deploys** — run the tests first when touching
  testable code.
- **Manual:** Xcode `⌘R` against the connected iPhone (for the debugger / live
  `os_log` console).
- The **iOS Simulator can't provide GPS, compass, or camera** — the iPhone is
  required for any runtime / field testing.
- `bin/log-start` / `bin/log-tail` stream the device syslog via `idevicesyslog`
  — that captures system-emitted lines *about* the app, but **not** the app's own
  `os_log` output (libimobiledevice doesn't expose `os_trace_relay`). For app
  logs, use Xcode's Console / `os_log` viewer.

**Failure modes that need Noah, not a retry:**
- `devicectl install` fails ("developer disk image could not be mounted") → unlock
  the phone, re-pair via USB, or open Xcode once to mount the DDI.
- `devicectl process launch` returns Locked → phone must be unlocked; ask, then
  retry the launch step.
- `xcodebuild` can't find the destination → check `devicectl list devices`;
  `unavailable` means USB re-pair or open Xcode once.

## Tests

Swift Testing (`@Test`, `#expect`, `@Suite`) — **not XCTest** — in
`ios/Tailspot/TailspotTests/`. (`TailspotUITests/` is slow template scaffolding,
not part of the workflow.) Run after substantive changes, and always before
committing/deploying when touching Geo, Aircraft decoding, `ADSBManager`, the
backend source client, or anything they depend on:

```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

First run ~3 min (sim cold-boot); cached ~30–60 s. Browse `TailspotTests/` for
coverage — inline inventories drift. **`ADSBManager.init(source: ADSBSource =
TailspotBackendClient())`** has a defaulted param so production uses the real
backend and tests inject a fixture; `ContentView`'s `@StateObject private var adsb
= ADSBManager()` depends on the no-arg default — don't break that shape.

## Workflow: branch → PR → merge → ship

`main` is the **enforced, always-green integration line** — branch protection
blocks direct pushes (admins included) and requires the green **Unit tests**
GitHub Actions check. **Shipping to TestFlight is a separate, manual step and
Noah's call only.** Canonical process: `CONTRIBUTING.md`.

- Flow: branch → field-test with `bin/deploy` → PR → squash-merge → lands on `main`
  (does **not** ship). Autonomous commit + `bin/deploy` + merges on green CI are
  fine; **only Noah triggers the TestFlight build** (App Store Connect / Xcode →
  Start Build, batching everything since the last build).
- **Build numbers auto-bump in CI** (`ci_scripts/ci_pre_xcodebuild.sh`). Leave
  `CURRENT_PROJECT_VERSION` at `1` in `project.pbxproj`.
- **Keep the same `MARKETING_VERSION` by default; let the build number increment**
  (App Review clears builds under an approved version string faster). Bump the
  version only for major changes worth flagging to testers.
- **SwiftData migrations stay lightweight/additive** (new optional fields with
  defaults). Testers have catches on-device — a breaking schema change loses them.
  The Hangar is **local-only** (no sync, photos not uploaded); reinstall loses it,
  so warn before any delete/reinstall test.
- **Don't force-push to `main` without Noah's explicit OK** (e.g. a leak needing
  history rewrite — surface the trade-offs and let him decide).
- After a TestFlight build, check App Store Connect → Crashes. Testers paste the
  version+build from Settings' tap-to-copy footer.

### Doc-staleness Stop hook

`.claude/settings.json` registers a `Stop` hook (`bin/doc-staleness-check`): if
there are unpushed commits on `main` and **none touched `CLAUDE.md` or `PLAN.md`**,
it blocks the turn and asks for a doc refresh. In this repo's model the live status
lives in **PLAN §9** (prior rounds in `CHANGELOG.md`), so finishing a round means
updating **PLAN §9** — which satisfies the hook. Update *this* file only when
*durable guidance* changes. (`.claude/settings.json` is gitignored; to make the
hook follow the repo, `!`-allow it in `.gitignore` and commit.)

## Secrets: PostHog key only

The app ships **no ADS-B secret.** OpenSky (the only credentialed source) and the
synthetic mock source were both removed in the 2026-06-21 cutover; ADS-B comes
solely from the Tailspot backend (`api.tailspot.app`), which needs no per-app
secret. The one build-time secret is the **optional** PostHog analytics key in
gitignored `ios/Tailspot/Tailspot.secrets.xcconfig` (`POSTHOG_API_KEY`); when
absent, `Analytics.swift` no-ops. It's a write-only anonymous key — baking it into
the binary is acceptable.

**Leak hygiene still applies** (two real leaks in this repo's history, both
OpenSky). Inspect `git diff --cached` before every commit; secrets belong only in
the gitignored secrets file — never in `.swift`, plists, commit messages, or a
staged secrets file. `Tailspot.xcscheme` is the **only** committed shared scheme
(`.gitignore` allows exactly it) — review before `git add ios/`.

## iOS conventions & load-bearing gotchas

The traps that cause real bugs. For subsystem internals (replay recorder/analyzer,
Hangar grouping, lock-on engine, metadata cache, camera zoom/tap-to-ID), read the
source + each one's focused test file — they're not restated here.

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
  Genuinely-visible-but-filtered planes are reachable via **tap-to-reveal**
  (`revealedIcao`: a tap pins + force-locks the single nearest in-data plane when
  `shouldTapReveal` says so — reason `filtered` (hidden by the band) **or**
  `off-frame` (a visible-tier plane projected off-screen, usually a compass/heading
  error; DAL972, 2026-07-11); `grounded` never reveals). **Don't loosen the ambient
  filter to chase one** — it resurfaces the MLAT clutter the precision lean kills
  (see the `FieldReplays` regression).
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
  re-tiering corrects old catches on read, no migration), and a **fully-nil route**
  heals via `CatchBackfill`'s per-callsign `GET /v1/routes` lookup (2026-07-04 —
  current filing, best-effort like operatorName; a one-sided as-observed route is
  moment-data and is never touched).
- **Permission strings** (`NSCameraUsageDescription`,
  `NSLocationWhenInUseUsageDescription`) live in the target's **Info** tab in
  Xcode, not in any tracked source file. Adding one is a **manual Xcode step Claude
  can't do** — flag it explicitly when needed.
- **Xcode 16 synchronized folders:** any `*.swift` dropped into
  `ios/Tailspot/Tailspot/` is auto-added to the project — no "Add Files" step.

## Architectural baseline (settled — see PLAN §1)

- **Identification is geometric, not visual** — GPS + true-north heading + camera
  elevation correlated against ADS-B positions; not ML object detection. *Visual
  confirmation* (bundled YOLOX detector) is live **only** to snap the reticle /
  catch-photo bracket onto the actual plane image and feed the catch-time gates
  (L2 sky gate enforcing; L4 detector gate in shadow) — never to identify. PLAN
  §1.1a / §9.
- **The Tailspot backend is the sole ADS-B provider** (`api.tailspot.app`,
  adsb.lol + MLAT), abstracted behind `ADSBSource` so adding/swapping a provider is
  one file.
- **Disambiguation is a v1 design choice:** render a label for every candidate in
  the angular cone; the user taps one.
- **Photos:** commissioned illustrated cards (type × livery) to sidestep licensing
  — but the *medium itself is reopened* (illustrated vs. real photos vs. other; see
  STRATEGY's Collection track / PLAN §6.3). Decide the medium before any
  commissioning pipeline.

**Design prototype:** the canvas handoff lives in `design/` (HTML/JSX, reference
only — recreate in SwiftUI, don't port the JSX). Open with `python3 -m
http.server 4173 --directory design && open http://127.0.0.1:4173/`.
