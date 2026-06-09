# Changelog

Historical per-session "Current state" entries, moved out of CLAUDE.md to keep
that file focused on the live state plus durable guidance. The live "Current
state" block stays in CLAUDE.md; each round's prior block lands here, newest first.
Git history and PLAN.md §9 remain the authoritative record.

## 2026-06-08 — field-fix ship: naming audit + visibility hysteresis (v0.2.2)

**Release-coordination round: bundled two field-driven fix streams that had been
sitting unshipped onto `main`, bumped to `MARKETING_VERSION` 0.2.2, and pushed for
TestFlight + `bin/deploy` to Noah's iPhone.** Both are tunings of existing
chokepoints — no new architecture. This session ran as the integrator across
several parallel work sessions: each session committed its own work (the
hysteresis stream landed on `fix/visibility-hysteresis-roll-readout`, the naming
audit was already on `main` from a prior commit), and this round merged, version-
bumped, doc-updated, and shipped once the working tree was clean.

1. **Aircraft-naming audit (was "in flight" last round, now shipped).** Commit
   `4430c39` fixes 57 DOC 8643 name mis-picks — military / foreign-licensee /
   converter / doubled strings → the recognizable civil name (e.g. H25B → Hawker
   800XP, GA6C → Gulfstream G600), each grounded in a real DOC 8643 / FAA row via
   the generator's `OVERRIDES` table. Files: `tools/generate-aircraft-types.py`,
   `AircraftTypes.json`, `AircraftNamingTests`, `GameSystemTests`. Known
   type-classification follow-up — several bizjets still typed `narrow`/`ga` — stays
   parked in PLAN.md §9 (couple it to the activity-rarity work; it changes rarity).

2. **Visibility hysteresis (AR bracket de-flicker).** A Schmitt trigger on the
   visibility distance cap: a plane already shown last frame keeps a wider cap so it
   doesn't blink off when it hovers right at the boundary (and drop the lock). New
   `ObservedAircraft.visibilityHysteresisFactor = 1.2` (~20% outer band) +
   `wasShownLastFrame` flag, applied via the shared `nonisolated
   applyVisibilityHysteresis(_:previouslyShown:)` helper. Threaded through BOTH the
   live path (`ADSBManager.reAnnotate`, carried in private `shownIcaos`) and the
   offline `ReplayAnalyzer` (carried across ticks) so the two can't drift — same
   "one chokepoint, both paths" discipline as the pinhole round. Field report
   2026-06-08: ASA733 oscillated False→True→False across consecutive ticks at the
   ~9 km cap (±0.1–1.1 km swing); the 1.2 band absorbs it while still dropping
   planes that genuinely recede. New plane must clear the *inner* cap to appear.

3. **Gravity-roll debug readout (`ContentView`).** A debug-overlay readout of the
   gravity-derived roll (behind the debug wrench), to eyeball the pinhole camera
   basis in the field. Debug-only; no production-surface change.

**Tests: 307 → 314, 0 failures** (verified green on iPhone 17 sim before push). New
`VisibilityHysteresisTests` (5: appear/stay/drop state machine end-to-end + helper
stamps `wasShownLastFrame` from the prior shown set).

**`MARKETING_VERSION` 0.2.1 → 0.2.2** (user-visible: recognizable aircraft names +
AR labels stop blinking at the distance edge).

## 2026-06-08 — 3D pinhole projection for AR label placement (v0.2.1)

**3D pinhole projection landed; device-verified by Noah; on `main` as
`MARKETING_VERSION` 0.2.1.** Replaces the separable tan projection in
`Geo.screenPosition` — which treated screen-x (from bearing delta) and screen-y
(from elevation delta) as independent — with a proper pinhole camera that couples
azimuth and elevation and honors device **roll**. This fixes the documented
systematic label offset (the "~1/cos(camElev) horizontal exaggeration", ~25% at
40° camera elevation) that was PLAN §9 #3's "cheaper partial step". The random
component (compass wobble) is untouched — that's the later Vision/ML half of #3.
Spec: `docs/superpowers/specs/2026-06-08-3d-pinhole-projection-design.md`.

Architecture principle: **all AR placement funnels through one chokepoint
(`Geo.screenPosition`), so the fix reaches the live overlay, lock-on, tap-to-ID,
multi-catch capture detection, and offline `ReplayAnalyzer` at once.** The camera
orientation is derived from the **gravity vector + heading** (consistent with the
gravity-based `cameraElevationDeg`; never the gimbal-flaky Euler roll).

1. **Pinhole core (`Geo.swift`).** New `Geo.CameraBasis` (forward/right/up world
   ENU unit vectors via `SIMD3<Double>`), two builders — `cameraBasis(headingDeg:
   cameraElevationDeg:rollDeg:)` and `cameraBasis(gravityX:Y:Z:headingDeg:)` (derives
   camEl + roll from gravity, delegates) — plus `rollDeg(gravity:)` and the pinhole
   `screenPosition(...basis...)`. The old scalar `screenPosition(...phoneHeadingDeg:
   cameraElevationDeg:rollDeg:...)` now builds a basis and delegates, so it gains the
   coupling fix + a `rollDeg` param while the existing `GeoTests`/`ClosestTargetTests`
   invariant net stays green unchanged (the regression proof that the common case
   didn't move). Builds for arm64 device.

2. **Roll threaded through every consumer.** `ObservedAircraft.screenPosition`
   gains a `CameraBasis` overload (built once per frame, then 3 dot products per
   plane); `closestTargetIcao24`/`icaosInZone` take `rollDeg` and build the basis
   once so lock-zone geometry matches label placement; `ContentView` builds the
   basis from the live gravity vector each frame and forwards roll to `handleTap`;
   `ReplayAnalyzer` derives roll from the recorded gravity vector when present, else
   falls back to roll = 0.

3. **Replay format additions (additive/optional, the `zoomFactor` pattern).**
   `SensorSnapshot` gains `gravityX/Y/Z: Double?` (lets future recordings
   reconstruct the exact live basis); `TapPin` gains `x/y: Double?` (pixel-exact
   tap ground truth for projection + the future visual-confirmation work).
   Synthesized `Codable` omits nil, so pre-existing recordings decode unchanged.
   `recordReplayTick` records gravity; `recordTapPin(tapPoint:)` records the tap.

4. **Verification.** Correctness is proved by analytic unit tests (basis-builder
   absolute correctness vs known poses; self-checking coupling identities —
   level-x == old separable x, level-y == old-y/cos(dB); the 302.16px
   horizontal-compression anchor; gravity-roll sign). No strong *offline* ground
   truth exists (committed `replays/*.jsonl` have no tap-pins), so the on-device
   eyeball was the acceptance gate — **passed** (roll glues correctly, overhead +
   corner planes sane). Future pin-protocol recordings now carry gravity + tap-xy
   for pixel-exact replay validation.

**Tests: 287 → 307, 0 failures.** New `CameraBasisTests` (16) + integration tests
in `ReplayAnalyzerTests` (roll plumbing) and `ReplayRecorderTests` (gravity +
tap-location round-trip, nil back-compat).

**`MARKETING_VERSION` 0.2.0 → 0.2.1** (user-visible AR accuracy: labels track the
real plane far better at elevation and under roll).

## 2026-06-07 — Aircraft-identity overhaul: classification, FAA fallback (v0.2.0)

**Shipping as TestFlight v0.2.0.** Built on the 2026-06-06 naming/catch-detail
work (ICAO DOC 8643 table, `AircraftNaming`, Catch schema +5 fields, `CatchDetailView`
AIRFRAME panel + delete). Field testing and a full data audit exposed a second
layer of problems: the DOC 8643 table had messy manufacturer strings, `AircraftType`
classification was broken for rotorcraft and GA, OpenSky 404s for US aircraft
left entire class of airframes unresolved, and the replay recorder was silently
recording only the filtered-visible subset (defeating the ReplayAnalyzer when
visibility filtered everything out). All fixed. Architecture principle established:
**every derived property (canonical name + aircraft type) resolves from the ICAO
typecode through authoritative reference data — DOC 8643 for names, DOC 8643
description/engine/wake for type — never from OpenSky's free-text fields; a
collection-wide background backfill (`CatchBackfill`) ensures old catches carry
a typecode.** Key files: `AircraftNaming.swift`, `CatchBackfill.swift`,
`IcaoRegistry.swift`, `FAARegistry.swift`, `ReverseGeocode.swift`; bundled
resources `AircraftTypes.json`, `faa-aircraft.bin`, `faa-models.json`; generators
`tools/generate-aircraft-types.py`, `tools/generate-faa-registry.py`; reference
data `tools/data/faa_aircraft_characteristics.xlsx`.

1. **Canonical-manufacturer normalization + FAA cross-check in the generator.**
   `tools/generate-aircraft-types.py` now normalizes messy OpenSky/DOC 8643 make
   strings to clean brand names ("Gulfstream Aerospace"→"Gulfstream",
   "Canadair"→"Bombardier"), strips doubled-brand model prefixes, and cross-checks
   ~5 military/conversion mis-picks against the committed FAA Aircraft
   Characteristics Database (`tools/data/faa_aircraft_characteristics.xlsx`). FAA
   wingspan/length data carried into ~92 entries as bonus metadata. `OVERRIDES`
   table extended accordingly; regeneration is idempotent.

2. **Airbus engine-variant collapse + Boeing 737 MAX short-codes in
   `AircraftNaming.cleanedModel`.** Engine-suffix variants collapse to family
   names ("A380-842"→"A380-800", "A321-271NX"→"A321neo"). Bare OpenSky model
   strings "737-8" / "737-9" (no typecode, no suffix) collapse to "737 MAX 8" /
   "737 MAX 9" — converging the no-typecode catch path with the typecode path.
   "737-800" NG stays distinct. Convergence pinned by parameterized tests in
   `AircraftNamingTests`.

3. **`AircraftType` classified from the typecode via DOC 8643 authoritative data.**
   `AircraftTypes.json` now carries a `type` field per entry (derived from
   DOC 8643 description + engine + wake categories). `Catch.resolvedType` reads it
   via `IcaoRegistry`. This fixes the core misclassification: helicopters (R44,
   EC35) and light GA (Cessna 172) were landing in `narrow` because the string
   classifier had no rotorcraft awareness and defaulted unknowns to `narrow`. New
   default is `.ga`; the string classifier (no-typecode fallback only) gained
   helicopter awareness. Type distribution across 2,612 entries: ga 2227,
   narrow 223, wide 61, regional 40, biz 39, mil 22. `AircraftTypeResolutionTests`
   pins every type bucket with representative icao24s.

4. **Collection-wide typecode backfill (`CatchBackfill.swift`).** On Hangar open,
   `CatchBackfill.backfillIfNeeded(in:)` fetches a typecode for every catch
   missing one (one OpenSky call per icao24, cached, fill-only-if-nil, runs in a
   background Task). Ensures the entire collection resolves through the clean table,
   not just newly caught planes. `CatchBackfillTests` covers the fill/skip
   semantics and the 404-fallback path.

5. **Sets model list sorts alphabetically** (was tail-count descending). Unknown
   bucket still forced to last. Fixes the jarring reorder on each catch.

6. **Replay recorder fix.** `ReplayRecorder.recordReplayTick` was silently recording
   only the visibility-filtered subset (`adsb.observed` post-filter), so when the
   filter rejected everything (a contrail cruising past the distance cap) the JSONL
   tick carried zero aircraft — defeating the ReplayAnalyzer's purpose. Now records
   the full annotated set before filtering. Found while diagnosing a contrail that
   was filtered as "no aircraft in range" and produced an empty replay.

7. **FAA-registry fallback for US aircraft OpenSky 404s (`IcaoRegistry.swift`,
   `FAARegistry.swift`).** US icao24↔N-number is a deterministic bit-level
   encoding; a bundled FAA snapshot (313,376 US aircraft, ~3.5 MB, binary-searched
   via `faa-aircraft.bin` + model table `faa-models.json`, generated by
   `tools/generate-faa-registry.py` from the public FAA Civil Aircraft Registry)
   supplies make/model/type when OpenSky has no record. Verified: Cirrus SR20
   (a9eefa), Embraer E175 (a8d71c), Pilatus PC-12 (a00965) recover; foreign tails
   (Korean 71c575) correctly stay unknown. Community aggregators (hexdb.io, adsbdb)
   404 the same airframes — shared OpenSky lineage, so they don't help. FAA fallback
   is wired into `CatchBackfill` as the OpenSky-404 path. `FAARegistryTests` and
   `IcaoRegistryTests` pin the round-trip encoding + lookup.

8. **ADS-B metadata sources research doc.** `docs/superpowers/research/2026-06-07-adsb-metadata-sources.md`
   documents when/how to move off OpenSky for metadata. Key findings: the baked
   single credential makes the 4,000/day quota a global bucket (exhausts at ~4
   simultaneous spotters); OpenSky terms are research-only (commercial use
   prohibited); adsb.lol (ODbL) is the one MLAT source whose license permits a
   distributed app; the planned backend is the keystone next step (fixes credential
   exhaustion + MLAT licensing + stale bundle at once). **NOT being built now —
   deferred to the backend round.** See the research doc for provider comparison
   table and decision matrix.

**Tests: 244 → 287, 0 failures.** New suites: `AircraftNamingTests` (extended),
`AircraftTypeResolutionTests`, `CatchBackfillTests`, `IcaoRegistryTests`,
`FAARegistryTests`, `ReverseGeocodeTests` (extended).

**`MARKETING_VERSION` 0.1.4 → 0.2.0** (major user-visible surface: standardized
aircraft identity + authoritative classification + catch-detail overhaul).

## 2026-06-06 — Naming standardization + catch detail upgrades (v0.1.4)

**Shipping as TestFlight v0.1.4.** Four user-reported problems drove
this round: (1) aircraft names were inconsistent — OpenSky raw strings
like "THE BOEING COMPANY" and customer-code variants like "737-8H4"
made sets look wrong and section headers untrustworthy; (2) Hangar sets
grouped by airline ended up with duplicates because the same type
appeared under multiple raw name variants; (3) the Unknown bucket sorted
to the **top** of the grouped list rather than the bottom; (4) the
Catch detail was missing useful information — ALT/SPD always blank, no
location name, no registration or ICAO typecode, and no way to delete a
row. Full spec: `docs/superpowers/specs/2026-06-06-plane-naming-catch-detail-design.md`.

1. **ICAO DOC 8643 table + generator.** `tools/generate-aircraft-types.py`
   fetches the official ICAO designator endpoint
   (`https://doc8643.icao.int/external/aircrafttypes`, 7,260 rows),
   reduces to one canonical (make, model) per designator (2,612 entries),
   and writes `ios/Tailspot/Tailspot/AircraftTypes.json` as a bundled
   resource. Reduction rules: most-frequent manufacturer per designator,
   shortest model string, title-case polish + Airbus hyphen fix. ~50
   human-reviewed `OVERRIDES` correct the handful of cases where
   "shortest name" picks a military designation (e.g., E145 → "C-99"
   without an override). **Full table, no corridor subset** — Noah
   explicitly chose full ICAO coverage over a US/EU cut-down. Licensing:
   factual aeronautical data; ICAO's pre-release terms pass; FAA JO
   7360.1 is the noted public-domain fallback if ICAO terms ever become
   an issue. Regeneration workflow documented in the script docstring;
   `--input` flag allows clean diffs against a saved source file.

2. **`AircraftNaming` — read-time canonical resolution.**
   `AircraftNaming.canonical(typecode:manufacturer:model:) -> CanonicalName`
   is the single entry point: typecode lookup in the bundled table wins
   outright; fallback applies string-cleanup rules (Boeing customer-code
   collapse `737-8H4` → `737-800`, idempotent on already-clean strings;
   make title-casing with aviation-specific exceptions; make-in-model
   dedupe). Architecture: raw OpenSky strings remain stored in SwiftData
   — canonicalization is read-time and pure, so classifier rule
   improvements apply retroactively to every existing catch without a
   migration. `AircraftNamingTests` sweeps the entire 2,612-entry bundled
   table for structural integrity plus the Boeing customer-code fallback
   suite (13 parameterized argument sets → 13 case executions).

3. **Sets + grouping fixes.** `HangarGrouping.key(.aircraftType)` now
   keys on the canonical `displayName` rather than the raw OpenSky model
   string — customer-code variants collapse across airlines, so UA and
   AA 737-800s share a section. `modelGroups` uses a sort key that pins
   the Unknown bucket to last position (was first). `PokeSets.matches`
   changed from intersection to UNION (raw OR canonical) — set membership
   only gains from canonicalization. `SetDetailView` and
   `ModelSlotDetailView` dropped their inline re-casing hacks (now
   redundant).

4. **`Catch` schema +5 optional fields** (lightweight migration):
   `registration`, `typecode`, `altitudeMeters`, `velocityMps`,
   `placeName`. All optional with nil defaults so existing rows migrate
   without disruption. `performCatch` populates them at save time
   (metadata.registration + metadata.typecodeIcao from `AircraftMetadata`;
   altitude + velocity from `ObservedAircraft`; placeName via a
   post-save fire-and-forget reverse-geocode).

5. **`ReverseGeocode` (new file).** `MKReverseGeocodingRequest` is the
   implementation — `CLGeocoder` is `API_DEPRECATED` at iOS 26 in the
   SDK headers, forcing the switch. **Gotcha:** `MKAddressRepresentations`
   (the MapKit successor's address model) has NO `administrativeArea`
   field, unlike `CLPlacemark`. The has-city path uses Apple's
   `cityWithContext` property (locale-aware, e.g., "Berkeley, CA" or
   "Toulouse, Occitanie") rather than assembling city + state manually.
   `ReverseGeocodeTests` verifies every placemark shape (city-only,
   country-only, city + country, nil result).

6. **`CatchDetailView` upgrades.** New place line (geocoded name if
   present, fallback to lat/lon coords). New AIRFRAME panel (REG / ICAO /
   TYPE). Red trash delete pill → confirmation alert → deletes the
   SwiftData row AND its photo file. **Backfill on open:** `CatchDetailView`
   may fill nil-only airframe fields (registration, typecode, manufacturer,
   model, placeName, operatorName) by re-fetching metadata — never
   overwrites a stored value, never touches moment-data. See "Hangar
   collection" section for the amended read-only-snapshot invariant.
   `ModelSlotDetailView` tail rows now prefer registration over hex ICAO
   when available. `HangarRecentView.performDelete` gained an
   orphaned-JPEG cleanup that the row-delete path was previously missing.

7. **`PokePlane` fixes.** Shared `altText(fromMeters:)` / `speedText(fromMps:)`
   helpers centralize unit formatting. `PokePlane.init(catchRecord:)`
   reads persisted `altitudeMeters` / `velocityMps` from the Catch row
   (previously always nil because the fields didn't exist yet — this was
   the "ALT/SPD always blank" bug). Canonical model names feed the PokeCard
   hero so cards now show "Boeing 737-800" instead of "737-8H4 (CFMI)".

**Tests: 213 → 244** (256 case executions). 30 net-new named tests:
`AircraftNamingTests` + `ReverseGeocodeTests` (new suites) + extensions
to `CatchTests`, `HangarGroupingTests`, `ADSBManagerTests`.

**`MARKETING_VERSION` 0.1.3 → 0.1.4.**

**Pending at session end:** device deploy + Noah's field-verification
checklist (canonical names on-screen, place names in catch detail, delete
flow) + merge to main. Device was unavailable for re-pair during this
session; the feature branch `feature/naming-catch-detail` is fully
tested (244/244 pass) and ready to merge when Noah re-pairs.

## 2026-06-06 — AR tracking overhaul: recall, elevation, ground-truth visibility (v0.1.3)

**Shipping as TestFlight v0.1.3.** The arc of this multi-day round: Noah
reported planes "identifying / locking on less reliably" + "labels far
off." Systematic diagnosis (git archaeology + offline replay analysis +
field recordings) found and fixed four distinct problems:

1. **Recall regression — the 2026-05-26 visibility triple-tightening.**
   20 km cap + 3° floor + 60 s freshness deleted ~73% of historically-
   visible planes (replayed against a real session). The 60 s freshness
   also interacted with 429 backoff (poll gap up to 120 s) to age out
   EVERY plane at once — the "no planes at all, restart fixes it"
   mechanism. Freshness now 150 s and **backoff-aware** (allowance grows
   by how overdue polling is; see `reAnnotate`'s `effectiveMaxAge`).

2. **Camera-elevation gimbal lock.** `90 − CMAttitude.pitch` breaks at
   the upright-portrait pose: pitch is Euler-bounded at ±90°, so tilting
   the camera below the horizon made pitch *reflect* (roll flips ±180°)
   and elevation went the wrong way — labels slid DOWN as you tilted
   down. Confirmed in a field replay (pitch peaked ~89° and bounced).
   Fixed: `cameraElevationDeg = asin(gravity.z)` — continuous through
   the horizon, roll-invariant, singularity-free. `MotionManagerTests`
   pins anchor poses + through-horizon monotonicity.

3. **Precision — ghost labels.** Solved by **the pin protocol**, the
   methodology discovery of this round: while recording a replay, the
   user tap-pins each plane they can ACTUALLY see; pins land in the
   JSONL with callsigns, so every recording becomes labeled ground
   truth. 4 sessions / 21 labeled planes produced a decisive split:
   every confirmed sighting was an airliner ≤ 8.3 km; ghosts included
   an 11 km/17.4° 737 in daylight and a 4.8 km/8° Cessna. Naked-eye
   spotting is a single-digit-km activity. The filter is now:
   - `maxVisibleDistance(forElevationDeg:)` — 4.5 km at the 1° floor
     ramping to a 13 km plateau at 30° (plateau kept for near-overhead
     cruise/contrail traffic, which no ghost observation contradicts);
   - `Aircraft.isLikelySmallAirframe` (US registration callsign pattern
     `N`+digit) **halves the cap** — GA airframes subtend ~⅓ of an
     airliner at the same distance. Separates all 21 ground-truth
     planes correctly; `ADSBManagerTests` pins every confirmed sighting
     and ghost class as regression tests. Don't re-tune without new
     pin-protocol data.

4. **`VisibilityDiagnostic` funnel + TEMP on-screen readout.** Per-tick
   counts (`fetched → onGround → stale → lowElev → far → shown`) via
   os_log + an always-visible readout strip in ContentView showing
   `air N · shown M · el E° · …` plus `ANON` / API-limit flags.
   **Deliberately ships in 0.1.3** (Release has no debug wrench;
   testers become sensors and can report the numbers). Remove after
   the TestFlight round validates the re-tune.

Also: `AspectFillTransform` marked `nonisolated` (cleared the four
Swift 6 MainActor warnings from Build 21 — would be hard errors under
Swift 6 language mode); mock templates retuned so couch-testing shows
4 visible planes + 1 deliberately-filtered far one.

**Known limitation (next round's work):** horizontal label offset.
Field-quantified: urban compass wobbles ±20° within seconds (one 165°
jump in 1 s) while CL claims ±10°, and the separable (dB,dE) projection
exaggerates horizontal offsets by ~1/cos(camElev) at high pitch (~25%
at 40°). The fix ladder: CV bracket-snap (PLAN §9 Pending #3, the real
answer) and/or proper 3D rotation projection in `Geo.screenPosition`.

**Tests: 213 pass.** `MARKETING_VERSION` 0.1.2 → 0.1.3. The replay
pull command (`xcrun devicectl device copy from … Documents/replays`)
plus offline python analysis of the JSONL was the workhorse instrument
all round — see Replay recorder section.

## 2026-05-29 — Typography + onboarding shipped (v0.1.2)

**Shipping as TestFlight v0.1.2.** Second feature drop today. The
2026-05-27 "first-tester feedback" work that had been sitting in a
local stash on Noah's machine now lands on main. Four UX fixes:

1. **"Reticles" copy dropped.** Two user-visible strings used the
   word (OnboardingFlow permissions step + HangarView empty state).
   Replaced with plainer language ("labels match the plane in view",
   "aim at a plane, then tap to catch it").

2. **Aviation typography — SF Pro + B612 Mono.** SF Pro stays for
   body/UI text (iOS-native); monospace swaps from SF Mono to
   **B612 Mono** (Airbus's open-source cockpit MFD font, SIL OFL 1.1).
   This is where the aviation feel hits hardest — callsigns, ICAO
   codes, headings, badge labels, wordmark. Files at
   `ios/Tailspot/Tailspot/B612Mono-{Regular,Bold,Italic,BoldItalic}.ttf`
   (~530KB total), registered in Info.plist via `UIAppFonts`. All
   137 ad-hoc `.system(... design: .monospaced)` callsites swept to
   `Brand.Font.mono(size:weight:italic:)` (new helper). B612 Mono
   ships in Regular + Bold only; SwiftUI weight requests map
   regular/medium → Regular, semibold/bold/heavy/black → Bold.
   `Brand.Font.wordmark` / `hudCallsign` / `hudData` retained as
   thin aliases over the helper. Process note: the perl sweep
   initially used `[^,]+?` which over-matched across `.system(...)`
   boundaries (regex spanned past `)` and ate `design: .monospaced`
   from a sibling callsite); reverted and re-ran with `[^,)]+?`.
   Document the safer form if doing any similar sweep again.

3. **Permission prompts moved into onboarding step 2.** Previously
   iOS surfaced the camera + location alerts at the end of
   onboarding when ContentView mounted — testers found the gap
   confusing. Now `OnboardingFlow.advance()` triggers
   `requestSystemPermissions()` when leaving the Permissions step,
   firing `AVCaptureDevice.requestAccess(for: .video)` plus
   `LocationManager.requestPermissionAndStart()` via a transient
   `@StateObject` LocationManager. CMMotion needs no prompt and
   stays informational on the row. ContentView still creates its
   own LocationManager later; iOS just doesn't re-prompt because
   auth state is already decided.

4. **Figure-8 calibration step removed from onboarding.** Awkward
   and rarely needed at launch. `totalSteps` dropped to 3 (Welcome
   → Permissions → Handle). The compass-warning badge in the AR
   view still opens `CompassCalibrationSheet` (with the figure-8
   animation) when accuracy genuinely degrades — same in-app
   trigger, just no upfront prompt. `Figure8Animation` struct
   retained for the sheet.

**Tests:** 176 still pass (no behavioral tests touched — the sweep
changed presentation only). Font loading is exercised by the host-
app build that runs before the test suite, so a missing or
unregistered .ttf would break the build.

**External TestFlight remains approved** (since 2026-05-26 Build 18).
v0.1.2 builds auto-approve for external testers via App Store
Connect → TestFlight → External Testing.

**MARKETING_VERSION bumped 0.1.1 → 0.1.2.** CFBundleVersion stays
at 1 locally; Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites per
archive.

**Open follow-ups specific to this round:**
- Field-test the new typography on device. The B612 Mono swap is
  unmissable but its weight mapping (collapses 4 SwiftUI weights
  into 2 physical faces) may look slightly heavier than SF Mono
  did at small sizes. Calibrate if needed.
- The semantic-size patterns (`.system(.body, design: .monospaced)`
  etc.) were converted to fixed sizes (17 / 12 / 11). This loses
  Dynamic Type scaling for those few callsites. Acceptable for v0
  but worth a `Brand.Font.mono(_:weight:)` TextStyle overload if
  Dynamic Type matters later.
- `design/font-explorer.html` — side-by-side font preview built
  during the typography decision. Reference material; remove if
  it gets stale.

## 2026-05-29 — Catch-photo bracket overlay + bigger reticles (v0.1.1)

**Shipped as TestFlight v0.1.1.** First post-v0 feature drop. Two
landings on main this session, both user-visible to testers.

1. **Catch photos now show which plane you caught.** New
   `CatchPhotoComposer` (pure CG/UIKit, no SwiftUI) decodes the
   captured JPEG, runs the screen→photo pixel transform assuming
   `.resizeAspectFill` (which `CameraPreview` uses), and re-renders
   with the cyan corner-bracket box drawn at the plane's on-screen
   position at capture time. Multi-catch saves one bracket per
   plane on each plane's own photo file.

   The path is: ContentView projects every visible plane to screen
   once per TimelineView frame (`onScreenProjected: [(icao, pos)]`),
   stashes the icao→position map, and threads `screenSize` +
   `positions` through `captureBar` → `captureButton` →
   `performCatch`. At save time the loop looks up `positions[icao]`,
   builds a `CatchPhotoComposer.BracketOverlay`, and calls
   `compose(jpegData:overlay:)`. Fall-through: if compose returns
   nil (bad JPEG, zero-area screen) OR positions misses the icao
   (the plane was on-screen when the button rendered but not in
   the dict at fire time), we save the raw JPEG. No catch is lost.

   `AspectFillTransform` factored out as its own struct so the
   coordinate math is unit-testable without touching UIImage.
   Tests cover same-aspect, wide-photo crops-sides, tall-photo
   crops-top, iPhone 12MP sanity, the compose smoke path, and
   invalid-input fall-throughs (176 tests total — added 7).

2. **Bigger lock-on reticles** for alignment forgiveness. The 56pt
   pinned bracket read tight in field testing: small sensor noise
   or HFOV mis-cal pushed the plane just outside the box. New
   sizes — pinned 140, ambient 96, empty-sky center 200, photo
   overlay 140 (matches pinned so saved photos show the same
   framing). Arm length stays `max(8, boxSize * 0.22)`, so arms
   scale proportionally.

**Tests:** 176 pass (169 baseline + 7 for CatchPhotoComposer).
Reticle bumps don't touch tests — they're presentation constants.

**Doc-staleness hook now guards on main.** `bin/doc-staleness-check`
used to false-fire on feature branches (its check is HEAD-vs-
`origin/main`, which is always ahead on a feature branch even when
that branch is fully pushed to its own remote). Added a one-line
guard: `[ "$current_branch" = "main" ] || exit 0`. Feature-branch
sessions no longer get blocked by the Stop hook — doc updates
land with the merge into main, where the hook still fires.

**MARKETING_VERSION bumped 0.1.0 → 0.1.1** (two configs in
`project.pbxproj`). `CURRENT_PROJECT_VERSION` stays at 1 locally;
Xcode Cloud's `ci_pre_xcodebuild.sh` rewrites it to
`CI_BUILD_NUMBER` per archive.

**Open follow-ups specific to this round:**
- Field-test the new 140pt pinned reticle. If still too tight,
  bump further; if too loose, dial back. The photo-overlay constant
  in `CatchPhotoComposer.bracketScreenBoxSize` must stay in lockstep
  with the live `LockBrackets` size in `ContentView` so saved photos
  match what testers saw.
- The bracket's center is the *predicted* screen position (from
  ADS-B + extrapolation + projection). Eventually the long-term
  fix for "box should land on the actual plane" is CV detection
  (PLAN §9 #3 Vision + COCO airplane class) — let the bracket
  snap to the detected airplane bbox rather than the prediction.
  Until that lands, the bigger box is the cheap forgiveness.

## 2026-05-26 — TestFlight v0 prep (v0.1.0)

**TestFlight v0 prep — landed 2026-05-26.** Everything required to
build, sign, and upload a TestFlight build is in place. See
`docs/testflight-handoff.md` for the step-by-step. Highlights:

- **Credentials baked via xcconfig + Info.plist.** Tailspot.xcconfig
  (committed) `#include?`s Tailspot.secrets.xcconfig (gitignored,
  holds real OpenSky values). Build-time substitution flows into
  Info.plist keys `OpenSkyClientID` / `OpenSkyClientSecret`. New
  resolution order in `OpenSkyClient.init`: explicit creds → env
  vars → `Bundle.main.infoDictionary` → nil/anonymous. Env-var path
  preserves Noah's existing dev loop; the bundle path is the only
  one that survives TestFlight / home-screen / `devicectl` launches.
  **Security accepted:** the values are in the shipped binary,
  extractable from any `.ipa`. v0 risk for 1-2 trusted testers;
  backend proxy is the path for wider distribution (PLAN.md §1).
- **Manual `Info.plist`** at `ios/Tailspot/Info.plist` replaces the
  previously-auto-generated one. Adds `ITSAppUsesNonExemptEncryption=false`
  and the custom OpenSky keys. The Tailspot target switched from
  `GENERATE_INFOPLIST_FILE=YES` + `INFOPLIST_KEY_*` build settings to
  `INFOPLIST_FILE=Info.plist`. The Info.plist sits at the project
  root (outside the synchronized `Tailspot/` folder) so it's not
  bundled as a duplicate resource.
- **Privacy manifest** at `ios/Tailspot/Tailspot/PrivacyInfo.xcprivacy`.
  Declares UserDefaults (`CA92.1`) + FileTimestamp (`0A2A.1`)
  required-reason API usage, and the two data categories we collect
  (precise location + photos — app-functionality only, not linked
  to identity, not tracking). Update when the backend ships.
- **Version + build number scheme.** `MARKETING_VERSION=0.1.0`,
  `CURRENT_PROJECT_VERSION=1`. Bump `CURRENT_PROJECT_VERSION` on
  every TestFlight upload (App Store Connect requires monotonic
  per marketing version); bump `MARKETING_VERSION` on meaningful
  feature drops.
- **App icon.** Programmatically generated 1024×1024 PNGs (3
  luminosity variants — light / dark / tinted) via
  `tools/generate-app-icon.swift`. Cyan→navy gradient + HangarGlyph,
  consistent with brand tokens. Re-run the script to regenerate,
  or replace the PNGs directly in `AppIcon.appiconset/`.
- **xcconfig precedence trick.** `Tailspot.xcconfig` defines
  `OPENSKY_CLIENT_ID =` (empty) as default, then `#include?`s the
  optional secrets file. Last-wins is xcconfig precedence — when
  the secrets file is present its assignments override the empty
  defaults; when missing, the empty defaults stand and Info.plist
  resolves to empty strings (anonymous mode). The `?` on
  `#include?` makes missing-file a no-error condition.

**Tests:** 169 still pass. The credential change is additive (env-var
fallback preserves existing tests that don't touch OpenSky live calls).

**Open follow-ups specific to TestFlight:**
- App Store Connect record creation, signing, Archive + Upload all
  live in Apple UIs — see `docs/testflight-handoff.md`.
- Privacy policy URL needed if/when adding external testers (>10
  beyond your team). Internal testers are sufficient for v0.

**Xcode Cloud (added 2026-05-26):** Apple's CI runs two scripts
checked into `ios/Tailspot/ci_scripts/`:

- `ci_post_clone.sh` materializes `Tailspot.secrets.xcconfig` from
  workflow env vars (`OPENSKY_CLIENT_ID` / `_SECRET`, both marked
  secret in the workflow's Environment Variables). When env vars
  are absent the script no-ops; build runs anonymous.
- `ci_pre_xcodebuild.sh` seds `CURRENT_PROJECT_VERSION` in
  `project.pbxproj` to match Apple's `CI_BUILD_NUMBER` before
  archive. Without this every CI archive shipped with
  `CFBundleVersion=1` and App Store Connect silently dropped
  subsequent uploads as duplicates — Xcode Cloud reported "build
  succeeded" while TestFlight stayed pinned to Build 1 forever.
  Local builds keep the committed value (1); only Xcode Cloud
  rewrites.

**Xcode Cloud setup gotchas that ate hours this session:**
1. Workflow's "Project or Workspace" field defaults to repo root;
   our project is at `ios/Tailspot/Tailspot.xcodeproj` — must be set
   explicitly or builds fail with the misleading "scheme Tailspot
   does not exist" error.
2. Workflow needs a TestFlight distribution **Post-Action**
   ("TestFlight Internal Testing"), separate from the Archive
   action. Without it, the archive succeeds but never reaches
   TestFlight.
3. Don't put trailing whitespace/newlines in env-var values; App
   Store Connect's UI rejects with "invalid value due to invalid
   value" without saying which character offended.

**Post-TestFlight polish landed same day (2026-05-26):**
- App icon swapped from the generated HangarGlyph-on-gradient to
  the B-lockon concept (cyan AR corner brackets framing a white
  airplane symbol on a navy gradient — references the AR mechanic).
  Generator: `tools/generate-icon-options.swift`. Picked variant's
  three PNGs (light/dark/tinted) committed in `AppIcon.appiconset/`;
  `tools/icon-options/` is gitignored.
- `ComingSoonPill` + `ComingSoonBanner` components (`ComingSoonPill.swift`).
  Applied to Leaderboard, Public Hangar, and Notifications screens
  with amber `hammer.fill` glyph so testers know these are mocks
  pending backend.
- Debug wrench toggle in `ContentView` wrapped in `#if DEBUG`.
  TestFlight (Release) builds show no wrench; local Xcode dev
  (Debug) keeps it.
- 8 Swift 6 prep warnings cleared (Log isolation, PhotoCaptureDelegate
  nonisolated, HangarGrouping no longer claims nonisolated when it
  touches `@MainActor Catch` state, MultiCatchReveal @ViewBuilder
  drop, Trophies closure @Sendable).
- Hangar glyph swapped to SF Symbol `airplane.path.dotted` (plane
  with dashed trail). Replaces the hand-drawn peaked-pentagon Shape
  in `HangarGlyph.swift`. Callers unchanged — same `HangarGlyph(tint:)`
  API, `lineWidth` retained as unused param for source compat.
- Settings → bottom of page renders `Tailspot 0.1.0 (build N) · tap
  to copy`. Tap copies the version line to the clipboard with a
  soft haptic; testers paste it verbatim into bug reports.
