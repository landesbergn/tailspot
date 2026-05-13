# Remote-Deploy Loop + Aircraft Type Lookup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Mac→iPhone build/install/launch/log-stream loop driven by Bash scripts, then use that loop to deliver per-icao24 aircraft metadata in the detail view.

**Architecture:** A new `bin/` directory holds shell entry points (`deploy`, `log-start`, `log-stop`, `log-tail`); `tools/deploy/config.sh` centralizes UDID/scheme/paths; a thin `Log.swift` wrapper around `os.Logger` gives device-side logs a stable subsystem so `log stream` can filter them. For the metadata feature, a new `AircraftMetadata` value type + `MetadataCache` actor sit behind a new method on the `ADSBSource` protocol; `ADSBManager.metadata(for:)` consults the cache lazily on tap; `AircraftDetailView` renders the result.

**Tech Stack:** Swift 6 (Xcode 26, iOS 26+), Swift Testing (`@Test`/`#expect`), `os.Logger`, OpenSky REST `/metadata/aircraft/icao/{icao24}`, macOS `xcodebuild` + `xcrun devicectl` + `log stream` on Noah's Mac.

**Spec:** `docs/superpowers/specs/2026-05-13-remote-deploy-loop-and-aircraft-type-lookup-design.md`

---

## Conventions in this plan

- All Swift files live in `ios/Tailspot/Tailspot/`. Tests live in `ios/Tailspot/TailspotTests/`. Xcode 16 synchronized folders mean new `.swift` files in those directories are picked up automatically — no Xcode project file edits required.
- The repo's `nonisolated` convention applies: pure data, Sendable types, the `ADSBSource` protocol, and clients are all explicitly `nonisolated` (or `actor`). UI / state-holding types (`ADSBManager`, views) stay `@MainActor` (the default under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). See CLAUDE.md.
- The unit test command (use literally; first run is ~3 min, subsequent ~30–60 s):

  ```sh
  xcodebuild test \
    -project ios/Tailspot/Tailspot.xcodeproj \
    -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

- Before every commit, run `git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable'` and confirm "no leaked secrets in staged diff." See CLAUDE.md "Credentials and the shared-scheme trap" for context.
- Commit messages end with the standard co-author footer (`Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`). Use a HEREDOC for multi-line messages.

---

# Phase A — Remote-deploy loop scaffolding

## Task A1: Add `Log.swift` and migrate three `print()` call sites

**Files:**
- Create: `ios/Tailspot/Tailspot/Log.swift`
- Modify: `ios/Tailspot/Tailspot/CameraPreview.swift:54`
- Modify: `ios/Tailspot/Tailspot/LocationManager.swift:98`
- Modify: `ios/Tailspot/Tailspot/MotionManager.swift:34`

- [ ] **Step 1: Create `Log.swift` with the wrapper enum**

  Create `ios/Tailspot/Tailspot/Log.swift` with this exact content:

  ```swift
  //
  //  Log.swift
  //  Tailspot
  //
  //  Thin wrapper around `os.Logger` so the whole app writes through one
  //  subsystem ("com.landesberg.tailspot"), grouped by category. The
  //  bin/log-tail script on the Mac runs `log stream --predicate
  //  'subsystem == "com.landesberg.tailspot"'` against the connected
  //  iPhone — without this stable subsystem, the stream would either be
  //  unfiltered fire-hose or have to predicate on the bundle ID
  //  (which doesn't work cleanly for system-emitted lines).
  //
  //  Logger calls are async-safe, free to call from any actor, and
  //  zero-cost when the level is filtered out at the unified-logging
  //  layer. Use these instead of print().
  //

  import os

  enum Log {
      static let openSky  = Logger(subsystem: "com.landesberg.tailspot", category: "openSky")
      static let adsb     = Logger(subsystem: "com.landesberg.tailspot", category: "adsb")
      static let location = Logger(subsystem: "com.landesberg.tailspot", category: "location")
      static let motion   = Logger(subsystem: "com.landesberg.tailspot", category: "motion")
      static let ui       = Logger(subsystem: "com.landesberg.tailspot", category: "ui")
  }
  ```

- [ ] **Step 2: Replace the print in `CameraPreview.swift`**

  Open `ios/Tailspot/Tailspot/CameraPreview.swift`. Find line 54:

  ```swift
                  print("CameraPreview: failed to set up back camera")
  ```

  Replace with:

  ```swift
                  Log.ui.error("CameraPreview: failed to set up back camera")
  ```

- [ ] **Step 3: Replace the print in `LocationManager.swift`**

  Open `ios/Tailspot/Tailspot/LocationManager.swift`. Find line 98:

  ```swift
          print("LocationManager error: \(error.localizedDescription)")
  ```

  Replace with:

  ```swift
          Log.location.error("LocationManager error: \(error.localizedDescription, privacy: .public)")
  ```

  (`privacy: .public` keeps the message readable in `log stream` output — the default redacts string interpolations.)

- [ ] **Step 4: Replace the print in `MotionManager.swift`**

  Open `ios/Tailspot/Tailspot/MotionManager.swift`. Find line 34:

  ```swift
              print("Device motion not available on this device")
  ```

  Replace with:

  ```swift
              Log.motion.notice("Device motion not available on this device")
  ```

- [ ] **Step 5: Run the test suite**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: all 44 tests pass. The migration is pure log-routing; no test logic changes.

- [ ] **Step 6: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/Log.swift \
          ios/Tailspot/Tailspot/CameraPreview.swift \
          ios/Tailspot/Tailspot/LocationManager.swift \
          ios/Tailspot/Tailspot/MotionManager.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Add Log.swift wrapper; migrate the three print() call sites

  Establishes "com.landesberg.tailspot" as the unified-logging subsystem
  for the app. The bin/log-stream script (next commit) filters on this
  predicate to give the Mac a clean view of device-side logs.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task A2: Add `tools/deploy/config.sh`

**Files:**
- Create: `tools/deploy/config.sh`

- [ ] **Step 1: Create the directory and file**

  ```sh
  mkdir -p tools/deploy
  ```

  Create `tools/deploy/config.sh` with this exact content:

  ```sh
  # Tailspot deploy-loop config.
  # Sourced by bin/deploy, bin/log-start, bin/log-stop, bin/log-tail.
  #
  # To override any value locally (e.g. a different device UDID for
  # someone else's clone), copy this file to tools/deploy/config.local.sh
  # and edit the values there. config.local.sh is gitignored.

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

  # Optional local override (gitignored)
  __cfg_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$__cfg_dir/config.local.sh" ] && source "$__cfg_dir/config.local.sh"
  unset __cfg_dir
  ```

- [ ] **Step 2: No tests / no commit yet — committed together with the scripts in A6.**

---

## Task A3: Add `bin/log-start`, `bin/log-stop`, `bin/log-tail`

**Files:**
- Create: `bin/log-start`
- Create: `bin/log-stop`
- Create: `bin/log-tail`

- [ ] **Step 1: Create `bin/` directory**

  ```sh
  mkdir -p bin
  ```

- [ ] **Step 2: Create `bin/log-start`**

  Create `bin/log-start` with this exact content:

  ```sh
  #!/usr/bin/env bash
  # Starts a background `log stream` against the paired iPhone, filtered
  # to the Tailspot subsystem, redirected to a file. Idempotent: if the
  # stream is already running (per pidfile + a live-process check), exits 0.
  set -euo pipefail

  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$here/tools/deploy/config.sh"

  mkdir -p "$TAILSPOT_LOG_DIR"

  if [ -f "$TAILSPOT_LOG_PIDFILE" ]; then
    pid="$(cat "$TAILSPOT_LOG_PIDFILE")"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "log-stream already running (pid $pid)"
      exit 0
    fi
    # Stale pidfile — clean up.
    rm -f "$TAILSPOT_LOG_PIDFILE"
  fi

  predicate="subsystem == \"$TAILSPOT_LOG_SUBSYSTEM\""

  # First try --device <UDID>; on systems where that flag isn't accepted,
  # fall back to --device-name. We test the flag with a 1-line capture.
  if log stream --device "$TAILSPOT_DEVICE_ID" --predicate "$predicate" --style syslog 2>/dev/null >/dev/null &
  then
    :  # background started; PID below
  fi

  # Actually start the stream; we can't easily probe without consuming
  # output, so run it and hope. Failure shows up on first read of the file.
  nohup log stream \
    --device "$TAILSPOT_DEVICE_ID" \
    --predicate "$predicate" \
    --style syslog \
    >"$TAILSPOT_LOG_FILE" 2>&1 &

  stream_pid=$!
  echo "$stream_pid" > "$TAILSPOT_LOG_PIDFILE"

  # Brief wait + alive check; if the process dies immediately we likely
  # need the --device-name fallback.
  sleep 1
  if ! kill -0 "$stream_pid" 2>/dev/null; then
    rm -f "$TAILSPOT_LOG_PIDFILE"
    echo "log stream failed with --device UDID — retrying with --device-name"
    nohup log stream \
      --device-name "$TAILSPOT_DEVICE_NAME" \
      --predicate "$predicate" \
      --style syslog \
      >"$TAILSPOT_LOG_FILE" 2>&1 &
    stream_pid=$!
    echo "$stream_pid" > "$TAILSPOT_LOG_PIDFILE"
    sleep 1
    if ! kill -0 "$stream_pid" 2>/dev/null; then
      rm -f "$TAILSPOT_LOG_PIDFILE"
      echo "log stream failed; see $TAILSPOT_LOG_FILE for diagnostics" >&2
      exit 1
    fi
  fi

  echo "log-stream running (pid $stream_pid); output -> $TAILSPOT_LOG_FILE"
  ```

- [ ] **Step 3: Create `bin/log-stop`**

  Create `bin/log-stop`:

  ```sh
  #!/usr/bin/env bash
  set -euo pipefail
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$here/tools/deploy/config.sh"

  if [ ! -f "$TAILSPOT_LOG_PIDFILE" ]; then
    echo "log-stream not running (no pidfile)"
    exit 0
  fi

  pid="$(cat "$TAILSPOT_LOG_PIDFILE")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    echo "stopped log-stream (pid $pid)"
  else
    echo "pidfile present but process not running"
  fi
  rm -f "$TAILSPOT_LOG_PIDFILE"
  ```

- [ ] **Step 4: Create `bin/log-tail`**

  Create `bin/log-tail`:

  ```sh
  #!/usr/bin/env bash
  # Usage:
  #   bin/log-tail            last 200 lines
  #   bin/log-tail -f         follow
  #   bin/log-tail -n 500     last 500 lines
  #   bin/log-tail -n 500 -f  last 500 lines, then follow
  set -euo pipefail
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$here/tools/deploy/config.sh"

  lines=200
  follow=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -n) lines="$2"; shift 2 ;;
      -f) follow="-f"; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  if [ ! -f "$TAILSPOT_LOG_FILE" ]; then
    echo "no log file at $TAILSPOT_LOG_FILE — run bin/log-start first" >&2
    exit 1
  fi

  # shellcheck disable=SC2086
  tail -n "$lines" $follow "$TAILSPOT_LOG_FILE"
  ```

- [ ] **Step 5: Mark all three scripts executable**

  ```sh
  chmod +x bin/log-start bin/log-stop bin/log-tail
  ```

---

## Task A4: Add `bin/deploy`

**Files:**
- Create: `bin/deploy`

- [ ] **Step 1: Create `bin/deploy`**

  Create `bin/deploy` with this exact content:

  ```sh
  #!/usr/bin/env bash
  # bin/deploy [--no-build] [--no-launch] [--dry-run]
  #
  # Build the Tailspot iOS app for Noah's iPhone, install it over the
  # CoreDevice wireless link, and launch the app. Idempotently ensures
  # bin/log-start is running so device-side logs are captured to
  # $TAILSPOT_LOG_FILE for bin/log-tail to inspect.
  #
  # Exits non-zero on any step failure; stderr is preserved.

  set -euo pipefail

  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "$here/tools/deploy/config.sh"

  do_build=1
  do_launch=1
  dry_run=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-build) do_build=0; shift ;;
      --no-launch) do_launch=0; shift ;;
      --dry-run) dry_run=1; shift ;;
      *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
  done

  run() {
    if [ "$dry_run" -eq 1 ]; then
      echo "DRY: $*"
    else
      echo "+ $*"
      "$@"
    fi
  }

  # Step 0: ensure log stream is running (idempotent).
  if [ "$dry_run" -eq 1 ]; then
    echo "DRY: bin/log-start"
  else
    "$here/bin/log-start"
  fi

  app_path="$here/$TAILSPOT_BUILD_DIR/Build/Products/Debug-iphoneos/Tailspot.app"

  # Step 1: build (optional).
  if [ "$do_build" -eq 1 ]; then
    run xcodebuild build \
      -project "$here/$TAILSPOT_PROJECT" \
      -scheme "$TAILSPOT_SCHEME" \
      -destination "platform=iOS,id=$TAILSPOT_DEVICE_ID" \
      -derivedDataPath "$here/$TAILSPOT_BUILD_DIR"
  fi

  if [ "$dry_run" -eq 0 ] && [ ! -d "$app_path" ]; then
    echo "expected .app not found at $app_path" >&2
    exit 1
  fi

  # Step 2: install.
  run xcrun devicectl device install app \
    --device "$TAILSPOT_DEVICE_ID" \
    "$app_path"

  # Step 3: launch (optional).
  if [ "$do_launch" -eq 1 ]; then
    run xcrun devicectl device process launch \
      --device "$TAILSPOT_DEVICE_ID" \
      "$TAILSPOT_BUNDLE_ID"
  fi

  echo "deployed; log at $TAILSPOT_LOG_FILE"
  ```

- [ ] **Step 2: Mark `bin/deploy` executable**

  ```sh
  chmod +x bin/deploy
  ```

- [ ] **Step 3: Smoke-test the dry-run mode**

  ```sh
  bin/deploy --dry-run
  ```

  Expected output (order matters; line content approximate):

  ```
  DRY: bin/log-start
  DRY: xcodebuild build -project /Users/noah/Desktop/tailspot/ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination platform=iOS,id=B88009FD-BC73-575C-BF03-02A46C9DDC98 -derivedDataPath /Users/noah/Desktop/tailspot/build
  DRY: xcrun devicectl device install app --device B88009FD-BC73-575C-BF03-02A46C9DDC98 /Users/noah/Desktop/tailspot/build/Build/Products/Debug-iphoneos/Tailspot.app
  DRY: xcrun devicectl device process launch --device B88009FD-BC73-575C-BF03-02A46C9DDC98 com.landesberg.Tailspot
  deployed; log at /Users/noah/Library/Logs/tailspot/device.log
  ```

  Exit code: 0.

---

## Task A5: Update `.gitignore`

**Files:**
- Modify: `.gitignore` (append entries; preserve existing rules)

- [ ] **Step 1: Append to `.gitignore`**

  Open `.gitignore`. The file currently ends at line 89 (`tools/replay-harness/recordings/`). Add a new section at the end:

  ```
  # Deploy-loop artifacts and per-user overrides
  /build/
  tools/deploy/config.local.sh
  ```

  (Note: `build/` is already ignored on line 9 as a pattern, but the leading slash anchors the rule to the repo root — defensive.)

- [ ] **Step 2: Verify pattern is respected**

  ```sh
  git check-ignore -v build/ tools/deploy/config.local.sh
  ```

  Expected: both paths print as ignored (matched against the new rules or pre-existing `build/`).

---

## Task A6: Commit the loop scaffolding

- [ ] **Step 1: Stage and verify no secrets**

  ```sh
  git add bin/ tools/deploy/ .gitignore
  git status
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  ```

  Expected: new files under `bin/` (deploy, log-start, log-stop, log-tail), `tools/deploy/config.sh`, modified `.gitignore`. No secret matches.

- [ ] **Step 2: Commit**

  ```sh
  git commit -m "$(cat <<'EOF'
  Add remote-deploy loop: bin/deploy + log-start/stop/tail + config

  bin/deploy [--no-build] [--no-launch] [--dry-run] builds Tailspot via
  xcodebuild, installs to the paired iPhone via xcrun devicectl, and
  launches the app. bin/log-start runs a background `log stream` filtered
  on the com.landesberg.tailspot subsystem, redirected to
  ~/Library/Logs/tailspot/device.log so bin/log-tail can read it.

  Config (device UDID, scheme, paths) is centralized in
  tools/deploy/config.sh, overridable per-machine via config.local.sh
  (gitignored). build/ is gitignored too.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task A7: First real deploy — manual checkpoint

- [ ] **Step 1: Verify Noah's iPhone is reachable**

  ```sh
  xcrun devicectl list devices 2>&1 | grep -E "Noah|iPhone" | head -5
  ```

  Expected: a line like `Noah's iPhone  Noahs-iPhone.coredevice.local  B88009FD-BC73-575C-BF03-02A46C9DDC98  available (paired)  iPhone 16 (iPhone17,3)`. If "unavailable" or missing, ask Noah to unlock the phone and ensure same WiFi.

- [ ] **Step 2: Do the first real deploy**

  ```sh
  bin/deploy --launch
  ```

  Expected: 30–60 s of `xcodebuild` output, then "Install Succeeded" / "Launch Succeeded" lines from `devicectl`, then `deployed; log at /Users/noah/Library/Logs/tailspot/device.log`.

  If `log stream --device <UDID>` fails (visible in the log-start fallback to `--device-name`), that's expected behavior — confirm via the second nohup line in `bin/log-start`. The script handles it.

- [ ] **Step 3: Verify the log capture is working**

  ```sh
  bin/log-tail -n 20
  ```

  Expected: at least the LocationManager / CameraPreview / MotionManager log lines that the app emits at startup (if any errors arose) — OR an empty/short output if the app started cleanly. The point is `tail` succeeds and prints from `$TAILSPOT_LOG_FILE`.

- [ ] **Step 4: Noah confirms**

  Stop here. Ask Noah: "App is running on the phone now — does the AR view show, and does the bottom list populate? (No new features yet; this is just to confirm the deploy loop landed cleanly.)" If yes, proceed. If no, debug before moving on.

---

# Phase B — Aircraft type lookup (TDD-driven)

## Task B1: Failing test for `AircraftMetadata` decoding

**Files:**
- Create: `ios/Tailspot/TailspotTests/AircraftMetadataDecodingTests.swift`

- [ ] **Step 1: Write the failing test file**

  Create `ios/Tailspot/TailspotTests/AircraftMetadataDecodingTests.swift`:

  ```swift
  //
  //  AircraftMetadataDecodingTests.swift
  //  TailspotTests
  //
  //  OpenSky's /metadata/aircraft/icao/{icao24} returns a flat JSON
  //  object keyed by field name. Most fields are nullable in practice —
  //  e.g. small GA aircraft often lack a model or registered owner.
  //  AircraftMetadata's Decodable must tolerate that.
  //

  import Testing
  import Foundation
  @testable import Tailspot

  @Suite("AircraftMetadata Decoding")
  struct AircraftMetadataDecodingTests {

      @Test func decodesFullPayload() throws {
          let json = """
          {
            "icao24": "a3b15e",
            "registration": "N12345",
            "manufacturerName": "BOEING",
            "manufacturerIcao": "BOEING",
            "model": "737-800",
            "typecode": "B738",
            "serialNumber": "12345",
            "operator": "American Airlines",
            "operatorIcao": "AAL",
            "owner": "American Airlines Inc"
          }
          """.data(using: .utf8)!

          let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
          #expect(m.icao24 == "a3b15e")
          #expect(m.registration == "N12345")
          #expect(m.manufacturerName == "BOEING")
          #expect(m.model == "737-800")
          #expect(m.typecode == "B738")
          #expect(m.operatorName == "American Airlines")
      }

      @Test func toleratesMissingOptionalFields() throws {
          let json = """
          {
            "icao24": "abc123"
          }
          """.data(using: .utf8)!

          let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
          #expect(m.icao24 == "abc123")
          #expect(m.registration == nil)
          #expect(m.manufacturerName == nil)
          #expect(m.model == nil)
          #expect(m.typecode == nil)
          #expect(m.operatorName == nil)
      }

      @Test func toleratesExplicitNulls() throws {
          let json = """
          {
            "icao24": "abc123",
            "registration": null,
            "manufacturerName": null,
            "model": null,
            "typecode": null,
            "operator": null
          }
          """.data(using: .utf8)!

          let m = try JSONDecoder().decode(AircraftMetadata.self, from: json)
          #expect(m.icao24 == "abc123")
          #expect(m.model == nil)
          #expect(m.operatorName == nil)
      }

      @Test func missingIcao24Throws() {
          let json = """
          { "model": "A320" }
          """.data(using: .utf8)!
          #expect(throws: DecodingError.self) {
              _ = try JSONDecoder().decode(AircraftMetadata.self, from: json)
          }
      }
  }
  ```

- [ ] **Step 2: Run tests — verify these four fail**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/AircraftMetadataDecodingTests
  ```

  Expected: build error — `cannot find 'AircraftMetadata' in scope`. That's the "red" stage of TDD; we have not created the type yet.

---

## Task B2: Implement `AircraftMetadata`

**Files:**
- Create: `ios/Tailspot/Tailspot/AircraftMetadata.swift`

- [ ] **Step 1: Create the type**

  Create `ios/Tailspot/Tailspot/AircraftMetadata.swift`:

  ```swift
  //
  //  AircraftMetadata.swift
  //  Tailspot
  //
  //  Per-aircraft metadata from OpenSky's
  //  /api/metadata/aircraft/icao/{icao24} endpoint. Decoded once per
  //  unique icao24 that the user taps, cached in MetadataCache.
  //
  //  Almost every field is optional — OpenSky's DB has plenty of holes,
  //  especially for non-US GA. icao24 is the only field we require.
  //
  //  `nonisolated` + `Sendable` per the repo convention: this is a pure
  //  value type that flows from the OpenSky client (any actor) to
  //  ADSBManager (@MainActor) to the detail view.
  //

  import Foundation

  nonisolated struct AircraftMetadata: Equatable, Sendable {
      let icao24: String
      let registration: String?
      let manufacturerName: String?
      let manufacturerIcao: String?
      let model: String?
      let typecode: String?
      // `operator` is a Swift reserved word; decode the JSON key
      // "operator" into `operatorName` via CodingKeys.
      let operatorName: String?
  }

  nonisolated extension AircraftMetadata: Decodable {
      enum CodingKeys: String, CodingKey {
          case icao24
          case registration
          case manufacturerName
          case manufacturerIcao
          case model
          case typecode
          case operatorName = "operator"
      }
  }
  ```

- [ ] **Step 2: Run the decoding tests — verify all four pass**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/AircraftMetadataDecodingTests
  ```

  Expected: 4 tests pass.

- [ ] **Step 3: Run the full suite — confirm nothing else broke**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 48 tests pass (existing 44 + 4 new).

- [ ] **Step 4: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/AircraftMetadata.swift \
          ios/Tailspot/TailspotTests/AircraftMetadataDecodingTests.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Add AircraftMetadata + decoding tests

  Mirrors the shape of OpenSky's /metadata/aircraft/icao endpoint.
  Every field besides icao24 is optional — OpenSky's DB has plenty of
  holes, especially for non-US GA. `operator` is a Swift reserved word,
  so we decode the JSON key into `operatorName` via CodingKeys.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task B3: Failing tests for `MetadataCache`

**Files:**
- Create: `ios/Tailspot/TailspotTests/MetadataCacheTests.swift`

- [ ] **Step 1: Write the failing tests**

  Create `ios/Tailspot/TailspotTests/MetadataCacheTests.swift`:

  ```swift
  //
  //  MetadataCacheTests.swift
  //  TailspotTests
  //
  //  The cache is the deduplication layer in front of OpenSky's metadata
  //  endpoint. Two requirements drive the design:
  //
  //  1. Distinguish "not yet fetched" from "fetched, no record." OpenSky
  //     returns 404 for a lot of icao24s; we cache the absence as
  //     `.set(icao, nil)` so subsequent taps don't re-fetch the miss.
  //  2. Bound memory growth. 500 entries fits a long Berkeley session.
  //     Oldest insertion evicts when full.
  //

  import Testing
  import Foundation
  @testable import Tailspot

  @Suite("MetadataCache")
  struct MetadataCacheTests {

      @Test func getReturnsNotFetchedForUnknownIcao24() async {
          let cache = MetadataCache(cap: 10)
          let result = await cache.get(icao24: "abc123")
          #expect(result == .notFetched)
      }

      @Test func setThenGetReturnsStoredValue() async {
          let cache = MetadataCache(cap: 10)
          let m = AircraftMetadata(
              icao24: "abc123",
              registration: "N1",
              manufacturerName: "BOEING",
              manufacturerIcao: "BOEING",
              model: "737",
              typecode: "B737",
              operatorName: "X"
          )
          await cache.set(icao24: "abc123", value: m)
          let result = await cache.get(icao24: "abc123")
          #expect(result == .hit(m))
      }

      @Test func setNilCachesTheMiss() async {
          let cache = MetadataCache(cap: 10)
          await cache.set(icao24: "abc123", value: nil)
          let result = await cache.get(icao24: "abc123")
          #expect(result == .hit(nil))
      }

      @Test func evictsOldestAtCap() async {
          let cache = MetadataCache(cap: 3)
          await cache.set(icao24: "a", value: nil)
          await cache.set(icao24: "b", value: nil)
          await cache.set(icao24: "c", value: nil)
          await cache.set(icao24: "d", value: nil)   // evicts "a"

          #expect(await cache.get(icao24: "a") == .notFetched)
          #expect(await cache.get(icao24: "b") == .hit(nil))
          #expect(await cache.get(icao24: "c") == .hit(nil))
          #expect(await cache.get(icao24: "d") == .hit(nil))
      }
  }
  ```

  Note: tests reference a `Lookup` enum-like result type — `.notFetched` vs `.hit(_)`. Defined in the next task.

- [ ] **Step 2: Run tests — confirm build failure (`MetadataCache` not defined)**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/MetadataCacheTests
  ```

  Expected: `cannot find 'MetadataCache' in scope` build error.

---

## Task B4: Implement `MetadataCache`

**Files:**
- Create: `ios/Tailspot/Tailspot/MetadataCache.swift`

- [ ] **Step 1: Create the actor**

  Create `ios/Tailspot/Tailspot/MetadataCache.swift`:

  ```swift
  //
  //  MetadataCache.swift
  //  Tailspot
  //
  //  Bounded LRU cache for AircraftMetadata, keyed by icao24. Stores
  //  Optional<AircraftMetadata>, so a "known miss" (OpenSky returned 404)
  //  is distinguishable from "we haven't asked yet" — preventing repeated
  //  lookups for icao24s that OpenSky doesn't know about.
  //
  //  Implemented as an `actor` so it's safe to share between the
  //  @MainActor ADSBManager and any other context that ends up reading
  //  it. The eviction order is "oldest insertion first" — we don't bump
  //  on read, since this isn't a true working-set cache, just a
  //  per-session memoization.
  //

  import Foundation

  actor MetadataCache {

      enum Lookup: Equatable, Sendable {
          case notFetched
          case hit(AircraftMetadata?)
      }

      private let cap: Int
      private var storage: [String: AircraftMetadata?] = [:]
      private var order: [String] = []   // insertion order, oldest first

      init(cap: Int = 500) {
          precondition(cap > 0)
          self.cap = cap
      }

      func get(icao24: String) -> Lookup {
          if let inner = storage[icao24] {
              return .hit(inner)
          }
          return .notFetched
      }

      func set(icao24: String, value: AircraftMetadata?) {
          if storage[icao24] == nil && !storage.keys.contains(icao24) {
              order.append(icao24)
          }
          storage[icao24] = value

          while order.count > cap {
              let oldest = order.removeFirst()
              storage.removeValue(forKey: oldest)
          }
      }
  }
  ```

  Note: the `storage[icao24] == nil && !storage.keys.contains(icao24)` guard distinguishes "key absent" from "key present with nil value." Swift `Dictionary` subscript returns `Optional<Optional<T>>` for `[K: T?]` — `nil` could mean either. The `contains` check disambiguates.

- [ ] **Step 2: Run the cache tests — verify all pass**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/MetadataCacheTests
  ```

  Expected: 4 tests pass.

- [ ] **Step 3: Run full suite**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 52 tests pass.

- [ ] **Step 4: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/MetadataCache.swift \
          ios/Tailspot/TailspotTests/MetadataCacheTests.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Add MetadataCache actor + tests

  Bounded LRU keyed by icao24. Stores Optional<AircraftMetadata> so a
  known 404-miss is distinguishable from a not-yet-fetched key — prevents
  re-fetching for icao24s OpenSky doesn't know about.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task B5: Extend `ADSBSource` protocol with `aircraftMetadata(icao24:)`

**Files:**
- Modify: `ios/Tailspot/Tailspot/ADSBSource.swift`

This is a breaking protocol change — both `OpenSkyClient` and `MockADSBSource` must be updated in the same commit so the project still builds. We add the protocol method now and immediately follow with both conformers (B6, B7) before any other test run.

- [ ] **Step 1: Extend the protocol**

  Open `ios/Tailspot/Tailspot/ADSBSource.swift`. Replace the protocol body to add the new method:

  ```swift
  nonisolated protocol ADSBSource: Sendable {
      func aircraftInBbox(
          lamin: Double, lomin: Double, lamax: Double, lomax: Double
      ) async throws -> [Aircraft]

      /// Fetch per-aircraft metadata (manufacturer / model / registration /
      /// operator) for a single icao24. Returns nil if the source has no
      /// record. Throws on transport/auth errors.
      func aircraftMetadata(icao24: String) async throws -> AircraftMetadata?
  }
  ```

  Project will not build until B6 and B7 land. **Do not run tests between these tasks** — the failures aren't informative.

---

## Task B6: Implement `OpenSkyClient.aircraftMetadata(icao24:)`

**Files:**
- Modify: `ios/Tailspot/Tailspot/OpenSkyClient.swift`

- [ ] **Step 1: Add the method to `OpenSkyClient`**

  Open `ios/Tailspot/Tailspot/OpenSkyClient.swift`. After the `aircraftInBbox(...)` method (i.e., after the `private struct StatesEnvelope` declaration around line 144), but BEFORE the `// MARK: - OAuth2` line, insert:

  ```swift
      // MARK: - Aircraft metadata

      /// Fetch metadata for a single icao24 from OpenSky's
      /// /metadata/aircraft/icao/{icao24} endpoint. Returns nil on 404
      /// (OpenSky doesn't have this aircraft in its DB).
      func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
          // Trim & lowercase: OpenSky expects the bare 24-bit hex,
          // and callsigns we hand in from Aircraft.icao24 already are lower.
          let key = icao24.trimmingCharacters(in: .whitespaces).lowercased()
          guard !key.isEmpty else { return nil }

          let url = base
              .appendingPathComponent("metadata")
              .appendingPathComponent("aircraft")
              .appendingPathComponent("icao")
              .appendingPathComponent(key)

          var request = URLRequest(url: url)
          request.timeoutInterval = 8.0

          if let token = try await bearerTokenIfPossible() {
              request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
          }

          let (data, response) = try await session.data(for: request)

          if let http = response as? HTTPURLResponse {
              if http.statusCode == 404 {
                  return nil
              }
              if http.statusCode == 429 {
                  throw ClientError.rateLimited
              }
              if http.statusCode != 200 {
                  throw ClientError.http(status: http.statusCode)
              }
          }

          do {
              return try JSONDecoder().decode(AircraftMetadata.self, from: data)
          } catch {
              throw ClientError.decoding(error)
          }
      }
  ```

- [ ] **Step 2: No test run yet — `MockADSBSource` still doesn't conform; build will fail. Proceed to B7.**

---

## Task B7: Update `MockADSBSource` with metadata fixtures

**Files:**
- Modify: `ios/Tailspot/Tailspot/MockADSBSource.swift`

- [ ] **Step 1: Add a metadata dictionary keyed by icao24, plus the new method**

  Open `ios/Tailspot/Tailspot/MockADSBSource.swift`. At the end of the class body (after the `aircraftInBbox(...)` method, before the closing `}` on line 105), insert:

  ```swift

      // MARK: - Metadata fixtures

      /// Hand-rolled metadata for each of the five mock planes — good
      /// enough to exercise the detail-view path end-to-end in MOCK mode.
      private let metadataByIcao24: [String: AircraftMetadata] = [
          "a3b15e": AircraftMetadata(
              icao24: "a3b15e",
              registration: "N12345",
              manufacturerName: "BOEING",
              manufacturerIcao: "BOEING",
              model: "737-800",
              typecode: "B738",
              operatorName: "United Airlines"
          ),
          "a52f30": AircraftMetadata(
              icao24: "a52f30",
              registration: "N87654",
              manufacturerName: "AIRBUS",
              manufacturerIcao: "AIRBUS",
              model: "A320-200",
              typecode: "A320",
              operatorName: "Southwest Airlines"
          ),
          "a91234": AircraftMetadata(
              icao24: "a91234",
              registration: "N201AS",
              manufacturerName: "BOMBARDIER",
              manufacturerIcao: "BOMBARDIER",
              model: "CRJ-700",
              typecode: "CRJ7",
              operatorName: "Alaska Airlines"
          ),
          "a4abcd": AircraftMetadata(
              icao24: "a4abcd",
              registration: "N98765",
              manufacturerName: "ATR",
              manufacturerIcao: "ATR",
              model: "ATR 72-600",
              typecode: "AT76",
              operatorName: "Delta Connection"
          ),
          // abc789 deliberately has NO metadata — exercises the 404/cache-miss
          // path on tap.
      ]

      func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
          // Match the small artificial latency from aircraftInBbox so the
          // loading UI in AircraftDetailView behaves like the live source.
          try? await Task.sleep(for: .milliseconds(100))
          return metadataByIcao24[icao24.lowercased()]
      }
  ```

- [ ] **Step 2: Run the full suite — confirm everything still builds and all existing tests pass**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 52 tests pass (no new tests added in B5–B7; we'll add ADSBManager-level tests in B8).

- [ ] **Step 3: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/ADSBSource.swift \
          ios/Tailspot/Tailspot/OpenSkyClient.swift \
          ios/Tailspot/Tailspot/MockADSBSource.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Extend ADSBSource with aircraftMetadata(icao24:); implement in both

  OpenSkyClient hits /metadata/aircraft/icao/{icao24} with the OAuth2
  bearer; 404 returns nil. MockADSBSource returns hand-rolled fixtures
  for four of the five mock planes (the fifth deliberately has no
  record so we exercise the cache-miss path).

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task B8: Failing tests for `ADSBManager.metadata(for:)`

**Files:**
- Modify: `ios/Tailspot/TailspotTests/ADSBManagerTests.swift` (append a new `@Suite`-block style — or add cases to the existing suite, matching whatever pattern is already used). For clarity here we add a new test file.
- Create: `ios/Tailspot/TailspotTests/ADSBManagerMetadataTests.swift`

- [ ] **Step 1: Write the failing test file**

  Create `ios/Tailspot/TailspotTests/ADSBManagerMetadataTests.swift`:

  ```swift
  //
  //  ADSBManagerMetadataTests.swift
  //  TailspotTests
  //
  //  Tests for ADSBManager.metadata(for:): cache consultation, source
  //  fall-through, dedupe of repeated requests, error handling.
  //

  import Testing
  import Foundation
  @testable import Tailspot

  // A minimal ADSBSource fixture that counts metadata calls and returns
  // configurable results, so tests can assert dedupe + error behavior.
  private final class CountingMetadataSource: ADSBSource, @unchecked Sendable {

      // Empty aircraft list for the bbox call — we only care about
      // metadata in these tests.
      func aircraftInBbox(
          lamin: Double, lomin: Double, lamax: Double, lomax: Double
      ) async throws -> [Aircraft] { [] }

      // Configurable per-icao24 result. Throws if the icao24 is in
      // `errors`; otherwise returns the value in `results`.
      var results: [String: AircraftMetadata?] = [:]
      var errors: Set<String> = []

      private(set) var callCounts: [String: Int] = [:]

      func aircraftMetadata(icao24: String) async throws -> AircraftMetadata? {
          callCounts[icao24, default: 0] += 1
          if errors.contains(icao24) {
              throw OpenSkyClient.ClientError.rateLimited
          }
          if let result = results[icao24] {
              return result
          }
          return nil
      }
  }

  private func makeMetadata(icao24: String, model: String) -> AircraftMetadata {
      AircraftMetadata(
          icao24: icao24,
          registration: nil,
          manufacturerName: nil,
          manufacturerIcao: nil,
          model: model,
          typecode: nil,
          operatorName: nil
      )
  }

  @Suite("ADSBManager metadata lookups")
  @MainActor
  struct ADSBManagerMetadataTests {

      @Test func cacheMissTriggersSourceCall() async {
          let src = CountingMetadataSource()
          let expected = makeMetadata(icao24: "abc", model: "737-800")
          src.results["abc"] = expected

          let mgr = ADSBManager(liveSource: src, mockSource: src)
          let got = await mgr.metadata(for: "abc")

          #expect(got == expected)
          #expect(src.callCounts["abc"] == 1)
      }

      @Test func repeatedCallsHitCacheOnly() async {
          let src = CountingMetadataSource()
          src.results["abc"] = makeMetadata(icao24: "abc", model: "737")

          let mgr = ADSBManager(liveSource: src, mockSource: src)
          _ = await mgr.metadata(for: "abc")
          _ = await mgr.metadata(for: "abc")
          _ = await mgr.metadata(for: "abc")

          #expect(src.callCounts["abc"] == 1)
      }

      @Test func unknownIcao24CachesAsMiss() async {
          let src = CountingMetadataSource()
          // No entry in src.results -> returns nil from source.

          let mgr = ADSBManager(liveSource: src, mockSource: src)
          let first = await mgr.metadata(for: "xyz")
          let second = await mgr.metadata(for: "xyz")

          #expect(first == nil)
          #expect(second == nil)
          // Cached as miss -> source called exactly once.
          #expect(src.callCounts["xyz"] == 1)
      }

      @Test func sourceErrorDoesNotPoisonCache() async {
          let src = CountingMetadataSource()
          src.errors.insert("err")

          let mgr = ADSBManager(liveSource: src, mockSource: src)
          // First call hits the error path; we should get nil back.
          let firstResult = await mgr.metadata(for: "err")
          #expect(firstResult == nil)

          // Now make the source succeed and retry.
          src.errors.remove("err")
          src.results["err"] = makeMetadata(icao24: "err", model: "A320")
          let second = await mgr.metadata(for: "err")

          #expect(second?.model == "A320")
          #expect(src.callCounts["err"] == 2)   // error did not cache
      }
  }
  ```

- [ ] **Step 2: Run — confirm `metadata(for:)` not in scope**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/ADSBManagerMetadataTests
  ```

  Expected: `value of type 'ADSBManager' has no member 'metadata'` build error.

---

## Task B9: Implement `ADSBManager.metadata(for:)`

**Files:**
- Modify: `ios/Tailspot/Tailspot/ADSBManager.swift`

- [ ] **Step 1: Add cache + method**

  Open `ios/Tailspot/Tailspot/ADSBManager.swift`.

  After the existing private state declarations (around line 137, after `private var locationProvider`), add:

  ```swift
      /// Per-icao24 metadata memoization. Lookups go through here lazily
      /// when AircraftDetailView appears for a given aircraft.
      private let metadataCache = MetadataCache()
  ```

  Then add this new method to the class — right before the closing `}` of `ADSBManager` (i.e., after `private func reAnnotate(...)` block, currently around line 295):

  ```swift
      /// Resolve metadata for a single icao24, consulting the in-memory
      /// cache first and falling back to the current source on miss.
      /// A successful response (including a 404 / nil) is cached;
      /// transport errors are NOT cached, so a later tap can retry.
      func metadata(for icao24: String) async -> AircraftMetadata? {
          switch await metadataCache.get(icao24: icao24) {
          case .hit(let value):
              return value
          case .notFetched:
              do {
                  let fetched = try await source.aircraftMetadata(icao24: icao24)
                  await metadataCache.set(icao24: icao24, value: fetched)
                  return fetched
              } catch {
                  // Transport / auth / 429 — surface via lastError but
                  // do NOT cache. The next tap will retry.
                  Log.adsb.error("metadata lookup failed for \(icao24, privacy: .public): \(error.localizedDescription, privacy: .public)")
                  self.lastError = "Metadata lookup failed: \(error.localizedDescription)"
                  return nil
              }
          }
      }
  ```

- [ ] **Step 2: Run only the metadata tests — confirm all pass**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests/ADSBManagerMetadataTests
  ```

  Expected: 4 tests pass.

- [ ] **Step 3: Run the full suite**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 56 tests pass.

- [ ] **Step 4: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/ADSBManager.swift \
          ios/Tailspot/TailspotTests/ADSBManagerMetadataTests.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Add ADSBManager.metadata(for:) backed by MetadataCache

  Lazy lookup: tap a reticle -> AircraftDetailView calls
  manager.metadata(for: icao24) -> cache hit returns immediately, miss
  triggers a single source fetch and caches the result (including
  known-misses). Transport errors are surfaced via lastError and NOT
  cached so the next tap can retry.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task B10: Update `AircraftDetailView` to render metadata

**Files:**
- Modify: `ios/Tailspot/Tailspot/AircraftDetailView.swift`

- [ ] **Step 1: Replace the view to accept an `ADSBManager` and resolve metadata**

  Open `ios/Tailspot/Tailspot/AircraftDetailView.swift`. Replace the entire file with:

  ```swift
  //
  //  AircraftDetailView.swift
  //  Tailspot
  //
  //  Detail sheet shown when the user taps an aircraft's reticle in the AR
  //  view. Surfaces every field we have, including per-icao24 metadata
  //  (manufacturer / model / registration / operator) fetched lazily
  //  from OpenSky on first appearance via ADSBManager.metadata(for:).
  //  Repeated taps on the same plane hit the in-memory MetadataCache.
  //

  import SwiftUI

  struct AircraftDetailView: View {
      let observed: ObservedAircraft
      let manager: ADSBManager
      @Environment(\.dismiss) private var dismiss

      @State private var metadata: AircraftMetadata?
      @State private var didLoad = false

      var body: some View {
          NavigationStack {
              List {
                  Section("Identity") {
                      row("Callsign",     observed.aircraft.callsign ?? "—")
                      row("ICAO24",       observed.aircraft.icao24)
                      row("Country",      observed.aircraft.originCountry)
                      row("Registration", metadata?.registration ?? "—")
                      row("Manufacturer", metadata?.manufacturerName ?? "—")
                      row("Model",        metadata?.model ?? "—")
                      row("Operator",     metadata?.operatorName ?? "—")
                  }

                  Section("Flight") {
                      row("Origin → Destination", "—")
                      row("Altitude", altitudeText)
                      row("Speed",    speedText)
                      row("Track",    trackText)
                  }

                  Section("Geometry from you") {
                      row("Bearing",         String(format: "%.1f°", observed.bearingDeg))
                      row("Elevation",       String(format: "%+.1f°", observed.elevationDeg))
                      row("Slant distance",  String(format: "%.1f km", observed.slantDistanceMeters / 1000))
                      row("Ground distance", String(format: "%.1f km", observed.groundDistanceMeters / 1000))
                  }

                  Section {
                      Text(footerText)
                          .font(.footnote)
                          .foregroundStyle(.secondary)
                  }
              }
              .navigationTitle(observed.aircraft.callsign ?? observed.aircraft.icao24)
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                  ToolbarItem(placement: .topBarTrailing) {
                      Button("Done") { dismiss() }
                  }
              }
              .task {
                  guard !didLoad else { return }
                  didLoad = true
                  metadata = await manager.metadata(for: observed.aircraft.icao24)
              }
          }
      }

      private var footerText: String {
          if metadata == nil && didLoad {
              return "OpenSky has no record for this aircraft. Origin/destination still requires a separate data source (see PLAN.md)."
          }
          return "Origin/destination requires a data source beyond OpenSky's /states/all. See PLAN.md."
      }

      // MARK: - Formatting

      private var altitudeText: String {
          let m  = Int(observed.aircraft.altitudeMeters.rounded())
          let ft = Int((observed.aircraft.altitudeMeters * 3.28084).rounded())
          return "\(ft.formatted(.number)) ft (\(m.formatted(.number)) m)"
      }

      private var speedText: String {
          guard let mps = observed.aircraft.velocityMps else { return "—" }
          let mph = mps * 2.23694
          let kt  = mps * 1.94384
          return String(format: "%.0f mph (%.0f kt)", mph, kt)
      }

      private var trackText: String {
          guard let t = observed.aircraft.trackDeg else { return "—" }
          return String(format: "%.0f°", t)
      }

      private func row(_ label: String, _ value: String) -> some View {
          HStack {
              Text(label)
              Spacer()
              Text(value).foregroundStyle(.secondary)
          }
      }
  }
  ```

- [ ] **Step 2: Find and update the call site in `ContentView.swift`**

  Open `ios/Tailspot/Tailspot/ContentView.swift` and find where `AircraftDetailView(observed: ...)` is constructed (likely inside a `.sheet(item:)` or similar). The current call passes only `observed:`; update it to pass `manager: adsb` (the `@StateObject` named `adsb` in `ContentView`).

  Search:

  ```sh
  grep -n "AircraftDetailView" ios/Tailspot/Tailspot/ContentView.swift
  ```

  At each match, change

  ```swift
  AircraftDetailView(observed: someObserved)
  ```

  to

  ```swift
  AircraftDetailView(observed: someObserved, manager: adsb)
  ```

  If the variable name in `ContentView` differs from `adsb`, use whatever name the `@StateObject` is declared with there.

- [ ] **Step 3: Run the test suite — confirm nothing regressed**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 56 tests pass.

- [ ] **Step 4: Commit**

  ```sh
  git add ios/Tailspot/Tailspot/AircraftDetailView.swift \
          ios/Tailspot/Tailspot/ContentView.swift
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  AircraftDetailView: show manufacturer / model / registration / operator

  Replaces the "Aircraft type: —" placeholder with four fields populated
  from OpenSky's /metadata/aircraft/icao endpoint. Lookup is lazy
  (per-tap), cached per-session via ADSBManager.metadataCache, so a
  re-tap is instant. ContentView passes the manager in.

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task B11: Field test — manual checkpoint

- [ ] **Step 1: Deploy and observe**

  ```sh
  bin/deploy --launch
  ```

  Expected: build + install + launch as in A7.

- [ ] **Step 2: Test MOCK mode (no OpenSky credits needed)**

  Ask Noah:

  > In the app, tap the ADSB status row to switch to MOCK mode (if not already). Tap one of the AR reticles (or list rows) — the detail sheet should now show Manufacturer / Model / Operator / Registration filled in (e.g., "BOEING / 737-800 / United Airlines / N12345" for UAL248). One mock plane (JBU412 / abc789) is deliberately missing metadata — tap that and confirm fields show "—".

  Wait for confirmation before proceeding.

- [ ] **Step 3: Test LIVE mode**

  Ask Noah:

  > Switch back to LIVE mode. Tap any aircraft in the bottom list. Confirm the detail sheet eventually shows manufacturer/model/operator if OpenSky has them, or "—" if not.

  Inspect `bin/log-tail` for `metadata lookup failed` lines.

- [ ] **Step 4: If anything's off, debug before proceeding to Phase C.**

---

# Phase C — Roadmap refresh + docs

## Task C1: Update PLAN.md (refresh §9, add §3.0c, update §8)

**Files:**
- Modify: `PLAN.md`

- [ ] **Step 1: Replace §9 (Immediate next steps)**

  Open `PLAN.md`. Find the heading `## 9. Immediate next steps (post-POC)` and replace the entire section through the end of the file (currently ending with item #6 about the accuracy bar) with:

  ```markdown
  ## 9. Immediate next steps (post-POC)

  Friday POC (§3.0a) shipped early. The deploy loop (§3.0c) shipped May 13, 2026, alongside aircraft type lookup. Re-prioritized backlog after that:

  | # | Item | Est. | Why now |
  |---|------|------|---------|
  | 1 | ~~Remote-deploy loop + Log wrapper~~ ✅ shipped 2026-05-13 | — | Tooling investment that pays back on every subsequent item. |
  | 2 | ~~Aircraft type lookup~~ ✅ shipped 2026-05-13 | — | First product change through the new loop. |
  | 3 | **Heading-accuracy color cue** | ~10 min | First "trivial" iteration through the loop — proves the loop is fast for tiny UI changes. Turn the heading readout red when `headingAccuracy > 15°`. |
  | 4 | **Rotate leaked OpenSky client secret** | ~10 min | Long-standing security debt from commit `869d06d`. No code; regenerate on opensky-network.org, update the user-only scheme's env var. |
  | 5 | **Catch flow v0 — tap-Catch button + SwiftData persistence** | ~3–4 hr | First actual *game* mechanic. AircraftDetailView gets a "Catch" button; SwiftData stores a `Catch` model (icao24, callsign, model, timestamp, observer lat/lon, slant distance). Phase 1 work pulled forward because the deploy loop makes UI iteration cheap. |
  | 6 | **Hangar (collection) v0** | ~2–3 hr | List/grid of catches, grouped by airline or aircraft type, with tap-for-detail. Closes the product loop visually. |
  | 7 | **Replay harness** | ~1.5 hr | Phase 0-main infra. Becomes more valuable once a game exists to validate. |
  | 8 | **Visual confirmation (Vision + COCO airplane class)** | ~1 day | Per §1.1a. Hardest of these; defer until accuracy bar work (§3.0 main) starts. |
  ```

- [ ] **Step 2: Add new §3.0c describing the deploy loop**

  In `PLAN.md`, find `### Phase 0b — POC retrospective / what's still on the table` (around line 135). Immediately *before* that line, insert:

  ```markdown
  ### Phase 0c — Remote-deploy loop ✅ DELIVERED (May 13, 2026)

  A Bash-driven loop for iterating on the phone without leaving the editor:

  - `bin/deploy [--no-build] [--no-launch] [--dry-run]` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches the app on Noah's paired iPhone (UDID stashed in `tools/deploy/config.sh`).
  - `bin/log-start` / `bin/log-tail` / `bin/log-stop` — background `log stream` filtered on subsystem `com.landesberg.tailspot`, redirected to `~/Library/Logs/tailspot/device.log`. Survives across deploys.
  - All app-side logging now flows through `Log.swift` (`os.Logger` wrapper, categories: openSky / adsb / location / motion / ui) so the subsystem-predicate filter actually catches everything.

  Why: tightens the test-and-iterate loop. Claude can edit code, run the unit tests, push a build to the phone, and read back device logs in a single chat turn — Noah picks up the phone and sees the new build already running.

  ```

- [ ] **Step 3: Update §8 repo structure**

  In `PLAN.md`, find `## 8. Repo structure (current)` and inside the code block, add these lines at the appropriate places:

  - After the line `└─ ios/                     ← Xcode project`, insert two new lines BEFORE that line (so `bin/` and `tools/` appear first):

    ```
    ├─ bin/                     ← deploy / log-start / log-stop / log-tail (Phase 0c)
    ├─ tools/
    │  └─ deploy/config.sh      ← UDID, scheme, paths
    ```

  - Under `Tailspot/`, after the line `│  ├─ Aircraft.swift          — Aircraft struct + Decodable + FailableDecodable + extrapolatedPosition`, add:

    ```
    │  ├─ AircraftMetadata.swift  — Decodable struct from /metadata/aircraft/icao
    │  ├─ MetadataCache.swift     — bounded LRU actor keyed by icao24
    │  ├─ Log.swift               — os.Logger wrapper, subsystem com.landesberg.tailspot
    ```

  - Under `TailspotTests/`, append:

    ```
    │  ├─ AircraftMetadataDecodingTests.swift — payload + tolerant decode
    │  ├─ MetadataCacheTests.swift            — LRU + miss-as-hit semantics
    │  └─ ADSBManagerMetadataTests.swift      — cache consultation, dedupe, error path
    ```

  And remove `└─` from whichever line is no longer last.

- [ ] **Step 4: No test run; this is doc-only.**

---

## Task C2: Update CLAUDE.md (Deploy loop subsection + Logger convention)

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Add a "Deploy loop" subsection under "Build and run"**

  Open `CLAUDE.md`. Find the heading `## Build and run` and the line `The iOS app is built and run from Xcode (`⌘R` on Noah's machine) on a physical iPhone.` Right *before* the `### OpenSky credentials` subheading, insert:

  ```markdown
  ### Remote-deploy loop

  For tighter iteration than ⌘R-in-Xcode, the repo now ships a Bash-driven loop:

  - `bin/deploy [--launch]` — builds via `xcodebuild`, installs via `xcrun devicectl`, optionally launches the app. Reads device UDID / scheme / bundle ID from `tools/deploy/config.sh`. Wireless dev pairing must already be active (Xcode's "Connect via network" toggle — confirm with `xcrun devicectl list devices`).
  - `bin/log-tail [-n N] [-f]` — reads `~/Library/Logs/tailspot/device.log`, which `bin/log-start` keeps fresh via `log stream --device <UDID> --predicate 'subsystem == "com.landesberg.tailspot"'` running in the background.

  Rules:
  - **Always run the unit tests before `bin/deploy`** when touching testable code. The loop will happily deploy a broken build.
  - If `xcrun devicectl install` fails because the iPhone is unreachable, surface the message and stop — don't silently retry. Most "deploy failed" cases are an unlocked phone or WiFi gap, both of which require Noah's attention.
  - The device UDID in `tools/deploy/config.sh` is Noah's; override locally via `tools/deploy/config.local.sh` (gitignored) if running from a different machine.

  ```

- [ ] **Step 2: Add a Logger-convention bullet under "Key code patterns"**

  Open `CLAUDE.md`. Find the heading `## Key code patterns` and the subhead `### CMMotion / CLLocation / AVCapture concurrency`. Immediately AFTER that section (the one ending `Revisit when ARKit lands.`), insert:

  ```markdown
  ### Logging through `Log.swift`

  All app-side logging flows through `Log.swift`, a thin enum of `os.Logger` instances grouped by category:

  ```swift
  Log.openSky.info("token cache hit")
  Log.adsb.error("metadata lookup failed for \(icao, privacy: .public)")
  Log.ui.notice("camera setup failed")
  ```

  The subsystem is always `"com.landesberg.tailspot"` — `bin/log-tail` predicates on this so the Mac sees a filtered stream instead of the device's full firehose. Use `privacy: .public` on string interpolations whose contents you actually want to read in `log` output (Apple redacts string interpolations by default).

  **Do not `print(...)` from app code.** Existing `print` calls have been migrated; new ones won't be visible in the deploy-loop logs.

  ```

- [ ] **Step 3: No test run; doc-only.**

---

## Task C3: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the "Build and run" section**

  Open `README.md`. Find the section heading `## Build and run`. Replace its body with:

  ```markdown
  iOS app, built via Xcode (`⌘R`) on a physical iPhone. Simulator can't provide GPS/compass/camera, so device is required.

  For tighter iteration there is also a Bash-driven deploy loop: `bin/deploy --launch` builds, installs over the paired iPhone's wireless link, and launches the app; `bin/log-tail` reads the filtered device log. See [CLAUDE.md "Remote-deploy loop"](CLAUDE.md#remote-deploy-loop) for details.

  For LIVE ADS-B data, register a free account at [opensky-network.org](https://opensky-network.org), then add `OPENSKY_CLIENT_ID` and `OPENSKY_CLIENT_SECRET` to a **user-only** Xcode scheme's Environment Variables. The MOCK toggle in the app works without credentials.

  Unit tests via `xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' -only-testing:TailspotTests`.
  ```

- [ ] **Step 2: Commit C1–C3 together**

  ```sh
  git add PLAN.md CLAUDE.md README.md
  git diff --cached | grep -iE 'OPENSKY|client_secret|EnvironmentVariable' \
    || echo "no leaked secrets in staged diff"
  git commit -m "$(cat <<'EOF'
  Docs: deploy-loop section in CLAUDE.md/README; refreshed PLAN §9

  Records the §3.0c deploy-loop delivery and re-prioritizes §9's backlog
  to pull catch flow + hangar earlier (now that the loop makes UI work
  cheap) and push the replay harness + visual confirmation later. Adds
  Logger conventions under CLAUDE.md "Key code patterns".

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )"
  ```

---

## Task C4: Final verification

- [ ] **Step 1: Full unit suite green**

  ```sh
  xcodebuild test -project ios/Tailspot/Tailspot.xcodeproj -scheme Tailspot \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
    -only-testing:TailspotTests
  ```

  Expected: 56 tests pass.

- [ ] **Step 2: One last deploy to confirm the live loop**

  ```sh
  bin/deploy --launch
  ```

  Expected: clean build, install, launch.

- [ ] **Step 3: `git status` is clean**

  ```sh
  git status
  ```

  Expected: `nothing to commit, working tree clean`. No untracked files outside `build/` and `~/Library/Logs/tailspot/`.

- [ ] **Step 4: Inspect the commit list**

  ```sh
  git log --oneline -20
  ```

  Expected to include (newest first):

  - Docs: deploy-loop section …
  - AircraftDetailView: show manufacturer / model …
  - Add ADSBManager.metadata(for:) …
  - Extend ADSBSource with aircraftMetadata(icao24:) …
  - Add MetadataCache actor + tests
  - Add AircraftMetadata + decoding tests
  - Add remote-deploy loop: bin/deploy …
  - Add Log.swift wrapper; migrate the three print() call sites
  - Add design spec: remote-deploy loop …

---

## Self-review checklist (run before claiming done)

- [ ] **Spec coverage.** Walked back through each section of `docs/superpowers/specs/2026-05-13-remote-deploy-loop-and-aircraft-type-lookup-design.md` — every requirement (loop scripts, Log.swift, AircraftMetadata, MetadataCache, OpenSkyClient.aircraftMetadata, ADSBManager.metadata, AircraftDetailView, PLAN/CLAUDE/README updates) is covered above. The mock-source fixture metadata + the abc789 deliberate-miss are covered in Task B7.
- [ ] **Placeholder scan.** No "TBD", "implement later", "similar to Task N". Every test step shows full code; every command step shows the exact command and expected output (or success criteria).
- [ ] **Type consistency.** `AircraftMetadata.operatorName` matches across the type, tests, fixtures, view. `MetadataCache.Lookup` enum cases (`.notFetched`, `.hit(_)`) match across tests and implementation. `ADSBSource.aircraftMetadata(icao24:)` signature is identical in the protocol, OpenSkyClient, MockADSBSource, and CountingMetadataSource fixture.
- [ ] **TDD discipline.** Each feature task pairs a failing-test step with an implementing step. The protocol-change tasks (B5–B7) are sequenced so the project never sits in a broken state across more than one commit boundary.
