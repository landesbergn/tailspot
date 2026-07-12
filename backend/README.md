# Tailspot API

Node 22 + TypeScript (strict, ESM) + Fastify backend for the Tailspot iOS app.

## What this service becomes

This scaffold is Work Package 1.1 of the Track 1 data-backbone programme
(`docs/superpowers/plans/2026-06-10-track1-data-backbone.md`). Subsequent work
packages add: a **position proxy** (`GET /v1/aircraft?bbox=…`) that polls
adsb.lol server-side so OpenSky credentials are no longer baked into the iOS
binary; a **metadata service** (`GET /v1/metadata/{icao24}`) merging the FAA
releasable DB + ICAO DOC 8643; a **catch ingestion endpoint** (`POST /v1/catches`)
with instrumented anti-cheat validation; and an **anonymous leaderboard**
(`GET /v1/leaderboard`) backed by Fly.io managed Postgres with device-token
identity and claimable handles — no sign-in, no PII beyond a self-chosen handle.

## Endpoints

### `GET /healthz`

Liveness probe. Returns `{ "status": "ok", "version": "<pkg version>" }`.

### `GET /v1/aircraft?lamin=&lomin=&lamax=&lomax=` (WP 1.2 + 1.3)

Cached, single-flighted position proxy. Takes a bounding box in decimal
degrees and returns a normalized, SI-unit snapshot of aircraft inside it:

```jsonc
{
  "fetchedAt": 1781116526,        // unix SECONDS of the upstream snapshot (NOT serve time)
  "aircraft": [
    {
      "icao24": "a92d6d",          // lowercase hex
      "callsign": "UAL875",        // trimmed; null if empty
      "originCountry": "United States",
      "longitude": -122.45, "latitude": 37.82,
      "altitudeMeters": 3322.3,    // geometric preferred, baro fallback, 0 if unknown/on-ground
      "velocityMps": 150.1,        // ground speed; null if unknown
      "trackDeg": 311.94,          // degrees true; null if unknown
      "onGround": false,
      "positionTimestamp": 1781116525  // unix seconds of last position update; null if unknown
    }
  ]
}
```

Errors: `400 { "error": "..." }` for a missing / non-numeric / out-of-range /
inverted / oversized (> 4 sq deg) bbox; `503 { "error": "upstream unavailable" }`
when the upstream is down **and** no acceptably-fresh cache exists.

Behind the route:

- **Region-tile cache** — the bbox is quantized to a coarse grid (`0.25°`) to
  collapse a neighbourhood of near-identical viewports onto one cache key.
  Fresh entries (within `CACHE_TTL_SECONDS`, default 10) are served without an
  upstream call.
- **Single-flight dedup** — concurrent requests for the same tile share one
  in-flight upstream fetch.
- **Last-good fallback** — on upstream failure, a cached snapshot younger than
  `STALE_MAX_SECONDS` (default 60) is served with its true `fetchedAt` so the
  client sees the staleness; otherwise the request 503s. Upstream errors never
  surface as a 500.

### `GET /v1/metadata/{icao24}` (WP 1.4)

Per-airframe metadata, merging the **FAA Releasable Aircraft DB** (authoritative
for US tails: registration + manufacturer/model + typecode) with **ICAO DOC 8643**
(authoritative for clean type naming). `{icao24}` is lowercase hex, validated as
`[0-9a-f]{6}` (uppercase is accepted and normalized).

```jsonc
{
  "icao24": "a12345",           // echoed, lowercased
  "registration": "N12345",     // FAA tail number; null if unknown
  "manufacturer": "Boeing",     // DOC 8643 clean name when the typecode is known there, else raw FAA
  "model": "737-800",
  "typecode": "B738",           // ICAO type designator; null if the FAA row carries none
  "operatorName": null,         // always null for now — community lookup is a later seam
  "source": "merged"            // "merged" | "faa" | "doc8643"
}
```

Errors: `400 { "error": "malformed icao24" }`; `404 { "error": "unknown aircraft" }`
when no source knows the airframe.

**Merge semantics.** The FAA registry says *which airframe* a US tail is and
supplies registration + typecode. When the FAA row's typecode is also in the DOC
8643 table, we prefer DOC 8643's **clean** manufacturer/model (`Boeing` /
`737-800`) over the FAA's messy ALL-CAPS strings (`BOEING` / `737-800` — the FAA
casing/formatting is inconsistent across rows). `source` records provenance:
`merged` (both contributed), `faa` (registry only — typecode absent or unknown
to DOC 8643), `doc8643` (type table only). The merge is a pure function
(`src/metadata/merge.ts`), unit-tested without a database.

**Storage.** Postgres via Drizzle ORM — `registry` (icao24 PK) + `typecodes`
(typecode PK). The route depends on an injected `MetadataStore` (mirrors the
aircraft route's injected `PositionProvider`), so the storage backend is swappable
and tests inject a PGlite-backed store. See **Database & ingestion** below.

### Configuration (env)

| Var | Default | Meaning |
|---|---|---|
| `POSITION_PROVIDER` | — (composite) | Unset: adsb.lol primary with airplanes.live failover. `adsblol` or `airplaneslive`: that provider only. Read once at startup. |
| `CACHE_TTL_SECONDS` | `10` | Fresh-cache window. |
| `STALE_MAX_SECONDS` | `60` | Max age of a last-good snapshot served on upstream failure. |
| `CACHE_TILE_SIZE_DEG` | `0.25` | Grid size for bbox→tile quantization. |
| `DATABASE_URL` | — | Postgres connection string. Required for `/v1/metadata` and the ingest jobs; read lazily (the position-only endpoints don't need it). |

**Providers.** The primary is **adsb.lol** (`https://api.adsb.lol`), whose only
geographic query is point+radius (`GET /v2/point/{lat}/{lon}/{radius}`, radius
in NM) — so the adapter fetches the smallest circle covering the bbox and
filters back to the rectangle. readsb feeds report feet / knots and don't carry
`origin_country`, so the adapter converts to meters / m·s⁻¹ and derives the
country from the icao24 via the ICAO Annex 10 24-bit allocation table. The
**airplanes.live** failover speaks the same readsb dialect (same adapter,
different host) and kicks in when adsb.lol errors.

## Running locally

```sh
cd backend
npm install
npm run dev        # starts with --watch; restarts on file changes
```

The server binds to `0.0.0.0:8080` by default. Override with `PORT=<n>`.

## Database & ingestion (WP 1.4)

Postgres via **Drizzle ORM**; schema in `src/db/schema.ts` (two tables:
`registry`, `typecodes`). Migrations are **generated and committed** — no
raw-SQL drift.

```sh
npm run db:generate   # drizzle-kit generate → drizzle/*.sql (run after schema edits)
DATABASE_URL=… npm run db:migrate   # apply committed migrations to the target DB
```

Two ingest jobs populate the tables. Both are **runnable scripts, not cron** —
Fly.io machines (or a GitHub Action) schedule the refresh later (see the plan).
Both upsert idempotently, so re-runs are clean.

### DOC 8643 typecodes

```sh
DATABASE_URL=… npm run ingest:doc8643 -- ../ios/Tailspot/Tailspot/AircraftTypes.json
```

The **single source of truth** is the repo's `ios/Tailspot/Tailspot/AircraftTypes.json`
(2,612 entries: typecode → `{ make, model, type, rarity }`), the same table the
iOS client bundles. We deliberately do **not** copy it into `backend/`; the path
is an argument so a deploy can mount it.

> **Build-time copy note (for the Docker/Fly image):** the JSON lives outside
> `backend/`, so it isn't in the Docker build context by default. Either (a) build
> the image from the repo root with a context that includes `ios/.../AircraftTypes.json`
> and `COPY` it in, or (b) run `ingest:doc8643` from a machine/job that has the
> repo checked out and can reach `DATABASE_URL`. Until the deploy wires this, run
> the ingest manually from a checkout. The file is ~120 KB — cheap to mount.

### FAA Releasable Aircraft Database

```sh
# 1. Download + unzip (manual / cron — NOT done by the test suite).
#    IMPORTANT: the FAA's Akamai front 403s curl's DEFAULT User-Agent. Pass a
#    browser UA so the GET returns HTTP 200 with a valid ZIP body:
curl -L -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" \
  -o ReleasableAircraft.zip \
  https://registry.faa.gov/database/ReleasableAircraft.zip
unzip ReleasableAircraft.zip -d faa/           # → faa/MASTER.txt, faa/ACFTREF.txt (~250 MB unzipped)
# 2. Stream-parse + enrich + upsert:
DATABASE_URL=… npm run ingest:faa -- ./faa            # full registry
DATABASE_URL=… npm run ingest:faa -- ./faa --limit 1000   # smoke test
```

The importer **streams** `MASTER.txt` line-by-line (the files are large) joined
against `ACFTREF.txt` (manufacturer/model), keyed by `MODE S CODE HEX` → lowercase
`icao24`. US tails only, by construction.

**Typecode enrichment (WP 1.4b).** Each row's `MFR MDL CODE` is looked up in the
committed `data/faa-typecode-map.json` to attach an ICAO type designator
(`registry.typecode`), so `/v1/metadata/{icao24}` can merge in DOC 8643's clean
names + rarity (`source: "merged"`). A code with no mapping leaves `typecode` null
(`source: "faa"`, raw FAA names). The lookup is a flat Map read at runtime — no
fuzzy matching on the hot path. See **Rebuilding the typecode map** below.

> **Download UA requirement (verified 2026-06-10):** a `GET` with curl's default
> User-Agent **403s** at the Akamai edge; a browser UA (`Mozilla/5.0 …`) returns
> HTTP 200 with a valid ZIP. A bare `HEAD` returns 503 (a HEAD-method quirk, not
> an outage). If a scripted `GET` still 403s, download the zip manually from the
> FAA registry site and point `ingest:faa` at the extracted directory — the parser
> doesn't care how the files arrived.

### Rebuilding the typecode map (`data/faa-typecode-map.json`)

The committed map (`MFR MDL CODE` → ICAO designator) is built **offline** by a
reproducible Python script; the ingest reads it at runtime. Regenerate it when
the FAA registry or `AircraftTypes.json` changes:

```sh
# Download the FAA data with a browser UA (same Akamai requirement as above):
curl -L -A "Mozilla/5.0 ... Chrome/120.0 Safari/537.36" \
  -o /tmp/ReleasableAircraft.zip https://registry.faa.gov/database/ReleasableAircraft.zip
unzip /tmp/ReleasableAircraft.zip -d /tmp/faa/
python3 tools/build-typecode-map.py \
  --acftref /tmp/faa/ACFTREF.txt \
  --master  /tmp/faa/MASTER.txt \
  --out     data/faa-typecode-map.json
```

**Three-pass mapping strategy** (documented precedence; first hit wins):
1. **Family rules** — a curated `(canonical-make, model-prefix) → designator`
   table where the tail mass lives (Cessna 172\*, Piper PA-28\*, Beech 36\* …,
   each grounded in a DOC 8643 ModelFullName).
2. **Aircraft-characteristics xlsx join** — normalized FAA-naming join against
   `tools/data/faa_aircraft_characteristics.xlsx` (carries the ICAO designator).
3. **DOC 8643 normalized join** — `(make, model)` against `AircraftTypes.json`.
4. **Overrides** — a small per-code hand table for high-tail misses.

The script **validates** every emitted designator is a key in
`AircraftTypes.json` and runs ≥20 known-pair spot-checks (fails the build on a
mismatch), then reports **code-weighted and tail-weighted coverage** (the
MASTER.txt download is only needed for the tail-weighted number — omit `--master`
to skip it). `MASTER.txt`/`ACFTREF.txt` are **never committed**; only the
generated map is.

## Tests

```sh
npm test           # vitest run (in-process, no network)
```

Tests use Fastify's `app.inject()` transport — the server never opens a real TCP
socket, so tests are fast and cannot conflict with a running dev server.

Database-backed tests (metadata merge/route, the two ingest pipelines) run
against **PGlite** — an in-process WASM Postgres officially supported by Drizzle
(`drizzle-orm/pglite`) — so they exercise the real merge query, ON CONFLICT
upserts, and the registry→typecode join with **no Docker and no external DB**.
Each test builds a fresh PGlite instance and replays the committed migration SQL,
so the test schema is identical to a freshly-migrated production database. (The
combo was verified working in vitest before the service was built on it; the
in-memory `Map` fallback the plan allowed for wasn't needed.)

## Typecheck

```sh
npm run typecheck  # tsc --noEmit, reports type errors without emitting files
```

## Lint / format

```sh
npm run lint       # biome check src test
```

[Biome](https://biomejs.dev) handles both linting and formatting in a single
pass (no separate Prettier + ESLint config to keep in sync).

## Building for production

```sh
npm run build      # tsc → dist/
node dist/index.js
```

Or via Docker (multi-stage; final image uses only production deps):

```sh
docker build -t tailspot-api .
docker run -p 8080:8080 tailspot-api
```

## Deploying to Fly.io

```sh
fly deploy   # from this directory; uses fly.toml + Dockerfile
```

Primary region: `sjc` (San Jose, CA). See `fly.toml` for machine/VM config and
health-check settings. Secrets (Postgres URL, adsb.lol key, etc.) are set via
`fly secrets set KEY=value` — never committed to the repo. `DATABASE_URL` is the
Fly managed-Postgres connection string.

After provisioning Postgres and setting `DATABASE_URL`, apply migrations and seed
the metadata tables once (then on each refresh):

```sh
DATABASE_URL=… npm run db:migrate
DATABASE_URL=… npm run ingest:doc8643 -- <path-to-AircraftTypes.json>
DATABASE_URL=… npm run ingest:faa -- <extracted-FAA-dir>
```
