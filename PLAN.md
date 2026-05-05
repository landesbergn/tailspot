# Tailspot — Build, Test & Ship Plan

iOS app that turns plane spotting into a collection game. Point phone at sky → AR overlay identifies aircraft via ADS-B + geometry → catch to collection.

This document covers the architectural decisions, phased roadmap, testing strategy, risks, and the open questions that need answers before we commit to a stack.

---

## 1. Architectural decisions (and why)

These are the four calls that shape everything else. Worth getting right before code.

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

### Phase 0 — De-risk geometric ID (2–4 weeks)

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
| 1 | Geometric ID accuracy below threshold in field | Medium | Critical | Phase 0 with hard success criterion; replay harness for fast iteration |
| 2 | ADS-B commercial licensing forces costly vendor | High | High | Resolve in Phase 0 alongside monetization (§6.1); provider abstraction in code |
| 3 | Compass calibration UX failure → user rage | High | High | Block ID when `headingAccuracy` is poor; mandatory calibration onboarding |
| 4 | ADS-B 5–15s lag causes mis-identifies on fast aircraft | Medium | Medium | Forward-extrapolate positions; widen tolerance for high-velocity aircraft |
| 5 | Photo / livery licensing | Low (with illustrated cards) | High | Commissioned cards strategy (§1.4) |
| 6 | App Store rejection (camera + location + AR) | Medium | High | Clear permission strings; location-**when-in-use** only; explicit privacy explainers in onboarding |
| 7 | ADS-B coverage gaps disappoint users in non-hub regions | Medium | Medium | Region-limited launch (§3.3); in-app messaging when no aircraft are in range |
| 8 | Backend cost spike on virality | Low at v1 scale | Medium | Aggressive caching; rate limiting per user; alarms on egress |

---

## 6. Open questions (need user input)

Listed in resolution-priority order. The first one cascades into several others.

### 6.1 Monetization model — **gates ADS-B vendor decision**

Free? Freemium? One-time purchase? Subscription? Ads?

This is not a launch-day question — it's a Phase 0 question. **OpenSky's free tier is non-commercial.** If Tailspot has any IAP, subscription, or ads, we likely need a paid feed (cheapest path: ADSBexchange via RapidAPI; serious option: FlightAware AeroAPI at real money). The monetization answer is the data-vendor answer is the unit-economics answer. We need it before we commit to a provider.

### 6.2 Solo developer or team?

Phase estimates assume solo dev, full-time. A 2–3 person team (iOS + backend + design) compresses every phase by ~40% but adds coordination and cost. What's the actual setup?

### 6.3 Photo strategy preference

§1.4 recommends commissioned illustrated cards. Confirm — or override with: (a) AI-generated, (b) user-uploaded with moderation, (c) licensed photo library. Each has very different cost/timeline implications.

### 6.4 Target ship date or budget

Is there a hard deadline, a budget cap, or pure best-effort?

### 6.5 Privacy posture

Recommendation: location-**when-in-use** only (not "always"); the only data point that ever leaves the device with a location attached is the catch event itself, and that's needed for cheat validation. Confirm this is acceptable, or specify a stricter posture.

### 6.6 Launch region

§3.3 recommends US + Western Europe based on ADS-B coverage. Confirm or specify.

### 6.7 Backend hosting / ownership

Comfortable building and operating a backend, or want to use a BaaS (Firebase, Supabase) to avoid ops?

---

## 7. App Store / privacy notes

Concrete bullets that reviewers and users care about:

- **Location:** when-in-use only. Permission string explains: "Tailspot uses your location to identify the aircraft you're pointing at, by matching your viewing angle against live flight positions."
- **Camera:** for AR overlay; we never record or transmit the camera feed.
- **Catches:** the only event that ships your location to the backend, and only for cheat validation; not retained as a location history.
- **Sign in with Apple:** the only required auth; email is optional / hidden via Apple relay.
- **No tracking SDKs at v1.** Ad SDKs (if v2 monetization picks them) require an ATT prompt and a hard look at App Store rules.

---

## 8. Repo structure (proposed)

```
tailspot/
├─ PLAN.md                  ← this file
├─ README.md
├─ .gitignore
├─ ios/                     ← Xcode project (created Phase 0)
│  ├─ Tailspot/
│  ├─ TailspotTests/
│  └─ TailspotUITests/
├─ backend/                 ← Node/TS API (created Phase 1)
│  ├─ src/
│  │  ├─ adapters/          ← OpenSky, ADSBexchange, …
│  │  ├─ routes/
│  │  └─ validators/        ← catch validator
│  └─ tests/
├─ shared/                  ← schemas / type defs shared between ios + backend
└─ tools/
   └─ replay-harness/       ← Phase 0 sensor+ADS-B record/replay
```

---

## 9. Immediate next steps

In order:

1. **Resolve §6.1** (monetization → ADS-B vendor). Without this, Phase 0 ADS-B integration could need rework.
2. **Resolve §6.2 and §6.4** so phase estimates are real.
3. **Begin Phase 0:** scaffold iOS project, build the bare "see all overhead aircraft" prototype, build the replay harness alongside.
4. **Run a Phase 0 field test** against the §3.0 success criterion.
5. **Go / no-go review** against Phase 0 results before committing to Phase 1.
