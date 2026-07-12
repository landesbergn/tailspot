# Backend Ops Runbook — api.tailspot.app

**Audience:** Noah (and future Claude sessions). Every command verified during
the actual first deploy on 2026-06-10. Companion to `backend/README.md`
(dev-loop docs); this file is production operations.

## The pieces

| Thing | Value |
|---|---|
| API app | Fly.io app `tailspot-api`, region `sjc`, one shared-CPU 256 MB machine, **scale-to-zero** (`auto_stop_machines`) |
| Database | Fly.io Postgres app `tailspot-db` (single node, 3 GB volume, same `sjc`) |
| Public hostname | `https://api.tailspot.app` (Namecheap: A `api` → 66.241.124.136, AAAA `api` → 2a09:8280:1::125:df95:0; TLS cert auto-managed by Fly) |
| Fallback hostname | `https://tailspot-api.fly.dev` (always works; useful to bisect DNS vs app problems) |
| Cost | ~$5–15/mo at beta scale (machine + volume); scale-to-zero keeps idle cost near the volume floor |

Secrets on the app (set, never committed): `DATABASE_URL` (written by
`fly postgres attach`), `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET`
(fallback provider creds, sourced from the local
`ios/Tailspot/Tailspot.secrets.xcconfig`).

## Is it up?

```sh
curl -s https://api.tailspot.app/healthz
# → {"status":"ok","version":"0.1.0"}
curl -s "https://api.tailspot.app/v1/aircraft?lamin=37.6&lomin=-122.6&lamax=38.1&lomax=-122.0" | head -c 300
curl -s https://api.tailspot.app/v1/metadata/a9eefa
# → Cirrus SR20, typecode SR20, source "merged" (the canary airframe)
```

First request after idle takes ~2–4 s (machine cold-starts from zero). That's
the scale-to-zero trade, not an outage.

```sh
fly status -a tailspot-api      # machine state
fly logs -a tailspot-api        # live request/error logs
fly status -a tailspot-db      # database health
```

## Deploy a new version

```sh
cd backend
fly deploy --remote-only        # builds the Dockerfile on Fly's builders
```

That's it — `fly.toml` + `Dockerfile` carry all config. Health-check gating is
built in: a deploy that fails `/healthz` doesn't replace the running machine.

**Rollback:** `fly releases -a tailspot-api` lists releases;
`fly deploy --image <previous image ref>` re-deploys the prior image (get the
ref from `fly releases --json`).

## Database migrations

Migrations are drizzle SQL files in `backend/drizzle/`, applied MANUALLY (no
auto-migrate on deploy — deliberate; a bad migration shouldn't ride along with
a routine code deploy). When a PR adds a migration:

```sh
fly proxy 15432:5432 -a tailspot-db &        # tunnel; leave running
cd backend && npm ci && DATABASE_URL='postgres://tailspot_api:<PW>@localhost:15432/tailspot_api?sslmode=disable' npm run db:migrate
kill %1                                       # stop the tunnel
```

The `tailspot_api` DB password is in the `DATABASE_URL` secret
(`fly ssh console -a tailspot-api -C "printenv DATABASE_URL"` if lost).

## Data ingestion (run on demand; not yet scheduled)

Both ingests run FROM YOUR MAC against the tunneled DB (the app machine is
256 MB — don't run them there). Always `npm run build` first: the ingest
scripts run from `dist/`, not source.

**DOC 8643 typecodes** (rerun whenever `AircraftTypes.json` regenerates):

```sh
node dist/ingest/doc8643.js ../ios/Tailspot/Tailspot/AircraftTypes.json
# → "doc8643: upserted 2612 typecodes"
```

**FAA registry** (refresh ~monthly; 313k US tails, ~5 min over the tunnel):

```sh
# Akamai 403s curl's default user agent — the browser UA is REQUIRED.
# (A bare HEAD returns 503; that's an Akamai quirk, not an outage.)
curl -sL -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" \
  -o /tmp/faa.zip https://registry.faa.gov/database/ReleasableAircraft.zip
unzip -o -q /tmp/faa.zip -d /tmp/faa-extracted
node dist/ingest/faa.js /tmp/faa-extracted
# → "faa: upserted 313523 registry rows" (typecodes attached via the committed map)
rm -rf /tmp/faa.zip /tmp/faa-extracted
```

After either ingest, verify the canary: `curl -s
https://api.tailspot.app/v1/metadata/a9eefa` must show `"source":"merged"`
with `"typecode":"SR20"`. If it shows raw ALL-CAPS names, the typecode map
didn't apply — check `backend/data/faa-typecode-map.json` exists in the build.

**Scheduling note:** when manual reruns get old, the cheap path is a Fly
scheduled machine (`fly machine run --schedule weekly`) running the ingest
image — tracked as a post-beta nicety, not built.

## Position provider controls

- `POSITION_PROVIDER` env (default `adsblol`): set `opensky` to fail over the
  whole app to the OpenSky adapter — `fly secrets set POSITION_PROVIDER=opensky
  -a tailspot-api` (machine restarts; reverse the same way). Use only for
  adsb.lol outages; OpenSky's terms make it a stopgap, not a home.
- Cache tuning: `CACHE_TTL_SECONDS` (default 10), `STALE_MAX_SECONDS` (60).
  Defaults are right until proven otherwise.

## When things look wrong

| Symptom | First move |
|---|---|
| App 503s, `/healthz` dead on BOTH hostnames | `fly status -a tailspot-api`; `fly machine restart <id>` |
| Works on fly.dev, dead on api.tailspot.app | DNS/cert: `fly certs check api.tailspot.app -a tailspot-api`; check Namecheap records unchanged |
| `/v1/aircraft` empty over a busy area | adsb.lol upstream: `curl https://api.adsb.lol/v2/point/37.8/-122.27/30`; if dead, flip `POSITION_PROVIDER=opensky` |
| `/v1/metadata` 404s for known US tails | Registry table empty/stale → rerun the FAA ingest |
| 429s reported by app users | Rate-limit counters are in-memory per machine; a restart clears them. If legit traffic trips them, raise the limits in code (WP 1.5 `RateLimiter` call sites) |
| Postgres disk filling | `fly volumes list -a tailspot-db`; catches are the only growing table — at beta scale this is years away |

## Standing cautions

- **Never commit secrets** — `fly secrets set` only. The repo-wide rules in
  CLAUDE.md apply to `DATABASE_URL` and the OpenSky pair here.
- **Migrations before deploys that need them** — the app does not auto-migrate;
  a deploy whose code expects a missing column will error at runtime, not boot.
- **The `tailspot` Fly app** (no `-api` suffix) is an empty stray from initial
  account setup — ignore or delete it in the dashboard; `tailspot-api` is the
  real one.
- **ODbL attribution** (adsb.lol) must ship in the app's About/credits before
  public beta — the data license requires it (drafted in `docs/legal/`).
