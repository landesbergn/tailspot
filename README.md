# Tailspot

iOS app that turns plane spotting into a collection game. Point your phone at a plane in the sky; an AR overlay identifies the aircraft, flight, and airline using live ADS-B data; catch it to your collection.

**Status:** Friday POC (PLAN.md §3.0a) ✅ delivered May 5–7, 2026. Field-tested in Berkeley — AR labels track real aircraft. Catch flow, persistence, and backend are next phases. See [PLAN.md](PLAN.md) for the roadmap and [CLAUDE.md](CLAUDE.md) for working conventions.

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

For tighter iteration there is also a Bash-driven deploy loop: `bin/deploy` builds, installs over the paired iPhone's wireless link, and launches the app; `bin/log-tail` (currently a stub — see PLAN.md §9 #3) is intended to surface filtered device logs once iOS log streaming is wired in. See [CLAUDE.md "Remote-deploy loop"](CLAUDE.md#remote-deploy-loop) for details.

For LIVE ADS-B data, register a free account at [opensky-network.org](https://opensky-network.org), then add `OPENSKY_CLIENT_ID` and `OPENSKY_CLIENT_SECRET` to a **user-only** Xcode scheme's Environment Variables. The MOCK toggle in the app works without credentials.

Unit tests via `xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:TailspotTests`.

## Repo layout

See [PLAN.md §8](PLAN.md#8-repo-structure-current). `ios/Tailspot/` is the only thing that exists today; `backend/`, `shared/`, and `tools/replay-harness/` are planned.
