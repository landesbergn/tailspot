# CLAUDE.md

<!-- Durable "how to work here" guidance only. Product status, the backlog and
history live in PLAN §9, CHANGELOG.md and git log; don't mirror them here.
Edit this file only when durable guidance changes. Anthropic's guidance is to
keep it under ~200 lines and to leave out anything Claude can learn by reading
the code. -->

## Orient first

- `STRATEGY.md`: priorities. North-star metric is catch-confirmation-rate ("is
  the catch real?"). Make the catch real first (trustworthy ID), then make it a
  game (collection and progression), then social and the backend platform. Not
  doing, so don't propose: monetization, Android, a web app.
- `PLAN.md`: architectural decisions (§1), roadmap, risks, open questions, and
  §9, the ranked backlog and current status. Read §9 for "what's next" or "what
  just shipped". Finishing a round means updating §9.
- `CHANGELOG.md`: per-round history, newest first.
- `CONTRIBUTING.md`: the release process in full.

Read PLAN and STRATEGY before proposing anything structural or reprioritizing.

## Working with Noah

- Solo developer. Claude writes the code; Noah runs it on his iPhone 16 (iOS
  26.x), field-tests and reports back.
- Noah decides UI, workflows and product/user experience: bring him choices
  there, with screenshots or mockups. Code-level decisions are Claude's; don't
  narrate Swift patterns or ask him to weigh in on implementation.
- Simplest viable choice at each fork: SwiftUI, SwiftData, Apple-native, no
  third-party dependencies unless clearly worth it.
- Field-test location varies. Home is Berkeley/Oakland (dense ADS-B incl. MLAT),
  but he also tests while travelling (e.g. Bali). Don't assume a US location.

## Build, run, deploy

- `bin/deploy [--no-build] [--no-launch] [--dry-run]` builds with `xcodebuild`,
  installs with `xcrun devicectl` and launches on Noah's iPhone wirelessly.
  Device and scheme config: `tools/deploy/config.sh` (override in gitignored
  `config.local.sh`). Nothing tests a deploy, so run the tests first when
  touching testable code.
- The iOS Simulator has no GPS, compass or camera; runtime and field testing
  need the iPhone.
- `bin/log-start` / `bin/log-tail` stream the device syslog, which does not
  include the app's own `os_log` output. For app logs use Xcode's console.

Failures that need Noah, not a retry:
- `devicectl install` says the developer disk image could not be mounted: he
  unlocks the phone, re-pairs over USB, or opens Xcode once.
- `devicectl process launch` returns Locked: ask him to unlock, then retry the
  launch.
- `xcodebuild` can't find the destination: check `xcrun devicectl list devices`;
  `unavailable` means a USB re-pair or opening Xcode once.

## Tests

Swift Testing (`@Test`, `#expect`), not XCTest, in `ios/Tailspot/TailspotTests/`.
Run them after substantive changes and always before committing or deploying
changes to Geo, Aircraft decoding, `ADSBManager`, the backend client, or
anything they depend on:

```
xcodebuild test \
  -project ios/Tailspot/Tailspot.xcodeproj \
  -scheme Tailspot \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  -only-testing:TailspotTests
```

- About 6–7 min cold and 4 min warm, so run it in the background.
- Most suites are `@MainActor`, so the main thread is the bottleneck. Never
  block it in a test with `RunLoop.main.run(until:)`; use `try? await
  Task.sleep(for:)`.
- `ContentView` relies on `ADSBManager()` taking no arguments
  (`init(source: ADSBSource = TailspotBackendClient())`); tests inject a fixture
  through that parameter. Keep that shape.
- Measuring test speed: see CONTRIBUTING.md → Measuring test time.

## Shipping

Tailspot is live on the App Store. Process and checklists: `CONTRIBUTING.md`.

- `main` is protected and always green: branch, field-test with `bin/deploy`,
  open a PR, squash-merge on green CI. Merging does not ship.
- Claude may commit, `bin/deploy`, merge on green CI, and cut TestFlight builds
  with `bin/xcode-cloud-build --watch` (one build per batch; say what went in).
- Claude never submits to App Review or touches a phased release. That's Noah's,
  because an App Store release can't be rolled back.
- One `MARKETING_VERSION` per public release, bumped when the release train
  opens, in both config blocks of the app target. Leave
  `CURRENT_PROJECT_VERSION` at `1`; CI bumps build numbers.
- SwiftData changes stay additive (new optional fields with defaults). The
  Hangar is local-only with no sync, so a breaking schema change or a reinstall
  destroys a real user's collection. Warn before any delete/reinstall test on a
  device that matters.
- The backend serves old app versions for months: API changes are additive,
  deploy the server before the client that needs it, and snapshot the DB before
  migrations.
- No force-push to `main` without Noah's explicit OK.
- After a build reaches TestFlight or the App Store, check App Store Connect →
  Crashes (and, for the App Store, ratings and the PostHog funnel by version).

## Secrets

The only build-time secret is the optional PostHog key in gitignored
`ios/Tailspot/Tailspot.secrets.xcconfig`; without it `Analytics.swift` no-ops.
Fresh worktrees don't have that file, so `bin/deploy` copies it from the primary
checkout. Keep that step.

Inspect `git diff --cached` before every commit (this repo has leaked secrets
twice). Secrets never go in `.swift`, plists or commit messages.
`Tailspot.xcscheme` is the only committed shared scheme.

## Architecture

- Identification is geometric (GPS, true-north heading and camera elevation
  matched against ADS-B positions), not visual. The bundled detector only snaps
  the bracket onto the plane and feeds the catch-time checks; it never decides
  which plane was caught.
- The Tailspot backend (`api.tailspot.app`) is the only ADS-B source, behind the
  `ADSBSource` protocol.
- When several planes are in view, every candidate gets a label and the user
  taps one.
- iOS conventions and traps live in `ios/CLAUDE.md`, which loads when working
  under `ios/`.
- Design prototype (reference only; rebuild in SwiftUI, don't port the JSX):
  `python3 -m http.server 4173 --directory design`, then open
  http://127.0.0.1:4173/.
