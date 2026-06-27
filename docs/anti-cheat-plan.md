# Catch authenticity: closing the "point anywhere in dense airspace" hole

**Date:** 2026-06-26 · **Status:** design-complete, pre-implementation (Noah review)
**Decided:** enforcement = **hard-block + "Catch anyway"** (purist; matches
"make the catch real first"). No two-tier Hangar.
**North star:** catch-confirmation-rate ("is the catch real?"). This is a direct
attack on it.

---

## 1. Evidence (PostHog `catch_performed`, John/jdurovsik's session today)

One ~11-minute session (13:53–14:04 UTC), **12 real catches** (dupes excluded).
The geoip city reads "San Diego" (unreliable carrier/VPN routing); the data is
John's — `max slant = 28.7 km` matches the Citation screenshot exactly.

| Signal | Value |
|---|---|
| Slant distances (km) | 28.7, 21.9, 20.7, 18.2, 17.6, 11.1, 10.9, 10.9, 8.2, 7.6, 5.8, 3.2 |
| Avg / median / max | 13.7 / ~12 / 28.7 km |
| Beyond 15 km | 5 of 12 |
| Inside field-confirmed naked-eye range (≤5.8 km) | **2 of 12** |
| `visual_confirm_enabled` | True on all 12 |
| `visual_fix_active` (detector saw a plane) | **False on all 12** |
| Notable | 13:53:45 tap = **3 simultaneous catches** at 3.2 / 10.9 / 21.9 km |

Several far catches are **biz jets** (small airframes, ~⅓ an airliner's angular
size): 28.7, 20.7, 10.9, 8.2 km. The four screenshots map to rows: 28.7 Citation,
18.2 A220, 10.9 E175, 8.2 Hawker — every photo points at a building/tree/street.

## 2. Root cause (three compounding gaps)

1. **Whole-frame multi-catch, not aim.** `ContentView.swift:444` →
   `.multi(onScreenIcaos)` captures *every* visible plane projecting anywhere on
   the 56°×72° frame. Nothing requires the target under the reticle. → the 3-at-once tap.
2. **Open-sky distance band in an urban canyon.** `ADSBManager.swift`: full-tier
   13 km / contrail 25 km / faint 35 km, 1° horizon floor — all fit to
   open-sightline Berkeley/Sea Ranch ground truth. No occlusion model: a plane
   behind a skyscraper reads "visible." → the 28.7 km catch.
3. **Visual confirmation runs but never gates.** `VisualConfirmationPipeline`
   only snaps the bracket; the detector result is discarded at catch time. It went
   0/12 and blocked nothing.

`SkyCheck` only blocks the *indoor* (warm-light) cheat; it fails open on every
outdoor scene, so John's outdoor cheat is invisible to it.

## 3. What "a real catch" requires (threat model)

A catch is real only if all three hold. Each maps to a lever:

| Requirement | Violated by | Lever |
|---|---|---|
| **Aimed** — the reticle is on the plane | spray-catching the whole frame | L1 |
| **Visible** — the plane isn't behind a building/tree | urban occlusion | **L2 (keystone)** |
| **Resolvable** — close/big enough to see at all | 28.7 km bizjet | L3 (floor) |
| *(gold)* corroborated by the camera | detector ignored | L4 (flagged) |

**Keystone insight:** the *same* 20 km plane is a legit catch over open coastline
(contrail visible — the Sea Ranch ANA179 case the band was widened for) and a cheat
in Manhattan (behind buildings). **Distance alone cannot separate them**; a blanket
distance cap would re-break the hard-won "never hide a visible plane" doctrine. The
discriminator that *does* separate them is **"is the patch of frame where the plane
should appear actually open sky?"** → the localized sky gate (L2) is the keystone,
not a distance cap.

## 4. Enforcement model (decided: hard-block + "Catch anyway")

Generalize the existing indoor machinery (`showIndoorNudge` / `overrideCatch` /
`nudgeToken`, "Catch anyway" at `ContentView:808`) from a single indoor reason into
a **reasoned block**:

```
enum CatchBlockReason { case offAim, occluded, tooFar, noDetection, indoor }
```

- Any failed requirement → a one-line nudge keyed to the reason + a one-tap
  **"Catch anyway"** override (never a dead end). `offAim` is the exception: it's
  *eligibility*, surfaced as a disabled/empty capture button (nothing under the
  reticle), not a nudge.
- Every block fires `catch_blocked{reason,...signals}`; every override fires
  `catch_gate_override{reason,...}`. **Override-rate is the calibration signal** —
  a reason testers override constantly is mis-tuned.
- The Hangar only ever holds real catches (or explicit overrides). No provisional tier.

## 5. The levers — full design

### Lever 1 — Aim, don't spray *(pure geometry; PR1; fully unit-testable)*

**Today:** capture set = `onScreenProjected` = every visible plane anywhere on the
56°×72° frame (`ContentView.swift:417–456`).

**Change:** capture set = planes within a **tight central catch zone** around the
reticle, reusing the existing zone helpers:
- **Single:** the pin (`lockOn.state.targetIcao24`) if present, else
  `closestTargetIcao24(at: center, lockZoneRadius: 80)` (unchanged 80 px).
- **Multi:** `icaosInZone(at: center, zoneRadius: R)` with **R tightened from 180 →
  the catch-zone radius** so multi means "the cluster I'm genuinely aimed at," not
  the whole sky. Start R ≈ lock zone (80–100 px); tune in field test.
- Radius stays in **pixels** (a UI affordance that scales with zoom — already the
  design intent in `LockOnEngine.swift:140–145`), so zooming in tightens the
  angular tolerance, which is exactly right for disambiguating spread-apart planes.

**Net:** you must put the reticle *on* the plane. Kills the 3-at-once firehose; the
saved photo is aimed where the plane geometrically is. Capture button shows the
in-zone count; empty zone → disabled.

**Keep:** sticky-hold for the pinned single (compass jitter); a *modest* multi-zone
so a real formation / approach corridor still works.

**Tests:** `closestTargetIcao24` / `icaosInZone` are pure — synthetic poses asserting
in-zone vs out-of-zone selection, zoom scaling, multi grouping.

### Lever 2 — Localized sky gate *(keystone; perception + calibration; PR2)*

**Idea:** `SkyCheck` today collapses the whole frame to one verdict. Extend it to
judge **the patch under each catch target's predicted screen point.**

**Mechanism (reuses the 12×12 lattice already computed every frame):**
1. `SkyFeatures.extract` already samples a 12×12 luminance lattice on the camera
   queue. Promote it to also retain the **per-tile** map (lum / local edge / warmth),
   not just the four collapsed scalars. Cheap — same samples.
2. Store that tile map alongside `latestSkyFeatures` (lock-guarded snapshot, same as
   today).
3. At catch time we already have each target's predicted screen point
   (`onScreenPositions[icao]`, passed into `performCatch` as `positions`). Map it →
   buffer space (`AspectFillTransform`, same transform the detector uses) → the tile
   it lands in, plus an N×N neighborhood (start 3×3).
4. **Localized verdict** via the same logic as `SkyCheck.verdict`, on the local
   neighborhood: warm+lit → occluded; cluttered/structured (high local edge/variance)
   → occluded; smooth+cool/dark → sky.
5. **Block only when** the local patch is confidently non-sky **AND** open sky exists
   elsewhere in the frame (`skyTileFraction ≥ minSkyFraction`). This guard makes it
   **fail open** when the whole frame is featureless (uniform overcast, fog, dusk):
   if there's no clearly-sky region anywhere, never block on locality.

**Why it's safe (preserves the doctrine):**
- Night: a dark, smooth, neutral tile reads sky → allow (the night case `SkyCheck`
  was explicitly built to protect).
- Contrail / far-but-open: projects onto smooth sky → allow.
- A building/tree/pavement patch (structured or warm) with sky available elsewhere →
  block. **This is exactly John's four screenshots.**
- Ambiguous patch → `.uncertain` → allow. Fail-open everywhere.
- Labels are untouched — only *catching* a plane whose pixel patch is occluded is
  blocked (+ override).

**Thresholds:** localized analogues of `edgeSmooth` / `varianceSmooth` /
`warmThreshold` + `minSkyFraction`. **Calibrated on device** — see §7.

### Lever 3 — Absolute angular-size floor *(geometry backstop; PR1; testable)*

Some catches are unresolvable *regardless* of occlusion. Apparent angular size:

```
apparentSizeRad ≈ wingspanMeters / slantDistanceMeters
```

Class wingspans (from emitter `category` (#69) + `typecode`, fallback
`isLikelySmallAirframe` = US `N`+digit tail): widebody ~60, narrow ~36, regional ~26,
biz ~16, GA ~11, heli rotor ~14 m.

**Floor ≈ 2.5–3 arcmin (~0.0008 rad)** — kills only the physically-unresolvable while
keeping every legit case:

| Case | wingspan/slant | arcmin | verdict |
|---|---|---|---|
| Citation @ 28.7 km (John) | 16/28700 | **1.9** | blocked ✓ |
| narrowbody @ 13 km | 36/13000 | 9.5 | kept |
| widebody contrail @ 19 km (Sea Ranch) | 60/19000 | 10.9 | kept |
| narrowbody @ 5.8 km (confirmed visible) | 36/5800 | 21 | kept |

This is the **floor**; L2 handles the mid-range occlusion (e.g. an 18 km narrowbody =
7 arcmin, above the floor but behind a building → caught by L2, not L3). **Decoupled
from label rendering** — labels stay generous; only catching a sub-floor plane is
blocked (`tooFar` nudge + override). Pure function → unit-tested over (wingspan, slant).

### Lever 4 — Detector soft-gate, in-envelope only *(gold standard; flagged; PR3)*

Promote the detector from cosmetic to corroborating, **only where it's competent:**
- **Envelope:** `meanLuminance ≥ daylight threshold` **AND** expected on-screen
  footprint ≥ ~15–20 px (REPORT.md detection floor; compute from `apparentSizeRad ×
  focalPx`).
- **In-envelope:** require a live `fixes[icao]` (or a broader full-frame detection
  pass) for the target → else hard-block (`noDetection`) + override.
- **Out-of-envelope** (night, tiny/far footprint, low light): geometry only, **never
  blocked** — preserves the hard catches the doc protects.
- Detector-confirmed catches become the gold signal feeding catch-confirmation-rate
  (and, later, scoring/trophies — Noah's gamification interest).

**Risk:** false negatives on genuinely-visible planes (compass off → crop misses
the plane; glare). **Mitigations:** for the *gate* question ("is any plane in view?")
search a wider region than the predicted-point crop; flag-gated (UserDefaults like
`visualConfirm.enabled`); default-off until override-rate telemetry says it's safe.

## 6. Unified gate (integration in `performCatch`)

Order, cheapest-first, per the decided hard-block model:

1. **Aim (L1)** — no target in catch zone → button disabled (eligibility, no nudge).
2. **Indoor (existing whole-frame `SkyCheck`)** — `.notSky` → block `indoor`.
3. Per target:
   a. **Angular-size floor (L3)** → block `tooFar`.
   b. **Localized sky (L2)** → block `occluded`.
   c. **Detector in-envelope (L4, flagged)** → block `noDetection`.
4. Any block → reasoned nudge + "Catch anyway".

**Multi mode:** gate per-target — catch the subset that passes, surface the blocked
count ("2 caught · 1 too far"). (Open question §11: per-target vs block-whole-tap.)

## 7. Device calibration plan *(gates L2, then L4)*

Reuse the existing offline harness rather than guessing thresholds:
- **`CropFrameSaver` already** writes a crop JPEG + JSONL sidecar with the predicted
  screen point during replay recording (`VisualConfirmationPipeline.swift:208`).
  Extend it to also save the **full frame + per-tile feature map + target screen
  point**, so each saved frame is a localized-gate test case.
- **Corpus** (mirror the 48-image `tools/authenticity-gate` set, calibrated
  2026-06-25): add **localized** labels — per (frame, target), "patch-under-bracket
  is sky vs occluded." Sources: **John's NYC occluded frames** (block) + **Noah's
  open-sky Berkeley/Bali frames incl. night / overcast / contrail** (pass).
- **Tune** `edgeSmooth/varianceSmooth/warmThreshold/minSkyFraction` (local) offline to
  hit: open-sky pass-rate ≥ current 92%, occluded block-rate high, fail-open bias.
- **Ship-gate L2 on the offline numbers**, exactly like the 2026-06-25 calibration.

## 8. Telemetry additions

- `catch_performed` += `camera_elevation_deg`, `reticle_offset_px` (target distance
  from center at catch), `multi_n`, `local_sky_verdict`, `angular_size_arcmin`,
  `detector_in_envelope`, `detector_hit`. *(Today we can't even see how off-axis
  his catches were.)*
- `catch_blocked` / `catch_gate_override` += `reason` enum + raw signals.
- **Watch:** catch-confirmation-rate and **median catch slant** before/after. Target:
  median slant falls toward the ≤5.8 km confirmed-visible regime; override-rate low.

## 9. Test plan

- **Unit (Swift Testing):** L1 aim-zone selection (in/out, zoom, multi grouping); L3
  angular-size floor over (wingspan, slant); L2 localized verdict over synthetic
  per-tile maps (sky / building / night / overcast); gate ordering (which reason fires).
- **Offline:** §7 calibration corpus pass/block rates.
- **Field:** Noah open-sky — must NOT regress (night/contrail still catch); John NYC —
  must block the building catches.

## 10. Rollout & risk

- **PR1** L1 (aim) + L3 (size floor) + telemetry — pure logic, no perception risk,
  ships the biggest safe cut (stops the 28.7/21.9/20.7/18.2 km catches + the spray).
- **PR2** L2 (localized sky) — after the calibration corpus.
- **PR3** L4 (detector gate) — flagged, default-off, enabled on telemetry evidence.
- **Risk:** re-breaking "never hide a visible plane." **Mitigated by:** catch-eligibility
  decoupled from label rendering (labels stay generous); fail-open everywhere; an
  override on every block; override-rate watch. The doctrine stays intact — labels
  unchanged, only *catching* gets stricter, and only with corroboration or override.

## 11. Open questions

1. **Multi-catch on partial block:** catch the passers + surface blocked count, or
   block the whole tap? (Leaning: catch passers.)
2. **Anti-frustration:** if a tester overrides the same reason repeatedly, auto-relax
   that threshold for them? Or just retune from telemetry?
3. **PLAN §9 placement** — rank this as the next Bet A item once design is approved.
