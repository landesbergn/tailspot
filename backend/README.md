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
