# Remote-deploy loop + aircraft type lookup — design

**Date:** 2026-05-13
**Status:** Approved by Noah (sections 1 & 2 confirmed; remainder approved with "seems good")
**Author:** Claude (Opus 4.7, 1M context) in session with Noah Landesberg
**Implements:** PLAN.md §9 #1, plus new tooling not previously in the plan

---

## 1. Scope and success criteria

### What this spec ships

Two bundled deliverables:

1. **Remote-deploy loop (tooling).** A repeatable Mac → iPhone push-build-launch-observe pipeline that Claude drives via Bash. Includes a Swift `os.Logger` wrapper so device logs are filterable.
2. **Aircraft type lookup (product, PLAN.md §9 #1).** Per-icao24 metadata fetch from OpenSky's `/metadata/aircraft/icao/{icao24}`, cached, surfaced in `AircraftDetailView`.

The two are bundled so the loop ships in the same push as the first feature it enables.

### Out of scope

- Heading-color cue, OpenSky secret rotation, replay harness, visual confirmation — separate items, listed in §5 below.
- Persisting the metadata cache across app launches (in-memory only; SwiftData persistence is a Phase 1 concern).
- Auto-deploy on file save / true hot reload.
- Automated certificate / provisioning-profile renewal (paid Dev Program cert valid through May 2027).

### Success criteria

- Loop: `bin/deploy --launch` builds, installs, and launches Tailspot on the paired iPhone in one command. `bin/log-tail` returns the most recent filtered device console output. Claude can perform code-change → deploy → log-inspect in a single chat turn.
- Aircraft type lookup: tapping a reticle in the field opens a detail sheet that shows manufacturer + model + registration when OpenSky has them; the previous "Aircraft type: —" placeholder is replaced with real data when available. Repeated taps on the same icao24 don't re-fetch.
- Unit test suite remains green and grows to cover the metadata client, cache, and (smoke-level) loop scripts. TDD discipline: tests precede implementation.

---

## 2. Remote-deploy loop architecture

### Device empirics (verified during brainstorming)

- Device: Noah's iPhone (iPhone 16, iPhone17,3), iOS 26.3.1.
- UDID: `B88009FD-BC73-575C-BF03-02A46C9DDC98`.
- Hostname: `Noahs-iPhone.coredevice.local` (CoreDevice — wireless dev paired; USB not required).
- Signing: Apple Development cert valid through 2027-05-06. Paid Dev Program.
- Bundle ID: `com.landesberg.Tailspot`. Team: `G9FJX2A5TA`.

### New files (added at repo root)

```
bin/deploy             — build + install + launch in one shot
bin/log-tail           — tail filtered device console
bin/log-start          — start background `log stream` capture (idempotent)
bin/log-stop           — stop the background capture
tools/deploy/config.sh — UDID, scheme, bundle ID, paths (sourceable)
ios/Tailspot/Tailspot/Log.swift — os.Logger wrapper, subsystem + categories
```

### Configuration (`tools/deploy/config.sh`)

```sh
TAILSPOT_DEVICE_ID="B88009FD-BC73-575C-BF03-02A46C9DDC98"
TAILSPOT_DEVICE_NAME="Noah's iPhone"
TAILSPOT_SCHEME="Tailspot"
TAILSPOT_PROJECT="ios/Tailspot/Tailspot.xcodeproj"
TAILSPOT_BUNDLE_ID="com.landesberg.Tailspot"
TAILSPOT_LOG_SUBSYSTEM="com.landesberg.tailspot"
TAILSPOT_BUILD_DIR="build"
TAILSPOT_LOG_DIR="$HOME/Library/Logs/tailspot"
TAILSPOT_LOG_FILE="$TAILSPOT_LOG_DIR/device.log"
TAILSPOT_LOG_PIDFILE="$TAILSPOT_LOG_DIR/log-stream.pid"

# Optional override: copy this file to tools/deploy/config.local.sh and edit
[ -f "$(dirname "${BASH_SOURCE[0]}")/config.local.sh" ] \
  && source "$(dirname "${BASH_SOURCE[0]}")/config.local.sh"
```

`tools/deploy/config.local.sh` is gitignored.

### `bin/deploy [--no-build] [--no-launch] [--dry-run]`

Flow:

1. Source config.
2. Ensure log-stream daemon is running (call `bin/log-start` — idempotent).
3. Unless `--no-build`:
   `xcodebuild build -project "$TAILSPOT_PROJECT" -scheme "$TAILSPOT_SCHEME" -destination "platform=iOS,id=$TAILSPOT_DEVICE_ID" -derivedDataPath "$TAILSPOT_BUILD_DIR"`
4. Resolve `.app` path: `"$TAILSPOT_BUILD_DIR/Build/Products/Debug-iphoneos/Tailspot.app"`.
5. `xcrun devicectl device install app --device "$TAILSPOT_DEVICE_ID" "$APP_PATH"`.
6. Unless `--no-launch`: `xcrun devicectl device process launch --device "$TAILSPOT_DEVICE_ID" "$TAILSPOT_BUNDLE_ID"`.
7. Print `deployed; log at $TAILSPOT_LOG_FILE`.

`--dry-run` prints each command without executing. Exits non-zero on any step failing.

### `bin/log-start` / `log-stop` / `log-tail`

- `log-start` — reads UDID; checks pidfile; if process not alive, starts:
  `log stream --device "$TAILSPOT_DEVICE_ID" --predicate 'subsystem == "com.landesberg.tailspot"' --style syslog > "$TAILSPOT_LOG_FILE" 2>&1 &`
  and writes the PID. If `--device <UDID>` syntax is rejected by the macOS `log` command on the implementation machine, fall back to `--device-name "$TAILSPOT_DEVICE_NAME"`.
- `log-stop` — kill the PID, remove pidfile.
- `log-tail [-f] [-n N]` — wraps `tail`. Default: last 200 lines, no follow.

### Swift-side `Log.swift`

```swift
import os

enum Log {
    static let openSky  = Logger(subsystem: "com.landesberg.tailspot", category: "openSky")
    static let adsb     = Logger(subsystem: "com.landesberg.tailspot", category: "adsb")
    static let location = Logger(subsystem: "com.landesberg.tailspot", category: "location")
    static let motion   = Logger(subsystem: "com.landesberg.tailspot", category: "motion")
    static let ui       = Logger(subsystem: "com.landesberg.tailspot", category: "ui")
}
```

Existing `print(...)` call sites (verified during brainstorming — three total) are migrated to the matching `Log.<cat>.info/notice/error(...)` call:

- `CameraPreview.swift:54` → `Log.ui.error(...)`
- `LocationManager.swift:98` → `Log.location.error(...)`
- `MotionManager.swift:34` → `Log.motion.error(...)`

This is the one product-code change the loop requires.

### `.gitignore` additions

- `build/`
- `tools/deploy/config.local.sh`

### Failure modes

- **iPhone unreachable** (locked / off WiFi): `devicectl install` fails fast; surface the message and exit non-zero. Do not silently retry.
- **xcodebuild build error**: propagate non-zero exit; stderr preserved.
- **Stale pidfile**: `log-start` checks process liveness before deciding it's already running.
- **First-run cold build**: ~60 s. Incremental: ~10–20 s. Acceptable.

### Why scripts, not inline Bash

Claude can run inline Bash, but scripts mean Noah can invoke the same commands from a terminal, and a future `/loop` automation can call `bin/deploy` on a cadence.

---

## 3. Aircraft type lookup architecture

### Endpoint

`GET /api/metadata/aircraft/icao/{icao24}` — OpenSky.

Example response:

```json
{
  "icao24": "a1b2c3",
  "registration": "N12345",
  "manufacturerName": "BOEING",
  "manufacturerIcao": "BOEING",
  "model": "737-800",
  "typecode": "B738",
  "operator": "American Airlines",
  "operatorIcao": "AAL"
}
```

Returns 404 (or null fields) when the icao24 isn't in the OpenSky DB. Uses the same OAuth2 bearer we already mint for `/states/all`.

### New types and files (in `ios/Tailspot/Tailspot/`)

```
AircraftMetadata.swift — Decodable struct. Fields: icao24, registration?,
                         manufacturerName?, model?, typecode?, operatorName?
                         (decoded from JSON key "operator" via CodingKeys —
                         `operator` is a Swift reserved word). All optional
                         except icao24. Sendable + nonisolated.
MetadataCache.swift    — actor. Bounded LRU, cap=500. Stores Optional<AircraftMetadata>
                         so a known-miss is distinguishable from not-yet-fetched.
```

### Modifications

- **`OpenSkyClient.swift`** — add `func aircraftMetadata(icao24: String) async throws -> AircraftMetadata?`. Returns nil on 404, throws on auth/network/decoding.
- **`ADSBSource.swift`** — extend protocol with same signature.
- **`MockADSBSource.swift`** — return hand-rolled metadata for each of the 5 mock planes (e.g., 737-800, A320, CRJ-700, ATR-72, Citation X — real-feeling diversity).
- **`ADSBManager.swift`** — owns a `MetadataCache`. Exposes `metadata(for icao24:) async -> AircraftMetadata?` that consults cache first; on miss, fetches from source, stores result (including nil sentinel for 404).
- **`AircraftDetailView.swift`** — on `.task { ... }`, kick off metadata lookup; replace the "Aircraft type: —" placeholder with manufacturer + model + registration when available.

### Fetch policy

**Lazy on tap.** Eager-on-poll would burn ~10–30 credits per poll cycle against a 4000/day budget. Lazy means one fetch per *uniquely tapped* icao24 per session. The compact AR label keeps its current `callsign / FL / km` content; "type on label" stays a §3.0b optional item, deferred.

### Cache

- In-memory only. Cap at 500 entries (a long Berkeley session might see ~500 unique icao24s in a day; 500 keeps RAM trivial).
- LRU by insertion-order tracking.
- No persistence — relaunch re-fetches on next tap. Matches the credit budget logic; SwiftData is a Phase 1 concern.
- Stores `Optional<AircraftMetadata>` so 404s are cached too.

### Concurrency

`MetadataCache` is an `actor`. `AircraftMetadata` is a `Sendable` value type, marked `nonisolated` per the repo convention (CLAUDE.md "MainActor default isolation").

### Failure handling

- Network error: don't cache; next tap retries.
- 404: cache the nil.
- 429: existing rate-limit treatment in `OpenSkyClient` applies — for v1, a 429 surfaces as a thrown error and is not cached.

---

## 4. Testing strategy (TDD)

Following the repo convention: Swift Testing (`@Test`, `#expect`, `@Suite`), fixtures injected via `ADSBSource`. Tests precede implementation.

### New unit tests

**`AircraftMetadataDecodingTests.swift`**
- Decodes a full OpenSky metadata payload.
- Tolerates missing optional fields.
- Surfaces icao24 even when other fields are null.

**`MetadataCacheTests.swift`**
- `get` returns nil for unknown icao24.
- `set` then `get` returns stored value.
- `set` with nil (known miss) still returns "hit" on subsequent `get` — distinguishes not-fetched from fetched-and-missing.
- At cap, oldest insertion evicted.

**`OpenSkyClientMetadataTests.swift`**
- URL construction includes the icao24.
- Decoder matches the production decoder.

**Extensions to `ADSBManagerTests.swift`**
- `metadata(for:)` consults cache first.
- Cache miss triggers `mockSource.aircraftMetadata(icao24:)`.
- Repeated calls don't re-fetch.
- Source error doesn't poison the cache.

### Loop scripts

- `bin/deploy --dry-run` is the testable form. Prints the commands it would run; exits 0.
- No unit-test coverage for the device install path; the first real `bin/deploy` on Noah's machine is the integration test.

### Workflow per change

1. Write failing test.
2. Implement to make it pass.
3. `xcodebuild test ...` — green.
4. `bin/deploy --launch`.
5. `bin/log-tail` — sanity check.
6. Noah exercises the feature on device, reports back.

---

## 5. Roadmap refresh and doc updates

### Re-prioritized PLAN.md §9

| # | Item | Est. | Why now |
|---|------|------|---------|
| 1 | Remote-deploy loop + Log wrapper | ~1.5 hr | Tooling investment. THIS SESSION. |
| 2 | Aircraft type lookup | ~45–60 min | First product change through the new loop. THIS SESSION. |
| 3 | Heading-accuracy color cue | ~10 min | Tiny iteration to validate loop speed. |
| 4 | Rotate leaked OpenSky client secret | ~10 min | Long-standing security debt. |
| 5 | Catch flow v0 — tap-Catch button + SwiftData persistence | ~3–4 hr | First actual game mechanic. Phase 1 work pulled forward because the loop makes UI iteration cheap. |
| 6 | Hangar (collection) v0 | ~2–3 hr | Closes the product loop visually. |
| 7 | Replay harness | ~1.5 hr | Phase 0-main infra; more valuable once a game exists to validate. |
| 8 | Visual confirmation (Vision + COCO airplane) | ~1 day | Hardest. Defer until accuracy bar work begins. |

### Why pull catch + hangar earlier

The current PLAN.md sequence spends 2–3 weeks on infrastructure (replay, visual confirmation, accuracy bar) before any game mechanic ships. That's right for a research project, not for keeping Noah motivated and giving field tests real signal. Catch flow makes "did the user identify the right plane?" a real per-tap event instead of a manual judgment call. SwiftData is a named "things Noah is learning"; earlier exposure helps.

### Doc edits to land with this spec's implementation

- **PLAN.md §9** — replaced with table above.
- **PLAN.md new §3.0c** — short paragraph on the deploy loop: what it is, how to invoke, where the scripts live.
- **PLAN.md §8 (repo structure)** — add `bin/`, `tools/deploy/`, `Log.swift`, `AircraftMetadata.swift`, `MetadataCache.swift`.
- **CLAUDE.md** — new "Deploy loop" subsection under "Build and run"; new bullet under "Key code patterns" describing the Logger convention.
- **README.md** — one-line pointer to `bin/deploy --launch` for device builds.

---

## 6. Implementation order

Listed here for the writing-plans handoff:

1. Add `Log.swift`, migrate existing `print()` calls. Run unit tests — confirm still green.
2. Write loop scripts (`bin/deploy`, `log-start`, `log-stop`, `log-tail`), `tools/deploy/config.sh`, `.gitignore` updates.
3. First real `bin/deploy --launch` on Noah's iPhone. Verify app launches; verify `bin/log-tail` shows Logger output. **Checkpoint.**
4. Write failing tests for `AircraftMetadata` decoding, `MetadataCache`.
5. Implement `AircraftMetadata`, `MetadataCache`. Tests pass.
6. Write failing tests for `OpenSkyClient.aircraftMetadata(icao24:)` and `ADSBManager.metadata(for:)`.
7. Implement those methods. Extend `ADSBSource` protocol + `MockADSBSource` fixtures. Tests pass.
8. Update `AircraftDetailView` to consume metadata. Build + deploy.
9. Field test: tap a reticle in MOCK mode (sees Mock-source fixture data), then LIVE mode (sees real OpenSky data). **Checkpoint.**
10. Update PLAN.md, CLAUDE.md, README.md per §5 above.
11. Commit and confirm tests + a final deploy still work.
