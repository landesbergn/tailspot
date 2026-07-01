# Runbook — Collection-economy leaderboard rollout

**Date:** 2026-07-01
**Owner:** Noah (all prod steps are Noah-gated — see the ⚠️ markers).
**What it does:** makes the already-merged economy re-balance *live on prod* so the
leaderboard reflects the new tiers + points, and (with PR #89) real catches get
airport city names.

## Context — what's already merged vs. what prod is running

Merged to `main` (PR #88, + PR #89 for airport names) but **NOT yet on prod**:

- Points ladder `10/25/100/500/2000` → **`10/20/50/100/500`** (`backend/src/catches/points.ts`).
- `CURRENT_SCORING_VERSION` → **2**.
- Server-authoritative **first-of-type +50%** (`first_of_type` column, migration `0005`).
- Re-tiered `AircraftTypes.json` (2,612 entries — the same file the backend ingests
  into `typecodes` and the iOS client bundles).
- adsb.lol route + airport-name passthrough on `/v1/aircraft`.

**Prod is still running the old deploy** (points `10/25/100/500/2000`, scoring_version 1,
old tiers) until the steps below. Nothing has moved on the live leaderboard yet.

## Fly targets

- Backend app: **`tailspot-api`** (region `sjc`); **no `release_command` → migrations are manual.**
- DB: `tailspot-db` (connect per the prod-DB-lookup pattern).

## Rollout — ordered. ⚠️ = irreversible / prod-writing → Noah's explicit go.

### 1. ⚠️ Apply pending migrations to prod
Both are additive `ADD COLUMN … NOT NULL DEFAULT` (safe, instant on PG for constant
defaults — no table rewrite): `0004` = `scoring_version`, `0005` = `first_of_type`.
`drizzle-kit migrate` is idempotent (applies only what's pending):

```bash
cd backend
DATABASE_URL="<prod>" npm run db:migrate
```

**Verify:** `catches` has `scoring_version` + `first_of_type` columns.

### 2. ⚠️ Deploy the backend to Fly
Ships the new points ladder, scoring_version 2, first-of-type logic, and the route +
airport-name passthrough.

```bash
cd backend
fly deploy --remote-only
```

**Verify:** `GET https://api.tailspot.app/v1/aircraft?...` returns a `route` with
`originName`/`destName` on a scheduled flight; app shows city names on a fresh catch.

### 3. ⚠️ Re-ingest the new tiers into prod `typecodes`
The backend scores from `typecodes.rarity`; re-ingest the regenerated file so prod
tiers match the merged ones. Runs locally against the prod DB, reading the repo file:

```bash
cd backend
DATABASE_URL="<prod>" npm run ingest:doc8643 -- ../ios/Tailspot/Tailspot/AircraftTypes.json
```

**Verify (spot-check prod `typecodes`):** `B52`→legendary, `C17`→epic, `A388`→rare,
`B744`→rare, `C172`→common.

### 4. Preview the leaderboard delta (READ-ONLY — safe)
Dry-run computes the full delta and writes nothing. **Review this before step 5.**

```bash
cd backend
DATABASE_URL="<prod>" npm run rescore -- --dry-run
```

Expect a sizeable shift: e.g. an A380 catch 500→50, a 747-400 100→50, a C-17 100→100,
a B-52 500→500. **Note:** first-of-type is frozen at upload, so pre-`0005` catches keep
`first_of_type=false` — rescore does **not** retroactively award the +50% bonus (correct;
it's a going-forward bonus).

### 5. ⚠️ Apply the rescore
Re-derives points for every stale row (`scoring_version < 2` or null rarity) via the
one canonical `scoreCatch`. Idempotent + re-derivable (a later logic fix re-fixes).

```bash
cd backend
DATABASE_URL="<prod>" npm run rescore
```

**Verify:** query the leaderboard (top entries + @noah's total) — points reflect the
new ladder/tiers.

## Rollback

- **Migrations:** additive only — nothing to roll back.
- **Deploy:** `fly deploy` the prior image if needed.
- **Rescore:** points are a re-derivable projection (scoring_version) — re-run rescore
  with corrected logic to re-fix; no data is lost.

## Local verification already done (2026-07-01)

- Regenerated `AircraftTypes.json` (2,612 entries) carries the correct new rarities
  (spot-checked above); `scoring-points.json` = `10/20/50/100/500`.
- Migrations `0004`/`0005` reviewed — simple additive `ADD COLUMN`s.
- `ingest:doc8643` shape matches the file (it already ingests this format to prod).
- Route/airport-name code: backend vitest (16) + iOS `TailspotTests` green; PR #89.
- Rescore logic is unit-tested + dry-runnable.
