# Tailspot

iOS app that turns plane spotting into a collection game. Point your phone at a plane in the sky; an AR overlay identifies the aircraft, flight, and airline using live ADS-B data; catch it to your collection.

**Status:** in TestFlight beta, preparing the v1 App Store launch. The catch flow, local Hangar collection, scoring/rarity economy, trophies, leaderboards, and the production backend are all live. See [PLAN.md §9](PLAN.md) for the ranked backlog and current status, [CHANGELOG.md](CHANGELOG.md) for history, and [CLAUDE.md](CLAUDE.md) for working conventions.

## Goals (v1)

- Make plane spotting feel like a game, not a research project
- Reward repeat engagement
- Build a community of avgeeks and casual users alongside each other

## Non-goals (v1)

- Replacing serious flight trackers (Flightradar24, FlightAware)
- Indoor / non-AR identification
- Multiplayer, trading, Android

## Build and run

iOS app, built via Xcode (`⌘R`) on a physical iPhone. Simulator can't provide GPS/compass/camera, so device is required.

For tighter iteration there is also a Bash-driven deploy loop: `bin/deploy` builds, installs over the paired iPhone's wireless link, and launches the app. `bin/log-start` / `bin/log-tail` capture the device syslog via `idevicesyslog` (system-emitted lines about the app; the app's own `os_log` output still needs Xcode's console). See [CLAUDE.md](CLAUDE.md) for details.

ADS-B data comes from the Tailspot backend (`api.tailspot.app`), so the app needs no per-device credentials — just build and run.

Unit tests via `xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:TailspotTests`.

## Repo layout

See [PLAN.md §8](PLAN.md#8-repo-structure-current). The two deployables are `ios/Tailspot/` (the app) and `backend/` (the Fly.io API at `api.tailspot.app`); `web/` serves the static legal/marketing pages, `tools/` holds dataset generators and eval harnesses, and `docs/` carries plans, runbooks, and legal text (historical material in `docs/archive/`).
