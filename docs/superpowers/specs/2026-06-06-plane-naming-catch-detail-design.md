# Plane naming standardization + catch detail upgrades

**Date:** 2026-06-06
**Status:** Approved by Noah (design conversation, this date)

## Problem

Seven user-reported issues, two clusters:

**Naming / Sets:**
1. Model/make names come straight from OpenSky's metadata DB — inconsistent
   casing ("BOEING"), Boeing customer codes ("737-8H4" is a Southwest
   737-800; the `H4` suffix encodes the airline), and no anchor to an
   official source.
2. Sets distinguish the same model by airline: `777-322ER` and `777-3F2ER`
   bucket as two different model groups because the customer code differs.
3. The "Unknown" model group usually sorts to the TOP of a set's detail
   view (sort is tail-count-desc and Unknown is usually the biggest bucket).

**Catch detail view (`CatchDetailView`):**
4. ALT and SPD stat chips are always "—". Root cause: the catch reveal
   borrows live values from `ObservedAircraft`, but `Catch` never persists
   altitude/speed, so the detail view has nothing to show.
5. Location shows raw GPS coordinates; should show City, State.
6. No way to delete a catch from the detail view.
7. Tail number (registration) is never shown — it's in OpenSky's metadata
   but never stored on `Catch`.

## Architecture decision: normalize at read time

Raw OpenSky strings stay stored on `Catch` untouched. A pure function
normalizes wherever names display or group. Rationale:

- Old catches re-bucket automatically; future rule improvements are
  retroactive.
- Matches the existing `AircraftClassifier.classify` read-time pattern.
- Preserves the frozen-snapshot philosophy: we never rewrite recorded data.

Rejected: write-time normalization (needs migration, rule fixes don't
retroact, overwrites raw data) and hybrid stored-canonical field (extra
schema for no gain).

## A. `AircraftNaming` (new file `AircraftNaming.swift`)

`nonisolated enum AircraftNaming` exposing:

```swift
struct CanonicalName: Equatable {
    let make: String?      // "Boeing"
    let model: String?     // "777-300ER"
    var displayName: String?  // "Boeing 777-300ER" (joined, nil-safe)
}
static func canonical(typecode: String?, manufacturer: String?, model: String?) -> CanonicalName
```

Resolution order:

1. **ICAO type-designator table hit** → official make + model. The
   table is the **complete DOC 8643 designator set (~2,700 entries),
   generated from ICAO's official data — never typed from memory.**
   Noah's direction (2026-06-06): full coverage, not a corridor subset;
   the app must work everywhere.

   **Generator tool** (`tools/generate-aircraft-types.py`, follows the
   `tools/generate-app-icon.swift` checked-in-generator precedent):
   - Fetches `https://doc8643.icao.int/external/aircrafttypes` (POST,
     empty body → 7,260 rows; verified working 2026-06-06).
   - Reduces multiple manufacturer/model rows per designator to one
     canonical (make, model) pair: most frequent manufacturer wins;
     among its rows, the shortest `ModelFullName` (the base model).
   - Applies deterministic display polish: title-case manufacturers
     with an exceptions list (ATR, SAAB…), Airbus hyphen style
     `A-320neo` → `A320neo` / `A-220-300` → `A220-300`.
   - An in-script override map handles designators where the
     deterministic rule picks a poor representative (e.g., shared
     designators like `C172`, which covers Cessna and Reims builds).
     **The override map is populated from post-generation review, not
     written from guesses up front:** after generating, pull ~25
     designators at random across categories (helicopters, gliders,
     GA, military, airliners) and read them. Names that read like a
     database dump get an override entry; regenerate and re-review.
     This review is an explicit implementation task — the table isn't
     done until it passes.
   - Emits `AircraftTypes.json`, checked into the app bundle
     (~150–250 KB — smaller than the B612 fonts). **The checked-in
     JSON diff is the verification surface** — review it after every
     regeneration. Re-run the script to refresh when ICAO updates.
   - Licensing: the endpoint is publicly accessible without auth
     (verified 2026-06-06); designator→model mappings are factual
     reference data bundled by flight trackers industry-wide. No
     explicit redistribution terms were located in this session's
     check — a proper licensing pass belongs on the pre-App-Store
     release checklist. Clean fallback if ICAO's terms disappoint:
     FAA Order JO 7360.1 (US-government work, public domain) carries
     substantially the same designator→model data.

   Runtime: lazy `static let` decode of the bundled JSON into a
   `[String: CanonicalName]` on first use (one-time, milliseconds for
   ~2,700 entries), `nonisolated`/`Sendable`. A missing or corrupt
   resource degrades to the string fallback — never crashes.

   The mock fixtures already pin `B738`/`A320`/`CRJ7`/`AT76`; tests
   assert those resolve through the real bundled table.
2. **String cleanup fallback** (covers rows with no typecode):
   - Strip Boeing customer codes: variant digit + 2-char customer code
     after the dash → variant-hundred. `737-8H4` → `737-800`;
     `777-322` → `777-300` (all-digit customer codes exist — 22 is
     United); suffix preserved: `777-3F2ER` → `777-300ER`.
   - **Idempotent on clean inputs** — Boeing dropped customer codes
     ~2016, so OpenSky has both dirty and clean strings. `737-800`,
     `787-9`, `737 MAX 8`, `747-8` must pass through unchanged. This is
     a hard requirement with pinned tests (this repo has a documented
     prior regex over-match incident).
   - Title-case manufacturers with an exceptions list (`BOEING` →
     `Boeing`; `ATR` stays `ATR`).
   - Dedupe manufacturer repeated inside model ("Boeing Boeing 737").
3. Nothing usable → nil fields → callers render "Unknown".

Implementation notes: regexes compiled once (`static let`) — grouping
re-runs per render, so the normalizer must stay cheap.

Display surfaces switching to canonical names: PokeCard title, catch
reveal, Hangar `.aircraftType` group headers, Set model rows, AR
ambient/locked labels.

## B. Sets fixes

- `HangarGrouping.key(for:mode:.aircraftType)` and
  `HangarGrouping.modelGroups` key on the canonical display name →
  same model collapses across airlines.
- `modelGroups` sort pins the Unknown bucket LAST (after tail-count
  desc / alphabetical for everything else).
- `SetDetailView.displayModel` / `ModelSlotDetailView.displayModel`
  drop their ad-hoc re-casing hacks — canonical name is display-ready.
- `PokeSets.matches(catch:entry:)` becomes a **union**: tokens match
  against canonical name OR raw model. Membership can only gain, never
  lose. Pinned by a regression test so it can't silently revert.

Known low-risk wrinkle: `ModelSlotRoute` is keyed on the canonical model
string. If a backfill (§ E) changes a row's canonical name while the
route is on the stack, the bridge rebuilds an empty group. Acceptable —
backfill fires at the leaf (`CatchDetailView`), below this route; the
empty-group render is transient and self-heals on re-navigation.

## C. `Catch` schema additions

All optional with nil defaults → SwiftData lightweight migration,
tester-safe (per CLAUDE.md rule: additive only once testers have data).

```swift
var registration: String?    // tail number, e.g. "N321DN"
var typecode: String?        // ICAO designator, e.g. "B77W"
var altitudeMeters: Double?  // aircraft altitude at catch moment
var velocityMps: Double?     // ground speed at catch moment
var placeName: String?       // "Berkeley, CA" — reverse-geocoded
```

`performCatch` populates:
- `registration`/`typecode` from the resolved `AircraftMetadata`.
- `altitudeMeters`/`velocityMps` from `observed.aircraft` (the ALT/SPD
  fix at the source).
- `placeName`: reverse-geocode AFTER save, async, never blocking the
  catch; failure leaves nil for the § E backfill.

Geocoding API: **decided at build time, not in this spec.** Candidates
are `CLGeocoder.reverseGeocodeLocation` and the newer MapKit reverse-
geocoding request; write it against the deployment target and let
deprecation warnings pick. Wrapped in one small helper
(`ReverseGeocode.placeName(lat:lon:) async -> String?`) so the choice is
one line to change. Output formatting is **locale-aware, not
US-hardcoded** (the app must work for everyone): "City, ST" when the
placemark has an admin-area abbreviation (US/CA style), "City, Region"
with the full region name otherwise, "City, Country" when there's no
admin area at all, and the country alone as the last resort. The
formatting is a pure function over placemark fields with tests for each
shape; the network wrapper itself stays thin and untested.

## D. `CatchDetailView` upgrades

- **ALT/SPD:** `PokePlane(catchRecord:)` formats the new stored fields —
  `37,000 ft` / `478 kt`, same formatting as ContentView's reveal
  builder (extract/share that formatting). Old rows: "—" (the moment is
  unrecoverable; deliberately NOT backfilled).
- **Location:** FIRST CAUGHT panel shows `placeName`; falls back to the
  existing coordinate string while nil.
- **Tail number:** new AIRFRAME panel (same `bgElevated` card style as
  FIRST CAUGHT, placed directly below it) — registration + icao24 hex +
  typecode, mono font, "—" for missing fields. Also
  `ModelSlotDetailView` tail rows prefer registration over raw hex when
  present.
- **Delete:** red trash chrome pill in the floating chrome bar →
  confirmation alert (same copy pattern as `HangarRecentView`: "Delete
  catch of UAL123?" / "This can't be undone.") → deletes ALL the row's
  catches AND their photo files via `CatchPhotoStore.delete`, then
  `dismiss()`. Side fix in scope: `HangarRecentView.performDelete`
  currently orphans photo files — add the same `CatchPhotoStore.delete`
  call there.

## E. One-time backfill on detail-view open

**This deliberately amends a documented invariant.** CLAUDE.md says
"CatchDetailView is a read-only snapshot — no live re-fetch." The
invariant's intent — don't let tomorrow's data rewrite a recorded
moment — is preserved by two rules:

1. **Fill-only-if-nil.** Existing values are never overwritten.
2. **Airframe-static fields only, plus one documented exception.**
   `registration`/`typecode` are properties of the airframe, not the
   moment — backfilling them is recovering facts, not rewriting history.
   `operatorName` is the exception: airframes change operators (leases,
   sales), so a backfilled operator is "best-effort current," not
   "as-flown." We backfill it anyway (nil → something beats nil) and
   document the caveat in code. ALT/SPD are moment-data and are NEVER
   backfilled.

Mechanics, in `CatchDetailView.task`:
- If `registration == nil || typecode == nil` → one metadata fetch via a
  `static let` shared `OpenSkyClient()` owned by the view file.
  **Deliberate choice:** this bypasses `ADSBManager`'s `MetadataCache`
  (the manager isn't reachable from the Hangar sheet without threading
  it through every layer). A second token/cache instance is acceptable
  for a one-shot backfill path; the metadata endpoint also works
  anonymously (`bearerTokenIfPossible` attaches auth only when
  available).
- If `placeName == nil` and stored coords are non-zero → reverse-geocode
  and write back.
- Write-backs persist via `modelContext.save()`, so each row backfills
  at most once; offline/failed fetches leave nil and retry on next open.
- Fields filled when nil: `registration`, `typecode`, `manufacturer`,
  `model`, `operatorName` (caveat above), `placeName`.

## F. Tests

- **`AircraftNamingTests` (new):** bundled-table integrity is
  **structural across the whole table, not just spot-values** —
  spot-checks tell you nothing about the other ~2,690 entries:
  - loads; entry count in [2,500, 3,000];
  - every entry has non-empty, whitespace-trimmed make AND model, no
    double spaces;
  - no raw-source artifacts: no Airbus entry retains the `A-320`
    hyphen style; no make is fully upper-case unless on the known
    exceptions list (ATR, PZL, …);
  - spot-checks on top: `B738` → Boeing 737-800, `B77W` → Boeing
    777-300ER, `A20N` → Airbus A320neo, `BCS3` → Airbus A220-300,
    plus the four mock-fixture designators.

  Also: customer-code stripping
  incl. all-digit codes (`777-322` → `777-300`); suffix preservation
  (`777-3F2ER` → `777-300ER`); **idempotence on clean inputs**
  (`737-800`, `787-9`, `737 MAX 8`, `747-8` unchanged); casing
  exceptions (ATR); manufacturer-dedupe; all-nil → nil; missing
  resource degrades to string fallback. The python generator itself is
  not Swift-tested — its checked-in OUTPUT is what the suite pins.
- **`HangarGroupingTests`:** canonical collapsing (two customer-code
  variants of the same model land in one `ModelGroup`); Unknown sorts
  last in `modelGroups`.
- **`SetsTests`/`AircraftClassifierTests` area:** `PokeSets.matches`
  union behavior pinned (raw-only match still matches; canonical-only
  match now matches).
- **`CatchTests`:** new-field persistence round-trip; ALT/SPD formatting
  in `PokePlane(catchRecord:)`; nil fields → "—".
- Place-name formatting ("City, ST") as a pure function test.

## G. Documentation

- Update CLAUDE.md's "CatchDetailView is a read-only snapshot" note to
  state the amended invariant (fill-only-if-nil backfill of
  airframe-static fields; operator caveat). The Stop hook enforces doc
  freshness; the next session must not read a note that contradicts the
  code.
- Refresh CLAUDE.md "Current state" + PLAN.md § 9 per the usual rule.

## Out of scope

- Recovering ALT/SPD for pre-existing catches (impossible).
- FAA registry (ACFTREF) bundling — US-only and keyed by N-number;
  superseded by the full ICAO DOC 8643 table above, which is global.
  (An earlier draft limited the table to a hand-curated SFO/OAK subset;
  Noah rejected that — full coverage is in scope.)
- Localizing UI strings ("Unknown", panel labels) — naming data is now
  global, but UI copy localization is a separate effort.
- Dynamic Type, dedupe-across-models, CV bracket-snap — unrelated
  backlog items.
