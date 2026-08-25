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

## Workflow: four rings (local → main → TestFlight → App Store)

**Tailspot is live on the App Store** (v1.0.0 build 83, approved 2026-08-08), so
there are now four rings, not three. Canonical process, with the per-release
checklist and soak table: `CONTRIBUTING.md`.

```
Ring 0 bin/deploy → Ring 1 main → Ring 2 TestFlight → Ring 3 App Store
       (Noah's phone)  (nobody)     (invited testers)   (the public, NO ROLLBACK)
```

- `main` is the **enforced, always-green integration line** — branch protection
  blocks direct pushes (admins included) and requires the green **Unit tests**
  check. Flow: branch → field-test with `bin/deploy` → PR → squash-merge.
  **Merging does not ship; cutting a TestFlight build does not ship.**
- **Claude may** commit, `bin/deploy`, and merge on green CI autonomously.
  **Claude may not** promote to Ring 2 or Ring 3 — the Start Build and the App
  Review submission are Noah's, always.
- **Ring 3 is irreversible.** iOS has no rollback; the only post-hoc levers are
  pull-from-sale, an expedited review, or pausing a phased rollout. Front-load
  the caution — soak on TestFlight, and prefer phased release on every submit.
- **Versioning — this rule INVERTED at GA.** Pre-GA guidance was "keep the same
  `MARKETING_VERSION`, let the build number increment"; that is **wrong for the
  App Store**, where each public release needs a new, higher version string. Now:
  **one `MARKETING_VERSION` per public release, bumped when the train opens**
  (not at submission), edited in *both* config blocks of the app target only.
  Build numbers still auto-bump in CI (`ci_scripts/ci_pre_xcodebuild.sh`) —
  leave `CURRENT_PROJECT_VERSION` at `1` in `project.pbxproj`.
- **SwiftData migrations stay lightweight/additive** (new optional fields with
  defaults). The Hangar is **local-only** (no sync, photos not uploaded), so a
  breaking schema change destroys real users' collections — and post-GA there is
  no one to warn, because they aren't testers you can message. Reinstall also
  loses it: warn before any delete/reinstall test on a device that matters.
- **The backend is half of production and serves clients you can't fix.** Old
  app versions live on phones for months: API changes are **additive-only** with
  respect to shipped builds, deploy the **server before the client** that needs
  it, and snapshot the DB before migrations.
- **Don't force-push to `main` without Noah's explicit OK** (e.g. a leak needing
  history rewrite — surface the trade-offs and let him decide).
- After any build reaches Ring 2 or 3, check App Store Connect → Crashes (and,
  for Ring 3, ratings/reviews + the PostHog funnel by version). Testers paste the
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
the binary is acceptable. **Worktree trap:** being gitignored, the file is absent
from every fresh per-feature worktree, so worktree `bin/deploy` builds were
silently keyless — the dev phone sent zero analytics/replays for 6 days
(2026-08-19 → 08-25) before anyone noticed. `bin/deploy` now heals the file from
the primary checkout (or warns loudly if it can't); don't remove that backstop.

**Leak hygiene still applies** (two real leaks in this repo's history, both
OpenSky). Inspect `git diff --cached` before every commit; secrets belong only in
the gitignored secrets file — never in `.swift`, plists, commit messages, or a
staged secrets file. `Tailspot.xcscheme` is the **only** committed shared scheme
(`.gitignore` allows exactly it) — review before `git add ios/`.

## iOS conventions & load-bearing gotchas

Moved to **`ios/CLAUDE.md`** — it loads automatically whenever Claude works with
files under `ios/`, which is exactly when those traps apply: MainActor default
isolation, pitch vs. camera elevation, the portrait + iPhone-only pins, the
visibility filter and tap-to-reveal, the design system, logging, the analytics
identity rule, and the `Catch` / backfill contracts.

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
