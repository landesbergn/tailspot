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
      │  └─ CatchDetailView.swift   — read-only detail of a single Catch row (frozen snapshot)
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
      │  └─ HangarGroupingTests.swift           — both grouping modes, fallbacks, sort, whitespace folding
      └─ TailspotUITests/           — Xcode template scaffolding, not in regular test cadence
```

Planned but not yet created:
- `backend/` — Node/TS API (Phase 1)
- `shared/` — schemas / type defs shared between ios + backend
- `tools/replay-harness/` — Phase 0 main sensor+ADS-B record/replay

---

## 9. Immediate next steps (post-POC)

Friday POC (§3.0a) shipped 2026-05-07. The deploy loop (§3.0c) shipped 2026-05-13. Through 2026-05-16, also delivered: aircraft type lookup, lock-on interaction, catch flow v0, clean default UI + debug toggle, 30 km visibility cap, heading-accuracy color cue, partial device log streaming, **Hangar (collection) v0**.

**Pending (priority order):**

| # | Item | Est. | Why |
|---|------|------|-----|
| 1 | **Rotate leaked OpenSky client secret** | ~10 min | Long-standing security debt from commit `869d06d`. No code; regenerate on opensky-network.org, update the user-only scheme's env var. Independent of every other item. |
| 2 | **Capture `os_log` output from the device** | ~1–2 hr | `bin/log-tail` currently sees system-emitted lines about Tailspot but not `os.Logger` calls from the app — those flow through `com.apple.os_trace_relay`, which libimobiledevice doesn't expose. Candidates: in-app file logging (`Log.swift` mirrors to `Documents/tailspot.log`, retrieved via `xcrun devicectl device copy from`); or wrap Console.app's private framework. Until this lands, use Xcode's Console (Cmd+Shift+C) for app-side logs. |
| 3 | **Replay harness** | ~1.5 hr | Phase 0-main infra. Record `(sensor stream + ADS-B snapshot + observer pose)` to disk during a session; replay offline through the ID engine. Becomes more valuable once we want to validate lock-on accuracy across sessions. |
| 4 | **Hangar v1 polish** | ~2–3 hr | Things v0 deliberately left out: dedupe (collapse repeat catches of the same icao24 under a single row with "×N" badge), swipe-to-delete with confirm alert, illustrated-card stub for top type×airline combos. Defer until there's real catch volume to design against. |
| 5 | **Visual confirmation (Vision + COCO airplane class)** | ~1 day | Per §1.1a. Detect the actual plane image in the camera frame and lock the brackets to it rather than the compass-predicted position. Hardest of these; defer until the accuracy bar work (§3.0 main) starts. |
| 6 | **Achievements / streaks / scoring** | open | Phase 2 work. Wait until Hangar has real catch volume to design against. |

**Shipped 2026-05-13 → 2026-05-16 (was queued in this section earlier):**

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
