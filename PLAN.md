# Tailspot — Build, Test & Ship Plan

iOS app that turns plane spotting into a collection game. Point phone at sky → AR overlay identifies aircraft via ADS-B + geometry → catch to collection.

This document covers the architectural decisions, phased roadmap, testing strategy, risks, and the open questions that need answers before we commit to a stack.

---

## 1. Architectural decisions (and why)

These are the four calls that shape everything else. Worth getting right before code.

### 1.1a Visual confirmation — deferred but planned

The original §1.1 call was: identification is geometric, not visual. That call holds — for *which plane is which*, geometry is the right answer.

But for *where to draw the AR reticle on screen*, Noah wants visual confirmation: the reticle should sit on the actual plane in the camera frame, not just at the geometrically-predicted position. Compass error (±5–15° on iPhone) means the predicted position can be visibly off from the real plane. This is real and worth fixing.

Plan when we tackle it (Phase 0 main, after the replay harness lands):

- Add a Vision-framework `VNCoreMLRequest` running at ~10 fps on the camera buffer, using a model with the COCO `airplane` class (YOLOv8n is the obvious starting point).
- For each ADS-B plane currently inside the predicted FOV, look for a detected airplane near its predicted position. If found, lock the reticle to the **visual** position. If not, fall back to drawing the reticle at the **predicted** position with a faint / lower-confidence visual treatment (so e.g. on cloudy days you still see "the plane is supposed to be here").
- Detection range limit is real: a 737 at 30 km cruise is ~0.5 px on a 400-px portrait viewport — undetectable by any general object detector. Visual confirmation effectively works for **close** planes (regional approaches, helicopters, small craft within ~10–15 km). Cruise traffic stays predicted-only.

Not started; tracked here so it's not lost.

### 1.1 Identification is geometric, not visual

The "AR plane recognition" framing is misleading. ARKit and CoreML cannot reliably distinguish a 737-800 from a 737-700 through a phone camera at typical spotting distances (3–10 km, often 9+ km up). Object detection on a 20-pixel silhouette in a hazy sky is a research problem, not a v1 feature.

The actual identification is **geometric correlation**:

1. Phone knows its own pose: GPS `(lat, lon, alt)` + heading + pitch from CoreMotion + CLLocation.
2. ADS-B feed gives every nearby aircraft's `(lat, lon, alt, velocity, heading)`.
3. For each aircraft compute the line-of-sight vector from the phone — its true bearing and elevation angle.
4. Compare against the phone's pointing direction. Aircraft within angular tolerance is a candidate.
5. Render an AR overlay at the aircraft's projected screen position.

ARKit's value here is *drift correction* (visual-inertial odometry keeps the reticle stable as the user moves) and a clean session for camera + world-tracking, **not** recognition. This dramatically de-risks the AR work — we are doing geometry, not ML.

### 1.2 Backend from day 1, not optional

A client-only architecture (each app hits OpenSky directly) is tempting for MVP but cripples us:
- Per-user rate limits instead of pooled.
- No ADS-B caching across nearby users.
- ADS-B credentials shipped in the app binary.
- No way to validate catches against actual ADS-B history → trivial to cheat.
- Can't swap data providers without an app update.

We need a backend for accounts, leaderboards, achievements, sync, and anti-cheat anyway. Building a thin proxy from day 1 also gives us a **provider-abstraction seam** — when the OpenSky-vs-paid decision lands (see §6.1), only the backend changes.

### 1.3 Disambiguation is a v1 design problem, not polish

Near a hub, two aircraft within 3–5° of each other in the user's FOV is the common case, not the edge case. "Lock onto one" is the wrong interaction. The v1 model:

> Render an overlay tag for **every** aircraft inside the angular tolerance cone. User taps the specific tag to inspect → tap "Catch" to claim.

This reframes the screen from "AR target reticle" to "AR floating label set." It's actually simpler to build and feels more like a game.

### 1.4 Photo strategy: commissioned illustrated cards

Photo licensing is a swamp. Planespotters.net images aren't freely licensed; AI-generated images of branded liveries are a legal gray zone; user-uploads create moderation burden and offer no v1-day inventory.

Recommendation: **commissioned vector illustrations indexed by (aircraft type × airline livery)**, treated like trading cards. Pros:
- Zero photo licensing exposure.
- Distinctive visual identity (the app's "look" is the cards).
- Scales incrementally — start with the 200 most-spotted combinations, fill in as needed.
- Same illustration style means new cards always feel "right."

Open: airline livery as trade dress is generally fair to depict, but trademarks (the airline logo) need care. We use livery + tail design but avoid the literal logo on the card face.

---

## 2. Tech stack

| Layer | Choice | Why |
|---|---|---|
| iOS | Swift, SwiftUI, SwiftData | iOS 17+ targets unlock SwiftData and modern SwiftUI; covers ~95% of likely users |
| AR | ARKit + SceneKit/RealityKit overlay | Standard stack; we need AR session for camera + drift correction |
| Sensors | CoreLocation (when-in-use), CoreMotion (CMDeviceMotion), CLHeading | All Apple-native, no third-party |
| Auth | Sign in with Apple | Free, App Store likes it, minimal PII |
| Backend | Node/TypeScript on Fly.io (or Cloudflare Workers) | Fast iteration, cheap at v1 scale; revisit if scale demands |
| DB | Postgres (managed) | Boring, correct |
| Cache | Redis or KV — short-TTL ADS-B bbox cache | ~5s TTL coalesces requests across nearby users |
| ADS-B | OpenSky (free / dev) → swap-able provider | See §6.1 — the choice is gated on monetization |
| Aircraft metadata | OpenFlights + manually curated table | One-time import, small file |
| Telemetry | A privacy-respecting choice (TBD: Posthog self-hosted vs. raw logs) | Need it for tuning angular tolerance, but cautious of PII |

**Provider abstraction.** The backend exposes one internal interface — `getAircraftInBbox(lat1, lon1, lat2, lon2) → [Aircraft]` — implemented by an `OpenSkyAdapter`, with stubs for `ADSBExchangeAdapter` and `FlightAwareAdapter`. The adapter swap is a config change, not a refactor.

---

## 3. Phased roadmap

Phase length assumes **solo dev, full-time**. With a team of 2–3 (iOS + backend + design), compress by ~40%. The brief did not specify team size — see §6.5.

### Phase 0a — Friday proof of concept ✅ DELIVERED (May 5–7, 2026)

Original goal: *"on Noah's phone, a screen showing live aircraft labels at the right places in the sky."* Field-tested in Berkeley with real planes overhead — labels land on or near actual aircraft, system fundamentally works.

**What actually shipped (more than the original scope):**

Day 1 (Tue):
- Xcode 16 / Swift 6 SwiftUI project on iPhone 16 / iOS 26.
- `LocationManager` (CLLocation + CLHeading), `MotionManager` (CMDeviceMotion), `CameraPreview` (AVCaptureSession via UIViewRepresentable).
- Live sensor readout overlay (GPS, true-north heading w/ accuracy, pitch/roll/cam-elevation).

Day 2 (Wed):
- `OpenSkyClient` + `Aircraft` decoder (positional JSON, FailableDecodable for lossy per-element decoding).
- `Geo` helpers: haversine distance, true bearing, elevation, projection (Geo.project, Geo.screenPosition).
- `ADSBSource` protocol with `OpenSkyClient` + `MockADSBSource` (5 hand-picked synthetic planes at fixed bearings/distances, for couch-testing).
- `ADSBManager` (@MainActor ObservableObject) polling the source, annotating each aircraft with bearing/elevation/distance from the user, sorting by slant distance.
- Scrollable bottom list showing every plane in the 50 km bbox.
- Live/Mock toggle in the UI (tap the ADSB status row).

Day 3 (Thu):
- AR label projection: per-aircraft cyan reticle box drawn at the plane's projected screen position via `obs.screenPosition(phoneHeadingDeg:cameraElevationDeg:in:)`.
- Pitch-vs-camera-elevation bug fix: `CMAttitude.pitch ≈ +90°` when phone is held upright in portrait, so camera elevation = `90 − pitch`. Encoded in `MotionManager.cameraElevationDeg`.
- Forward-extrapolation: `Aircraft.extrapolatedPosition(at:)` projects each plane along its track using its reported velocity to bring 5–15 s-old ADS-B positions to "now."
- Tap-to-inspect: tapping a reticle presents `AircraftDetailView` with every available field (callsign / ICAO24 / country / altitude in ft (m) / speed in mph (kt) / track / bearing / elevation / distances).

Day 4+ (Fri–Wed, post-POC iteration):
- OAuth2 client-credentials auth with the OpenSky API (registered tier = 4000 credits/day vs 400 anonymous). Token cached via `OSAllocatedUnfairLock`. Credentials read from `OPENSKY_CLIENT_ID`/`OPENSKY_CLIENT_SECRET` env vars.
- 429-aware exponential backoff (up to 120 s) in `ADSBManager` so we stop hammering a rate-limited server.
- **Smooth tracking**: split network polling (every 20 s) from re-annotation (every 1 s). Reticles glide continuously with each plane's projected motion between fetches rather than jumping every 20 s.
- **Visibility filter**: `ObservedAircraft.isLikelyVisibleToObserver` — true when `elevationDeg > 0` AND `slantDistanceMeters < 100 km`. AR labels filter by this; bottom list does not.
- 44 unit tests across `GeoTests`, `AircraftDecodingTests`, `ADSBManagerTests` covering geometry, OpenSky decode (including FailableDecodable's lossy behavior), annotation, sort order, error handling, extrapolation, visibility predicate, and screen projection (cardinal directions, FOV bounds, 0°/360° wraparound).

**Field test (Wed evening, Berkeley):**
- Labels land on or near actual aircraft ("pretty impressive" per Noah).
- Some planes don't appear at all — OpenSky free tier excludes MLAT, so most small GA, helicopters, military traffic are invisible. Coverage limit, not a bug.
- Tracking was "very loosely" smooth — fixed by the 1 Hz re-annotation loop landed Wed evening.
- See §3.0b for what comes next.

### Phase 0c — Remote-deploy loop ✅ DELIVERED (May 13, 2026)

A Bash-driven loop for iterating on the phone without leaving the editor:

- `bin/deploy [--no-build] [--no-launch] [--dry-run]` — builds via `xcodebuild`, installs via `xcrun devicectl`, launches the app on Noah's paired iPhone (UDID + config in `tools/deploy/config.sh`; override locally via gitignored `config.local.sh`).
- `bin/log-start` / `bin/log-stop` / `bin/log-tail` — wrappers around a background `log stream` filtered on subsystem `com.landesberg.tailspot`. **Known gap:** the host macOS `log` binary on Noah's Mac does not accept `--device <UDID>`, so device-side streaming is currently a no-op (`log-start` exits 0 with a notice; `log-tail` is empty). Tracked in §9 as a follow-up; candidate fixes are `idevicesyslog` (libimobiledevice via Homebrew) or `xcrun devicectl device process launch --console` blocking attach.
- All app-side logging now flows through `Log.swift` (`os.Logger` wrapper, categories: `openSky` / `adsb` / `location` / `motion` / `ui`) so the subsystem-predicate filter will catch everything when the streaming gap is fixed.

Why: tightens the test-and-iterate loop. Claude can edit code, run the unit tests, push a build to the phone, and report back in a single chat turn — Noah picks up the phone and sees the new build already running. Log capture is the missing piece for the "tightest" loop but doesn't block the rest.

### Phase 0b — POC retrospective / what's still on the table

Things observed in field testing or left over from Phase 0a that aren't yet in code:

1. **Visual confirmation** (per §1.1a) — labels track to *predicted* position, not actual visual plane position. Compass error (±5–15°) is the dominant offset source. Documented roadmap: Vision-framework + YOLOv8 COCO airplane class, lock reticle to detection when found, faint predicted reticle as fallback for cloudy days. **Postponed by user direction.**
2. **Heading-accuracy color cue** — `headingAccuracy` is shown in the readout but Noah didn't notice the value during testing. Color the line red when `>15°` so it's actionable. ~10 min of work.
3. **Aircraft type lookup** — OpenSky has a per-`icao24` metadata endpoint (`/metadata/aircraft/icao/{icao24}`) that returns manufacturer/model/registration. Fill the "Aircraft type: —" placeholder in `AircraftDetailView` and optionally on the compact label. Cache per-icao24 to keep credit usage low. ~45–60 min. **Queued as the next session's first piece.**
4. **Origin/destination route info** — not in `/states/all`; needs a different API (FlightAware, ADSBexchange, etc.) or callsign-prefix → airline-schedule lookup. Deferred indefinitely.
5. **Replay harness** (§3.0 main) — record sensor + ADS-B traces during a session, replay later for offline regression testing. Still not built. Phase 0 main blocker.

### Phase 0 — De-risk geometric ID (2–4 weeks after POC)

The single highest-risk technical assumption is "geometric correlation actually picks the right plane in the field." We validate before building anything else.

**Build:**
- Bare iOS app: open camera, fetch your location, fetch ADS-B in a 50-km bbox via OpenSky, draw a label for every aircraft at its projected screen position. No game, no auth, no collection.
- Plus: a **sensor+ADS-B recorder/replay harness**. Capture `(timestamp, GPS, CMDeviceMotion stream, ADS-B snapshot)` tuples to disk during a field session. Replay them offline through the ID engine. This is non-negotiable Phase 0 infra — without it, every tuning iteration requires standing outside near an airport.

**Hard success criterion:**
> In a field test near [chosen test airport — e.g., LGA approach path] with ≥2 aircraft visible simultaneously, the ID engine picks the correct aircraft for **≥80%** of catches across **≥50 trials** spanning at least 3 sessions.

If we miss this number, Phase 0 fails. We either tune the engine, change the interaction model (e.g., always show all candidates), or rethink whether this product is buildable. Better to fail Phase 0 in 3 weeks than Phase 2 in 6 months.

**Error budget to design against:**
- iPhone compass: typically ±5°, ±15° near cars/metal/buildings. `CLHeading.headingAccuracy` exposes this — refuse to identify and trigger calibration (figure-8) UX when it's bad.
- Pitch is more accurate than heading — disambiguate by altitude when two planes are bearing-aligned.
- ADS-B position lag: 5–15s typical. A 500-kt aircraft moves ~2.5 km in 10s — several degrees of angular error at viewing distance. **Forward-extrapolate** ADS-B positions using the reported velocity vector to current time before correlating.
- ADS-B coverage gaps: GA aircraft often lack ADS-B Out; receiver density varies by region. Phase 0 sessions near a hub guarantee coverage.

### Phase 1 — MVP / TestFlight alpha (8–12 weeks)

**Goal:** internal team + ~10 trusted testers can use the core game loop end-to-end.

**Build:**
- Catch flow: AR view → tap label → review card → catch.
- Collection ("Hangar"): SwiftData store, organized by airline / aircraft type / region, with filters and sort.
- Points + rarity scoring (v1 formula: base by aircraft type rarity × distance traveled multiplier; tunable).
- Sign in with Apple.
- Backend: ADS-B proxy w/ short-TTL cache, account service, catch ingestion endpoint, sync endpoint.
- Catch validation server-side (not enforced in alpha, but recorded — instrument first, enforce in beta).
- ~30 major airlines + ~50 aircraft types in the metadata table.

**Out of scope for Phase 1:** achievements, streaks, social features, cross-device sync, illustrated cards (use placeholder type silhouettes).

### Phase 2 — Closed beta (6–10 weeks)

**Goal:** ~200 TestFlight beta testers; product is fun to play, not just functional.

**Build:**
- Achievements + badges system (data-driven so we can add new ones without app updates).
- Daily streak + passive engagement (e.g., "rare-aircraft alert: a 747 is over your area" push notifications, opt-in).
- Cross-device sync (catches sync via backend).
- Anti-cheat: enforce server-side catch validation. Reject catches where the claimed aircraft was not within angular tolerance from the user's reported pose at the catch timestamp (with a small window of slack for ADS-B lag).
- Illustrated cards for top ~200 (type × airline) combinations.
- Onboarding flow: permissions explanation + compass calibration tutorial.

### Phase 3 — Launch (4–6 weeks)

**Goal:** App Store launch in a deliberate region.

**Build:**
- App Store assets (screenshots, video, ASO).
- Privacy policy, terms of service.
- Localization: English-only at launch.
- Final compass-calibration UX polish — by far the highest-impact onboarding step. Most user-facing failure modes trace to bad heading.
- **Region-limited launch.** ADS-B coverage is non-uniform: dense around major hubs and the US/EU, sparse in remote areas and parts of the global south. Launching in regions where the implicit promise ("see every plane overhead") will be met. Recommendation: US + Western Europe at launch.
- Crash & error monitoring (Sentry or similar).

### Phase 4 — Post-launch (ongoing)

Friends/leaderboards, rare-aircraft discovery features, broader metadata coverage, photo upload (optional, moderated), more nuanced scoring. Monetization features per §6.1 outcome.

---

## 4. Testing strategy

AR + outdoors + ADS-B-required is genuinely awkward to test. Layered approach:

1. **Unit tests.** Geometry (LOS, bearing, elevation, angular delta), ADS-B parsing, scoring, achievement triggers, anti-cheat validator. All deterministic, fast, run on every commit.
2. **Replay harness (built in Phase 0).** Recorded sensor+ADS-B traces replay through the ID engine. Catches accuracy regressions when we tweak the algorithm.
3. **Synthetic harness.** Generate fake aircraft + simulated phone pose for development without going outside. Especially useful for testing edge cases (two planes near-aligned, fast-moving aircraft, ADS-B dropouts).
4. **TestFlight field testing.** Manual sessions, ideally near a busy approach path. Internal team in Phase 1, expanded to ~200 in Phase 2.
5. **Telemetry-driven tuning.** In-app counters for "candidates shown," "catches attempted," "catches succeeded" — visualize per-session to tune angular tolerance and lag-extrapolation parameters.
6. **Backend tests.** API tests, catch-validator unit tests, load tests on the ADS-B cache (it's the hot path).

---

## 5. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Geometric ID accuracy below threshold in field | Medium → Low | Critical | Phase 0a field test: labels land on/near planes. §3.0 main accuracy bar still TBD. |
| 2 | ADS-B commercial licensing forces costly vendor | High | High | Resolved for v1: OpenSky free tier fits non-commercial use (§6.1) |
| 3 | Compass calibration UX failure → user rage | High | High | Block ID when `headingAccuracy` is poor; mandatory calibration onboarding. Partially exposed via heading-accuracy in readout; color cue (§3.0b #2) pending. |
| 4 | ADS-B 5–15s lag causes mis-identifies on fast aircraft | Medium → Low | Medium | `Aircraft.extrapolatedPosition(at:)` projects positions to "now" using velocity/track. Re-annotated every 1 s in ADSBManager. |
| 5 | Photo / livery licensing | Low (with illustrated cards) | High | Commissioned cards strategy (§1.4) |
| 6 | App Store rejection (camera + location + AR) | Medium | High | Clear permission strings; location-**when-in-use** only; explicit privacy explainers in onboarding |
| 7 | ADS-B coverage gaps disappoint users in non-hub regions | Medium | Medium | Region-limited launch (§3.3); in-app messaging when no aircraft are in range |
| 8 | Backend cost spike on virality | Low at v1 scale | Medium | Aggressive caching; rate limiting per user; alarms on egress |
| 9 | **Secret leak via Xcode shared scheme** | High (occurred twice) | High | `.gitignore` blocks all shared schemes via `**/` pattern + `*.xcscheme` filename rule, allowing exactly the one committed `Tailspot.xcscheme` via `!` exception. **gitignore does not protect already-tracked files** — see CLAUDE.md for full guidance. |

---

## 6. Open questions

Status legend: ✅ resolved · ⏳ still open

### ✅ 6.1 Monetization model — **resolved: free, no monetization**

Implication: **OpenSky Network's free tier is the v1 ADS-B source.** Their terms cover "research and non-commercial purposes," and a free, ad-free, no-IAP app squarely fits. We still build the provider-abstraction adapter (§2) so we can swap if usage outgrows OpenSky's limits, but no paid feed is required for v1.

### ✅ 6.2 Team — **resolved: solo dev (Noah + Claude), no prior iOS background**

This rewrites the working model:

- **Claude writes the code.** Noah reviews, runs, debugs, and field-tests.
- **Explain-as-we-go.** Every Swift/SwiftUI/ARKit pattern Claude introduces gets a short explanation in commit messages or comments — Noah is learning iOS in parallel with shipping.
- **Phase estimates from §3 are no longer reliable.** "8–12 weeks for MVP" assumed solo-with-iOS-experience. Realistically: 4–6 months to a polished MVP. We won't re-cost the whole plan now; we'll re-estimate after Phase 0 lands and we know the actual velocity.
- **Pick the simplest viable iOS stack at every fork.** SwiftUI over UIKit, SwiftData over Core Data, Apple-native libs over third-party, no Cocoapods. Less learning surface, fewer ways to get stuck.

### ✅ 6.4 Timeline — **resolved: proof of concept by Friday (3 days)**

A POC by Fri is doable but tight. The POC is **not** the MVP; it's the narrowest demonstration that the core idea works on a real phone. See new §3.0 below.

### ⏳ Still open

- **6.3 Photo strategy** — defaulting to commissioned illustrated cards (§1.4); revisit at Phase 2 (months out, plenty of time).
- **6.5 Privacy posture** — defaulting to location-when-in-use, only catches send location to backend; revisit at Phase 1 when we add the backend.
- **6.6 Launch region** — defaulting to US + Western Europe; revisit at Phase 3.
- **6.7 Backend hosting** — defaulting to Fly.io + Postgres; revisit at Phase 1 when we actually start the backend.

These four can stay deferred without blocking anything before Phase 1.

---

## 7. App Store / privacy notes

Concrete bullets that reviewers and users care about:

- **Location:** when-in-use only. Permission string explains: "Tailspot uses your location to identify the aircraft you're pointing at, by matching your viewing angle against live flight positions."
- **Camera:** for AR overlay; we never record or transmit the camera feed.
- **Catches:** the only event that ships your location to the backend, and only for cheat validation; not retained as a location history.
- **Sign in with Apple:** the only required auth; email is optional / hidden via Apple relay.
- **No tracking SDKs at v1.** Ad SDKs (if v2 monetization picks them) require an ATT prompt and a hard look at App Store rules.

---

## 8. Repo structure (current)

```
tailspot/
├─ PLAN.md                  ← this file
├─ README.md
├─ CLAUDE.md                ← guidance for future Claude Code sessions
├─ .gitignore
├─ bin/                     ← deploy / log-start / log-stop / log-tail (Phase 0c)
├─ tools/
│  └─ deploy/config.sh      ← UDID, scheme, paths (overridable via config.local.sh)
└─ ios/                     ← Xcode project
   └─ Tailspot/
      ├─ Tailspot.xcodeproj/
      │  ├─ project.pbxproj
      │  └─ xcshareddata/xcschemes/Tailspot.xcscheme  ← MUST stay secret-free
      ├─ Tailspot/
      │  ├─ TailspotApp.swift       — @main, owns the WindowGroup
      │  ├─ ContentView.swift       — top-level view: camera + readout + AR + bottom list
      │  ├─ AircraftDetailView.swift— tap-to-inspect detail sheet
      │  ├─ CameraPreview.swift     — UIViewRepresentable wrapping AVCaptureSession
      │  ├─ LocationManager.swift   — CLLocation + CLHeading wrapper
      │  ├─ MotionManager.swift     — CMDeviceMotion wrapper (incl. cameraElevationDeg)
      │  ├─ Geo.swift               — pure geometry: distance, bearing, elevation, project, screenPosition
      │  ├─ Aircraft.swift          — Aircraft struct + Decodable + FailableDecodable + extrapolatedPosition
      │  ├─ AircraftMetadata.swift  — Decodable struct from /metadata/aircraft/icao
      │  ├─ MetadataCache.swift     — bounded LRU actor keyed by icao24
      │  ├─ Log.swift               — os.Logger wrapper, subsystem com.landesberg.tailspot
      │  ├─ ADSBSource.swift        — protocol abstracting fetch
      │  ├─ OpenSkyClient.swift     — ADSBSource for OpenSky (OAuth2 client-credentials)
      │  ├─ MockADSBSource.swift    — ADSBSource for synthetic couch-testing data
      │  ├─ ADSBManager.swift       — @MainActor ObservableObject: polling, annotation, smoothness, visibility, metadata(for:)
      │  ├─ LockOnEngine.swift      — pure state machine for the AR lock-on interaction + closestTargetIcao24 helper
      │  ├─ Catch.swift             — @Model SwiftData row written when the user taps "Catch this plane" (incl. operatorName)
      │  ├─ HangarGrouping.swift    — pure-function grouping (by type or airline) used by HangarView
      │  ├─ HangarView.swift        — sheet listing every Catch, grouped and tappable
      │  ├─ CatchDetailView.swift   — read-only detail of a single Catch row (frozen snapshot)
      │  ├─ ReplayRecorder.swift    — JSONL field-session recorder (sensor + ADS-B tick stream)
      │  ├─ ReplayAnalyzer.swift    — offline replay through annotation + visibility + lock-on (+ describe())
      │  └─ ReplayReportView.swift  — in-app sheet that loads a .jsonl, runs the analyzer, shows describe()
      ├─ TailspotTests/
      │  ├─ TailspotTests.swift     — Xcode template placeholder (kept for noise; the real tests are below)
      │  ├─ GeoTests.swift          — geometry + screen-projection tests
      │  ├─ AircraftDecodingTests.swift — OpenSky positional JSON + FailableDecodable
      │  ├─ ADSBManagerTests.swift  — orchestration tests using injected FixedSource
      │  ├─ AircraftMetadataDecodingTests.swift — payload + tolerant decode
      │  ├─ MetadataCacheTests.swift            — LRU + miss-as-hit semantics
      │  ├─ ADSBManagerMetadataTests.swift      — cache consultation, dedupe, error path
      │  ├─ CatchTests.swift                    — SwiftData insert/fetch, including operatorName default
      │  ├─ LockOnEngineTests.swift             — full state-machine coverage
      │  ├─ HangarGroupingTests.swift           — both grouping modes, fallbacks, sort, whitespace folding
      │  ├─ ReplayRecorderTests.swift           — JSONL round-trip + recorder lifecycle
      │  ├─ ReplayAnalyzerTests.swift           — annotation + visibility + lock progression across synthetic recordings
      │  └─ ClosestTargetTests.swift            — center / tap-point / FOV-narrowing behavior of closestTargetIcao24
      └─ TailspotUITests/           — Xcode template scaffolding, not in regular test cadence
```

Planned but not yet created:
- `backend/` — Node/TS API (Phase 1)
- `shared/` — schemas / type defs shared between ios + backend
- `tools/replay-harness/` — Phase 0 main sensor+ADS-B record/replay

---

## 9. Immediate next steps (post-POC)

**Production v1 program APPROVED 2026-06-10 (planning round; umbrella spec at `docs/superpowers/specs/2026-06-10-production-v1-program-design.md`).** The road from TestFlight v0 to public beta → App Store launch → growth push, craft-first, descope-over-compromise. Three parallel tracks: **Track 1** — backend data backbone on Fly.io + Postgres (adsb.lol primary behind the §2 provider-adapter ladder — OpenSky adapter as outage fallback, airplanes.live commercial as paid escalation, **enterprise feeds (Spire/FlightAware Firehose) noted per Noah as a reasonable future rung at scale**; merged FAA + DOC 8643 metadata; anonymous device-token leaderboard with NO accounts; anti-cheat instrumented-not-enforced; cutover deletes the baked OpenSky creds + rotates the secret, retiring item #6 below) — implementation plan at `docs/superpowers/plans/2026-06-10-track1-data-backbone.md`, WP 1.1–1.5 MERGED same day (PRs #3 #5 #6 #7; backend server side complete, 152 tests; security review fixed per-device idempotency + trustProxy). WP 1.4b (FAA typecode enrichment) discovered as a pre-cutover requirement. Remaining: 1.4b, 1.6 iOS client, 1.7 leaderboard UI, 1.8 cutover, 1.9 runbook + Fly.io deploy (needs Noah's account/hostname). **Track 2** — on-device craft in gated stages: visual confirmation first (go/no-go vs pin-protocol replay ground truth; supersedes Pending #3's standalone status), then a 4–5-card silhouette style spike for Noah's sign-off, only then bulk silhouette generation (~40–60 type families); plus the two parked rarity divergences. **Track 3** — hardening: ~~Pokédex IP scrub~~ ✅ SHIPPED 2026-06-10 (PR #4), mock-surface cleanup (Public Hangar cut, Notifications reduced to honest coming-soon), observability (MetricKit + PostHog, no third-party crash SDK), legal/attribution (ODbL, FAA public-domain, ICAO re-check = #7 below, B612 OFL), App Store assets at launch gate. Beta gate + 0.5.0 bump per spec §6; launch = 1.0.0. Execution model: Fable 5 orchestrates/reviews every PR, Opus/Sonnet/Haiku execute packages by task shape.

**Dev workflow formalized 2026-06-09 (branch → PR → CI gate → merge → ship).** `main` is now an *enforced* production-ready release line, not a convention. Feature branches → PR → a free GitHub Actions run of `TailspotTests` (hermetic; public repo → no-cost macOS runners) → squash-merge → existing Xcode Cloud → external TestFlight trigger (unchanged). Branch protection requires the **Unit tests** check and is **enforced on admins** (emergency override = lift protection, push, restore — see `CONTRIBUTING.md`). `bin/deploy` stays the instant per-branch device loop; autonomy lives on branches, the PR merge is the one checkpoint. Housekeeping: auto-merge + auto-delete merged branches on; two stale branches removed; a docs-only Xcode Cloud build-skip filter avoids burning external-review builds on `.md`-only merges (manual App Store Connect step). Spec/plan: `docs/superpowers/specs|plans/2026-06-09-dev-workflow*`. Canonical human doc: `CONTRIBUTING.md`.

**Bizjet + regional type-classification fix SHIPPED 2026-06-09 (TestFlight v0.2.2, build-only bump; follow-on to the activity-rarity round below).** Resolves parked follow-up (c) from the rarity round. Systematic-debugging Phase 1 found the root cause is broader than the flagged bizjet gap: `aircraft_type()`'s jet-fallback (`Jet+WTC M → narrow`, `Jet+WTC L → ga`) has no signal for non-airliner jets, so the entire tail leans on the hand-maintained `BIZ`/`MIL` exact-match sets — and ~50 bizjets + ~12 regional jets + ~110 military jets were missing, defaulting to narrow/ga at `common`. **Scope decision (user): fix bizjets + regionals, skip military.** Bizjets and regionals carry ADS-B Out so they appear in-app (wrong glyph/tier users see); the ~110 military jets (F-16/F-35/MiG/Su/etc.) are MLAT-excluded on OpenSky free tier and almost never surface, so they're left mislabeled (low ROI; a make/model military heuristic is the option if ever wanted). Expanded `BIZ` (Gulfstream G300–G800, Global 5000/7500/Express, Citation/Falcon/Learjet families, Embraer Legacy/Praetor, Hawker 125/4000, Beechjet 400, HondaJet, Cirrus Vision, Eclipse 500, + classic bizjets) and added a `REGIONAL` exact-match set (BAe 146, Avro RJ, Fokker 70/100/F28, Dornier 328JET, An-148/158), each verified against its DOC 8643 `ModelFullName`. Correct side effect: newly-`biz` airframes pick up biz default rarity → `uncommon` (were wrongly `common`); flagship ULR Gulfstreams G600/G700/G800 → `rare`; Eclipse 500 VLJ reclassified `ga→biz`. Distribution: narrow 223→176, biz 39→86, regional 40→52. JSON diff is type/rarity-only (103/103). 318 → 321 tests, 0 failures (new `mistypedBizjets`/`mistypedRegionals`/`bizjetRarityAfterTypeFix` suites). **Remaining classifier follow-up:** the military-jet tail (see above) — deferred, not lost.

**Activity-based rarity tiering SHIPPED 2026-06-08 (TestFlight v0.2.2, build-only bump).** Re-tiered rarity by **sky presence** (how many of a type are airborne at any given moment) instead of curated spotter-interest, and moved rarity onto the typecode-driven path — the last derived property still resolving from OpenSky free-text. Driven by a user observation: a 737 MAX was `uncommon` only for being new (it's one of the most-seen jets), a Phenom 300 `common` despite being a rarely-airborne bizjet. The generator emits a per-typecode `rarity` in `AircraftTypes.json` (`RARITY_OVERRIDES` + `aircraft_rarity()`, category default keyed on DOC 8643 description/engine/WTC; regen diff is rarity-only, 2612/0). `AircraftNaming.rarity(forTypecode:)` reads it; `Catch.resolvedRarity` derives live and **drops the stored snapshot** — the deliberate exception to the frozen-moment rule — so re-tiering corrects prior catches on read with no migration (stored `rarity` kept only as audit). Tier moves: 737 MAX `uncommon→common`; light/mid bizjets `common→uncommon`; workhorse widebodies (A330/767/787/777/A350) → `uncommon`; scarce widebodies (747/A340/MD-11) + heavy bizjets (G650/Global) → `rare`; super-heavy/strategic → `epic`; icons → `legendary`. Verified every caught-data display reads `resolvedRarity` (`HangarRow.rarity`, `PokePlane(catchRecord:)`), so the Hangar/detail/card/points surfaces show the new tier, not the stale stored one. 314 → 318 tests, 0 failures (new `RarityResolutionTests` incl. a re-rank-on-read proof). Spec/plan: `docs/superpowers/specs|plans/2026-06-08-activity-rarity*`. **Three parked follow-ups:** (a) `ContentView` live AR-overlay tier (~line 1735) still uses the string `AircraftClassifier` directly, bypassing the typecode even when known — small divergence now the rules match, but pre-catch HUD tier can differ from post-catch; (b) `SetsScreen` set-catalog `entry.rarity` (`Sets.swift`) is static and NOT re-tiered to the activity model; (c) the bizjet type-classification bug — **RESOLVED 2026-06-09** by the follow-on entry above (bizjets + regionals fixed; military jets deferred).

**Field-fix ship SHIPPED 2026-06-08 as TestFlight v0.2.2.** A release-coordination round that bundled two field-driven fix streams onto `main` once the working tree was clean (each parallel session committed its own work; this round merged + version-bumped + doc-updated + pushed). (1) **Aircraft-naming audit** (commit `4430c39`, was "in flight" the prior round) — 57 DOC 8643 name mis-picks corrected via the generator's `OVERRIDES` table (H25B → Hawker 800XP, GA6C → Gulfstream G600, etc.); files `tools/generate-aircraft-types.py`, `AircraftTypes.json`, `AircraftNamingTests`, `GameSystemTests`. (2) **Visibility hysteresis** — a Schmitt trigger on the visibility distance cap so a plane hovering at the ~9 km boundary doesn't flicker the AR bracket / drop the lock (field report: ASA733 oscillated across the cap ±0.1–1.1 km across ticks); new `ObservedAircraft.visibilityHysteresisFactor = 1.2` + `wasShownLastFrame` flag, applied via shared `applyVisibilityHysteresis` helper threaded through both `ADSBManager.reAnnotate` (live) and `ReplayAnalyzer` (offline). (3) **Gravity-roll debug readout** in `ContentView` (debug-overlay only) to eyeball the pinhole basis in the field. 307 → 314 tests, 0 failures (new `VisibilityHysteresisTests`). `MARKETING_VERSION` 0.2.1 → 0.2.2. Known type-classification follow-up (several bizjets still typed `narrow`/`ga`) stays parked below, coupled to the activity-rarity work.

**3D pinhole projection SHIPPED 2026-06-08 (v0.2.1), device-verified.** Replaced
the separable tan projection in `Geo.screenPosition` (independent screen-x from
bearing-delta, screen-y from elevation-delta) with a gravity-derived pinhole
camera that couples azimuth/elevation and honors device roll. Fixes the systematic
"~1/cos(camElev)" horizontal label offset (~25% at 40° camera elevation) — the
"cheaper partial step" of #3 below. Compass wobble (the random component) is
untouched, leaving the Vision/ML visual-confirmation half of #3 as the remaining
accuracy lever. One chokepoint (`Geo.screenPosition`) so the live overlay, lock-on,
tap-to-ID, multi-catch detection, and `ReplayAnalyzer` all benefit. Replay format
gained optional gravity (`SensorSnapshot`) + tap-xy (`TapPin`) for exact future
replay validation. Built TDD; 287 → 307 tests, 0 failures; device eyeball passed
(roll, overhead, corner). Spec: `docs/superpowers/specs/2026-06-08-3d-pinhole-projection-design.md`.
See CLAUDE.md Current state for the file-by-file detail.

**Aircraft-identity overhaul SHIPPED 2026-06-07 as TestFlight v0.2.0.** Built on the 2026-06-06 naming/catch-detail base. Eight field-driven refinements landed: (1) canonical-manufacturer normalization + FAA cross-check in the DOC 8643 generator (messy make strings cleaned, ~5 military mis-picks corrected against `tools/data/faa_aircraft_characteristics.xlsx`); (2) Airbus engine-variant collapse + Boeing 737 MAX short-code normalization in `AircraftNaming.cleanedModel`; (3) `AircraftType` reclassified from the typecode via DOC 8643 description/engine/wake fields (helicopters and light GA no longer land in `narrow`; new default `.ga`; type distribution: ga 2227, narrow 223, wide 61, regional 40, biz 39, mil 22); (4) collection-wide typecode backfill via `CatchBackfill.swift` (background, fill-only-if-nil, runs on Hangar open); (5) Sets model list alphabetized (Unknown still last); (6) replay recorder fixed to record the full annotated set rather than only the visibility-filtered subset; (7) FAA-registry fallback for US aircraft OpenSky 404s — `IcaoRegistry.swift` + `FAARegistry.swift` + bundled `faa-aircraft.bin` / `faa-models.json` (313,376 US aircraft, ~3.5 MB, deterministic icao24↔N-number encoding); (8) ADS-B metadata sources research doc at `docs/superpowers/research/2026-06-07-adsb-metadata-sources.md`. 287 tests, 0 failures. `MARKETING_VERSION` 0.1.4 → 0.2.0. **ADS-B / metadata backend is researched and remains the deferred keystone** — see the research doc for provider comparison and decision matrix; NOT being built now (pending §9 #2 backend round).

**Naming standardization + catch detail upgrades SHIPPED 2026-06-06 as TestFlight v0.1.4.** Four user-reported problems addressed: (1) aircraft names were inconsistent — raw OpenSky strings like "THE BOEING COMPANY" and customer-code variants like "737-8H4" made Hangar section headers unreliable; (2) the same type appeared under multiple section keys across airlines, producing spurious duplicates in set grouping; (3) the Unknown bucket sorted to the TOP of grouped lists; (4) Catch detail was sparse — ALT/SPD always blank, no location name, no registration or typecode, no delete. New `AircraftNaming.canonical(typecode:manufacturer:model:)` resolves names read-time from the bundled DOC 8643 table (2,612 entries, full coverage — no corridor subset) with a string-cleanup fallback (Boeing customer-code collapse, title-casing, make-in-model dedupe). Raw strings stay stored; retroactive improvement is free. `Catch` schema grew 5 optional fields (registration, typecode, altitudeMeters, velocityMps, placeName; lightweight migration). `performCatch` populates them at save time + fires a post-save reverse-geocode via `MKReverseGeocodingRequest` (`CLGeocoder` is `API_DEPRECATED` at iOS 26). `CatchDetailView` shows place name, AIRFRAME panel, and a delete pill with confirmation. Backfill amendment: on open, `CatchDetailView` fills nil-only airframe fields from live metadata — recorded values are never overwritten. 244 tests (256 executions). `MARKETING_VERSION` 0.1.3 → 0.1.4. **Pre-release checklist item:** ICAO DOC 8643 licensing — factual aeronautical data; ICAO terms pass for non-commercial use; FAA JO 7360.1 is the public-domain fallback source and was verified to cover all designators in the table. Pending: device deploy + Noah's field-verification checklist + merge to main (device unavailable for re-pair during this session; branch `feature/naming-catch-detail` ready to merge).

**AR tracking overhaul SHIPPED 2026-06-06 as TestFlight v0.1.3.** Multi-day diagnosis-and-fix round driven by tester report "planes not identifying / labels far off." Four fixes: (1) the 2026-05-26 visibility triple-tightening (20 km + 3° + 60 s freshness) was deleting ~73% of visible traffic, and its freshness cut interacted with 429 backoff to blank every label at once ("restart fixes it") — freshness now 150 s and backoff-aware; (2) camera elevation re-derived from the gravity vector (`asin(gravity.z)`) instead of Euler pitch, which gimbal-locked exactly at the portrait hold and inverted vertical tracking below the horizon; (3) the visibility filter re-fit to **tap-pin ground truth** — a new field protocol where the user pins each plane they can actually see during a replay recording, turning recordings into labeled data: 21 planes across 4 sessions showed every confirmed sighting is an airliner ≤ 8.3 km, so the filter is now an elevation-dependent curve (4.5 km @ 1° → 13 km plateau @ 30°) with a small-airframe half-cap (US `N`+digit callsign heuristic); (4) a `VisibilityDiagnostic` funnel + temporary on-screen readout ships in 0.1.3 so testers can report the counts (remove after validation). 213 tests; constants documented in `ADSBManager.swift` with the field data inline — don't re-tune without new pin-protocol recordings. **Residual known limitation:** horizontal label offset from compass wobble (±20° actual in urban Berkeley vs ±10° claimed) plus ~1/cos(camElev) exaggeration in the separable projection — folded into Pending #3 below.

**Typography + onboarding fixes SHIPPED 2026-05-29 as TestFlight v0.1.2.** Second drop of the day; the 2026-05-27 "first-tester feedback round" work (B612 Mono swap, "reticles" copy drop, permissions moved into onboarding step 2, figure-8 calibration step removed) had been sitting in a local stash and now lands on main. **B612 Mono** — Airbus's open-source cockpit MFD font (SIL OFL 1.1) — replaces SF Mono for all monospace text (callsigns, ICAO codes, headings, badge labels, wordmark). 4 .ttf files (~530KB total) bundled into `ios/Tailspot/Tailspot/` and registered in `Info.plist` via `UIAppFonts`. New `Brand.Font.mono(size:weight:italic:)` helper centralizes the call; 137 ad-hoc `.system(... design: .monospaced)` callsites swept to it. Weight mapping collapses 4 SwiftUI weights into B612's 2 physical faces (regular/medium → Regular, semibold/bold/heavy/black → Bold). "Reticles" copy dropped from the OnboardingFlow permissions step + HangarView empty state in favor of plainer language ("aim at a plane, then tap to catch it"). Permission prompts (camera + location) now fire inside onboarding step 2 via `requestSystemPermissions()` rather than at the end when ContentView mounted — testers found the gap confusing. Figure-8 calibration step removed from onboarding (`totalSteps` 4 → 3); the compass-warning badge in the AR view still opens `CompassCalibrationSheet` with the figure-8 animation when accuracy actually degrades. `MARKETING_VERSION` bumped 0.1.1 → 0.1.2. 176 unit tests still pass — the sweep changed presentation only.

**Catch-photo bracket overlay + bigger reticles SHIPPED 2026-05-29 as TestFlight v0.1.1.** First feature drop after the v0 launch. New `CatchPhotoComposer` (pure CG/UIKit, decoupled from SwiftUI) decodes the captured JPEG, runs the screen→photo pixel transform assuming `.resizeAspectFill` (which `CameraPreview` uses), and re-renders the saved JPEG with the cyan corner-bracket box drawn at the plane's on-screen position at capture time — so the photo in Hangar records *which* plane the catch represents. `AspectFillTransform` is factored out as its own struct so the math is unit-testable without UIImage/CG. Multi-catch saves one bracket per plane on each plane's own photo file. ContentView projects every visible plane to screen once per TimelineView frame, stashes an icao→position map, and threads `screenSize` + `positions` through `captureBar` → `captureButton` → `performCatch`; the save loop looks up `positions[icao]` and falls back to the raw JPEG if compose fails or the dict misses (no catch is lost). Same session also bumped the live + photo lock-on reticles: pinned 56→140, ambient 36→96, empty-sky center 88→200, photo overlay 56→140 (matches pinned so saved photos read at the same scale testers saw on screen) — forgiveness for sensor noise / HFOV mis-cal pushing planes just outside the old 56pt box. 176 unit tests pass (169 baseline + 7 for CatchPhotoComposer). `MARKETING_VERSION` bumped 0.1.0 → 0.1.1. `bin/doc-staleness-check` Stop hook gained a `[ "$current_branch" = "main" ] || exit 0` guard so it stops false-firing on feature branches. The longer-term version of "make the bracket land on the actual plane" is **Pending #3** (Vision + COCO airplane class) — snap the bracket to the detected airplane bbox rather than the predicted screen position. Until then the bigger box is the cheap forgiveness.

**TestFlight v0 SHIPPED to internal testers 2026-05-26.** Build 11+ on TestFlight, attached to the "Student Pilots" internal-testing group. Stack: credential baking via xcconfig + Info.plist (`Tailspot.xcconfig` + gitignored `Tailspot.secrets.xcconfig` → Info.plist `OpenSkyClientID/Secret` keys → `Bundle.main.infoDictionary` at runtime); manual `Info.plist` replacing the auto-generated one (adds `ITSAppUsesNonExemptEncryption=false` and the custom OpenSky keys); `PrivacyInfo.xcprivacy` declaring UserDefaults + FileTimestamp required-reason APIs + precise-location + photos data categories; `MARKETING_VERSION=0.1.0`; CFBundleVersion auto-bumped per CI build via `ios/Tailspot/ci_scripts/ci_pre_xcodebuild.sh` (rewrites `CURRENT_PROJECT_VERSION` to `CI_BUILD_NUMBER` before archive so App Store Connect doesn't dedupe-reject); B-lockon app icon (cyan AR corner brackets framing white airplane glyph); SF Symbol `airplane.path.dotted` for the Hangar glyph; `ComingSoonBanner` on mock surfaces (Leaderboard / Public Hangar / Notifications); debug wrench `#if DEBUG`-gated so TestFlight builds show clean AR view; Settings page-bottom tap-to-copy version footer for bug triage. 169 unit tests still pass. **Apple-side ops** (App Store Connect record, signing, Archive + Upload, TestFlight beta tester invite, workflow Post-Action setup, secret-env-var configuration on the workflow) all live in `docs/testflight-handoff.md` — Claude can't do these, they require Noah in Apple UIs. **Security accepted for v0:** the OpenSky secret is in the shipped binary, extractable from any .ipa; rotation is the mitigation if a tester device is compromised, and rotation OAuth-fails every old build until the tester updates — so warn testers ahead. Backend proxy (Pending #2) is the path for wider distribution.

**Capture & Hangar redesign shipped 2026-05-25.** Reworked the core UX of catching planes and viewing the collection. Spec: `docs/superpowers/specs/2026-05-25-capture-and-hangar-redesign-design.md`. Plan: `docs/superpowers/plans/2026-05-25-capture-and-hangar-redesign.md`. End-to-end summary in `CLAUDE.md` Current state. Headlines: all-frame ambient AR labels with tap-pin override and tap-empty try-harder; unified capture button with `×N` badge for multi; merged `performCatch(mode:)` with dedup-on-insert (`Catch.exists`); 3-state lock engine; staggered multi-catch reveal with haptic + chime + combo banner; duplicate catches render with `ALREADY CAUGHT` stamp and no DB row; segmented Hangar (Sets default · Recent · Trophies); set → model-slot → tail drill-down; PokeCard-first tail detail. Subsumes the prior §9 row for multi-catch (already shipped 2026-05-21 then extended here with the stagger + dedup) and the visual-identity Phase B "Hangar polish / HUD label redesign" surface — those are now folded into the redesign and **don't need separate work**. Phase C (app icon, onboarding reskin) still applies. The Pending table below has been left intact for the items not absorbed by the redesign.

Friday POC (§3.0a) shipped 2026-05-07. The deploy loop (§3.0c) shipped 2026-05-13. Through 2026-05-20, also delivered: aircraft type lookup, lock-on interaction, catch flow v0, clean default UI + debug toggle, 30 km visibility cap, heading-accuracy color cue, partial device log streaming, **Hangar (collection) v1** (dedupe + swipe-delete + binary rare flag), **Replay recorder v0**, **Replay analyzer v0**, **Camera zoom + Tap-to-ID**, **Visual identity Phase A**, **Planespotters photo integration**, **auto-catch with camera capture**, and as of 2026-05-20 the **Game-system spine Phase 1** — Pokédex-style 5-tier rarity (`Rarity.common/uncommon/rare/epic/legendary`) + 7-type taxonomy (`AircraftType.narrow/wide/regional/biz/mil/ga/heritage`), a deterministic curated classifier (`AircraftClassifier.classify`), `Catch.rarity` + `Catch.aircraftType` snapshotted at insert with classifier-driven backfill for legacy rows, `PokeCardView` hero card with rarity-driven holo + legendary gold-dust, `RarityBadge` + `TypeBadge` + `TagRow` SwiftUI components, applied to the AR lock label, the Hangar row (rarity stripe + type glyph well), and `CatchDetailView` (PokeCard as hero section).

**Visual identity spec approved 2026-05-18** — see `docs/superpowers/specs/2026-05-18-tailspot-visual-identity-design.md`. Three implementation phases:
- **Phase A** (tokens + light retheme, ~3–4 hr) — `Brand.swift` + migrate 6 view files. Next implementation candidate; tracked as Pending item below.
- **Phase B** (component rebuild, ~1–2 d) — redesigned HUD label, Hangar dedupe + swipe-delete + rarity, brand splash screen.
- **Phase C** (full identity, ~3–4 d) — app icon asset pipeline, onboarding flow, settings reskin.

**Aircraft-naming audit COMMITTED to `main` 2026-06-08 (not yet TestFlight-deployed; `MARKETING_VERSION` not yet bumped).** Field reports — N667WJ shown as "British Aerospace C-29" (should be Hawker 800XP) and N415P/`GA6C` shown as "Gulfstream G-7 Gulfstream G800" (should be Gulfstream G600) — exposed a class of DOC 8643 name mis-picks. The generator's "most-frequent-make + shortest-model" reduction systematically picked a military designation ("C-29", "U-21F Ute", "C-18"), a foreign-licensee make ("Aviones Colombia", "Aicsa"/"Chincul"), a conversion shop ("Hamilton", "Riley"), or a doubled/garbled string ("Gulfstream G-7 Gulfstream G600") over the recognizable civil name. **57 typecodes fixed** via the generator's `OVERRIDES` table — every `(make, model)` grounded in an actual DOC 8643 `ModelFullName` row or FAA characteristics string (never from memory), mirrored surgically into `AircraftTypes.json`, regression-locked by `AircraftNamingTests.auditBatchNamesResolveFromTypecode`. Found via three lenses: the committed FAA-vs-DOC8643 disagreement report, a military-MDS-model scan, and a make/model **doubling** scan. All user-facing surfaces resolve through `AircraftNaming.canonical(typecode:…)` (live AR overlay, Hangar grouping, `PokePlane`/catch card), so the fix is retroactive for existing catches with no migration. **Deferred follow-ups (different signal source — they affect rarity/game mechanics, so couple them to the activity-rarity work, NOT done here):**

- **Type-classification gaps (bizjets mis-typed).** Confirmed business jets are missing from the generator's `BIZ` exact-match set and fall through to `narrow`/`ga`: `LJ23`/`LJ24`/`LJ25` (→ `ga`); `H25C`/`BE40`/`HA4T`/`FA20`/`GLF2`/`GLF3`/`G150`/`G280`/`GA3C`/`GA4C`/`GA5C`/`GA6C`/`GA7C`/`GA8C` (→ `narrow`). The name fixes make this *more* visible (e.g. "Gulfstream G600" now reads under a narrowbody bucket — not a regression, the type was always wrong). Fix = add them to `BIZ` in `tools/generate-aircraft-types.py` + regenerate; do it alongside the rarity work since it changes catch rarity tiers. The gap list is also pinned in a comment next to the `BIZ` set.
- **~24 homebuilt/ultralight doubling entries** (`Aeropup`/`Aeropup`, `Berkut`/`Berkut`, `Sam Aircraft`/`Sam`, …) — `strip_leading_brand` doesn't collapse an exact make==model. Separate generator fix; near-zero ADS-B impact (obscure kit aircraft).
- **`tools/data/faa-doc8643-disagreements.txt` is now a stale snapshot** — it still lists the pre-fix mismatches; regenerate it on the next full `generate-aircraft-types.py` run.

**Pending (priority order):**

| # | Item | Est. | Why |
|---|------|------|-----|
| 1 | **Capture `os_log` output from the device** | ~1–2 hr | `bin/log-tail` currently sees system-emitted lines about Tailspot but not `os.Logger` calls from the app — those flow through `com.apple.os_trace_relay`, which libimobiledevice doesn't expose. Candidates: in-app file logging (`Log.swift` mirrors to `Documents/tailspot.log`, retrieved via `xcrun devicectl device copy from`); or wrap Console.app's private framework. Until this lands, use Xcode's Console (Cmd+Shift+C) for app-side logs. |
| 2 | **Backend / public leaderboard / Sets sync** | open | Required for anonymous global leaderboard, public-hangar visits, and curated-rarity table refreshes. Effort: weeks, not days. Phase 2. Leaderboard + Public Hangar ship as preview UI with mock data; Settings + Notifications have toggles persisted via @AppStorage but no push delivery until this lands. |
| 3 | **Visual confirmation (Vision + COCO airplane class)** | ~1 day | Per §1.1a. Detect the actual plane image in the camera frame and lock the brackets to it rather than the compass-predicted position. **Update 2026-06-08: the "cheaper partial step" — proper 3D pinhole projection in `Geo.screenPosition` — SHIPPED (v0.2.1), removing the systematic ~25%-at-40° geometric offset and adding roll handling.** What remains here is the ML half: the *random* offset from compass wobble (±20° actual urban vs ±10° claimed; one 165°-in-1s jump on record), which geometry can't fix. Use Vision + YOLOv8 COCO `airplane` to snap brackets to the detected plane image, falling back to the (now-corrected) predicted position. Measure against the pin-protocol recordings in `Documents/replays` — they carry tap-confirmed ground truth, and new recordings now also carry the tap-xy + gravity for pixel-exact validation. |
| 4 | **Capture `os_log` output from the device** | ~1–2 hr | `bin/log-tail` currently sees system-emitted lines about Tailspot but not `os.Logger` calls from the app — those flow through `com.apple.os_trace_relay`, which libimobiledevice doesn't expose. Candidates: in-app file logging (`Log.swift` mirrors to `Documents/tailspot.log`, retrieved via `xcrun devicectl device copy from`); or wrap Console.app's private framework. Until this lands, use Xcode's Console (Cmd+Shift+C) for app-side logs. |
| 5 | ~~Multi-catch AR state + N-card fan reveal~~ ✅ 2026-05-21 — `icaosInZone` finds every visible plane inside the 180px (zoom-scaled) capture zone; a magenta dashed `multiCatchFrame` pulses around that zone whenever ≥2 candidates are present (suppressed when a single-catch pin or active lock is engaged). "[N]× CATCH" capture button surfaces at the bottom showing the combo multiplier; tap fires `performMultiCatch` which inserts N Catch rows and triggers `MultiCatchReveal` — full-screen fan of up to 5 PokeCards with rarity holo, magenta backdrop, staggered reveal animation, combo math receipt (base + multiplier = awarded), View-in-Hangar / Keep-spotting buttons. Combo ladder is 2→×1.5, 3→×2.0, 4→×2.5, 5+→×3.0. |
| 6 | **Rotate leaked OpenSky client secret** | ~10 min | Long-standing security debt from commit `869d06d`. Demoted to the bottom 2026-05-17 per Noah: anonymous-tier remaining credit headroom and field-test cadence make this not-urgent for now. Still worth doing eventually (10 min, regenerate on opensky-network.org and update the user-only scheme's env var) — but not blocking anything. |
| 7 | **ICAO DOC 8643 licensing / terms re-check before App Store submission** | ~30 min | `AircraftTypes.json` was built from `https://doc8643.icao.int/external/aircrafttypes`. Factual aeronautical data; current ICAO pre-release terms pass for non-commercial use. FAA JO 7360.1 is the documented public-domain fallback (covers all commercial aircraft type designators in the table). Before any wider App Store distribution, confirm the ICAO endpoint's terms haven't changed and that the bundled JSON is attributed correctly in the privacy manifest / About screen. |

**Shipped 2026-05-13 → 2026-05-18 (was queued in this section earlier):**

- ~~Remote-deploy loop + `Log.swift`~~ ✅
- ~~Aircraft type lookup~~ ✅
- ~~Device-side log streaming~~ ✅ partial (system-level only; see Pending #2)
- ~~Heading-accuracy color cue~~ ✅
- ~~Tighter 30 km visibility cap, applied to bottom list too~~ ✅
- ~~Catch flow v0 (button + `Catch` SwiftData model + container)~~ ✅
- ~~AR lock-on interaction (acquire-on-aim → green brackets + label)~~ ✅
- ~~Clean default UI; sensor readout + aircraft list behind a debug toggle~~ ✅
- ~~Lock label content: airline + make/model + altitude + speed~~ ✅
- ~~Hangar v0~~ ✅ — tray glyph + count badge in `ContentView`, sheet-presented `HangarView` with grouped list (by aircraft type or airline) backed by pure-function `HangarGrouping`. `Catch` gained an `operatorName` column (additive optional, lightweight migration). `CatchDetailView` is a frozen read-only snapshot. v0 explicitly defers dedupe and delete (see Pending #4).
- ~~Replay recorder v0~~ ✅ — `ReplayRecorder` writes JSONL (`Documents/replays/replay-<utc>.jsonl`) at 1 Hz when **Record session** is tapped in the debug overlay. One `session-start` header line + one `tick` per second carrying sensor state + visible-aircraft snapshot. Decoder tolerates a trailing partial line (crash mid-write). `AircraftSnapshot` is intentionally separate from `Aircraft` so future OpenSky decoder churn doesn't break recorded files.
- ~~Replay analyzer v0~~ ✅ — `ReplayAnalyzer` reads a recorded `.jsonl` (or in-memory `[ReplayEvent]`) and runs every tick back through `ObservedAircraft.annotate(_:observer:now:)` + the visibility filter + `closestTargetIcao24` + `LockOnEngine`, emitting one structured `ReplayTickReport` per tick. Annotation was lifted out of `ADSBManager.reAnnotate` into the shared helper so live + replay paths can't drift. No human-readable summary or CLI yet — that's Pending #2.
- ~~Camera zoom + Tap-to-ID~~ ✅ — Pinch-to-zoom on the camera (1×–5×, digital, via `AVCaptureDevice.videoZoomFactor`) with the projection math reading the current zoom and dividing the effective FOV so brackets stay attached. Tap any visible plane to pin the lock to it instantly (engine `forceLock`); tap same plane to unpin, tap empty sky to clear. `closestTargetIcao24` gained `at: CGPoint?` (defaulting to center) so the same helper drives both center-driven and tap-driven locks. `SensorSnapshot` gained optional `zoomFactor`; the analyzer divides FOV by it. **Tap-pin events are NOT yet captured in replay** — that's Pending #3.
- ~~Replay analyzer summary + in-app loader~~ ✅ — `ReplayReport.describe()` formats the structured output as a multi-line monospaced String (header + per-tick blocks with observer pose, sorted aircraft, closest-to-center bullet, lock state). `ReplayReportView` (SwiftUI sheet) loads a `.jsonl` URL, runs the analyzer, displays the report. Debug overlay has an **"Analyze last recording"** row backed by `ReplayRecorder.mostRecentRecording()` — greyed out when no recordings exist; loads + presents in one tap.
- ~~Tap-pin events in replay~~ ✅ — `ReplayEvent` gained `.tapPin(TapPin)` and `.unpin(Unpin)` cases. `ContentView.handleTap` records them whenever the user pins / unpins. Analyzer walks all events in order, maintains running `pinnedIcao`, calls `engine.forceLock` on `.tapPin` so the replayed lock-on path matches what live actually did. Pinned plane no longer visible → per-tick `pinStillVisible` check falls back to center-driven, mirroring ContentView.
- ~~Visual identity Phase A — design tokens + light retheme~~ ✅ — `Brand.swift` namespace with all color + font tokens; five SwiftUI view files migrated to consume them; FAA semantic fixes (compass-bad red→amber, tap-pin cyan→magenta); horizontal lockup (airplane + TAILSPOT wordmark) added to `HangarView` nav header as the principal toolbar item with the catch count moved to a trailing pill. Phase B (Hangar v1 polish, HUD label redesign, splash) and Phase C (app icon, onboarding) remain pending.
- ~~Planespotters photo integration~~ ✅ — `PlanespottersClient` (`nonisolated struct`, unauthenticated) fetches photo metadata by icao24. `PlanePhoto` value carries thumbnailLargeURL, thumbnailURL, photographer, link. Per TOS: no disk caching — image bytes via `AsyncImage`, API response in `PlanespottersCache` actor (cap 200, per-session). `CatchDetailView` gains hero photoSection above Identity: `AsyncImage` of large thumbnail, hidden when nil. Attribution text `"© photographer · planespotters.net"` opens Safari. `PlanespottersClient.shared` singleton. 5 new tests → 130 total. Hangar row thumbnails and AR label thumbnails deferred (attribution UI doesn't fit cleanly).
- ~~Design-canvas QA pass — 9 structural fixes~~ ✅ 2026-05-21 — Code-level review of every screen against the design canvas's accessibility tree (`design/` served locally via `python3 -m http.server`). Identified 9 structural divergences and shipped fixes for all of them: Trophies tri-section partition (Earned / In progress / Locked-as-"???"), Onboarding step 4 availability + suggestions + public toggle, Profile identity hero with avatar disc + joined date + PUBLIC pill + Medals stat tile, CardReveal "tap card to flip" hint, Sets numbered slot prefixes + "POKÉDEX-STYLE" header, Hangar empty state with sets preview + Go-outside hero, Notifications four-section restructure (Push / Nearby aircraft / Progress / Quiet hours, 9 @AppStorage toggles), Leaderboard "CLIMB" coaching banner. Pixel-level visual polish (corner radii, padding, line-heights) deferred to a phone-based review pass.
- ~~Compass calibration sheet + Empty-sky AR state + Multi-catch mechanic + Trophy / Set tests~~ ✅ 2026-05-21 — The AR caution badge is now a tappable button (chevron + "Tap to calibrate" subtitle); tapping it opens `CompassCalibrationSheet` — explains what's wrong (magnetometer drift near metal), shows the figure-8 calibration motion live (animation extracted from onboarding step 3 and made internal so both surfaces share it), and renders a live `HEADING / ACCURACY` readout that ticks down in real time as the user moves the phone. A `calibratedThisSession` latch flips the headline + button state once accuracy drops under ±10° so the user gets explicit confirmation. Empty-sky AR state: when no visible aircraft are present and no lock is engaged, the AR view now shows a 24%-opacity center reticle + a status pill anchored at ~82% screen height — "SCANNING SKY…" before the first fetch, "NO AIRCRAFT IN VIEW · N IN RANGE" when bbox traffic exists but is past the visibility filter, "NO AIRCRAFT IN RANGE" otherwise. The status dot breathes via an `EmptyPulse` TimelineView modifier (~1 Hz cosine 0.4→1.0) for ambient "still scanning" signal; pulse disabled when an error is surfaced. Multi-catch mechanic shipped — see §9 row 5. `TrophiesTests` (10 tests covering roster integrity, Trophies.inputs aggregation across rarity / type / slant / night, per-achievement `currentTier`/`nextTier`/`isLocked` transitions) and `PokeSetsTests` (7 tests covering empty-input → all-locked, model-substring fills, wrong-set non-fill, case-insensitive matching, progress count, set + entry id uniqueness) and `MultiCatchComboTests` (combo-multiplier ladder + sub-2 identity case). 21 new tests → 164 total.
- ~~Game-system spine Phase 2 — everything else from the design canvas~~ ✅ 2026-05-20 — Card-reveal catch moment (`CardReveal.swift`) replaces the 900 ms green-flash overlay: full-screen takeover with rarity-tinted radial bloom + light rays (rare+), "● NEW CARD · ENTRY #N" pill, PokeCard center-stage at `.lg`, two minimal buttons (View in Hangar / Keep spotting). Tap the card to flip to a `CardBackView` Pokédex-style entry (POKÉDEX ENTRY label, identity, full stat block, type chip + base points, TAILSPOT footer). Trophies system (`Trophies.swift` + `TrophyView.swift` + `TrophiesScreen.swift`): `Achievement` value type with multi-tier (`bronze/silver/gold/platinum`) ladders, threshold-driven progression evaluated as a pure function over the Hangar contents (`Trophies.inputs(from:)` returns a `TrophyProgressInputs` aggregate; `currentTier`/`nextTier`/`isLocked` per achievement). 13 achievements (Catcher / Wide Awake / Regional Pilot / Long Lens / World Tour / Constellation / Quintet / First Rare / Epic Encounter / Legendary / Centurion / Heritage / Night Owl) with 15 custom hex-framed `Shape`-based icons ported from the design's SVGs (catcher reticle, widebody top-down, regional jet + speed lines, telescope, globe + orbit, 3-plane constellation, 5-dot V quintet, cut diamond, 4-point sparkle, crown, centurion laurels + "100" text, clipboard checklist, crescent moon + stars, biplane silhouette, coastline). `HexShape` is a Swift `Shape` matching the canvas's CSS `clip-path` polygon. Locked variant is a dashed-outline hex with a padlock glyph. Sets system (`Sets.swift` + `SetsScreen.swift`): 7 Pokédex-style `PokeSet`s organized by `AircraftType`, 39 curated `PokeSetEntry` slots (model-substring matchers, rarity-tinted silhouettes when uncaught, full color when caught). Browser screen + detail screen with locked-silhouette grid; entry-count progress bar in each row; "COMPLETE" pill when all slots filled. Rarity + Types reference screens (`ReferenceScreens.swift`): static doc surfaces explaining the 5 tiers + 7 types, each with example airframes. Profile screen (`ProfileScreen.swift`): the gamification hub — `ProfileStats` aggregate (total points = sum of resolvedRarity.basePoints, unique airframes, rare+ unique, longest slant km, per-rarity counts), identity hero with @handle + total points + (placeholder) global rank, 4-stat tile row, rarity breakdown strip showing counts + segments per tier, horizontal recent-trophies row, quick links to Sets/Map/Leaderboard, section links to Rarity reference / Types reference / Settings / Notifications. Map screen (`MapScreen.swift`): MapKit `Map` (iOS 17+ API) plotting one rarity-tinted pin per Catch at the observer's lat/lon, legendary halo, rarity filter chips, summary panel ("N sightings · M days span"), auto-fit camera. Public surfaces (`PublicScreens.swift`): anonymous-global `LeaderboardScreen` with mock rows + the user injected by points (handles + ranks + "YOU" pill, podium for top 3, Window picker), `ShareCardSheet` using `ImageRenderer` to stamp a SwiftUI card → `ShareLink`, `PublicHangarScreen` placeholder for visiting another spotter (routed via leaderboard `NavigationLink`). Settings (`SettingsScreen.swift`): @AppStorage-backed handle TextField, public-hangar toggle, rare-aircraft notification toggle, version/build/about. Notifications (`NotificationsScreen.swift`): lock-screen-style preview of a rare-aircraft push, 5 alert toggles. Onboarding (`OnboardingFlow.swift` + `RootView`): 4-step flow gated by `@AppStorage("tailspot.onboarding.completed")` — Welcome (lockup + value pitch + sample PokeCard at -4° rotation), Permissions (3 rows explaining location/camera/motion), Compass calibration (animated cyan dot tracing a parametric figure-8 via `TimelineView` + `Canvas`), Pick a handle (validates 3-20 alphanumerics + underscore, persists to `SpotterHandle.storageKey`). `RootView` swaps in `ContentView` after onboarding completes; in `TailspotApp.swift`, `WindowGroup` now hosts `RootView` rather than `ContentView` directly. ContentView gained a `profileButton` (person.crop.circle.fill glyph) next to the hangar / debug buttons and presents `ProfileScreen` as a sheet. The catch path in `performAutoCatch` no longer flashes — it builds a `PokePlane` from the just-inserted Catch and sets `pendingReveal` to trigger the full-screen card reveal. View-in-Hangar button transitions to the Hangar sheet; Keep-spotting dismisses to the AR view. 23 new SwiftUI view files, ~3200 lines of code. No test regressions; 143 tests still pass. Design source remains in `design/` for visual reference.
- ~~Game-system spine Phase 1 — Pokédex rarity + types + PokeCard~~ ✅ 2026-05-20 — Pulled the design-canvas handoff (claude.ai/design, 33 artboards) into the SwiftUI app. New `GameSystem.swift` defines `Rarity` (5 tiers — common 10 / uncommon 25 / rare 100 / epic 500 / legendary 2000 base points) and `AircraftType` (7 categories — narrow/wide/regional/biz/mil/ga/heritage with single-letter glyphs and tint colors). `AircraftClassifier.classify(manufacturer:model:operatorName:)` is a deterministic curated rule table — first-match wins, operator gate is any-of (so a 747-2 only resolves to legendary VC-25 if the operator is USAF/Air Force, otherwise falls through to the rare 747 bucket). `Catch` gained `rarity: String?` + `aircraftType: String?` (raw values, optional for SwiftData lightweight migration); the init runs the classifier so new rows are born with a snapshotted tier; `resolvedRarity`/`resolvedType` computed properties backfill via the classifier for pre-existing rows. `HangarRarity` (binary common/rare) deleted — subsumed by the new system. New SwiftUI components: `RarityBadge` (mono-font pill, tier-tinted, legendary gets a leading ★), `TypeBadge` (rounded chip with dark-circle glyph well + label on type-tinted background), `TagRow` (combined). `PokeCardView` is the hero collectible: 3 sizes (sm 150×210 / md 220×308 / lg 280×400), rarity-tinted 5pt top rail, rarity-tinted 1.5pt border + 18pt rarity glow + 20pt drop shadow, rare-or-above tiers get a conic-gradient holo wash blended `.overlay` + a diagonal foil shine blended `.screen`, legendary additionally gets 4 radial gold-dust hot-spots blended `.screen`. Photo slot falls back to a striped placeholder in the rarity tint. The card is applied as a List section hero in `CatchDetailView` (no live re-fetch — frozen-moment), as type-glyph + rarity-tinted leading stripe + inline `RarityBadge` (rare+) on the Hangar row, and as a `TagRow` on the AR lock label (only after metadata lands, so the classifier has something to read). Hangar "rare" stat pill now counts unique airframes at rare+ (rare/epic/legendary), not just the old binary list. Catch-flash overlay's `caughtWasRare` flag uses the same rare+ threshold. New `GameSystemTests` suite (~22 tests) pins legendary VC-25 / SR-71 / B-2, epic A380 / 747-8, rare 787 / A350 / 777 / 747, uncommon A220 / 737 MAX, common 737NG / A320 / E175 / Cessna 172, plus determinism, case-insensitivity, nil-input defaults, and that every entry from the legacy `HangarRarity.rareModelTokens` list still resolves to rare-or-higher. `HangarRarityTests` deleted with the type it covered. `CatchTests` extended with 3 new tests covering classifier snapshotting at insert, nil-field classifier backfill on resolved* read, and explicit init-time rarity overriding the classifier. Total tests: ~143 (was 130; +22 new game-system, +3 new Catch, –12 deleted HangarRarity). Design source: `design/` directory (HTML/JSX handoff, 340K, served via `python3 -m http.server 4173 --directory design`; not built into the iOS bundle).
