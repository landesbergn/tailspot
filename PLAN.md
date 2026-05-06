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

### Phase 0a — Friday proof of concept (3 days)

The narrowest possible demo: **on Noah's phone, a screen showing live aircraft labels at the right places in the sky**, no game, no auth, no backend, no polish. Existence proof that the idea is buildable.

**Scope (in):**
- iOS app builds and runs on Noah's iPhone.
- Camera feed as the background.
- Live readout: GPS coordinates, compass heading, device pitch.
- OpenSky API call (direct from device, not via backend) for aircraft inside ~50 km bbox around current position.
- For each aircraft, compute true bearing + elevation from device.
- Render a text label for each aircraft at its projected screen position; label includes callsign + altitude.

**Scope (out):**
- ARKit / drift correction — raw compass + pitch is good enough for a POC.
- "Catch" interaction or any persistence.
- Backend, auth, accounts, scoring, achievements, illustrated cards.
- Visual polish, error states, calibration UX.
- Forward-extrapolation of ADS-B positions (we'll find out if it's needed).

**Day-by-day (assuming 3 evenings of work):**

| Day | Goal |
|---|---|
| Tue (today) | Confirm prereqs (see §10). Scaffold Xcode project. App requests camera + location permissions and shows live GPS / heading / pitch readout on top of camera feed. |
| Wed | OpenSky integration. Show a list of nearby aircraft (callsign, altitude, bearing-from-me, elevation-angle). Still scrolling list, not overlaid yet. |
| Thu | Project each aircraft's bearing/elevation onto screen coordinates and render labels at those positions over the camera feed. |
| Fri | Field test outside. Iterate on whatever is broken. Demo. |

**Success criterion (loose, vs. Phase 0 main):**
> Walk outside, point phone at a plane I can see overhead, and the corresponding label appears reasonably close to it. Doesn't have to be 80% accurate or work for multiple planes — that's Phase 0 main.

This POC only proves "the pipeline runs end-to-end." The harder accuracy bar from §3.0 below (≥80%, ≥50 trials) is the **subsequent** Phase 0 work, which the replay harness and field testing serves.

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
| 1 | Geometric ID accuracy below threshold in field | Medium | Critical | Phase 0 with hard success criterion; replay harness for fast iteration |
| 2 | ADS-B commercial licensing forces costly vendor | High | High | Resolve in Phase 0 alongside monetization (§6.1); provider abstraction in code |
| 3 | Compass calibration UX failure → user rage | High | High | Block ID when `headingAccuracy` is poor; mandatory calibration onboarding |
| 4 | ADS-B 5–15s lag causes mis-identifies on fast aircraft | Medium | Medium | Forward-extrapolate positions; widen tolerance for high-velocity aircraft |
| 5 | Photo / livery licensing | Low (with illustrated cards) | High | Commissioned cards strategy (§1.4) |
| 6 | App Store rejection (camera + location + AR) | Medium | High | Clear permission strings; location-**when-in-use** only; explicit privacy explainers in onboarding |
| 7 | ADS-B coverage gaps disappoint users in non-hub regions | Medium | Medium | Region-limited launch (§3.3); in-app messaging when no aircraft are in range |
| 8 | Backend cost spike on virality | Low at v1 scale | Medium | Aggressive caching; rate limiting per user; alarms on egress |

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

1. **Confirm prerequisites in §10** so Tue work isn't blocked.
2. **Tue evening:** scaffold Xcode project; permissions + sensors readout on camera view.
3. **Wed–Thu:** OpenSky integration → projected labels (per §3.0a day-by-day).
4. **Fri:** field test, iterate, demo.
5. **Sat onward:** retrospective on what the POC taught us; commit to Phase 0 main scope.

## 10. Prerequisites for the Friday POC

Need to confirm before Claude starts writing Swift on Tue:

1. **Mac with Xcode installed?** (Xcode 15+ for iOS 17 SwiftUI/SwiftData; free from the Mac App Store, ~10 GB and a long download.)
2. **iPhone for testing?** What model and iOS version? The Simulator does not provide real GPS/compass/camera, so for this app, a physical device is required from day 1.
3. **Apple Developer account?** Two paths:
   - **Free Apple ID signing** — works for personal-device testing, but the build expires after 7 days and you need to re-sign / re-install. Fine for POC.
   - **$99/yr paid program** — needed for TestFlight, App Store, and persistent installs. Not needed this week.
   - Default: free signing for POC; pay if/when we want testers in Phase 1.
4. **Field-test location?** Are you somewhere with regular overhead air traffic (near a major airport approach path, an urban area, etc.)? "Friday demo" requires a sky with planes in it.
5. **Learning preference?** Do you want every step explained as we go (slower, more learning), or do you want code first and questions later (faster, learn ad hoc)?
