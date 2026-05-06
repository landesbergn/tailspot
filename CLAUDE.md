# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read PLAN.md first

`PLAN.md` is the single source of truth for product scope, architectural decisions, phased roadmap, risks, and unresolved open questions. The repo is at a very early stage and will be confusing without it.

## Current state

- Phase: **POC Day 1 of 3** (Friday POC milestone, see PLAN.md §3.0a).
- App builds and runs on a physical iPhone, showing a camera background with a live overlay of GPS, true-north heading, and device pitch/roll. Nothing else exists yet.
- Deliberately not yet present: ADS-B integration, "catch" flow, collection / hangar, persistence, backend, ARKit drift correction, achievements, scoring. Don't try to "fix" what isn't built — see PLAN.md §3 for the phase order.

## Working model

- Solo developer (Noah) with no prior iOS experience. Claude writes the code; Noah runs it on his iPhone 16 (iOS 26.3.1) and reports back.
- Field-test location: Berkeley/Oakland CA — under SFO/OAK approach corridors, dense ADS-B coverage.
- Preference is **explain-as-we-go**: when introducing a Swift / SwiftUI / iOS pattern Noah hasn't seen, narrate it in the commit message or inline comments. He is learning iOS in parallel with shipping.
- Pick the simplest viable iOS choice at every fork: SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods/SPM deps yet.

## Build and run

The iOS app is built and run from Xcode (`⌘R` on Noah's machine). Claude does not run builds; Noah does. There are no scripts and no CI.

For a code-only sanity check that things compile, `xcodebuild -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` is plausible but has not been used in this repo — prefer asking Noah to ⌘R and report any errors.

The iOS Simulator cannot provide real GPS, compass, or camera, so a physical device is required for any meaningful testing of this app.

## Repository layout

- `PLAN.md` — full product + technical plan
- `ios/Tailspot/` — Xcode project. Uses **Xcode 16 synchronized folders**: any `*.swift` dropped into `ios/Tailspot/Tailspot/` is automatically added to the Xcode project. There is no manual "Add Files to Project" step.
- `backend/`, `shared/`, `tools/replay-harness/` — planned for later phases (see PLAN.md §8); not created yet.

## Architectural baseline

These decisions are settled (PLAN.md §1) and shouldn't be relitigated without a real reason:

- **Plane identification is geometric, not visual.** Inputs are GPS + true-north heading + pitch + ADS-B aircraft positions; the ID is angular correlation within a tolerance, not ML/CoreML object detection. ARKit's role (later) is drift correction and a stable reticle, not recognition.
- **Backend from day 1**, not optional — needed for ADS-B caching, anti-cheat, sync, leaderboards. Not yet built.
- **Disambiguation is a v1 design problem**, not polish: when multiple aircraft fall within the angular tolerance, render an overlay tag for *each* and let the user tap one. Don't design a single-target "lock-on" interaction.
- **OpenSky free tier** is the v1 ADS-B provider — Tailspot is free with no monetization, so OpenSky's non-commercial terms fit. Build the data fetcher behind a swap-able provider interface anyway.
- **Photos:** commissioned illustrated cards (aircraft type × airline livery), not real photos. Sidesteps licensing.

## iOS code conventions in this repo

- Sensor wrappers (`LocationManager`, `MotionManager`) are `ObservableObject` classes exposing `@Published` properties; owned by a SwiftUI view via `@StateObject`.
- A file that uses `@Published` / `ObservableObject` but does **not** `import SwiftUI` must `import Combine` explicitly — SwiftUI re-exports Combine, but pure model files don't get it transitively.
- All `@Published` mutations must happen on the main thread. Background callbacks (CMMotion queue, AVCapture queue, URLSession completion) hop via `DispatchQueue.main.async` before mutating state.
- Camera (`AVCaptureSession`) configuration and `startRunning` run on a dedicated serial `DispatchQueue` — never on main.
- The motion-manager reference frame is currently `.xArbitraryZVertical` (gravity-aligned only). True-north alignment comes from `CLLocationManager`'s heading. We will revisit this when we introduce ARKit later.

## Permission strings

`NSCameraUsageDescription` and `NSLocationWhenInUseUsageDescription` live in the target's **Info** tab in Xcode (Custom iOS Target Properties), not in any source file under version control. Adding a new permission requires a manual Xcode UI step — Claude cannot add them via file edits. Flag it explicitly when needed.

## Open questions still on the table

PLAN.md §6 lists deferred questions with working defaults: photo strategy (illustrated cards), privacy posture (location-when-in-use), launch region (US + Western Europe), backend hosting (Fly.io + Postgres). Don't promote a default to a real decision without asking Noah.
