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

### Configuration (env)

| Var | Default | Meaning |
|---|---|---|
| `POSITION_PROVIDER` | `adsblol` | `adsblol` (primary) or `opensky` (OAuth2 fallback). Read once at startup. |
| `CACHE_TTL_SECONDS` | `10` | Fresh-cache window. |
| `STALE_MAX_SECONDS` | `60` | Max age of a last-good snapshot served on upstream failure. |
| `CACHE_TILE_SIZE_DEG` | `0.25` | Grid size for bbox→tile quantization. |
| `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET` | — | Required only when `POSITION_PROVIDER=opensky`. |

**Providers.** The primary is **adsb.lol** (`https://api.adsb.lol`), whose only
geographic query is point+radius (`GET /v2/point/{lat}/{lon}/{radius}`, radius
in NM) — so the adapter fetches the smallest circle covering the bbox and
filters back to the rectangle. readsb feeds report feet / knots and don't carry
`origin_country`, so the adapter converts to meters / m·s⁻¹ and derives the
country from the icao24 via the ICAO Annex 10 24-bit allocation table. The
**OpenSky** fallback (`/api/states/all`, OAuth2 client-credentials) is already
SI and supplies `origin_country` directly.

## Running locally

```sh
cd backend
npm install
npm run dev        # starts with --watch; restarts on file changes
```

The server binds to `0.0.0.0:8080` by default. Override with `PORT=<n>`.

## Tests

```sh
npm test           # vitest run (in-process, no network)
```

Tests use Fastify's `app.inject()` transport — the server never opens a real TCP
socket, so tests are fast and cannot conflict with a running dev server.

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
`fly secrets set KEY=value` — never committed to the repo.
