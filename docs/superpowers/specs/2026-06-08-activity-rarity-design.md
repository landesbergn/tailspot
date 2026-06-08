# Activity-based rarity tiering — design

**Date:** 2026-06-08
**Status:** Approved (brainstorm), pending implementation
**Supersedes:** the curated "spotter-interest" rarity model in `GameSystem.swift`

## Problem

Rarity today is a hand-curated "how interesting is this airframe to a
spotter" judgment, explicitly *not* frequency-based (`GameSystem.swift`
header comment). Two consequences the user wants fixed:

1. **Newness is mistaken for rarity.** A 737 MAX 8 is `uncommon` (25 pts)
   purely because it is the newest 737 generation — but there are
   ~1,500–1,800 flying daily, so it is one of the most-seen jets in the
   sky. It should be `common`.
2. **Low-activity airframes are under-tiered.** An Embraer EMB-505
   Phenom 300 is `common` (10 pts), but business jets are parked most of
   the time and you are far less likely to see one overhead than a MAX.
   It should rank *higher*, not lower.

The fix: tier by **sky presence** — how many of a type are airborne at any
given moment — rather than by editorial interest or by fleet count alone.

## Decisions (locked during brainstorm)

- **Metric: pure sky presence.** Rank by real-world flight movements /
  instantaneous airborne count. Detectability is explicitly *ignored*
  (we do NOT bump GA/heli/mil for OpenSky's MLAT blindness).
- **No real movements feed exists offline.** The tier is a *curated
  approximation*: a per-category default keyed on the DOC 8643 fields we
  already have (AircraftDescription / EngineType / WTC), plus a hand
  override table for named exceptions. Same `default + OVERRIDES` shape
  the `type` generator already uses.
- **Points are unchanged:** 10 / 25 / 100 / 500 / 2000. Only *which tier*
  an airframe lands in changes.
- **Architecture: typecode-driven (Approach B).** Rarity resolves from
  the ICAO typecode through the authoritative bundled table, exactly like
  `type` already does — finishing the migration off OpenSky free-text
  fields. The string `AircraftClassifier` survives only as the
  no-typecode fallback.
- **Frozen-moment reversal (intentional).** Rarity stops being a frozen
  snapshot and becomes a read-time derived property that floats with the
  table (as `type` already does). This is what makes "correct prior data"
  work with zero migration. A tester's point total can shift after an
  update; acceptable on internal TestFlight.

## The tier ladder (target)

```
COMMON     737 · A320 family · 757 · E175/E170 · CRJ700+ · ATR · Dash 8-400
           · Cessna 172/182 · Piper PA-28 · Cirrus SR22 · Diamond DA40
UNCOMMON   A330 · 767 · 787 · 777 · A350   (modern workhorse widebodies)
           · A220 · E190/E195 · 717 · MD-80 · 727   (newer/smaller narrowbody)
           · light+mid business jets (Phenom 300, Citation, Learjet,
             Challenger, Falcon, Hawker, G550)
           · GA turboprops (PC-12, TBM, King Air) · rotorcraft
RARE       747 (-200/-400/F) · A340 · MD-11   (scarce-in-the-air widebodies)
           · heavy/ULR bizjets (G650, G700, Global 7500, Global Express)
           · workhorse military (C-130, C-17, KC-135, P-8)
EPIC       A380 · 747-8 · B-52 · B-1 · E-3 AWACS · C-5 · An-124
LEGENDARY  Air Force One (VC-25) · SR-71 · B-2 · U-2 · Concorde · An-225
```

### What moves vs. today

| Airframe | Now → New | Note |
|---|---|---|
| 737 MAX 8 | uncommon → **common** | motivating case #1 |
| Light/mid bizjets (Phenom 300, Citation, Learjet, Challenger, Falcon) | common → **uncommon** | motivating case #2 |
| A330, 767, 787, 777, A350 | (mixed) → **uncommon** | workhorse widebodies; consistent airborne-count |
| Heavy bizjets (G650, Global 7500) | uncommon → **rare** | very few airborne |
| GA turboprops (PC-12, TBM, King Air), rotorcraft | common → **uncommon** | |
| 747, A340, MD-11 | (mixed) → **rare** | genuinely scarce airborne |
| A380, 747-8, C-5, bombers | epic → **epic** | unchanged |
| 737 NG, A320, regional, GA piston | common → **common** | unchanged |
| Air Force One, SR-71, B-2, Concorde | legendary → **legendary** | unchanged |

## Category-default classifier (generator)

`aircraft_rarity(tc, info, type_str)` in `tools/generate-aircraft-types.py`,
evaluated top to bottom:

1. **`tc in RARITY_OVERRIDES`** → return the override (see below).
2. **AircraftDescription starts with `H` / `G` / `T`** (helicopter /
   gyrocopter / tilt-rotor) → `uncommon`.
3. **WTC == `J`** (super-heavy: A380) → `epic`.
4. **type_str == `wide`** → `uncommon` (scarce widebodies overridden to
   rare/epic).
5. **type_str == `biz`** → `uncommon` (heavy bizjets overridden to rare).
6. **type_str == `mil`** → `rare` (bombers/AWACS/outsized overridden to
   epic; icons to legendary).
7. **type_str in {`narrow`, `regional`, `ga`}** → `common`
   (newer/smaller narrowbodies, scarce GA overridden to uncommon).
8. **Default** → `common`.

### `RARITY_OVERRIDES` (typecode → tier)

Exact typecodes verified against `AircraftTypes.json` keys at
implementation time; representative set:

- **legendary:** `CONC` (Concorde), `SR71`, `U2`, `B2` (B-2 Spirit),
  `A225` (An-225). *(VC-25 Air Force One has no distinct civil typecode —
  it stays operator-gated in the string classifier.)*
- **epic:** `A388`/`A380` (A380), `B748` (747-8), `C5`/`C5M` (C-5),
  `A124` (An-124), `B52`/`B52H` (B-52), `B1` (B-1), `E3TF`/`E3CF` (E-3).
- **rare (scarce widebodies):** `B742`, `B744`, `B74S` (747 family),
  `A342`/`A343`/`A345`/`A346` (A340 family), `MD11`.
- **rare (heavy/ULR bizjets):** `GLF6` (G650), `GL7T` (Global 7500),
  `GLEX` (Global Express/6000). *(G700 typecode confirmed at impl time.)*
- **rare (workhorse military):** `C130`/`C30J` (C-130), `C17`, `K35R`
  (KC-135), `P8` (P-8).
- **uncommon (newer/smaller narrowbody):** `BCS1`/`BCS3` (A220),
  `E190`/`E195`/`E290`/`E295`, `B712` (717), `MD82`/`MD83`/`MD88`/`MD90`,
  `B727`/`B72*` (727).
- **uncommon (GA turboprops):** `PC12`, `TBM7`/`TBM8`/`TBM9`,
  `BE20`/`BE30`/`B350` (King Air).

Regeneration is idempotent. `aircraft_rarity` is independent of the
make/model OVERRIDE branch (overrides change display names only),
mirroring how `aircraft_type` is computed from `desig_info`.

## Code changes

### `AircraftTypes.json` (regenerated)
Every entry gains `"rarity": "<tier>"` next to `"type"`. 2,612 entries.

### `AircraftNaming.swift`
- `Entry` (Decodable) gains `let rarity: String?` (optional for
  back-compat with pre-field JSON).
- `CanonicalName` gains `rarity: Rarity?`; the `table` builder maps
  `$0.rarity.flatMap { Rarity(rawValue: $0) }`.
- New: `static func rarity(forTypecode typecode: String?) -> Rarity?`
  mirroring `aircraftType(forTypecode:)` — returns `table[code]?.rarity`.

### `Catch.swift` — `resolvedRarity`
Changes from `stored-snapshot → classifier` to:

```swift
var resolvedRarity: Rarity {
    if let r = AircraftNaming.rarity(forTypecode: typecode) { return r }   // authoritative
    return AircraftClassifier.classify(                                    // no-typecode fallback
        manufacturer: manufacturer, model: model, operatorName: operatorName
    ).rarity
}
```

The stored `Catch.rarity` string is retained (written at insert, kept as
an as-caught audit value) but **no longer drives resolution** — every
catch re-ranks on read. This is the deliberate divergence from
`resolvedType` (which keeps a stored middle step); justified because the
user explicitly wants all prior rarity corrected. `CatchBackfill` already
ensures old catches acquire a typecode, so the authoritative branch
covers the vast majority; the re-tiered string classifier covers the
residual with no stored stale value in the way.

### `GameSystem.swift` — `AircraftClassifier.rules`
Re-tiered to match the activity model (no-typecode fallback only):
- Remove the `["max"]` uncommon rule → MAX falls through to `737` →
  `common`.
- Business jets (`citation`, `phenom`, `learjet`, `challenger`,
  `falcon`, `hawker`) → `uncommon` (was common).
- Widebodies (`787`, `a350`, `777`, `767`, `a330`, `747`) → `uncommon`
  (workhorse), EXCEPT scarce → rare: keep `a340` and (operator-free)
  747-classic handling; heavy bizjets (`g650`, `g700`, `global 7500`,
  `global express`) → `rare`.
- GA turboprops (`pc-12`, `tbm`, `king air`) → `uncommon`.
- Newer/smaller narrowbody (`a220`, `e190`, `e195`) stay `uncommon`.
- Operator-gated legendary/epic rules (VC-25/USAF, Concorde, SR-71, B-2,
  A380, 747-8, C-5) unchanged.
- Heuristic fallback type buckets unchanged; default rarity stays
  `common`.

### `ReferenceScreens.swift` — `RarityReferenceScreen`
- Header subtitle: *"Curated by airframe — not measured by frequency."*
  → *"Ranked by how much each type actually flies — how likely you are to
  see one overhead."*
- `examples(for:)`:
  - common: `737 · A320 · E175 · ATR · Cessna 172`
  - uncommon: `A330 · 787 · 777 · A350 · Phenom 300 · King Air`
  - rare: `747 · A340 · G650 · C-130 · C-17`
  - epic: `A380 · 747-8 · B-52 · C-5`
  - legendary: `Air Force One · SR-71 · B-2 · Concorde`
- Bottom caption ("Points are awarded by rarity only…") unchanged.

## Tests

- **New `RarityResolutionTests`** (mirrors `AircraftTypeResolutionTests`):
  typecode → expected tier for every bucket. Pins: MAX (`B38M`) →
  common; EMB-505 Phenom (`E50P`) → uncommon; A330 (`A333`) / 767
  (`B763`) / 787 (`B789`) → uncommon; 747 (`B744`) / G650 (`GLF6`) →
  rare; A380 (`A388`) → epic; B-2 (`B2`) → legendary.
- **Update `AircraftClassifierTests`** for the re-tiered string fallback
  (MAX→common, Phenom→uncommon, widebody→uncommon, heavy bizjet→rare).
- **`resolvedRarity` re-rank test**: a `Catch` with an old stored
  `rarity` snapshot but a known typecode resolves to the *new* tier,
  proving prior data is corrected.
- Run full suite: `xcodebuild test … -only-testing:TailspotTests`.

## Docs & version

- `CLAUDE.md` `Current state`: new block recording the activity-rarity
  overhaul + the frozen-moment reversal for rarity. Move prior block to
  `CHANGELOG.md`.
- `PLAN.md` §9: note the rarity-model change.
- `MARKETING_VERSION` 0.2.0 → **0.3.0** (re-prices every catch in every
  tester's hangar — a user-visible scoring change).

## Out of scope / non-goals

- No backend, no real movements feed, no local/temporal scarcity bonus
  (that's the deferred hybrid from the prior discussion).
- No change to `AircraftType` (`type`) buckets or to point values.
- No dedupe / Hangar changes.

## Risks

- **Typecode coverage of the override list.** A few overridden typecodes
  may not exist verbatim in `AircraftTypes.json` (e.g., `B2` vs `B2`
  spelling, G700 designator). Mitigated by verifying each against the
  JSON keys during implementation and pinning representatives in tests.
- **Tester score shift.** Communicated via the 0.3.0 bump; internal
  testers only.
