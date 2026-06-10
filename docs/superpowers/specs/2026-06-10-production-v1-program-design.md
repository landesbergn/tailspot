# Tailspot Production v1 Program — Design

**Date:** 2026-06-10
**Status:** Approved by Noah (this session)
**Scope:** The program-level design for taking Tailspot from TestFlight v0 to a
public beta, then App Store launch with a growth push. Each track below gets its
own implementation plan; this document is the umbrella.

---

## 1. North star and scope decisions

Decisions made explicitly by Noah in the 2026-06-10 planning session:

| Decision | Choice |
|---|---|
| Success target | Big public beta → App Store launch → real growth push. Craft is non-negotiable; **descope features rather than compromise quality**. |
| Social/account scope | **Anonymous leaderboard, no accounts.** Device-token identity + claimable handle. No sign-in, no cross-device sync, no public hangar visits at launch. |
| Card art | **Designed silhouette cards** (procedural, fully-owned). No commissioned illustrations, no photo card faces, no AI-generated art. |
| Visual confirmation | **In scope, pre-beta**, and it leads Track 2 (go/no-go gate before other craft work scales). |
| Timeline | Fastest possible. Parallel agent streams; quality enforced via the PR/CI gate and orchestrator review. |
| Model usage | Fable 5 orchestrates, designs, and reviews; cheaper Claude models execute well-specified packages (see §2). |

**Descoped from this program** (post-launch backlog, not lost): accounts /
Sign in with Apple, cross-device sync, public hangar visits, push notification
delivery, commissioned card art, the military-jet classifier tail, route
(origin/destination) data.

## 2. Execution model

Fable 5 in the main session is the **orchestrator and integrator**: decomposes
tracks into work packages, dispatches each to the cheapest model that can hit
the quality bar, and reviews every PR before merge. The enforced branch → PR →
CI workflow (CONTRIBUTING.md) is the quality mechanism — nothing reaches `main`
unreviewed regardless of which model wrote it.

Routing by task shape:

| Model | Gets | Examples |
|---|---|---|
| **Fable 5** | Architecture, novel algorithms, concurrency-sensitive Swift, integration/cutover, security-sensitive code, all final review | Backend API design, visual-confirmation association algorithm + tuning, `ADSBSource` cutover |
| **Opus 4.8** | Substantial self-contained implementation with judgment calls | Backend endpoint implementation from spec, silhouette card rendering system, replay-harness extensions |
| **Sonnet 4.6** | Well-specified component work following existing patterns | Test suites from specs, SwiftUI views on existing Brand patterns, metadata import pipeline |
| **Haiku 4.5** | Mechanical sweeps and exploration | IP-scrub rename sweep, copy scrubs, attribution strings, codebase searches, doc refreshes |

Escalation rule: if a package fails orchestrator review, it escalates one model
tier rather than iterating endlessly at the cheap tier. Tracks run as parallel
feature-branch streams; merges are sequenced by the orchestrator (tracks touch
nearly disjoint files by design).

## 3. Track 1 — Data backbone & anonymous leaderboard

All-new `backend/`: Node/TypeScript on Fly.io + managed Postgres (PLAN.md §2
defaults). The backend is the **keystone**: it simultaneously fixes the
shared-credential exhaustion trap, is the only *legal* route to an MLAT data
source for a distributed app, and hosts the merged metadata registry.

### 3.1 Position data — provider ladder

Researched in `docs/superpowers/research/2026-06-07-adsb-metadata-sources.md`.
The backend exposes `GET /v1/aircraft?bbox=…` behind a provider-adapter seam
(PLAN.md §2). The ladder, bottom to top:

1. **adsb.lol — primary.** ODbL 1.0 license (explicitly permits a distributed
   app, with attribution; share-alike applies only to published derived
   databases, which the leaderboard does not trigger). MLAT included — small
   GA, helicopters, and military traffic become visible, a real coverage and
   gameplay upgrade. No SLA; rate limits are dynamic but irrelevant at one
   server-side poll per region tile.
2. **OpenSky adapter — outage fallback only.** Kept config-switchable. Terms
   (research-only; operational use needs a written agreement) make it
   unsuitable as primary for a public app.
3. **airplanes.live commercial agreement — paid escalation** if adsb.lol
   reliability disappoints during beta. Read their actual terms before
   committing (primary ToS pages were unfetchable during research).
4. **Enterprise feeds (Spire, FlightAware Firehose) — the scale rung.** Noah's
   explicit note (2026-06-10): these may be a reasonable choice at some point —
   when user scale (or eventual revenue) justifies an annual contract, the
   adapter seam makes adopting one a config change plus an adapter file, not a
   refactor. Revisit at post-launch growth review.

Rejected: adsb.fi (license forbids non-personal use), ADS-B Exchange Community
tier (10k req/month is too small for a multi-user backend), flight-status-shaped
APIs (AeroAPI, FR24 — per-result pricing, wrong shape for bbox polling).

Cache: region-tiled, ~10 s TTL — one upstream fetch serves every user in a tile.

### 3.2 Metadata

`GET /v1/metadata/{icao24}` — server-side merged registry: FAA releasable DB
(public domain, daily refresh job) + ICAO DOC 8643 + cached community lookups.
The app keeps the bundled FAA snapshot as an offline/outage fallback for beta;
drop it in a later release once the backend is proven.

### 3.3 Catches and leaderboard

- `POST /v1/catches` — ingestion with the device's pose payload (heading,
  elevation, GPS, timestamp). **Anti-cheat instrumented, not enforced**: record
  what validation *would* reject; review during beta; enforce at launch only if
  the data says it is safe.
- `GET /v1/leaderboard` — anonymous identity: device-generated UUID token on
  first launch, claimable handle (server-side uniqueness + profanity filter).
  No sign-in, no email, no PII beyond the self-chosen handle.
- Per-token rate limiting on every endpoint.

### 3.4 iOS cutover

`TailspotBackendClient` implements the existing `ADSBSource` protocol — a
one-file swap by design. Mock source and replay harness untouched. At cutover:
**delete the baked OpenSky credentials from the binary and rotate the secret**
(retires PLAN §9 #6; warn testers first per the standing rule — old builds will
OAuth-fail).

## 4. Track 2 — On-device craft (three gated stages)

Per Noah's direction: validate before scaling. No bulk work proceeds past a
gate without evidence/approval.

### Stage 2a — Visual confirmation (leads the track; go/no-go gate)

Vision `VNCoreMLRequest` at ~10 fps with a COCO-airplane-class model (model
selection + license check is the first task). For each ADS-B plane predicted
in-FOV, find a detection near its predicted position → snap the bracket to the
visual position; no detection → predicted position with a lower-confidence
treatment. Tuned offline against the pin-protocol replay recordings
(tap-confirmed ground truth with tap-xy + gravity for pixel-exact validation) —
tuning never requires field time.

**Gate:** does snap-to-detection beat predicted-position against ground truth?
If no: ship feature-flagged off, beta proceeds without it, days spent not weeks.

### Stage 2b — Card style spike (style gate)

4–5 sample silhouette cards spanning the visual range (narrowbody, widebody
jumbo, bizjet, GA prop, helicopter), 2–3 style directions on the first sample,
reviewed by Noah on device or as rendered screenshots. Iterate on **one card**
until the style is right.

**Gate:** Noah signs off on the style direction.

### Stage 2c — Bulk silhouette generation

The approved sample becomes the template spec; the remaining ~40–60 type-family
silhouettes are bulk-produced by cheaper models against it, with airline accent
theming layered under the existing rarity holo/foil treatments. Striped
placeholder remains only for genuinely unknown types. Planespotters photos stay
as the detail-view bonus. Orchestrator review pass at the end.

### Also in Track 2 — parked-divergence fixes

- AR overlay tier goes typecode-first (`ContentView` ~1735 currently uses the
  string classifier even when the typecode is known).
- `SetsScreen` catalog rarity re-tiered to the activity model (static
  `Sets.swift` metadata currently diverges).

## 5. Track 3 — Hardening & launch surface

- **IP scrub (required pre-beta):** all "Pokédex" user-facing copy replaced;
  `Poke*` type names (`PokeCardView`, `PokePlane`, `PokeSet`…) renamed in the
  same sweep. Mechanics (rarity, cards, sets) are fine; the words are not.
- **Surface cleanup:** Public Hangar cut for beta (nav entry removed);
  Notifications screen cut or reduced to one honest "coming soon" row — no
  toggles that lie.
- **UX polish pass:** onboarding tightening; every empty/error state reviewed
  (especially "no aircraft here" coverage messaging); accessibility pass
  (Dynamic Type, VoiceOver labels where the AR surface supports them).
- **Observability:** crashes via Xcode Organizer / App Store Connect +
  MetricKit (no third-party crash SDK); product analytics via PostHog
  (anonymous device ID only — no ATT prompt) for funnel + AR-accuracy telemetry
  that feeds tuning.
- **Legal/compliance:** privacy policy + ToS (hosted page); attribution screen
  (adsb.lol ODbL, FAA public-domain note, ICAO DOC 8643 terms re-check =
  PLAN §9 #7, B612 OFL, Planespotters); App Privacy nutrition labels redone for
  the backend era.
- **Launch-gate only:** App Store assets (screenshots, preview video, ASO
  copy), phased-release plan, US + Western Europe availability.

## 6. Gates and versioning

**Beta gate** (public TestFlight link goes out): Track 1 live and cutover
complete (no OpenSky credentials in the binary), IP scrub done, surface cleanup
done, visual confirmation landed (or consciously flagged off via its gate),
crash reporting + telemetry wired, privacy policy hosted. Silhouette cards
strongly wanted but droppable if they are the last thing standing.

**Launch gate:** beta telemetry reviewed (crash-free sessions ≥ 99.5%,
AR-accuracy funnel healthy), anti-cheat enforce/observe decision made, App
Store assets done, legal checks closed.

`MARKETING_VERSION`: **0.5.0** at beta cutover (testers should notice),
**1.0.0** at launch. (Routine builds in between keep the same version per the
standing TestFlight preference.)

## 7. Top risks

1. **adsb.lol has no SLA** — absorbed by the provider ladder (§3.1): OpenSky
   adapter for outages, airplanes.live commercial as paid escalation,
   enterprise feeds at scale. Optional insurance: a home ADS-B feeder (Noah is
   under the SFO/OAK corridor) earns feeder status with the community networks.
2. **Visual confirmation is experimental** — bounded by its go/no-go gate and
   the replay-based tuning loop; failure costs days and ships flagged off.
3. **Backend introduces Noah-facing ops** (Fly.io account, Postgres, DNS,
   secrets, privacy-policy hosting) — Track 1 ships a runbook in the style of
   `docs/testflight-handoff.md` for every step requiring Noah in a dashboard.
4. **Integration friction between parallel tracks** — managed by near-disjoint
   file footprints, orchestrator-sequenced merges, and the existing CI gate.

## 8. Sequencing snapshot

All three tracks start in parallel. Within tracks: Track 1 is
proxy → metadata → catches/leaderboard → cutover; Track 2 is
2a → gate → 2b → gate → 2c; Track 3 front-loads the IP scrub and surface
cleanup (pre-beta requirements), back-loads App Store assets (launch-gate).
Beta ships when §6's beta gate is green; launch follows the beta-telemetry
review.
